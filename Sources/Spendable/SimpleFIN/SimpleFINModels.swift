import Foundation

// The shape of a SimpleFIN version 2 response.
//
// Every key is spelled out. No `keyDecodingStrategy` is correct for this document — `available-balance`
// and `balance-date` are hyphenated while `conn_id` and `org_name` are snake_case — and the natural
// mistake, mirroring the database records' `.convertFromSnakeCase`, decodes `conn_id` correctly and
// leaves the two balance fields nil without throwing. A silently nil balance is the worst possible
// failure here, so the keys are written out and `balance-date` is non-optional: a wrong key throws.

/// One error from the server. The code's prefix says who it is about.
struct SimpleFINServerError: Decodable, Sendable, Equatable {
    let code: String
    let msg: String
    let connId: String?
    let accountId: String?

    enum CodingKeys: String, CodingKey {
        case code, msg
        case connId = "conn_id"
        case accountId = "account_id"
    }

    /// `act`, `con` or `gen`. Unknown subcodes fall back to their prefix, as the protocol requires.
    var prefix: String {
        String(code.prefix(while: { $0 != "." }))
    }

    /// The server is warning that the app is asking too often. The one notice before the token is
    /// disabled, which would cost the owner a hand-made setup token to recover from.
    var isQuotaWarning: Bool {
        let text = msg.lowercased()
        return code.hasPrefix("gen.api")
            && (text.contains("rate") || text.contains("quota") || text.contains("requests"))
    }

    /// The server did not answer the question that was asked: it trimmed the range. Nothing in a
    /// response like this can be trusted to be complete.
    ///
    /// Told apart from the gentler warning by tense. "Requested date range exceeds recommended
    /// range of 45 days. In the future, this may be capped." is advice; "exceeds limit of 90 days
    /// and was capped" is a hole in the data. Matching the bare word "cap" catches both, and
    /// throwing away a perfectly good response is its own kind of wrong.
    var meansTheRangeWasCapped: Bool {
        let text = msg.lowercased()
        guard code.hasPrefix("gen.api") else { return false }
        if text.contains("may be capped") || text.contains("recommended range") { return false }
        return text.contains("was capped") || text.contains("exceeds limit")
    }
}

struct SimpleFINConnection: Decodable, Sendable, Equatable {
    let connId: String
    let name: String
    let orgId: String?
    let orgName: String?
    let orgUrl: String?
    let sfinUrl: String?

    enum CodingKeys: String, CodingKey {
        case name
        case connId = "conn_id"
        case orgId = "org_id"
        case orgName = "org_name"
        case orgUrl = "org_url"
        case sfinUrl = "sfin_url"
    }
}

/// Holdings are a Bridge extension, not part of the protocol, and their contents are of no use to
/// this app. Their *presence* is the strongest signal in the whole response that a balance is a
/// market value rather than money, so they are decoded only to be counted.
struct SimpleFINHolding: Decodable, Sendable, Equatable {}

struct SimpleFINTransaction: Decodable, Sendable, Equatable {
    let id: String
    let posted: Int64
    let amount: String
    let description: String
    let payee: String?
    let memo: String?
    let transactedAt: Int64?
    let pending: Bool?
    let mcc: String?

    enum CodingKeys: String, CodingKey {
        case id, posted, amount, description, payee, memo, pending, mcc
        case transactedAt = "transacted_at"
    }

    /// The key is absent rather than false once a transaction has posted.
    var isPending: Bool { pending ?? false }
}

struct SimpleFINAccount: Decodable, Sendable, Equatable {
    let id: String
    let name: String
    let connId: String?
    let currency: String
    let balance: String
    let availableBalance: String?
    let balanceDate: Int64
    let transactions: [SimpleFINTransaction]?
    let holdings: [SimpleFINHolding]?

    enum CodingKeys: String, CodingKey {
        case id, name, currency, balance, transactions, holdings
        case connId = "conn_id"
        case availableBalance = "available-balance"
        case balanceDate = "balance-date"
    }
}

/// A whole answer from `/accounts`.
struct SimpleFINAccountSet: Decodable, Sendable, Equatable {
    /// Required. A missing `errlist` is a decoding failure, never "no errors": the difference
    /// between the server saying nothing is wrong and the app failing to ask properly is the
    /// difference between a healthy sync and a silent one.
    let errlist: [SimpleFINServerError]
    /// Deprecated in version 2 but not removed, and the Bridge's own guide says the rate-limit
    /// warning arrives here rather than in `errlist`.
    let errors: [String]?
    let connections: [SimpleFINConnection]?
    let accounts: [SimpleFINAccount]

    enum CodingKeys: String, CodingKey {
        case errlist, errors, connections, accounts
    }

    /// A decoder with no key strategy at all. See the note at the top of this file.
    static func decode(_ data: Data) throws -> SimpleFINAccountSet {
        try JSONDecoder().decode(SimpleFINAccountSet.self, from: data)
    }

    var wasRangeCapped: Bool {
        errlist.contains(where: \.meansTheRangeWasCapped)
    }

    var carriesQuotaWarning: Bool {
        if errlist.contains(where: \.isQuotaWarning) { return true }
        return (errors ?? []).contains { text in
            let lower = text.lowercased()
            return lower.contains("rate") || lower.contains("quota") || lower.contains("limit")
                || lower.contains("requests")
        }
    }

    /// The whole credential has stopped working, as opposed to one bank inside it.
    var hasGeneralAuthFailure: Bool {
        errlist.contains { $0.code == "gen.auth" || $0.code == "gen.auth." }
    }

    /// The name to call a bank, given an account's connection. The connection's own name is the one
    /// the protocol says includes the institution, and the one the owner will recognise; the demo
    /// shows why the order matters, with `name` "SimpleFIN Demo" and `orgName` "SimpleFIN Bridge".
    func institutionName(forConnection connId: String?) -> String? {
        guard let connId, let connection = (connections ?? []).first(where: { $0.connId == connId })
        else { return nil }
        return connection.name.isEmpty ? connection.orgName : connection.name
    }

    func connection(_ connId: String?) -> SimpleFINConnection? {
        guard let connId else { return nil }
        return (connections ?? []).first { $0.connId == connId }
    }
}
