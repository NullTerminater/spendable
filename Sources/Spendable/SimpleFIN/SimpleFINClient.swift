import Foundation
import os

/// What can go wrong talking to SimpleFIN, in terms the app can act on.
///
/// No case stores an underlying `Error`. A `URLError` from the claim request carries the failing
/// URL in its `userInfo`, and that URL contains the setup token — a bearer credential that gives
/// whoever reads it live access to the owner's banks. `localizedDescription` hides it while
/// `String(describing:)` does not, so a redaction test looking only at the description would pass
/// while the token went into the log. The safest shape is an error that never held it.
enum SimpleFINFailure: Error, Equatable, Sendable {
    /// The pasted text is not a setup token.
    case notASetupToken
    /// The token was already claimed, or never existed.
    case tokenAlreadyUsed
    /// The claim worked but the answer was not a usable access URL.
    case claimAnswerUnusable
    /// The server sent the app somewhere else. Carries only the host, never the path or query.
    case redirected(toHost: String)
    /// HTTP 402.
    case subscriptionProblem(serverMessage: String?)
    /// HTTP 403 on a data request: the stored credential no longer works.
    case credentialRejected(serverMessage: String?)
    case unexpectedStatus(Int)
    case couldNotReachServer(Transport)
    case couldNotUnderstandAnswer
    /// The server trimmed the range it was asked for, so the answer is incomplete.
    case rangeWasCapped(String)

    enum Transport: Equatable, Sendable {
        case offline
        case timedOut
        case cancelled
        case secureConnectionFailed
        case other
    }

    /// Plain English, and never a word of it derived from a credential.
    var ownerFacingMessage: String {
        switch self {
        case .notASetupToken:
            "That doesn't look like a SimpleFIN setup token. Copy it again from the SimpleFIN website."
        case .tokenAlreadyUsed:
            "This setup token was already used or doesn't exist. If you didn't use it in another app, someone else may have — disable it on the SimpleFIN website, then generate a fresh one."
        case .claimAnswerUnusable:
            "SimpleFIN answered, but not with a connection I can use. Generate a fresh setup token and try again."
        case .redirected(let host):
            "SimpleFIN sent me to \(host) instead of answering. If you made this token a while ago, generate a new one from the SimpleFIN website."
        case .subscriptionProblem(let message):
            "SimpleFIN answered \"payment required\", which usually means the subscription needs renewing." + Self.appending(message)
        case .credentialRejected(let message):
            "SimpleFIN no longer accepts the saved connection." + Self.appending(message)
        case .unexpectedStatus(let status):
            "SimpleFIN answered in a way I didn't expect (\(status)). Nothing has changed; I'll try again later."
        case .couldNotReachServer(.offline):
            "I couldn't reach SimpleFIN. Check your internet connection."
        case .couldNotReachServer:
            "I couldn't reach SimpleFIN just now. Nothing has changed; I'll try again later."
        case .couldNotUnderstandAnswer:
            "SimpleFIN answered in a shape I don't understand. Nothing has been changed."
        case .rangeWasCapped:
            "SimpleFIN returned less history than I asked for, so I've thrown that answer away rather than store a gap."
        }
    }

    private static func appending(_ serverMessage: String?) -> String {
        guard let serverMessage, !serverMessage.isEmpty else { return "" }
        return " SimpleFIN said: \"\(serverMessage)\""
    }

    /// Converts a URLSession error without ever holding on to it.
    static func from(urlError code: URLError.Code) -> SimpleFINFailure {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dataNotAllowed, .internationalRoamingOff:
            .couldNotReachServer(.offline)
        case .timedOut:
            .couldNotReachServer(.timedOut)
        case .cancelled:
            .couldNotReachServer(.cancelled)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .appTransportSecurityRequiresSecureConnection:
            .couldNotReachServer(.secureConnectionFailed)
        default:
            .couldNotReachServer(.other)
        }
    }
}

/// What the app asked for. Which questions a response is allowed to answer depends entirely on
/// this, so it travels with the response rather than being inferred from it.
enum SimpleFINRequestKind: Equatable, Sendable {
    /// Balances and nothing else. The only request whose answer may write a balance, and an answer
    /// that says nothing whatever about transactions.
    case balances
    /// Transactions for a span of days. Its balance fields are parsed and thrown away.
    case window(start: CalendarDay, end: CalendarDay)

    var isWindow: Bool {
        if case .window = self { return true }
        return false
    }
}

/// Refuses every redirect.
///
/// Not because the credential would leak — CFNetwork strips a manually set `Authorization` header
/// across a redirect — but because following one silently downgrades the request to unauthenticated,
/// and an unauthenticated request to the Bridge answers 403, which the app would otherwise read as
/// "your connection has died; paste a new setup token". A 3xx has to be diagnosed, not followed.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Talks to SimpleFIN. Holds no state beyond its session.
struct SimpleFINClient: Sendable {
    /// The most days the app will ever ask for at once. The Bridge caps a request at 90 days and
    /// warns above 45; a request that gets capped comes back looking complete.
    static let longestWindowDays = 44

    private let session: URLSession
    private let delegate = RedirectRefuser()
    private static let log = Logger(subsystem: StorePaths.bundleIdentifier, category: "simplefin")

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = nil
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        // The host is known and fixed; there is no reason to route bank traffic through whatever
        // proxy the machine happens to be configured for.
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }

    // MARK: Claiming

    /// Turns the base64 text the owner pasted into a claim URL.
    static func claimURL(fromSetupToken token: String) throws -> URL {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let decoded = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]),
              let text = String(data: decoded, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              url.host() != nil
        else { throw SimpleFINFailure.notASetupToken }
        return url
    }

    /// Claims an access URL. The token is single-use: whatever comes back is the only chance to
    /// keep it, so the caller must store it before doing anything else.
    func claim(claimURL: URL) async throws -> SimpleFINCredential {
        var request = URLRequest(url: claimURL)
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200:
            guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let credential = Self.credential(fromAccessURL: text)
            else { throw SimpleFINFailure.claimAnswerUnusable }
            return credential
        case 403:
            throw SimpleFINFailure.tokenAlreadyUsed
        case 300...399:
            throw Self.redirection(response)
        default:
            throw SimpleFINFailure.unexpectedStatus(response.statusCode)
        }
    }

    /// Splits an access URL into the parts that go in the Keychain.
    ///
    /// Read through `URLComponents`, never `URL.user()` / `URL.password()`. Verified on this
    /// toolchain: for a password of `pq/rs@tu`, `URL.password()` returns `pq%2Frs%40tu` — still
    /// percent-encoded, despite the documented default. Writing that to the Keychain and then
    /// reading it back compares equal to itself, so the app would "verify" a password the server
    /// will never accept, and the single-use token would already be spent.
    static func credential(fromAccessURL text: String) -> SimpleFINCredential? {
        guard let url = URL(string: text),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let user = components.user, let password = components.password,
              !user.isEmpty, !password.isEmpty
        else { return nil }
        components.user = nil
        components.password = nil
        guard let base = components.url else { return nil }
        return SimpleFINCredential(baseURL: base, username: user, password: password)
    }

    // MARK: Reading

    /// Fetches one answer. The kind decides the query and, later, what the answer is allowed to say.
    func accounts(
        credential: SimpleFINCredential, kind: SimpleFINRequestKind
    ) async throws -> SimpleFINAccountSet {
        let request = try Self.accountsRequest(credential: credential, kind: kind)
        let (data, response) = try await send(request)

        switch response.statusCode {
        case 200:
            break
        case 402:
            throw SimpleFINFailure.subscriptionProblem(serverMessage: Self.serverMessage(in: data))
        case 403:
            throw SimpleFINFailure.credentialRejected(serverMessage: Self.serverMessage(in: data))
        case 300...399:
            throw Self.redirection(response)
        default:
            throw SimpleFINFailure.unexpectedStatus(response.statusCode)
        }

        let set: SimpleFINAccountSet
        do {
            set = try SimpleFINAccountSet.decode(data)
        } catch {
            throw SimpleFINFailure.couldNotUnderstandAnswer
        }
        // A trimmed range comes back as HTTP 200 looking complete. Nothing in it can be trusted to
        // be the whole answer, and the app cannot tell which part is missing, so the whole response
        // is thrown away rather than stored with a hole in it.
        if let capped = set.errlist.first(where: \.meansTheRangeWasCapped) {
            throw SimpleFINFailure.rangeWasCapped(capped.msg)
        }
        return set
    }

    static func accountsRequest(
        credential: SimpleFINCredential, kind: SimpleFINRequestKind
    ) throws -> URLRequest {
        var components = URLComponents(
            url: credential.baseURL.appendingPathComponent("accounts"), resolvingAgainstBaseURL: false)
        var query = [URLQueryItem(name: "version", value: "2")]
        switch kind {
        case .balances:
            query.append(URLQueryItem(name: "balances-only", value: "1"))
        case .window(let start, let end):
            let days = start.days(to: end, in: CalendarDay.utc)
            guard days >= 0, days <= longestWindowDays else {
                throw SimpleFINFailure.rangeWasCapped("the app tried to ask for \(days + 1) days at once")
            }
            query.append(URLQueryItem(name: "pending", value: "1"))
            query.append(URLQueryItem(name: "start-date", value: String(start.utcMidnight)))
            // Exclusive at the far end, per the protocol: "before, but not on".
            query.append(URLQueryItem(name: "end-date", value: String(end.adding(days: 1, in: CalendarDay.utc).utcMidnight)))
        }
        components?.queryItems = query
        guard let url = components?.url else { throw SimpleFINFailure.claimAnswerUnusable }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // In a header, never in the URL. A URL with a password in it ends up in logs, in crash
        // reports and in error messages; a header does not.
        let pair = Data("\(credential.username):\(credential.password)".utf8).base64EncodedString()
        request.setValue("Basic \(pair)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: Plumbing

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else {
                throw SimpleFINFailure.couldNotUnderstandAnswer
            }
            Self.log.info("simplefin answered \(http.statusCode, privacy: .public)")
            return (data, http)
        } catch let failure as SimpleFINFailure {
            throw failure
        } catch let error as URLError {
            throw SimpleFINFailure.from(urlError: error.code)
        } catch {
            throw SimpleFINFailure.couldNotReachServer(.other)
        }
    }

    /// A 3xx, named by where it points and nothing else.
    private static func redirection(_ response: HTTPURLResponse) -> SimpleFINFailure {
        let location = response.value(forHTTPHeaderField: "Location") ?? ""
        let host = URL(string: location)?.host() ?? "somewhere else"
        return .redirected(toHost: host)
    }

    /// The server's own words from an error body, if it sent any.
    static func serverMessage(in data: Data) -> String? {
        guard let set = try? SimpleFINAccountSet.decode(data) else {
            // An error body need not be a full account set; try the errors list alone.
            struct JustErrors: Decodable {
                let errlist: [SimpleFINServerError]?
                let errors: [String]?
            }
            guard let partial = try? JSONDecoder().decode(JustErrors.self, from: data) else { return nil }
            return partial.errlist?.first?.msg ?? partial.errors?.first
        }
        return set.errlist.first?.msg ?? set.errors?.first
    }
}
