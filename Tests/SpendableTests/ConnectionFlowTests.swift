import Foundation
import GRDB
import Security
import Synchronization
import Testing
@testable import Spendable

/// A separate protocol and per-host registry keep this suite independent of StubServer and of
/// other tests running at the same time. A missing route fails locally, never uses the network.
private final class ConnectionFlowProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var error: URLError.Code?
        var delay: TimeInterval = 0
    }
    struct Request: Sendable {
        let method: String
        let isWindow: Bool
    }
    final class Route: Sendable {
        let requests = Mutex<[Request]>([])
        let answer: @Sendable (URLRequest) -> Reply
        init(answer: @escaping @Sendable (URLRequest) -> Reply) { self.answer = answer }
    }
    static let routes = Mutex<[String: Route]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let route = Self.routes.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let window = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "start-date" } == true
        route.requests.withLock { $0.append(Request(method: request.httpMethod ?? "GET", isWindow: window)) }
        let reply = route.answer(request)
        if reply.delay > 0 { Thread.sleep(forTimeInterval: reply.delay) }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: URLError(error)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct ConnectionFlowServer: Sendable {
    let host: String
    let session: URLSession
    let route: ConnectionFlowProtocol.Route
    init(answer: @escaping @Sendable (URLRequest) -> ConnectionFlowProtocol.Reply) {
        host = "flow-\(UUID().uuidString.lowercased()).example.test"
        route = ConnectionFlowProtocol.Route(answer: answer)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionFlowProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
        ConnectionFlowProtocol.routes.withLock { $0[host] = route }
    }
    var client: SimpleFINClient { SimpleFINClient(session: session) }
    var base: URL { URL(string: "https://\(host)/simplefin")! }
    var claimURL: URL { base.appendingPathComponent("claim/synthetic-test") }
    var requests: [ConnectionFlowProtocol.Request] { route.requests.withLock { $0 } }
    func credential(_ name: String = "new") -> SimpleFINCredential {
        SimpleFINCredential(baseURL: base, username: name, password: "synthetic-password")!
    }
    func close() {
        session.finishTasksAndInvalidate()
        _ = ConnectionFlowProtocol.routes.withLock { $0.removeValue(forKey: host) }
    }
    static func claimBody(for request: URLRequest, user: String = "new") -> Data {
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.path = "/simplefin"
        components.query = nil
        components.user = user
        components.password = "synthetic-password"
        return Data(components.string!.utf8)
    }
    static let empty = Data(#"{"errlist":[],"accounts":[],"connections":[]}"#.utf8)
    static func accounts(for request: URLRequest, transactions: Bool = false) -> Data {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let startText = items.first { $0.name == "start-date" }?.value
        let start = startText.flatMap { Int64($0) }
        let rows: [[String: Any]] = transactions && start != nil ? [
            ["id": "transaction-\(start!)", "posted": start! + 3600, "amount": "-5.00", "description": "Synthetic coffee"]
        ] : []
        let account: [String: Any] = [
            "id": "checking", "conn_id": "CON-1", "name": "Chase Checking", "currency": "USD",
            "balance": "1240.18", "available-balance": "940.00", "balance-date": Int64(Date().timeIntervalSince1970),
            "holdings": [], "transactions": rows,
        ]
        return try! JSONSerialization.data(withJSONObject: [
            "errlist": [], "connections": [["conn_id": "CON-1", "name": "Chase", "org_id": "ORG"]],
            "accounts": [account],
        ] as [String: Any])
    }
}

private final class FlowCredentialStore: CredentialStore {
    struct State: Sendable {
        var credential: SimpleFINCredential?
        var loadError: CredentialStoreError?
        var writesToFail = 0
        var saves = 0
        var replacements = 0
    }
    let state: Mutex<State>
    init(_ credential: SimpleFINCredential? = nil, loadError: CredentialStoreError? = nil, writesToFail: Int = 0) {
        state = Mutex(State(credential: credential, loadError: loadError, writesToFail: writesToFail))
    }
    func load() throws -> SimpleFINCredential? {
        try state.withLock {
            if let error = $0.loadError { throw error }
            return $0.credential
        }
    }
    func save(_ credential: SimpleFINCredential) throws {
        try state.withLock {
            $0.saves += 1
            if $0.writesToFail > 0 {
                $0.writesToFail -= 1
                throw CredentialStoreError.keychain(errSecInteractionNotAllowed, while: .writing)
            }
            $0.credential = credential
        }
    }
    func replace(_ credential: SimpleFINCredential, expected: SimpleFINCredential) throws {
        try state.withLock {
            $0.replacements += 1
            guard $0.credential == expected else { throw CredentialStoreError.verificationFailed }
            if $0.writesToFail > 0 {
                $0.writesToFail -= 1
                throw CredentialStoreError.keychain(errSecInteractionNotAllowed, while: .writing)
            }
            $0.credential = credential
        }
    }
    func delete() { state.withLock { $0.credential = nil } }
}

@Suite("Connecting and refreshing a bank", .serialized)
@MainActor
struct ConnectionFlowTests {
    /// Waits for observable work rather than racing an unstructured first-sync task.
    static func eventually(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The expected connection state did not arrive within five seconds")
    }

    static func connectState(_ database: AppDatabase, now: Date = .now) throws {
        try database.writer.write { db in
            try SyncState.setDate(db, SyncState.connectedAt, now)
            try SyncState.setDate(db, SyncState.transactionsPulledAt, now)
        }
    }

    @Test("invalid setup text is rejected before any request or credential write")
    func invalidSetupText() async throws {
        let server = ConnectionFlowServer { _ in .init(body: ConnectionFlowServer.empty) }
        defer { server.close() }
        let credentials = FlowCredentialStore()
        let model = AppModel(database: try AppDatabase.inMemory(), credentialStore: credentials, client: server.client)
        await model.prepareSetup()
        #expect(model.setupState == .ready)
        #expect(throws: SimpleFINFailure.notASetupToken) { try SimpleFINClient.claimURL(fromSetupToken: "not-base64!!") }
        #expect(server.requests.isEmpty)
        #expect(credentials.state.withLock { $0.saves } == 0)
    }

    @Test("a second setup visit never replaces an existing or unreadable connection")
    func secondVisit() async throws {
        let server = ConnectionFlowServer { _ in .init(body: ConnectionFlowServer.empty) }
        defer { server.close() }
        let credentials = FlowCredentialStore(server.credential("original"))
        let model = AppModel(database: try AppDatabase.inMemory(), credentialStore: credentials, client: server.client)
        await model.prepareSetup()
        #expect(model.setupState == .alreadyConnected)
        await model.claimConnection(at: server.claimURL)
        credentials.state.withLock { $0.loadError = .keychain(errSecInteractionNotAllowed, while: .reading) }
        await model.prepareSetup()
        #expect(model.setupState == .keychainUnavailable)
        #expect(model.banner == .keychain)
        await model.claimConnection(at: server.claimURL)
        #expect(server.requests.isEmpty)
        #expect(credentials.state.withLock { $0.saves + $0.replacements } == 0)
    }

    @Test("a failed save retains the claimed connection and Retry never claims it twice")
    func retainedClaimAndRetry() async throws {
        let server = ConnectionFlowServer { request in
            .init(body: request.httpMethod == "POST" ? ConnectionFlowServer.claimBody(for: request) : ConnectionFlowServer.empty)
        }
        defer { server.close() }
        let database = try AppDatabase.inMemory()
        let credentials = FlowCredentialStore(writesToFail: 1)
        let model = AppModel(database: database, credentialStore: credentials, client: server.client)
        await model.prepareSetup()
        await model.claimConnection(at: server.claimURL)
        #expect(model.setupState == .unsaved)
        #expect(model.unsavedConnection == server.credential())
        #expect(model.banner == .unsaved)
        #expect(server.requests.map(\.method) == ["POST"])
        #expect(try await database.reader.read { try Account.fetchCount($0) } == 0)
        #expect(try await database.reader.read { try SyncState.date($0, SyncState.connectedAt) } == nil)
        await model.prepareSetup() // Simulates closing the setup screen and returning.
        #expect(model.unsavedConnection != nil)
        await model.retrySavingConnection()
        try await Self.eventually { model.setupMessage == ConnectionPresentation.emptyConnection && !model.isSyncing }
        #expect(model.unsavedConnection == nil)
        #expect(model.setupState == .connected)
        #expect(try credentials.load() == server.credential())
        #expect(server.requests.filter { $0.method == "POST" }.count == 1)
        #expect(server.requests.contains { $0.method == "GET" })
        #expect(credentials.state.withLock { $0.saves } == 2)
        #expect(try await database.reader.read { try SyncState.date($0, SyncState.connectedAt) } != nil)
    }

    @Test("a saved claim recovers the crash gap before its connected database marker was written")
    func savedClaimRepairsConnectionMarker() async throws {
        let server = ConnectionFlowServer { _ in .init(body: ConnectionFlowServer.empty) }
        defer { server.close() }
        let database = try AppDatabase.inMemory()
        let credentials = FlowCredentialStore(server.credential())
        let model = AppModel(database: database, credentialStore: credentials, client: server.client)
        await model.prepareSetup()
        #expect(model.setupState == .alreadyConnected)
        #expect(try await database.reader.read { try SyncState.date($0, SyncState.connectedAt) } != nil)
        #expect(try await database.reader.read { try SyncState.integer($0, "awaiting-first-balance") } == 1)
        await model.refresh()
        #expect(model.syncMessage == ConnectionPresentation.emptyConnection)
        #expect(model.banner == nil)
        #expect(server.requests.allSatisfy { $0.method == "GET" })
        #expect(!server.requests.isEmpty)
        #expect(try await database.reader.read { try SyncState.integer($0, "awaiting-first-balance") } == 0)
        #expect(credentials.state.withLock { $0.saves + $0.replacements } == 0)
    }

    @Test("credential recovery preserves the rejected item until a replacement saves successfully")
    func recoveryReplacement() async throws {
        let reject = Mutex(true)
        let server = ConnectionFlowServer { request in
            if request.httpMethod == "POST" { return .init(body: ConnectionFlowServer.claimBody(for: request)) }
            if reject.withLock({ $0 }) {
                return .init(status: 403, body: Data(#"{"errlist":[{"code":"gen.auth","msg":"Forbidden"}],"accounts":[],"connections":[]}"#.utf8))
            }
            return .init(body: ConnectionFlowServer.empty)
        }
        defer { server.close() }
        let original = server.credential("original")
        let credentials = FlowCredentialStore(original, writesToFail: 1)
        let database = try AppDatabase.inMemory()
        try Self.connectState(database)
        let model = AppModel(database: database, credentialStore: credentials, client: server.client)
        await model.refresh()
        guard case .rejected = model.banner else { Issue.record("Expected a rejected-connection banner"); return }
        await model.prepareSetup()
        #expect(model.setupState == .ready)
        await model.claimConnection(at: server.claimURL)
        #expect(model.unsavedConnection == server.credential())
        #expect(try credentials.load() == original)
        #expect(model.banner == .unsaved)
        reject.withLock { $0 = false }
        await model.retrySavingConnection()
        try await Self.eventually { model.setupMessage == ConnectionPresentation.emptyConnection && !model.isSyncing }
        #expect(try credentials.load() == server.credential())
        #expect(credentials.state.withLock { $0.replacements } == 2)
        #expect(server.requests.filter { $0.method == "POST" }.count == 1)
    }

    @Test("a successful token with no accounts stays connected and asks for no fresh token")
    func connectedWithoutAccounts() async throws {
        let server = ConnectionFlowServer { request in
            .init(body: request.httpMethod == "POST" ? ConnectionFlowServer.claimBody(for: request) : ConnectionFlowServer.empty)
        }
        defer { server.close() }
        let database = try AppDatabase.inMemory()
        let credentials = FlowCredentialStore()
        let model = AppModel(database: database, credentialStore: credentials, client: server.client)
        await model.prepareSetup()
        await model.claimConnection(at: server.claimURL)
        try await Self.eventually { model.setupMessage == ConnectionPresentation.emptyConnection && !model.isSyncing }
        #expect(try credentials.load() != nil)
        #expect(model.banner == nil)
        #expect(!(model.setupMessage ?? "").contains("generate a fresh"))
        #expect(try await database.reader.read { try Account.fetchCount($0) } == 0)
    }

    @Test("a first rejected credential survives relaunch and retries without spending another token", arguments: [200, 403])
    func firstClaimRejection(status: Int) async throws {
        let rejects = Mutex(true)
        let server = ConnectionFlowServer { request in
            if request.httpMethod == "POST" { return .init(body: ConnectionFlowServer.claimBody(for: request)) }
            if rejects.withLock({ $0 }) {
                return .init(status: status, body: Data(#"{"errlist":[{"code":"gen.auth","msg":"Forbidden"}],"accounts":[],"connections":[]}"#.utf8))
            }
            return .init(body: ConnectionFlowServer.empty)
        }
        defer { server.close() }
        let database = try AppDatabase.inMemory()
        let credentials = FlowCredentialStore()
        let model = AppModel(database: database, credentialStore: credentials, client: server.client)
        await model.prepareSetup()
        await model.claimConnection(at: server.claimURL)
        try await Self.eventually { model.setupState == .freshCredentialRejected && !model.isSyncing }
        #expect(model.banner == .freshCredentialRejected("Forbidden"))
        #expect(model.syncMessage == ConnectionPresentation.freshCredentialRejected)
        #expect(try credentials.load() == server.credential())
        #expect(try await database.reader.read { try SyncState.integer($0, "awaiting-first-balance") } == 1)

        let reopened = AppModel(database: database, credentialStore: credentials, client: server.client)
        await reopened.prepareSetup()
        #expect(reopened.setupState == .freshCredentialRejected)
        #expect(reopened.banner == .freshCredentialRejected("Forbidden"))
        await reopened.claimConnection(at: server.claimURL)
        #expect(server.requests.filter { $0.method == "POST" }.count == 1)
        rejects.withLock { $0 = false }
        await reopened.refresh()
        #expect(reopened.setupState == .connected)
        #expect(reopened.banner == nil)
        #expect(reopened.setupMessage == ConnectionPresentation.emptyConnection)
        #expect(try await database.reader.read { try SyncState.integer($0, "awaiting-first-balance") } == 0)
        #expect(try await database.reader.read { try String.fetchOne($0, sql: "SELECT value FROM sync_state WHERE key = 'credential-rejected'") } == nil)
        #expect(server.requests.filter { $0.method == "POST" }.count == 1)
    }

    @Test("an owner can deliberately replace a never-accepted credential, and the new one receives the same protection")
    func explicitFirstClaimRecovery() async throws {
        let server = ConnectionFlowServer { request in
            if request.httpMethod == "POST" { return .init(body: ConnectionFlowServer.claimBody(for: request)) }
            return .init(status: 403, body: Data(#"{"errlist":[{"code":"gen.auth","msg":"Forbidden"}],"accounts":[],"connections":[]}"#.utf8))
        }
        defer { server.close() }
        let database = try AppDatabase.inMemory()
        let credentials = FlowCredentialStore()
        let model = AppModel(database: database, credentialStore: credentials, client: server.client)
        await model.prepareSetup()
        await model.claimConnection(at: server.claimURL)
        try await Self.eventually { model.setupState == .freshCredentialRejected && !model.isSyncing }
        await model.approveRejectedReplacement()
        #expect(model.setupState == .ready && model.setupScreenRequested)
        #expect(try await database.reader.read { try SyncState.integer($0, "unverified-replacement-approved") } == 1)
        await model.prepareSetup()
        #expect(model.setupState == .ready)
        await model.claimConnection(at: server.claimURL)
        try await Self.eventually { model.setupState == .freshCredentialRejected && !model.isSyncing }
        #expect(try await database.reader.read { try SyncState.integer($0, "unverified-replacement-approved") } == 0)
        #expect(try credentials.load() == server.credential())
        #expect(server.requests.filter { $0.method == "POST" }.count == 2)
    }

    @Test("replacement restarts exhausted history without replenishing request budgets or clearing quota warnings")
    func replacementResetsHistoryOnly() async throws {
        let server = ConnectionFlowServer { request in
            .init(body: request.httpMethod == "POST" ? ConnectionFlowServer.claimBody(for: request) : ConnectionFlowServer.empty)
        }
        defer { server.close() }
        let database = try AppDatabase.inMemory()
        let credentials = FlowCredentialStore(server.credential("original"))
        try await database.writer.write { db in
            try SyncState.setDate(db, SyncState.connectedAt, .now)
            try SyncState.setDate(db, SyncState.transactionsPulledAt, .now)
            try SyncState.set(db, "credential-rejected", "Forbidden")
            try BackfillProgress(nextWindowIndex: 11, consecutiveEmptyWindows: 2, state: .exhausted, coveredBackTo: "2025-07-01").save(db)
            for _ in 0..<RequestBudget.maxBackfillInRollingDay { try RequestBudget.reserve(db, purpose: .backfill) }
            try RequestBudget.recordServerQuotaWarning(db)
        }
        let before = try await database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT key, value FROM sync_state WHERE key IN (?, ?, ?) ORDER BY key",
                arguments: [RequestBudget.timestampsKey, RequestBudget.backfillTimestampsKey, RequestBudget.quotaTrippedKey])
                .map { "\($0["key"] as String)=\($0["value"] as String)" }
        }
        let model = AppModel(database: database, credentialStore: credentials, client: server.client)
        await model.prepareSetup()
        #expect(model.setupState == .ready)
        await model.claimConnection(at: server.claimURL)
        try await Self.eventually { model.syncMessage?.contains("asked me to wait") == true && !model.isSyncing }
        #expect(try credentials.load() == server.credential())
        #expect(try await database.reader.read { try BackfillProgress.load($0) } == BackfillProgress())
        #expect(try await database.reader.read { try SyncState.date($0, SyncState.transactionsPulledAt) } == nil)
        let after = try await database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT key, value FROM sync_state WHERE key IN (?, ?, ?) ORDER BY key",
                arguments: [RequestBudget.timestampsKey, RequestBudget.backfillTimestampsKey, RequestBudget.quotaTrippedKey])
                .map { "\($0["key"] as String)=\($0["value"] as String)" }
        }
        #expect(after == before)
        #expect(server.requests.map(\.method) == ["POST"])
    }

    @Test("a new account forces a dated answer even during a balances-only run")
    func newAccountForcesDatedAnswer() async throws {
        let server = ConnectionFlowServer { .init(body: ConnectionFlowServer.accounts(for: $0)) }
        defer { server.close() }
        let database = try AppDatabase.inMemory()
        let credentials = FlowCredentialStore(server.credential())
        try Self.connectState(database)
        let coordinator = SyncCoordinator(database: database, client: server.client, credentials: credentials)
        let report = await coordinator.sync(shape: .balancesOnly)
        #expect(report.balancesRefreshed)
        #expect(server.requests.contains { $0.isWindow })
        #expect(try await database.reader.read { try Account.fetchOne($0)?.holdingsObservedAt } != nil)
        let count = server.requests.count
        let second = await coordinator.sync(shape: .balancesOnly)
        #expect(second.outcome.accountsInserted == 0)
        #expect(server.requests.count == count + 1)
    }

    @Test("a new account still gets inspected after an earlier empty history walk finished")
    func newAccountAfterExhaustedHistory() async throws {
        let server = ConnectionFlowServer { .init(body: ConnectionFlowServer.accounts(for: $0)) }
        defer { server.close() }
        let database = try AppDatabase.inMemory()
        try await database.writer.write { db in
            try BackfillProgress(nextWindowIndex: 2, consecutiveEmptyWindows: 2, state: .exhausted).save(db)
        }
        let coordinator = SyncCoordinator(database: database, client: server.client, credentials: FlowCredentialStore(server.credential()))
        _ = await coordinator.sync(shape: .balancesOnly)
        #expect(server.requests.contains { $0.isWindow })
        #expect(try await database.reader.read { try Account.fetchOne($0)?.holdingsObservedAt } != nil)
    }

    @Test("overlapping scheduled and manual triggers join one in-flight balances request")
    func singleFlight() async throws {
        let server = ConnectionFlowServer { _ in .init(body: ConnectionFlowServer.empty, delay: 0.2) }
        defer { server.close() }
        let database = try AppDatabase.inMemory()
        try Self.connectState(database)
        let coordinator = SyncCoordinator(database: database, client: server.client, credentials: FlowCredentialStore(server.credential()))
        let first = Task { await coordinator.syncIfDue(trigger: .scheduled) }
        try await Self.eventually { server.requests.count == 1 }
        let second = await coordinator.syncIfDue(trigger: .manual)
        let original = await first.value
        #expect(original.balancesRefreshed && second.balancesRefreshed)
        #expect(second.joinedARunInProgress)
        #expect(server.requests.count == 1)
        #expect(try await database.reader.read { try RequestBudget.remaining($0) } == 13)
    }

    @Test("gen.auth in an HTTP 200 answer is a failure and does not record a successful balance")
    func authIsNeverSuccess() async throws {
        let server = ConnectionFlowServer { _ in
            .init(body: Data(#"{"errlist":[{"code":"gen.auth","msg":"Forbidden"}],"accounts":[],"connections":[]}"#.utf8))
        }
        defer { server.close() }
        let database = try AppDatabase.inMemory()
        let coordinator = SyncCoordinator(database: database, client: server.client, credentials: FlowCredentialStore(server.credential()))
        let report = await coordinator.sync(shape: .balancesOnly)
        #expect(report.failure == .credentialRejected(serverMessage: "Forbidden"))
        #expect(!report.balancesRefreshed && !report.connectionIsWorking)
        #expect(report.needsAttention)
        #expect(try await database.reader.read { try SyncState.date($0, SyncState.balancesSyncedAt) } == nil)
    }

    @Test("a credential rejected during history remains rejected after the successful balance step", arguments: [200, 403])
    func historyCredentialRejectionIsDurable(status: Int) async throws {
        let server = ConnectionFlowServer { request in
            let isWindow = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "start-date" } == true
            if isWindow {
                return .init(status: status, body: Data(#"{"errlist":[{"code":"gen.auth","msg":"Forbidden during history"}],"accounts":[],"connections":[]}"#.utf8))
            }
            return .init(body: ConnectionFlowServer.accounts(for: request))
        }
        defer { server.close() }
        let database = try AppDatabase.inMemory()
        let credentials = FlowCredentialStore(server.credential())
        let coordinator = SyncCoordinator(database: database, client: server.client, credentials: credentials)
        let report = await coordinator.sync(shape: .balancesAndTransactions)
        #expect(report.balancesRefreshed)
        #expect(report.failure == .credentialRejected(serverMessage: "Forbidden during history"))
        #expect(!report.connectionIsWorking && report.needsAttention)
        #expect(report.stillFillingHistory && report.historyStopped == .failed)
        let rejected = try await database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'credential-rejected'")
        }
        #expect(rejected == "Forbidden during history")
        let account = try #require(try await database.reader.read { try Account.fetchOne($0) })
        #expect(account.balanceCents == 124018)
        #expect(account.notUpdatingSince != nil)
        #expect(account.txSyncedThrough == nil)
        #expect(try credentials.load() == server.credential())
    }

    @Test("an offline request is reserved but does not increase bank-failure back-off")
    func offlineDoesNotCountAsBankFailure() async throws {
        let server = ConnectionFlowServer { _ in .init(error: .notConnectedToInternet) }
        defer { server.close() }
        let database = try AppDatabase.inMemory()
        let coordinator = SyncCoordinator(database: database, client: server.client, credentials: FlowCredentialStore(server.credential()))
        let report = await coordinator.sync(shape: .balancesOnly)
        #expect(report.failure == .couldNotReachServer(.offline))
        #expect(try await database.reader.read { try SyncState.integer($0, SyncState.failuresInARow) } == 0)
        #expect(try await database.reader.read { try SyncState.date($0, SyncState.attemptedAt) } != nil)
        #expect(try await database.reader.read { try RequestBudget.remaining($0) } == 13)
    }

    @Test("dated scoped errors keep their cause, deduplicate notices, and leave the window retryable", arguments: ["con.auth", "act.failed"])
    func historyScopedErrorsAreDurable(code: String) async throws {
        let server = ConnectionFlowServer { request in
            let isWindow = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "start-date" } == true
            var response = try! JSONSerialization.jsonObject(with: ConnectionFlowServer.accounts(for: request)) as! [String: Any]
            if isWindow {
                let error = ["code": code, "msg": "Sign in again", "conn_id": "CON-1", "account_id": "checking"]
                response["errlist"] = [error, error]
            } else {
                response["errlist"] = [["code": "con.auth", "msg": "Another bank needs sign in", "conn_id": "OTHER"]]
            }
            return .init(body: try! JSONSerialization.data(withJSONObject: response))
        }
        defer { server.close() }
        let database = try AppDatabase.inMemory()
        let coordinator = SyncCoordinator(database: database, client: server.client, credentials: FlowCredentialStore(server.credential()))
        for _ in 0..<2 {
            let report = await coordinator.sync(shape: .balancesAndTransactions)
            #expect(report.historyStopped == .failed && report.stillFillingHistory)
            #expect(report.outcome.historyWindowIncomplete)
            #expect(report.outcome.notices.filter { $0.text == "Sign in again" }.count == 1)
            let text = try #require(try await database.reader.read { try String.fetchOne($0, sql: "SELECT value FROM sync_state WHERE key = 'connection-notices'") })
            let notices = try JSONDecoder().decode([SyncNotice].self, from: Data(text.utf8))
            #expect(notices.filter { $0.text == "Sign in again" }.count == 1)
            #expect(notices.contains { $0.text == "Another bank needs sign in" && $0.scope == .connection("OTHER") })
            let account = try #require(try await database.reader.read { try Account.fetchOne($0) })
            #expect(account.notUpdatingSince != nil)
            #expect(account.txSyncedThrough == nil)
            #expect(try await database.reader.read { try BackfillProgress.load($0).nextWindowIndex } == 0)
            #expect(try await database.reader.read { try SyncState.date($0, SyncState.transactionsPulledAt) } == nil)
        }
    }

    @Test("replayed stored transaction ids do not exhaust a restarted history walk")
    func replayedHistoryIsNotEmpty() async throws {
        let server = ConnectionFlowServer { .init(body: ConnectionFlowServer.accounts(for: $0, transactions: true)) }
        defer { server.close() }
        let database = try AppDatabase.inMemory()
        let now = Date()
        let today = CalendarDay(now)
        let windows = BackfillPlan.windows(endingOn: today)
        let balances = try SimpleFINAccountSet.decode(ConnectionFlowServer.accounts(for: URLRequest(url: server.base)))
        try await database.writer.write { db in
            _ = try SimpleFINIngest.ingest(balances, kind: .balances, into: db, now: now)
            for window in windows.prefix(2) {
                var url = URLComponents(url: server.base, resolvingAgainstBaseURL: false)!
                url.queryItems = [URLQueryItem(name: "start-date", value: String(window.lowerBound.utcMidnight))]
                let set = try SimpleFINAccountSet.decode(ConnectionFlowServer.accounts(for: URLRequest(url: url.url!), transactions: true))
                _ = try SimpleFINIngest.ingest(set, kind: .window(start: window.lowerBound, end: window.upperBound), into: db, now: now)
            }
            try BackfillProgress().save(db)
        }
        let coordinator = SyncCoordinator(database: database, client: server.client, credentials: FlowCredentialStore(server.credential()))
        let report = await coordinator.sync(shape: .balancesAndTransactions, now: now)
        #expect(report.historyStopped == .budget && report.stillFillingHistory)
        #expect(report.outcome.transactionsSeen > report.outcome.transactionsInserted)
        let progress = try await database.reader.read { try BackfillProgress.load($0) }
        #expect(progress.nextWindowIndex == 6 && progress.consecutiveEmptyWindows == 0)
        #expect(progress.state == .running)
    }

    @Test("history budget exhaustion leaves a working connection and an unfinished history message")
    func partialHistoryIsNotFailure() async throws {
        let server = ConnectionFlowServer { .init(body: ConnectionFlowServer.accounts(for: $0, transactions: true)) }
        defer { server.close() }
        let database = try AppDatabase.inMemory()
        let coordinator = SyncCoordinator(database: database, client: server.client, credentials: FlowCredentialStore(server.credential()))
        let report = await coordinator.sync(shape: .balancesAndTransactions)
        #expect(report.requestsSpent == 7)
        #expect(report.windowsFetched == 6)
        #expect(report.historyStopped == .budget)
        #expect(report.refusal == .backfillIsFullForToday)
        #expect(report.balancesRefreshed && report.connectionIsWorking && report.stillFillingHistory)
        #expect(report.failure == nil && !report.needsAttention)
        #expect(ConnectionPresentation.message(report, lastBalances: .now)?.contains("older months") == true)
    }

    @Test("the OS activity completion runs exactly once for keychain, offline and budget refusals")
    func activityAlwaysCompletes() async throws {
        for failure in 0..<3 {
            let server = ConnectionFlowServer { _ in .init(error: .notConnectedToInternet) }
            let database = try AppDatabase.inMemory()
            try Self.connectState(database)
            let credentials = FlowCredentialStore(server.credential(), loadError: failure == 0 ? .keychain(errSecInteractionNotAllowed, while: .reading) : nil)
            if failure == 2 {
                try await database.writer.write { db in
                    for _ in 0..<RequestBudget.maxInRollingDay { try RequestBudget.reserve(db, purpose: .refresh) }
                }
            }
            let coordinator = SyncCoordinator(database: database, client: server.client, credentials: credentials)
            let completions = Mutex(0)
            let report = await SyncActivity.run(coordinator: coordinator) { completions.withLock { $0 += 1 } }
            #expect(completions.withLock { $0 } == 1)
            #expect(try await database.reader.read { try SyncState.integer($0, SyncState.failuresInARow) } == 0)
            if failure == 0 { #expect(report.credentialProblem != nil && server.requests.isEmpty) }
            if failure == 1 { #expect(report.failure == .couldNotReachServer(.offline)) }
            if failure == 2 { #expect(report.skippedBecause == "no requests left today" && server.requests.isEmpty) }
            server.close()
        }
    }
}
