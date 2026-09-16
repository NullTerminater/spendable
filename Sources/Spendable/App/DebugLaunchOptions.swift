#if DEBUG
import AppKit
import Foundation
import GRDB
import os

/// Environment switches honoured by Debug builds only, so the measurement scripts and the builder
/// can drive the app without UI scripting. Nothing here exists in Release builds.
///
/// - `SPENDABLE_DEBUG_OPEN_WINDOW=1`: open the main window as soon as the menu bar item is up.
/// - `SPENDABLE_DEBUG_SEED_SAMPLE=1`: if there are no accounts, add three made-up manual ones.
/// - `SPENDABLE_DEBUG_MEMORY_CYCLE=N`: log the footprint at idle, then N times open the main
///   window, log, close it, log. The app stays running afterwards.
enum DebugLaunchOptions {
    private static let log = Logger(subsystem: StorePaths.bundleIdentifier, category: "debug")

    @MainActor
    static func apply(model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        if let fixture = environment["SPENDABLE_DEBUG_FIXTURE"] {
            Task {
                guard await waitForDatabase(model) != nil else { return }
                await model.replayConnectionFixture(fixture)
            }
        }
        if environment["SPENDABLE_DEBUG_SEED_SAMPLE"] != nil {
            Task { await seedSampleAccounts(model) }
        }
        if environment["SPENDABLE_DEBUG_OPEN_WINDOW"] != nil {
            MainWindowController.show(model: model)
        }
        if let cycles = environment["SPENDABLE_DEBUG_MEMORY_CYCLE"].flatMap(Int.init) {
            Task { await memoryCycle(model, cycles: max(1, cycles)) }
        }
        if let runs = environment["SPENDABLE_DEBUG_ENGINE_BENCH"].flatMap(Int.init) {
            Task { await benchmarkTheEngine(runs: max(1, runs)) }
        }
        if environment["SPENDABLE_DEBUG_CONNECT_DEMO"] != nil {
            Task { await connectToTheDemo(model) }
        }
    }

    /// Connects to SimpleFIN's own public demo, so the whole path — claim, store, sync, ingest —
    /// can be watched running without a real bank or a real token.
    ///
    /// It claims a fresh single-use token from SimpleFIN's developer page, exactly as the owner
    /// would paste one in milestone 4, and stores it under a **different** Keychain account from
    /// the real connection: Debug and Release share a bundle identifier and a login keychain, and
    /// one careless write would destroy an access URL that cannot be recovered without making a new
    /// token by hand.
    @MainActor
    private static func connectToTheDemo(_ model: AppModel) async {
        guard ProcessInfo.processInfo.environment["SPENDABLE_DEBUG_CONTAINER"] != nil else {
            log.error("demo connect refused: it only runs against a scratch container")
            DebugMeasurementLog.append("demo connect refused: set SPENDABLE_DEBUG_CONTAINER first")
            return
        }
        guard let database = await waitForDatabase(model) else { return }

        let store = model.credentialStore
        let client = SimpleFINClient()

        do {
            if try store.load() == nil {
                let guide = URL(string: "https://beta-bridge.simplefin.org/info/developers")!
                let (page, _) = try await URLSession(configuration: .ephemeral).data(from: guide)
                let text = String(decoding: page, as: UTF8.self)
                guard let token = text.firstMatch(of: try Regex("aHR0[A-Za-z0-9+/=]{40,}"))?.0 else {
                    DebugMeasurementLog.append("demo connect: no token on the developer page")
                    return
                }
                let claimURL = try SimpleFINClient.claimURL(fromSetupToken: String(token))
                let credential = try await client.claim(claimURL: claimURL)
                // Stored and read back before anything else: the token is spent either way.
                try store.save(credential)
                DebugMeasurementLog.append("demo connect: claimed and stored")
            }
        } catch let failure as SimpleFINFailure {
            DebugMeasurementLog.append("demo connect failed: \(failure.ownerFacingMessage)")
            return
        } catch {
            DebugMeasurementLog.append("demo connect failed while storing the credential")
            return
        }

        try? await database.writer.write { db in
            try SyncState.setDate(db, SyncState.connectedAt, Date())
        }
        guard let coordinator = model.syncCoordinator else { return }
        model.startScheduling()
        let report = await coordinator.sync(shape: .balancesAndTransactions)
        var verdict = "ok"
        if let problem = report.credentialProblem {
            verdict = problem
        } else if let failure = report.failure {
            verdict = "failure: " + failure.ownerFacingMessage
        } else if let refusal = report.refusal {
            verdict = "paused: " + refusal.ownerFacingMessage
        }
        if report.stillFillingHistory { verdict += " [still filling history]" }

        let counts = "\(report.requestsSpent) requests, \(report.windowsFetched) windows, "
            + "\(report.outcome.accountsInserted) accounts added, "
            + "\(report.outcome.transactionsInserted) transactions, "
            + "\(report.outcome.transactionsMatchedByContent) matched by content"
        let line = "demo sync: " + counts + ", " + verdict
        log.notice("\(line, privacy: .public)")
        DebugMeasurementLog.append(line)
    }

    /// Times the figure calculation on a load far past anything real: 40 accounts and 120 bills,
    /// including weekly ones, which is the worst case for expanding occurrences.
    @MainActor
    private static func benchmarkTheEngine(runs: Int) async {
        let calendar = Calendar.current
        let today = CalendarDay.today(in: calendar)
        var accounts: [Account] = []
        for index in 0..<40 {
            var account = Account.manual(
                displayName: "Account \(index)",
                type: [.checking, .savings, .cash, .credit][index % 4],
                balanceCents: Int64(index) * 1_000 + 500)
            account.id = Int64(index + 1)
            accounts.append(account)
        }
        var charges: [RecurringCharge] = []
        for index in 0..<120 {
            var charge = RecurringCharge.manual(
                name: "Bill \(index)", amountCents: Int64(index) * 100 + 199,
                cadence: Cadence.allCases[index % Cadence.allCases.count],
                nextDue: today.adding(days: -index % 40, in: calendar),
                payingAccountId: Int64(index % 40 + 1), calendar: calendar)
            charge.id = Int64(index + 1)
            charges.append(charge)
        }
        let schedule = PaySchedule(anchor: today.adding(days: -3, in: calendar))

        var slowest: Double = 0
        let start = Date()
        for _ in 0..<runs {
            let one = Date()
            _ = SafeToSpendEngine.compute(
                accounts: accounts, charges: charges, paySchedule: schedule,
                today: today, calendar: calendar)
            slowest = max(slowest, Date().timeIntervalSince(one))
        }
        let average = Date().timeIntervalSince(start) / Double(runs)
        let line = String(
            format: "engine %d accounts, %d bills: average %.3f ms, slowest %.3f ms over %d runs",
            accounts.count, charges.count, average * 1_000, slowest * 1_000, runs)
        log.notice("\(line, privacy: .public)")
        DebugMeasurementLog.append(line)
    }

    @MainActor
    private static func waitForDatabase(_ model: AppModel) async -> AppDatabase? {
        for _ in 0..<200 {
            if let database = model.database { return database }
            if model.startupError != nil { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    @MainActor
    private static func seedSampleAccounts(_ model: AppModel) async {
        guard let database = await waitForDatabase(model) else { return }
        do {
            try await database.writer.write { db in
                guard try Account.fetchCount(db) == 0 else { return }
                var wallet = Account.manual(displayName: "Wallet cash", type: .cash, balanceCents: 4_000)
                var savings = Account.manual(displayName: "Ally Savings", type: .savings, balanceCents: 120_000)
                var checking = Account.manual(displayName: "Chase Checking", type: .checking, balanceCents: 124_000)
                var card = Account.manual(displayName: "Chase Sapphire", type: .credit, balanceCents: -118_000)
                try wallet.insert(db)
                try savings.insert(db)
                try checking.insert(db)
                try card.insert(db)

                let today = CalendarDay.today()
                var rent = RecurringCharge.manual(
                    name: "Rent", amountCents: 50_000, cadence: .monthly,
                    nextDue: CalendarDay(year: today.year, month: today.month, day: 1),
                    payingAccountId: checking.id)
                var spotify = RecurringCharge.manual(
                    name: "Spotify", kind: .subscription, amountCents: 1_199, cadence: .monthly,
                    nextDue: today.adding(days: 6), payingAccountId: card.id)
                var insurance = RecurringCharge.manual(
                    name: "Car insurance", amountCents: 14_200, cadence: .quarterly,
                    nextDue: today.adding(days: 14), payingAccountId: checking.id)
                try rent.insert(db)
                try spotify.insert(db)
                try insurance.insert(db)
                try PaySchedule(anchor: today.adding(days: -3)).insert(db)
            }
            log.notice("seeded sample accounts")
        } catch {
            log.error("seeding failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    @MainActor
    private static func memoryCycle(_ model: AppModel, cycles: Int) async {
        guard await waitForDatabase(model) != nil else { return }
        try? await Task.sleep(for: .seconds(3))
        logFootprint("idle, menu bar only")
        for cycle in 1...cycles {
            MainWindowController.show(model: model)
            try? await Task.sleep(for: .seconds(3))
            logFootprint("cycle \(cycle): main window open")
            MainWindowController.closeForMeasurement()
            try? await Task.sleep(for: .seconds(3))
            logFootprint("cycle \(cycle): after window closed, window released = \(!MainWindowController.isOpen)")
        }
        log.notice("memory cycle done")
        DebugMeasurementLog.append("memory cycle done")
    }

    @MainActor
    private static func logFootprint(_ stage: String) {
        let text = MemoryFootprint.physicalMegabytesText()
        log.notice("footprint \(stage, privacy: .public): \(text, privacy: .public)")
        DebugMeasurementLog.append("footprint \(stage): \(text)")
    }
}
#endif
