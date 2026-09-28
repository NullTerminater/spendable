import Foundation

/// Turns a bank's description of a charge into the key detection groups by.
///
/// The key is an identity: two charges with the same key on the same account may become one bill,
/// and a charge whose key changes may look like a bill that stopped. So every rule here is fixed
/// and pinned by a table-driven test (`docs/reviews/milestone-5-review.md`, decision 7). Changing
/// any rule means bumping `version`, which re-keys every stored row through the backfill.
enum MerchantKey {
    /// Bumped whenever any rule below changes.
    static let version = 1

    struct Result: Equatable, Sendable {
        /// Nil when nothing usable is left: such a row never groups with anything.
        var key: String?
        /// The description's key when `key` came from the payee. A bank that starts sending a payee
        /// part-way through history would otherwise make a bill look as if it had stopped.
        var alternate: String?
    }

    static func normalize(payee: String?, description: String) -> Result {
        let trimmedPayee = payee?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedPayee.isEmpty {
            let key = normalize(trimmedPayee)
            let alternate = normalize(description)
            return Result(key: key, alternate: alternate == key ? nil : alternate)
        }
        return Result(key: normalize(description), alternate: nil)
    }

    /// True when the text says the charge is yearly, a membership or a renewal (decision 28).
    static func hasYearlyKeyword(payee: String?, description: String, memo: String?) -> Bool {
        let text = [payee, description, memo].compactMap { $0 }.map(fold).joined(separator: " ")
        let tokens = Set(text.split(separator: " ").map(String.init))
        let words: Set<String> = ["ANNUAL", "YEARLY", "RENEWAL", "MEMBERSHIP", "PRIME"]
        if !tokens.isDisjoint(with: words) { return true }
        if tokens.contains(where: { $0.hasPrefix("SUBSCR") }) { return true }
        return text.contains("ONE YEAR")
    }

    // MARK: - The rules

    /// Processor prefixes, stripped from the front only, longest first, repeatedly. Each carries
    /// the brand that becomes the key when nothing follows it: "AMZN Mktp US*2K4LQ09" is the
    /// Amazon marketplace, and must never become an empty key or merge with AMAZON PRIME.
    private static let prefixes: [(tokens: [String], brand: String)] = [
        (["AMZN", "MKTP", "US", "*"], "AMZN MKTP"),
        (["DEBIT", "CARD", "PURCHASE"], ""),
        (["PAYPAL", "*"], "PAYPAL"),
        (["GOOGLE", "*"], "GOOGLE"),
        (["SQU", "*"], "SQ"),
        (["SQ", "*"], "SQ"),
        (["TST", "*"], "TST"),
        (["APL", "*"], "APPLE"),
        (["PP", "*"], "PAYPAL"),
        (["CHECKCARD"], ""),
        (["POS"], ""),
    ].sorted { $0.tokens.count > $1.tokens.count }

    /// Words that never count towards the three that make a key.
    static let stopwords: Set<String> = [
        "THE", "OF", "AND", "&", "INC", "LLC", "LTD", "CO", "CORP", "COMPANY", "USA", "US",
        "ONLINE", "PAYMENT", "PURCHASE",
    ]

    /// Kept after the first three significant words, because they separate products of one company:
    /// AMAZON PRIME is not the Amazon marketplace, and APPLE MUSIC is not iCloud.
    static let productWords: Set<String> = [
        "PRIME", "KINDLE", "AUDIBLE", "MUSIC", "TV", "PLUS", "PREMIUM", "VIDEO", "STORAGE", "ICLOUD", "ONE",
    ]

    /// Two-letter state codes that are dropped from the end. The ones that are also ordinary words
    /// or abbreviations (CO is "company", IN, OR, ME, OK, HI, OH, LA, PA, DE, AL, MD) are left in:
    /// guessing wrong there would split one merchant into two.
    private static let stateCodes: Set<String> = [
        "AK", "AZ", "AR", "CA", "CT", "FL", "GA", "ID", "IL", "IA", "KS", "KY", "MA", "MI", "MN",
        "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY", "NC", "ND", "RI", "SC", "SD", "TN",
        "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY", "DC", "PR",
    ]

    /// Unicode compatibility decomposition, then ASCII only, then uppercase without a locale: an
    /// Azerbaijani or Turkish locale would otherwise turn "spotify" into "SPOTİFY" and change the
    /// key whenever the owner changed their language settings. Hyphens and apostrophes join
    /// ("7-ELEVEN" is "7ELEVEN"); everything else outside the kept set becomes a space.
    static func fold(_ text: String) -> String {
        var out = ""
        for scalar in text.decomposedStringWithCompatibilityMapping.unicodeScalars {
            guard scalar.isASCII else { continue }
            var character = Character(scalar)
            if let ascii = character.asciiValue, ascii >= 97, ascii <= 122 {
                character = Character(UnicodeScalar(ascii - 32))
            }
            switch character {
            case "A"..."Z", "0"..."9", "&", ".", "/", "#":
                out.append(character)
            case "*":
                out.append(" * ")
            case "-", "'":
                continue
            default:
                out.append(" ")
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    static func normalize(_ text: String) -> String? {
        var tokens = fold(text).split(separator: " ").map(String.init)

        // Web addresses. APPLE.COM/BILL is Apple; a .COM or .NET tail and a WWW. head are noise.
        tokens = tokens.map(stripWebAddress).filter { !isSlashDate($0) }
        tokens = tokens.flatMap { $0.split(whereSeparator: { $0 == "/" }).map(String.init) }

        var brandIfEmpty: String?
        var stripped = true
        while stripped {
            stripped = false
            for prefix in prefixes where tokens.starts(with: prefix.tokens) {
                tokens.removeFirst(prefix.tokens.count)
                if !prefix.brand.isEmpty { brandIfEmpty = prefix.brand }
                stripped = true
                break
            }
        }

        // A reference code follows a star: "AMAZON PRIME*2K4LQ09".
        var cleaned: [String] = []
        var afterStar = false
        for token in tokens {
            if token == "*" { afterStar = true; continue }
            defer { afterStar = false }
            if afterStar, token.contains(where: \.isNumber) { continue }
            if isReference(token) { continue }
            let bare = token.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "#", with: "")
            if !bare.isEmpty { cleaned.append(bare) }
        }

        // A trailing country, then at most one trailing state code, and nothing else: city words
        // are never guessed, because dropping the wrong one merges two merchants.
        while let last = cleaned.last, last == "US" || last == "USA", cleaned.count > 1 { cleaned.removeLast() }
        if cleaned.count > 1, let last = cleaned.last, stateCodes.contains(last) { cleaned.removeLast() }

        let significant = cleaned.filter { !stopwords.contains($0) }
        var key = Array(significant.prefix(3))
        if significant.count > 3, let product = significant.dropFirst(3).first(where: { productWords.contains($0) }) {
            key.append(product)
        }
        if key.isEmpty, let brand = brandIfEmpty { return brand }
        if key.isEmpty { return nil }
        return key.joined(separator: " ")
    }

    private static func stripWebAddress(_ token: String) -> String {
        var token = token
        if token.hasPrefix("APPLE.COM") { return "APPLE" }
        if token.hasPrefix("WWW.") { token.removeFirst(4) }
        for tail in [".COM", ".NET", ".ORG", ".CO", ".IO", ".TV"] {
            if let range = token.range(of: tail),
               range.upperBound == token.endIndex || token[range.upperBound] == "/" {
                return String(token[..<range.lowerBound])
            }
        }
        return token
    }

    /// 09/14 or 9/14/26: a date printed into the description.
    private static func isSlashDate(_ token: String) -> Bool {
        let parts = token.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isNumber) }
    }

    /// Reference numbers, masked card numbers and dates: they change from charge to charge and would
    /// give one merchant a different key every month.
    private static func isReference(_ token: String) -> Bool {
        if token.hasPrefix("#") { return true }
        let digits = token.filter(\.isNumber).count
        let letters = token.filter(\.isLetter).count
        if digits == 0 { return false }
        if letters == 0 { return digits >= 3 }
        // XX1234, a masked card number.
        if token.hasPrefix("XX"), token.drop(while: { $0 == "X" }).allSatisfy(\.isNumber) { return true }
        // A long run of digits inside a word.
        var run = 0
        for character in token {
            run = character.isNumber ? run + 1 : 0
            if run >= 4 { return true }
        }
        // Mixed codes. A name with a digit or two survives: 1PASSWORD, 23ANDME, 7ELEVEN.
        return digits >= 3 || letters < 2
    }
}
