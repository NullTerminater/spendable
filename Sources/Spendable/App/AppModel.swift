import AppKit
import Foundation
import GRDB
import Observation
import os
#if DEBUG
import Security
#endif

/// Process-owned database, connection, and the only coordinator/scheduler in the app.
@MainActor
@Observable
final class AppModel {
    private(set) var database: AppDatabase?
    private(set) var store: SpendableStore?
    private(set) var startupError: String?
    private(set) var syncCoordinator: SyncCoordinator?
    private(set) var unsavedConnection: SimpleFINCredential?
    private(set) var setupState: SetupState = .checking
    private(set) var setupMessage: String?
    private(set) var banner: ConnectionBanner?
    private(set) var syncMessage: String?
    private(set) var isSyncing = false
    var setupScreenRequested = false
    let credentialStore: any CredentialStore

    @ObservationIgnored private var historyObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var scheduler: NSBackgroundActivityScheduler?
    @ObservationIgnored private var network: NetworkReadiness?
    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private let client: SimpleFINClient
    @ObservationIgnored private let runsSystemActivity: Bool
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isSaving = false
    @ObservationIgnored private var connectionGeneration = 0
    @ObservationIgnored private var hasRejectedConnection = false
    @ObservationIgnored private var rejectedMessage: String?
    @ObservationIgnored private var awaitingFirstBalance = false
    @ObservationIgnored private var unverifiedReplacementApproved = false
    @ObservationIgnored private var replacementOf: SimpleFINCredential?
    @ObservationIgnored private var lastClaimAttempt: Date?
    @ObservationIgnored private var refreshing = 0
    private static let log = Logger(subsystem: StorePaths.bundleIdentifier, category: "startup")

    init(credentialStore: (any CredentialStore)? = nil, client: SimpleFINClient = SimpleFINClient()) {
        self.credentialStore = credentialStore ?? Self.liveCredentialStore()
        self.client = client
        self.runsSystemActivity = true
    }

    /// Tests use in-memory stores and no OS activity, network monitor, or owner's Keychain.
    init(database: AppDatabase, credentialStore: any CredentialStore = InMemoryCredentialStore(),
         client: SimpleFINClient = SimpleFINClient()) {
        self.database = database
        self.credentialStore = credentialStore
        self.client = client
        self.runsSystemActivity = false
        self.store = SpendableStore(database: database)
        self.syncCoordinator = SyncCoordinator(database: database, client: client, credentials: credentialStore)
        self.started = true
    }

    isolated deinit {
        scheduler?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
    }

    private static func liveCredentialStore() -> any CredentialStore {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SPENDABLE_DEBUG_FIXTURE"] == "locked" { return LockedFixtureCredentialStore() }
        if ProcessInfo.processInfo.environment["SPENDABLE_DEBUG_FIXTURE"] != nil { return InMemoryCredentialStore() }
        if ProcessInfo.processInfo.environment["SPENDABLE_DEBUG_CONTAINER"] != nil {
            return KeychainCredentialStore(account: KeychainCredentialStore.demoAccount)
        }
        #endif
        return KeychainCredentialStore()
    }

    func start() {
        guard !started else { return }
        started = true
        guard !ProcessInfo.processInfo.isRunningTests else { return }
        Task {
            do {
                let opened = try await Task.detached(priority: .userInitiated) {
                    try AppDatabase.open(at: StorePaths.live().databaseURL)
                }.value
                database = opened
                store = SpendableStore(database: opened)
                syncCoordinator = SyncCoordinator(database: opened, client: client, credentials: credentialStore)
                network = NetworkReadiness()
                Self.log.info("database ready")
                let connected = try await opened.reader.read { db in
                    try SyncState.date(db, SyncState.connectedAt) != nil
                }
                try await restoreRejectionState()
                if connected {
                    startScheduling()
                    await refresh(trigger: .launch)
                }
            } catch {
                startupError = "Spendable couldn't open its storage. Quit and open it again; if this keeps happening, tell the developer."
                Self.log.error("database failed to open")
            }
        }
    }

    func prepareSetup() async {
        guard unsavedConnection == nil else { setupState = .unsaved; return }
        guard setupState != .claiming, !isSaving else { return }
        setupState = .checking
        do {
            try await restoreRejectionState()
            let existing = try await Task.detached { [credentialStore] in try credentialStore.load() }.value
            if existing != nil, let database {
                // A claim is durable once the verified Keychain write succeeds. Repair the small
                // crash gap before its database bookkeeping without consuming another token.
                let repaired = try await database.writer.write { db in
                    guard try SyncState.date(db, SyncState.connectedAt) == nil else { return false }
                    try SyncState.setDate(db, SyncState.connectedAt, .now)
                    if try SyncState.date(db, SyncState.balancesSyncedAt) == nil {
                        try SyncState.setInteger(db, "awaiting-first-balance", 1)
                    }
                    return true
                }
                if repaired { try await restoreRejectionState(); startScheduling() }
            }
            if hasRejectedConnection, let existing {
                if awaitingFirstBalance && !unverifiedReplacementApproved {
                    replacementOf = nil
                    setupState = .freshCredentialRejected
                    banner = .freshCredentialRejected(rejectedMessage)
                    setupMessage = nil
                    return
                }
                banner = .rejected(rejectedMessage)
                replacementOf = existing
                setupState = .ready
                setupMessage = "Paste a fresh setup token to repair this connection. Your accounts, history and corrections will stay here."
            } else {
                replacementOf = nil
                setupState = existing != nil ? .alreadyConnected : .ready
                if banner == .keychain { banner = nil }
            }
        } catch {
            setupState = .keychainUnavailable
            banner = .keychain
        }
    }

    private func restoreRejectionState() async throws {
        guard let database else { return }
        let generation = connectionGeneration
        let state = try await database.reader.read { db in
            (try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: ["credential-rejected"]),
             try SyncState.integer(db, "awaiting-first-balance") != 0,
             try SyncState.integer(db, "unverified-replacement-approved") != 0)
        }
        guard generation == connectionGeneration else { return }
        hasRejectedConnection = state.0 != nil
        rejectedMessage = state.0.flatMap { $0.isEmpty ? nil : $0 }
        awaitingFirstBalance = state.1
        unverifiedReplacementApproved = state.2
        if hasRejectedConnection {
            banner = awaitingFirstBalance && !unverifiedReplacementApproved
                ? .freshCredentialRejected(rejectedMessage) : .rejected(rejectedMessage)
            if awaitingFirstBalance && !unverifiedReplacementApproved {
                syncMessage = ConnectionPresentation.freshCredentialRejected
            }
        }
    }

    /// Called only after the owner confirms the warning on the first-rejection banner.
    func approveRejectedReplacement() async {
        guard hasRejectedConnection, awaitingFirstBalance, let database else { return }
        do {
            try await database.writer.write { db in
                try SyncState.setInteger(db, "unverified-replacement-approved", 1)
            }
            unverifiedReplacementApproved = true
            syncMessage = nil
            setupScreenRequested = true
            await prepareSetup()
        } catch {
            syncMessage = "I couldn't save that choice. Your current connection is still saved; try again."
        }
    }

    /// The caller clears its text and undo buffer before starting this operation.
    func claimConnection(at claimURL: URL, now: Date = .now) async {
        guard setupState == .ready, unsavedConnection == nil else { return }
        setupState = .claiming
        setupMessage = "Asking SimpleFIN for your accounts…"
        // Recheck immediately before spending the token. A failed read is never absence.
        do {
            let existing = try await Task.detached { [credentialStore] in try credentialStore.load() }.value
            guard existing == replacementOf else { setupState = .alreadyConnected; setupMessage = nil; return }
        } catch {
            setupState = .keychainUnavailable
            banner = .keychain
            setupMessage = nil
            return
        }
        let recentAttempt = lastClaimAttempt.map { now.timeIntervalSince($0) < 3_600 } ?? false
        lastClaimAttempt = now
        do {
            unsavedConnection = try await client.claim(claimURL: claimURL)
            setupState = .unsaved
            await retrySavingConnection()
        } catch let failure as SimpleFINFailure {
            setupState = .ready
            if case .couldNotReachServer = failure {
                setupMessage = ConnectionPresentation.droppedClaim
            } else if failure == .tokenAlreadyUsed && recentAttempt {
                setupMessage = ConnectionPresentation.locallyUsedToken
            } else {
                setupMessage = failure.ownerFacingMessage
            }
        } catch {
            setupState = .ready
            setupMessage = ConnectionPresentation.droppedClaim
        }
    }

    /// Retry only saves the retained claim. It never asks the server to claim a token twice.
    func retrySavingConnection() async {
        guard !isSaving, let credential = unsavedConnection, let database else { return }
        isSaving = true
        connectionGeneration += 1
        await syncCoordinator?.pauseForCredentialChange()
        defer { isSaving = false }
        do {
            let isReplacement = replacementOf != nil
            try await Task.detached { [credentialStore, replacementOf] in
                if try credentialStore.load() == credential { return }
                if let replacementOf { try credentialStore.replace(credential, expected: replacementOf) }
                else { try credentialStore.save(credential) }
            }.value
            try await database.writer.write { db in
                if try SyncState.date(db, SyncState.connectedAt) == nil {
                    try SyncState.setDate(db, SyncState.connectedAt, Date())
                }
                try SyncState.clear(db, "credential-rejected")
                try SyncState.setInteger(db, "awaiting-first-balance", 1)
                try SyncState.clear(db, "unverified-replacement-approved")
                if isReplacement {
                    try BackfillProgress().save(db)
                    try SyncState.clear(db, SyncState.transactionsPulledAt)
                }
            }
            unsavedConnection = nil
            replacementOf = nil
            hasRejectedConnection = false
            rejectedMessage = nil
            awaitingFirstBalance = true
            unverifiedReplacementApproved = false
            banner = nil
            setupState = .connected
            setupMessage = "Connected. Getting your accounts and past spending — you don't need to wait here."
            await syncCoordinator?.resumeAfterCredentialChange()
            startScheduling()
            Task { await refresh() }
        } catch {
            await syncCoordinator?.resumeAfterCredentialChange()
            setupState = .unsaved
            banner = .unsaved
            setupMessage = nil
        }
    }

    func refresh(trigger: SyncPolicy.Trigger = .manual) async {
        guard let coordinator = syncCoordinator else { return }
        if trigger == .launch || trigger == .wake || trigger == .dayChanged, let network {
            guard await network.waitUntilOnline() else { return }
        }
        refreshing += 1
        isSyncing = true
        defer {
            refreshing -= 1
            isSyncing = refreshing > 0
            if !isSyncing { historyObservation?.cancel(); historyObservation = nil }
        }
        observeHistoryProgress()
        if trigger == .manual { syncMessage = "Checking your balances and past spending…" }
        let generation = connectionGeneration
        let report = await coordinator.syncIfDue(trigger: trigger)
        await receive(report, generation: generation)
    }

    private func observeHistoryProgress() {
        guard historyObservation == nil, let database else { return }
        historyObservation = ValueObservation.tracking { db in
            try BackfillProgress.load(db).coveredBackTo
        }.removeDuplicates().start(in: database.reader, scheduling: .async(onQueue: .main), onError: { _ in }, onChange: { [weak self] day in
            Task { @MainActor in
                guard let self, self.isSyncing, let day, let date = CalendarDay(isoString: day) else { return }
                self.syncMessage = "Getting your past spending — I've gone back as far as \(date.shortPhrase()) so far. You don't need to wait for this."
            }
        })
    }

    private func receive(_ report: SyncReport, generation: Int) async {
        guard generation == connectionGeneration else { return }
        let stored = try? await database?.reader.read { db in
            (try SyncState.date(db, SyncState.balancesSyncedAt),
             try SyncState.integer(db, "awaiting-first-balance") != 0,
             try SyncState.integer(db, "unverified-replacement-approved") != 0)
        }
        // The credential may have changed while the database read was suspended.
        guard generation == connectionGeneration else { return }
        if let stored {
            awaitingFirstBalance = stored.1
            unverifiedReplacementApproved = stored.2
        }
        if unsavedConnection != nil { banner = .unsaved }
        else if report.credentialProblem != nil { banner = .keychain }
        else if case .credentialRejected(let message) = report.failure {
            hasRejectedConnection = true
            rejectedMessage = message
            if awaitingFirstBalance && !unverifiedReplacementApproved {
                banner = .freshCredentialRejected(message)
                setupState = .freshCredentialRejected
                setupMessage = nil
            } else {
                banner = .rejected(message)
            }
        }
        else if report.balancesRefreshed {
            hasRejectedConnection = false
            rejectedMessage = nil
            banner = nil
            if setupState == .freshCredentialRejected { setupState = .connected }
        }
        if case .freshCredentialRejected = banner {
            syncMessage = ConnectionPresentation.freshCredentialRejected
        } else if let message = ConnectionPresentation.message(report, lastBalances: stored?.0) {
            syncMessage = message
        }
        if setupState == .connected, report.connectionIsWorking {
            setupMessage = report.outcome.accountsSeen == 0 && report.outcome.notices.isEmpty
                ? ConnectionPresentation.emptyConnection
                : "Connected. I found \(report.outcome.accountsSeen) \(report.outcome.accountsSeen == 1 ? "account" : "accounts")."
        }
        #if DEBUG
        DebugMeasurementLog.append("sync finished: \(report.requestsSpent) requests; \(report.windowsFetched) history requests")
        #endif
    }

    func retryKeychain() async {
        if unsavedConnection != nil { await retrySavingConnection(); return }
        await prepareSetup()
        if setupState == .alreadyConnected || setupState == .freshCredentialRejected { await refresh() }
    }

    func startScheduling() {
        guard runsSystemActivity, scheduler == nil, let coordinator = syncCoordinator else { return }
        let activity = NSBackgroundActivityScheduler(identifier: "com.nullterminater.spendable.sync")
        activity.interval = 6 * 3_600
        activity.tolerance = 3_600
        activity.qualityOfService = .utility
        activity.repeats = true
        activity.schedule { [weak self, coordinator] completion in
            Task { @MainActor [weak self] in
                if let self {
                    self.refreshing += 1
                    self.isSyncing = true
                    self.observeHistoryProgress()
                }
                defer {
                    if let self {
                        self.refreshing -= 1
                        self.isSyncing = self.refreshing > 0
                        if !self.isSyncing { self.historyObservation?.cancel(); self.historyObservation = nil }
                    }
                }
                let generation = self?.connectionGeneration ?? -1
                let report = await SyncActivity.run(coordinator: coordinator) { completion(.finished) }
                await self?.receive(report, generation: generation)
            }
        }
        scheduler = activity
        if observers.isEmpty {
            let workspace = NSWorkspace.shared.notificationCenter
            observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh(trigger: .wake) }
            }))
            let center = NotificationCenter.default
            observers.append((center, center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh(trigger: .dayChanged) }
            }))
        }
    }

    /// Prepared for milestone 9's disconnect UI.
    func stopScheduling() async throws {
        scheduler?.invalidate()
        scheduler = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        try await database?.writer.write { db in
            for key in [SyncState.connectedAt, SyncState.failuresInARow, SyncState.attemptedAt] {
                try SyncState.clear(db, key)
            }
        }
    }

    static func openSimpleFIN() {
        NSWorkspace.shared.open(URL(string: "https://beta-bridge.simplefin.org/")!)
    }

    static func openKeychainAccess() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

#if DEBUG
/// A named fixture must keep failing after the setup view rechecks the Keychain.
private final class LockedFixtureCredentialStore: CredentialStore {
    func load() throws -> SimpleFINCredential? {
        throw CredentialStoreError.keychain(errSecInteractionNotAllowed, while: .reading)
    }
    func save(_ credential: SimpleFINCredential) throws {}
    func delete() throws {}
}

extension AppModel {
    func replayConnectionFixture(_ name: String) async {
        guard ProcessInfo.processInfo.environment["SPENDABLE_DEBUG_CONTAINER"] != nil,
              let database else { return }
        let now = Date()
        if name != "setup" {
            let credential = SimpleFINCredential(baseURL: URL(string: "https://simplefin.invalid/simplefin")!, username: "fixture", password: "fixture")!
            try? credentialStore.save(credential)
            try? await database.writer.write { db in
                try SyncState.setDate(db, SyncState.connectedAt, now)
                if name != "fresh-rejected" {
                    try SyncState.setDate(db, SyncState.balancesSyncedAt, now)
                    try SyncState.setDate(db, SyncState.transactionsPulledAt, now)
                }
            }
            startScheduling()
        }
        switch name {
        case "rejected", "fresh-rejected":
            try? await database.writer.write { db in
                try SyncState.set(db, "credential-rejected", "Synthetic rejected connection.")
                if name == "fresh-rejected" {
                    try SyncState.setInteger(db, "awaiting-first-balance", 1)
                    try SyncState.clear(db, "unverified-replacement-approved")
                }
            }
            try? await restoreRejectionState()
            if name == "fresh-rejected" { setupState = .freshCredentialRejected }
        case "locked": banner = .keychain
        case "unsaved":
            unsavedConnection = SimpleFINCredential(baseURL: URL(string: "https://simplefin.invalid/simplefin")!, username: "fixture", password: "fixture")!
            setupState = .unsaved; banner = .unsaved
        case "empty": setupState = .connected; setupMessage = ConnectionPresentation.emptyConnection
        case "accounts":
            try? await database.writer.write { db in
                guard try Account.fetchCount(db) == 0 else { return }
                var manual = Account.manual(displayName: "Chase Checking", type: .checking, balanceCents: 120000, now: now)
                try manual.insert(db)
                var wallet = Account.manual(displayName: "Wallet", type: .cash, balanceCents: 6000, now: now)
                try wallet.insert(db)
                var synced = Account.manual(displayName: "Chase Total Checking", type: .checking, balanceCents: 124018, now: now)
                synced.source = .simplefin; synced.userType = nil; synced.guessedType = .checking
                synced.guessedFromName = "Chase Total Checking"; synced.remoteName = "Chase Total Checking"
                synced.connId = "SYNTHETIC-CHASE"; synced.connName = "Chase"
                synced.holdingsObservedAt = Int64(now.timeIntervalSince1970); synced.availableCents = 94000
                try synced.insert(db)
                manual.mergeCandidateFor = synced.id; try manual.update(db)
                var unknown = Account.manual(displayName: "SoFi Money", type: .checking, balanceCents: 350000, now: now)
                unknown.source = .simplefin; unknown.userType = nil
                unknown.holdingsObservedAt = Int64(now.timeIntervalSince1970); try unknown.insert(db)
                var savings = Account.manual(displayName: "Ally Savings", type: .savings, balanceCents: 800000, now: now)
                try savings.insert(db)
                var foreign = Account.manual(displayName: "Tangerine Savings", type: .savings, balanceCents: 240000, now: now)
                foreign.currency = "CAD"; try foreign.insert(db)
                var rent = RecurringCharge.manual(name: "Rent", amountCents: 50000, cadence: .monthly,
                    nextDue: CalendarDay(now), payingAccountId: manual.id)
                try rent.insert(db)
            }
        default: break
        }
    }
}
#endif
