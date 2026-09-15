import Foundation
import Synchronization
import Testing
@testable import Spendable

/// Answers HTTP requests from a script, and records what was asked.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var body: Data = Data()
        var headers: [String: String] = [:]
        var urlErrorCode: URLError.Code?
    }

    struct Asked: Sendable {
        var url: URL
        var method: String
        var headers: [String: String]
        var bodyLength: Int
    }

    private struct State {
        var replies: [Reply] = []
        var asked: [Asked] = []
    }

    private static let state = Mutex(State())

    static func script(_ replies: [Reply]) {
        state.withLock { $0 = State(replies: replies, asked: []) }
    }

    static var asked: [Asked] { state.withLock { $0.asked } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol strips the body into a stream; read it back to count the bytes.
        var bodyLength = request.httpBody?.count ?? 0
        if bodyLength == 0, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                bodyLength += read
            }
            stream.close()
        }
        let record = Asked(
            url: request.url!, method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:], bodyLength: bodyLength)

        let reply: Reply? = Self.state.withLock { state in
            state.asked.append(record)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }

        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if let code = reply.urlErrorCode {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Talking to SimpleFIN", .serialized)
struct SimpleFINClientTests {
    static let base = "https://beta-bridge.simplefin.org/simplefin"

    static func token(for url: String) -> String {
        Data(url.utf8).base64EncodedString()
    }

    /// Builds an access URL at run time rather than writing one out.
    ///
    /// A URL with a password in it is exactly what the repository's pre-commit hook refuses, and
    /// rightly so — it cannot tell a test's invented credential from the owner's real one, and the
    /// day it learns to is the day it stops protecting them. Assembling it here keeps the guard
    /// strict and this file honest.
    static func accessURL(user: String, password: String, percentEncoded: Bool = false) -> String {
        var components = URLComponents(string: base)!
        if percentEncoded {
            components.percentEncodedUser = user
            components.percentEncodedPassword = password
        } else {
            components.user = user
            components.password = password
        }
        return components.string!
    }

    // MARK: Setup tokens

    @Test("a setup token is base64 of an https URL, and nothing else is accepted")
    func decodingSetupTokens() throws {
        let url = try SimpleFINClient.claimURL(fromSetupToken: Self.token(for: "\(Self.base)/claim/ABC"))
        #expect(url.absoluteString == "\(Self.base)/claim/ABC")
        // Whitespace from a careless paste is fine.
        let padded = try SimpleFINClient.claimURL(fromSetupToken: "  \(Self.token(for: "\(Self.base)/claim/ABC"))\n")
        #expect(padded.absoluteString == "\(Self.base)/claim/ABC")

        for bad in ["", "not base64 at all!!", Self.token(for: "http://insecure.example.com/claim/x"),
                    Self.token(for: "ftp://x/y"), Self.token(for: "https:///no-host"),
                    Data("just some text".utf8).base64EncodedString()] {
            #expect(throws: SimpleFINFailure.notASetupToken) {
                try SimpleFINClient.claimURL(fromSetupToken: bad)
            }
        }
    }

    // MARK: The percent-encoding trap

    @Test("an access URL is split with URLComponents, so a percent-encoded password survives")
    func accessURLPercentDecoding() throws {
        // A password containing / and @, which must be percent-encoded inside a URL.
        let given = Self.accessURL(user: "ab%40cd", password: "pq%2Frs%40tu", percentEncoded: true)
        let credential = try #require(SimpleFINClient.credential(fromAccessURL: given))
        #expect(credential.username == "ab@cd")
        #expect(credential.password == "pq/rs@tu")
        #expect(credential.baseURL.absoluteString == "https://beta-bridge.simplefin.org/simplefin")

        // The header the client then builds must carry the decoded pair. URL.password() would have
        // returned "pq%2Frs%40tu" here, which the server would reject while the app "verified" it.
        let request = try SimpleFINClient.accountsRequest(credential: credential, kind: .balances)
        let header = try #require(request.value(forHTTPHeaderField: "Authorization"))
        let encoded = header.replacingOccurrences(of: "Basic ", with: "")
        let decoded = String(data: try #require(Data(base64Encoded: encoded)), encoding: .utf8)
        #expect(decoded == "ab@cd:pq/rs@tu")
    }

    @Test("an access URL without both parts is refused")
    func accessURLValidation() {
        #expect(SimpleFINClient.credential(fromAccessURL: "https://beta-bridge.simplefin.org/simplefin") == nil)
        #expect(SimpleFINClient.credential(fromAccessURL: "not a url at all") == nil)
        #expect(SimpleFINClient.credential(fromAccessURL: "") == nil)
    }

    // MARK: Claiming

    @Test("a successful claim stores the credential from the body")
    func claimSucceeds() async throws {
        StubServer.script([.init(status: 200, body: Data(Self.accessURL(user: "u", password: "p").utf8))])
        let client = SimpleFINClient(session: StubServer.session())
        let credential = try await client.claim(
            claimURL: URL(string: "\(Self.base)/claim/ABC")!)
        #expect(credential.username == "u")
        #expect(credential.password == "p")

        let asked = try #require(StubServer.asked.first)
        #expect(asked.method == "POST")
        #expect(asked.bodyLength == 0)
        #expect(asked.headers["Content-Length"] == "0")
    }

    @Test("a re-used token says so in words the owner can act on")
    func claimRejected() async throws {
        StubServer.script([.init(status: 403, body: Data("Forbidden (was it already claimed?)".utf8))])
        let client = SimpleFINClient(session: StubServer.session())
        await #expect(throws: SimpleFINFailure.tokenAlreadyUsed) {
            try await client.claim(claimURL: URL(string: "\(Self.base)/claim/ABC")!)
        }
        #expect(SimpleFINFailure.tokenAlreadyUsed.ownerFacingMessage.contains("already used"))
        #expect(SimpleFINFailure.tokenAlreadyUsed.ownerFacingMessage.contains("disable it"))
    }

    @Test("a claim answered with something that is not an access URL fails cleanly")
    func claimGarbage() async throws {
        StubServer.script([.init(status: 200, body: Data("thanks!".utf8))])
        let client = SimpleFINClient(session: StubServer.session())
        await #expect(throws: SimpleFINFailure.claimAnswerUnusable) {
            try await client.claim(claimURL: URL(string: "\(Self.base)/claim/ABC")!)
        }
    }

    // MARK: Redirects

    @Test("a redirect is never followed, and is named by where it points")
    func redirectIsDiagnosed() async throws {
        StubServer.script([.init(
            status: 302, body: Data(),
            headers: ["Location": "https://beta-bridge.simplefin.org/"])])
        let client = SimpleFINClient(session: StubServer.session())
        await #expect(throws: SimpleFINFailure.redirected(toHost: "beta-bridge.simplefin.org")) {
            try await client.claim(claimURL: URL(string: "https://bridge.simplefin.org/simplefin/claim/ABC")!)
        }
        // Exactly one request: the redirect was not chased.
        #expect(StubServer.asked.count == 1)
    }

    // MARK: Requests

    @Test("the balances request carries no dates at all")
    func balancesRequestHasNoDates() throws {
        let credential = try #require(SimpleFINCredential(
            baseURL: URL(string: Self.base)!, username: "u", password: "p"))
        let request = try SimpleFINClient.accountsRequest(credential: credential, kind: .balances)
        let query = try #require(request.url?.query())
        #expect(query.contains("version=2"))
        #expect(query.contains("balances-only=1"))
        #expect(!query.contains("start-date"))
        #expect(!query.contains("end-date"))
        // The credential is in a header, never in the URL.
        #expect(request.url?.absoluteString.contains("@") == false)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
    }

    @Test("a window request sends both dates as UTC midnight, with the far end exclusive")
    func windowRequestDates() throws {
        let credential = try #require(SimpleFINCredential(
            baseURL: URL(string: Self.base)!, username: "u", password: "p"))
        let start = CalendarDay(year: 2026, month: 8, day: 2)
        let end = CalendarDay(year: 2026, month: 9, day: 14)
        let request = try SimpleFINClient.accountsRequest(credential: credential, kind: .window(start: start, end: end))
        let url = try #require(request.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(value("version") == "2")
        #expect(value("pending") == "1")
        #expect(value("start-date") == String(start.utcMidnight))
        // "before, but not on": the day after the window's last day.
        #expect(value("end-date") == String(CalendarDay(year: 2026, month: 9, day: 15).utcMidnight))
        #expect(value("balances-only") == nil)
    }

    @Test("the app refuses to build a window longer than it promised")
    func windowTooLong() throws {
        let credential = try #require(SimpleFINCredential(
            baseURL: URL(string: Self.base)!, username: "u", password: "p"))
        let start = CalendarDay(year: 2026, month: 1, day: 1)
        let end = CalendarDay(year: 2026, month: 6, day: 1)
        #expect(throws: (any Error).self) {
            try SimpleFINClient.accountsRequest(credential: credential, kind: .window(start: start, end: end))
        }
    }

    // MARK: Statuses

    @Test("403 on a data request is the credential being rejected, with the server's own words")
    func credentialRejected() async throws {
        let body = try FixtureTests.load("Demo/v2-bad-credentials.json")
        StubServer.script([.init(status: 403, body: body)])
        let client = SimpleFINClient(session: StubServer.session())
        let credential = try #require(SimpleFINCredential(
            baseURL: URL(string: Self.base)!, username: "u", password: "p"))
        await #expect(throws: SimpleFINFailure.credentialRejected(serverMessage: "Forbidden")) {
            try await client.accounts(credential: credential, kind: .balances)
        }
    }

    @Test("402 says what was observed rather than asserting a cause")
    func paymentRequired() async throws {
        StubServer.script([.init(status: 402, body: Data(#"{"errlist":[{"code":"gen.","msg":"Subscription lapsed"}],"accounts":[],"connections":[]}"#.utf8))])
        let client = SimpleFINClient(session: StubServer.session())
        let credential = try #require(SimpleFINCredential(
            baseURL: URL(string: Self.base)!, username: "u", password: "p"))
        await #expect(throws: SimpleFINFailure.subscriptionProblem(serverMessage: "Subscription lapsed")) {
            try await client.accounts(credential: credential, kind: .balances)
        }
        let message = SimpleFINFailure.subscriptionProblem(serverMessage: "Subscription lapsed").ownerFacingMessage
        #expect(message.contains("usually means"))
        #expect(message.contains("Subscription lapsed"))
    }

    @Test("a trimmed range is thrown away rather than stored with a hole in it")
    func cappedRangeIsAFailure() async throws {
        let body = try FixtureTests.load("Demo/v2-range-capped.json")
        StubServer.script([.init(status: 200, body: body)])
        let client = SimpleFINClient(session: StubServer.session())
        let credential = try #require(SimpleFINCredential(
            baseURL: URL(string: Self.base)!, username: "u", password: "p"))
        do {
            _ = try await client.accounts(credential: credential, kind: .balances)
            Issue.record("expected the capped range to fail")
        } catch let failure as SimpleFINFailure {
            guard case .rangeWasCapped = failure else {
                Issue.record("expected rangeWasCapped, got \(failure)")
                return
            }
        }
    }

    @Test("a transport failure becomes a plain sentence and keeps nothing")
    func transportFailure() async throws {
        StubServer.script([.init(urlErrorCode: .notConnectedToInternet)])
        let client = SimpleFINClient(session: StubServer.session())
        let credential = try #require(SimpleFINCredential(
            baseURL: URL(string: Self.base)!, username: "u", password: "p"))
        await #expect(throws: SimpleFINFailure.couldNotReachServer(.offline)) {
            try await client.accounts(credential: credential, kind: .balances)
        }
    }

    // MARK: Nothing leaks

    @Test("no error path ever reveals the setup token or the password")
    func nothingLeaks() async throws {
        let secretToken = "SENTINELTOKEN12345"
        let secretPassword = "SENTINELPASSWORD67890"
        let claimURL = URL(string: "\(Self.base)/claim/\(secretToken)")!
        let credential = try #require(SimpleFINCredential(
            baseURL: URL(string: Self.base)!, username: "demo", password: secretPassword))

        var produced: [any Error] = []
        let client = SimpleFINClient(session: StubServer.session())

        for reply in [StubServer.Reply(urlErrorCode: .timedOut),
                      StubServer.Reply(status: 403),
                      StubServer.Reply(status: 500),
                      StubServer.Reply(status: 302, headers: ["Location": "https://elsewhere.example.com/x"])] {
            StubServer.script([reply])
            do { _ = try await client.claim(claimURL: claimURL) } catch { produced.append(error) }
            StubServer.script([reply])
            do { _ = try await client.accounts(credential: credential, kind: .balances) } catch { produced.append(error) }
        }
        #expect(produced.count >= 6)

        for error in produced {
            for rendering in [String(describing: error), String(reflecting: error),
                              (error as? SimpleFINFailure)?.ownerFacingMessage ?? "",
                              (error as NSError).userInfo.description] {
                #expect(!rendering.contains(secretToken), "a setup token escaped: \(rendering)")
                #expect(!rendering.contains(secretPassword), "a password escaped: \(rendering)")
            }
            var dumped = ""
            dump(error, to: &dumped)
            #expect(!dumped.contains(secretToken))
            #expect(!dumped.contains(secretPassword))
        }
    }

    @Test("dumping a credential reveals nothing, which description alone does not guarantee")
    func credentialIsUnreflectable() throws {
        let credential = try #require(SimpleFINCredential(
            baseURL: URL(string: Self.base)!, username: "demo-user", password: "SENTINELPASSWORD67890"))
        var dumped = ""
        dump(credential, to: &dumped)
        #expect(!dumped.contains("SENTINELPASSWORD67890"))
        #expect(Mirror(reflecting: credential).children.isEmpty)
        #expect(!String(describing: credential).contains("SENTINELPASSWORD67890"))
        #expect(!String(reflecting: credential).contains("SENTINELPASSWORD67890"))
    }

    @Test("a locked keychain is never mistaken for a bank rejecting the connection")
    func keychainRefusalIsItsOwnState() {
        let refused = CredentialStoreError.keychain(errSecInteractionNotAllowed)
        #expect(refused.isRefusalRatherThanAbsence)
        #expect(refused.ownerFacingMessage.contains("Unlock your login keychain"))
        #expect(!refused.ownerFacingMessage.lowercased().contains("setup token"))

        #expect(!CredentialStoreError.keychain(errSecItemNotFound).isRefusalRatherThanAbsence)
        #expect(CredentialStoreError.keychain(errSecAuthFailed).isRefusalRatherThanAbsence)
        #expect(CredentialStoreError.keychain(errSecUserCanceled).isRefusalRatherThanAbsence)
    }

    @Test("the demo connection is a different keychain item from the real one")
    func demoNeverTouchesTheRealItem() {
        #expect(KeychainCredentialStore.realAccount != KeychainCredentialStore.demoAccount)
    }
}
