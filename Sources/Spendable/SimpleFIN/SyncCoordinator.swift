import Foundation
import GRDB
import os

/// What one sync did, in terms the app can show and the log can keep.
struct SyncReport: Sendable {
    var requestsSpent: Int = 0
    var windowsFetched: Int = 0
    var outcome: SyncOutcome = SyncOutcome()
    var failure: SimpleFINFailure?
    var refusal: RequestBudget.Refusal?
    var credentialProblem: String?
    var finishedBackfill: Bool = false

    var succeeded: Bool { failure == nil && refusal == nil && credentialProblem == nil }
}

/// Runs syncs, one at a time.
///
/// An actor, so the six-hourly activity, a launch poll, a wake, a day change and the owner pressing
/// Refresh cannot each read the same request count and each decide they have room. Two triggers at
/// the same instant become one run.
actor SyncCoordinator {
    enum Reason: Sendable {
        case launch
        case scheduled
        case manual
        case firstConnection
    }

    private let database: AppDatabase
    private let client: SimpleFINClient
    private let credentials: any CredentialStore
    private let calendar: Calendar
    private static let log = Logger(subsystem: StorePaths.bundleIdentifier, category: "sync")

    init(
        database: AppDatabase,
        client: SimpleFINClient = SimpleFINClient(),
        credentials: any CredentialStore = KeychainCredentialStore(),
        calendar: Calendar = .current
    ) {
        self.database = database
        self.client = client
        self.credentials = credentials
        self.calendar = calendar
    }

    /// Reads balances, then fills in whatever history is still missing, within the day's budget.
    func sync(reason: Reason, now: Date = .now) async -> SyncReport {
        var report = SyncReport()

        let credential: SimpleFINCredential
        do {
            guard let stored = try credentials.load() else {
                report.credentialProblem = "No bank connection saved yet."
                return report
            }
            credential = stored
        } catch let error as CredentialStoreError {
            // A locked keychain is not a bank rejecting the connection, and must never send the
            // owner off to burn a setup token they did not need to burn.
            report.credentialProblem = error.ownerFacingMessage
            return report
        } catch {
            report.credentialProblem = CredentialStoreError.encoding.ownerFacingMessage
            return report
        }

        // Balances first, and from a request carrying no dates at all: a request with an end-date
        // is answered with the balance as of that date, so any other shape would write history into
        // today's figure.
        do {
            try await spend(.refresh, now: now)
            report.requestsSpent += 1
            let set = try await client.accounts(credential: credential, kind: .balances)
            report.outcome = try await database.writer.write { [calendar] db in
                try SimpleFINIngest.ingest(set, kind: .balances, into: db, now: now, calendar: calendar)
            }
        } catch let refusal as RequestBudget.Refusal {
            report.refusal = refusal
            return report
        } catch let failure as SimpleFINFailure {
            report.failure = failure
            return report
        } catch {
            report.failure = .couldNotUnderstandAnswer
            return report
        }

        await fillInHistory(credential: credential, now: now, report: &report)
        return report
    }

    /// Walks backwards through history, a window at a time, saving progress after each one so a
    /// crash, a quit or a spent budget resumes rather than starting again.
    private func fillInHistory(
        credential: SimpleFINCredential, now: Date, report: inout SyncReport
    ) async {
        let today = CalendarDay(now, in: calendar)
        var progress: BackfillProgress
        do {
            progress = try await database.reader.read { db in try BackfillProgress.load(db) }
        } catch {
            return
        }
        guard progress.state == .running else {
            report.finishedBackfill = true
            return
        }

        let windows = BackfillPlan.windows(endingOn: today, calendar: calendar)
        while progress.nextWindowIndex < windows.count {
            let window = windows[progress.nextWindowIndex]
            do {
                try await spend(.backfill, now: now)
            } catch let refusal as RequestBudget.Refusal {
                report.refusal = refusal
                return
            } catch {
                return
            }
            report.requestsSpent += 1

            do {
                let set = try await client.accounts(
                    credential: credential,
                    kind: .window(start: window.lowerBound, end: window.upperBound))
                let outcome = try await database.writer.write { [calendar] db in
                    try SimpleFINIngest.ingest(
                        set, kind: .window(start: window.lowerBound, end: window.upperBound),
                        into: db, now: now, calendar: calendar)
                }
                report.windowsFetched += 1
                report.outcome.transactionsInserted += outcome.transactionsInserted
                report.outcome.transactionsMatchedByContent += outcome.transactionsMatchedByContent
                report.outcome.pendingSuperseded += outcome.pendingSuperseded
                report.outcome.pendingVoided += outcome.pendingVoided

                let foundSomething = outcome.transactionsInserted > 0 || outcome.transactionsMatchedByContent > 0
                progress.consecutiveEmptyWindows = foundSomething ? 0 : progress.consecutiveEmptyWindows + 1
                progress.nextWindowIndex += 1
                progress.coveredBackTo = window.lowerBound.isoString
                // Two windows in a row with nothing in them: there is no more history to find.
                if progress.consecutiveEmptyWindows >= 2 { progress.state = .exhausted }
                if progress.nextWindowIndex >= windows.count { progress.state = .reachedLimit }
            } catch let failure as SimpleFINFailure {
                // A failed window leaves progress exactly where it was, so the same span is asked
                // for again rather than stepped over.
                report.failure = failure
                Self.log.error("backfill window failed; progress unchanged")
                try? await database.writer.write { [progress] db in try progress.save(db) }
                return
            } catch {
                try? await database.writer.write { [progress] db in try progress.save(db) }
                return
            }

            try? await database.writer.write { [progress] db in try progress.save(db) }
            if progress.state != .running {
                report.finishedBackfill = true
                return
            }
        }
        report.finishedBackfill = true
    }

    /// Takes a request from the budget before it is sent.
    ///
    /// Stamped with the wall clock rather than the sync's own start time: a history walk runs for
    /// minutes, and recording every window at the same instant would make them all fall out of the
    /// rolling window together. The budget's own arithmetic is tested with injected times.
    private func spend(_ purpose: RequestBudget.Purpose, now: Date) async throws {
        try await database.writer.write { db in
            _ = try RequestBudget.reserve(db, purpose: purpose, now: Date())
        }
    }
}
