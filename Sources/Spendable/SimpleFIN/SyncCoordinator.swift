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
    var skippedBecause: String?
    /// Balances came in. True even when the history walk then ran out of budget, because that is
    /// a working connection, not a failed one.
    var balancesRefreshed: Bool = false
    /// There is still history to fetch, and it will carry on tomorrow. Not a failure.
    var stillFillingHistory: Bool = false
    /// A sync was already running, so this trigger joined it rather than starting a second.
    var joinedARunInProgress: Bool = false

    /// A connection that is working. A budget refusal *after* balances arrived is not a failure —
    /// every first connection ends that way by design, and calling it an error would put a warning
    /// next to a bank that is working perfectly.
    var connectionIsWorking: Bool {
        credentialProblem == nil && (balancesRefreshed || skippedBecause != nil)
    }

    /// Something the owner needs to act on.
    var needsAttention: Bool {
        credentialProblem != nil || (failure != nil && !balancesRefreshed)
    }
}

/// Runs syncs, one at a time.
///
/// An actor alone is not enough: it serialises *statements*, not whole operations, so two triggers
/// arriving at once would each get past the budget check at a different `await` and each send a
/// request. The single-flight task below is what actually makes two triggers into one run.
actor SyncCoordinator {
    private let database: AppDatabase
    private let client: SimpleFINClient
    private let credentials: any CredentialStore
    private let calendar: Calendar
    private var inFlight: Task<SyncReport, Never>?
    private static let log = Logger(subsystem: StorePaths.bundleIdentifier, category: "sync")

    /// While history is still being filled in, leave this many requests for the day's ordinary
    /// refreshes and for the owner pressing Refresh. The walk is the lowest priority work there is.
    static let headroomForOrdinaryWork = 6

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

    /// Decides whether to sync at all, then does it. One run at a time.
    func syncIfDue(trigger: SyncPolicy.Trigger, now: Date = .now) async -> SyncReport {
        let decision: SyncPolicy.Decision
        do {
            let policy = try await database.reader.read { db in try SyncPolicy.load(db, now: now) }
            decision = policy.decide(trigger: trigger, now: now)
        } catch {
            return SyncReport(skippedBecause: "couldn't read when I last checked")
        }
        switch decision {
        case .skip(let why):
            return SyncReport(skippedBecause: why)
        case .sync(let shape):
            return await sync(shape: shape, now: now)
        }
    }

    /// Runs a sync, or joins the one already running.
    func sync(shape: SyncShape, now: Date = .now) async -> SyncReport {
        if let existing = inFlight {
            var report = await existing.value
            report.joinedARunInProgress = true
            return report
        }
        let task = Task { [shape, now] in await run(shape: shape, now: now) }
        inFlight = task
        let report = await task.value
        inFlight = nil
        return report
    }

    private func run(shape: SyncShape, now: Date) async -> SyncReport {
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

        // Recorded before the first request, so repeated wakes with no network back off instead of
        // spending the day's budget on requests the server never saw.
        try? await database.writer.write { db in try SyncState.setDate(db, SyncState.attemptedAt, now) }

        // Balances first, and from a request carrying no dates at all: a request with an end-date
        // is answered with the balance as of that date, so any other shape would write history into
        // today's figure.
        do {
            try await spend(.refresh)
            report.requestsSpent += 1
            let set = try await client.accounts(credential: credential, kind: .balances)
            report.outcome = try await database.writer.write { [calendar] db in
                let outcome = try SimpleFINIngest.ingest(set, kind: .balances, into: db, now: now, calendar: calendar)
                try SyncState.setDate(db, SyncState.balancesSyncedAt, now)
                try SyncState.setInteger(db, SyncState.failuresInARow, 0)
                return outcome
            }
            report.balancesRefreshed = true
        } catch let refusal as RequestBudget.Refusal {
            report.refusal = refusal
            return report
        } catch let failure as SimpleFINFailure {
            report.failure = failure
            await recordFailure()
            return report
        } catch {
            report.failure = .couldNotUnderstandAnswer
            await recordFailure()
            return report
        }

        guard shape == .balancesAndTransactions else { return report }

        await fetchTransactions(credential: credential, now: now, report: &report)
        return report
    }

    /// Catches the transaction history up: the recent gap first, then whatever backfill is left.
    private func fetchTransactions(
        credential: SimpleFINCredential, now: Date, report: inout SyncReport
    ) async {
        let today = CalendarDay(now, in: calendar)

        // The recent gap. Only when it fits in one window; a wider gap is left to the walk, which
        // asks in pieces the server will not trim.
        let watermark: CalendarDay? = try? await database.reader.read { [calendar] db in
            try Int64.fetchOne(db, sql: """
                SELECT MIN(tx_synced_through) FROM account
                 WHERE source = 'simplefin' AND archived_at IS NULL AND tx_synced_through IS NOT NULL
                """).map { CalendarDay(epochSeconds: $0, in: calendar) }
        } ?? nil

        if let window = BackfillPlan.incrementalWindow(since: watermark, today: today, calendar: calendar) {
            let fetched = await fetchWindow(window, credential: credential, purpose: .refresh, now: now, report: &report)
            if fetched {
                try? await database.writer.write { db in
                    try SyncState.setDate(db, SyncState.transactionsPulledAt, now)
                }
            }
            if report.failure != nil || report.refusal != nil { return }
        }

        await fillInHistory(credential: credential, today: today, now: now, report: &report)
    }

    /// Walks backwards through history, a window at a time, saving progress after each one so a
    /// crash, a quit or a spent budget resumes rather than starting again.
    private func fillInHistory(
        credential: SimpleFINCredential, today: CalendarDay, now: Date, report: inout SyncReport
    ) async {
        var progress: BackfillProgress
        do {
            progress = try await database.reader.read { db in try BackfillProgress.load(db) }
        } catch {
            return
        }
        guard progress.state == .running else { return }

        let windows = BackfillPlan.windows(endingOn: today, calendar: calendar)
        while progress.nextWindowIndex < windows.count {
            // The walk is the lowest priority work in the app: it stops while there is still room
            // needed for the day's refreshes and for the owner pressing Refresh.
            let remaining = (try? await database.reader.read { db in
                try RequestBudget.remaining(db, purpose: .refresh, now: Date())
            }) ?? 0
            guard remaining > Self.headroomForOrdinaryWork else {
                report.stillFillingHistory = true
                return
            }

            let window = windows[progress.nextWindowIndex]
            let before = report.outcome.transactionsInserted + report.outcome.transactionsMatchedByContent
            let fetched = await fetchWindow(window, credential: credential, purpose: .backfill, now: now, report: &report)
            guard fetched else {
                // A refused or failed window leaves progress exactly where it was, so the same span
                // is asked for again rather than stepped over. Either way the walk is unfinished:
                // saying otherwise would tell the owner their history is complete when months of
                // it never arrived.
                report.stillFillingHistory = true
                try? await database.writer.write { [progress] db in try progress.save(db) }
                return
            }

            let after = report.outcome.transactionsInserted + report.outcome.transactionsMatchedByContent
            progress.consecutiveEmptyWindows = after > before ? 0 : progress.consecutiveEmptyWindows + 1
            progress.nextWindowIndex += 1
            progress.coveredBackTo = window.lowerBound.isoString
            if progress.consecutiveEmptyWindows >= 2 { progress.state = .exhausted }
            if progress.nextWindowIndex >= windows.count { progress.state = .reachedLimit }
            try? await database.writer.write { [progress] db in try progress.save(db) }
            if progress.state != .running { return }
        }
    }

    /// Fetches one window and stores it. Returns false when nothing was fetched.
    private func fetchWindow(
        _ window: ClosedRange<CalendarDay>, credential: SimpleFINCredential,
        purpose: RequestBudget.Purpose, now: Date, report: inout SyncReport
    ) async -> Bool {
        do {
            try await spend(purpose)
        } catch let refusal as RequestBudget.Refusal {
            report.refusal = refusal
            return false
        } catch {
            return false
        }
        report.requestsSpent += 1

        do {
            let kind = SimpleFINRequestKind.window(start: window.lowerBound, end: window.upperBound)
            let set = try await client.accounts(credential: credential, kind: kind)
            let outcome = try await database.writer.write { [calendar] db in
                try SimpleFINIngest.ingest(set, kind: kind, into: db, now: now, calendar: calendar)
            }
            report.windowsFetched += 1
            report.outcome.transactionsInserted += outcome.transactionsInserted
            report.outcome.transactionsMatchedByContent += outcome.transactionsMatchedByContent
            report.outcome.pendingSuperseded += outcome.pendingSuperseded
            report.outcome.pendingVoided += outcome.pendingVoided
            return true
        } catch let failure as SimpleFINFailure {
            report.failure = failure
            Self.log.error("a window failed; progress left where it was")
            return false
        } catch {
            report.failure = .couldNotUnderstandAnswer
            return false
        }
    }

    /// Takes a request from the budget before it is sent, stamped with the wall clock: a history
    /// walk runs for minutes, and recording every window at the same instant would make them all
    /// fall out of the rolling window together.
    private func spend(_ purpose: RequestBudget.Purpose) async throws {
        try await database.writer.write { db in
            _ = try RequestBudget.reserve(db, purpose: purpose, now: Date())
        }
    }

    private func recordFailure() async {
        try? await database.writer.write { db in
            let count = try SyncState.integer(db, SyncState.failuresInARow)
            try SyncState.setInteger(db, SyncState.failuresInARow, count + 1)
        }
    }
}
