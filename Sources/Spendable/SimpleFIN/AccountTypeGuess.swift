import Foundation

/// Working out what kind of account a bank has sent, from its name alone.
///
/// SimpleFIN carries no account type, so this is a guess — and the owner's specification is
/// explicit that getting it wrong silently is worse than asking. Two mistakes in particular put a
/// wrong number in front of them: a credit card typed as a current account adds its credit limit to
/// what they can spend, and a brokerage sweep account named "…CASH MANAGEMENT" turns a share
/// portfolio into money. Both are avoided by refusing to guess rather than by guessing harder.
///
/// A pure function: a name in, a guess out. No database, no clock, no balance — the balance sign is
/// deliberately not an input, because the protocol defines no sign convention for what an account
/// owes and real banks differ, so it can only ever add noise to a name that already spoke.
enum AccountTypeGuess {
    /// What the name turned out to be, when it is not one of the four types the app can count.
    enum Class: String, Codable, Sendable, Equatable {
        /// Shares, funds, a retirement account, a brokerage sweep. Never money to spend.
        case investment
        /// A mortgage, a car loan, a line of credit. Money owed, not money held.
        case loan
    }

    struct Guess: Equatable, Sendable {
        var type: AccountType?
        var accountClass: Class?
        /// The exact string the guess was made from, so a later rename can be noticed without
        /// silently re-typing the account.
        var fromName: String

        /// The app has no idea and should ask.
        var isAsking: Bool { type == nil && accountClass == nil }
    }

    // MARK: The words

    /// Shares and funds. Checked first: these names very often also contain "cash" or "savings".
    static let investmentWords = [
        "cash management", "money market fund", "settlement fund", "mutual fund",
        "brokerage", "invest", "investment", "investor", "ira", "roth", "401k", "403b", "457",
        "sep", "rollover", "custodial", "ugma", "utma", "annuity", "portfolio", "cma", "sweep",
        "advisory", "managed", "529",
    ]

    /// Money owed rather than held. "student" alone is deliberately absent: a student checking
    /// account is a real current account.
    static let loanWords = [
        "student loan", "line of credit", "mortgage", "loan", "heloc", "lease",
    ]

    static let checkingWords = [
        "share draft", "draft account", "current account",
        "checking", "chequing", "chkg", "dda", "spending", "debit", "corriente",
    ]

    static let savingsWords = [
        "money market", "share savings", "regular share", "share certificate",
        "christmas club", "vacation club", "rainy day",
        "saving", "saver", "emergency", "certificate", "cd", "cds", "ahorro",
    ]

    /// The bare word "cash" is not here: it sits on "CITI DOUBLE CASH" and "BLUE CASH EVERYDAY",
    /// which are credit cards.
    static let cashWords = ["petty cash", "cash on hand", "wallet", "pocket"]

    static let creditWords = [
        "credit card", "charge card", "credit line",
        "card", "cardmember", "credit", "visa", "mastercard", "master card",
        "amex", "american express", "tarjeta", "credito",
    ]

    /// Never evidence of anything, written down so nobody adds them back. Every one of these sits on
    /// both deposit accounts and credit cards: "Wells Fargo Platinum Savings" and "Amex Platinum",
    /// "Chase Freedom" and "Freedom Checking", "Discover Bank" and the Discover card.
    static let neverKeywords = [
        "platinum", "select", "signature", "preferred", "world", "elite", "gold", "blue",
        "freedom", "venture", "quicksilver", "sapphire", "reserve", "reward", "cashback",
        "cash back", "discover", "cash", "everyday", "total", "access", "advantage", "premier",
        "plus", "one", "360", "essential", "complete", "secure", "high yield", "online", "free",
        "student", "business",
    ]

    /// Phrases removed before anything is matched, so "credit" can never survive out of
    /// "credit union" and turn a current account at a credit union into a card.
    static let strippedPhrases = ["federal credit union", "credit union"]

    /// Words that say which bank, not which kind of account.
    static let strippedWords = ["bank", "banking", "na", "fsb", "fcu", "cu"]

    // MARK: The guess

    static func guess(remoteName: String, institutionNames: [String] = []) -> Guess {
        var tokens = self.tokens(of: remoteName)

        // What the bank is called is not what the account is. Strip the phrases first, as phrases.
        for phrase in strippedPhrases {
            tokens = removing(self.tokens(of: phrase), from: tokens)
        }
        var noise = Set(strippedWords)
        for institution in institutionNames {
            noise.formUnion(self.tokens(of: institution))
        }
        tokens = tokens.filter { !noise.contains($0) }

        var remaining = tokens
        var hits: Set<String> = []

        // Phrases first, longest first, consuming what they match, so "money market fund" wins over
        // "money market" and "credit card" is never read as two separate words.
        let categories: [(name: String, words: [String])] = [
            ("investment", investmentWords), ("loan", loanWords),
            ("checking", checkingWords), ("savings", savingsWords),
            ("cash", cashWords), ("credit", creditWords),
        ]
        let phrases: [(String, [String])] = categories
            .flatMap { category -> [(String, [String])] in
                category.words.filter { $0.contains(" ") }.map { (category.name, Self.tokens(of: $0)) }
            }
            .sorted { $0.1.count > $1.1.count }
        for (category, phrase) in phrases {
            if let shortened = consuming(phrase, from: remaining) {
                hits.insert(category)
                remaining = shortened
            }
        }
        // Then single words, over whatever the phrases left.
        for (category, words) in categories {
            let singles = Set(words.filter { !$0.contains(" ") })
            if remaining.contains(where: { singles.contains($0) }) { hits.insert(category) }
        }

        // Money owed and shares are answers in themselves, and outrank the four countable types:
        // a "Fidelity Cash Management" account matches both "cash management" and nothing else,
        // and must never be read as cash.
        if hits.contains("loan") { return Guess(type: nil, accountClass: .loan, fromName: remoteName) }
        if hits.contains("investment") { return Guess(type: nil, accountClass: .investment, fromName: remoteName) }

        let countable: [(String, AccountType)] = [
            ("checking", .checking), ("savings", .savings), ("cash", .cash), ("credit", .credit),
        ]
        let matched = countable.filter { hits.contains($0.0) }
        // Two categories at once is not a close call to be settled by precedence: "Savings Secured
        // Visa" is a card and "Money Market Checking" is a current account, and no ordering gets
        // both right. Asking costs a click; guessing costs the owner money.
        guard matched.count == 1 else { return Guess(type: nil, accountClass: nil, fromName: remoteName) }
        return Guess(type: matched[0].1, accountClass: nil, fromName: remoteName)
    }

    // MARK: Words out of a name

    /// A bank's name for an account, reduced to comparable words.
    ///
    /// Matching is by whole word, never by substring: "CARDINAL CHECKING" contains "card", and a
    /// substring match would call a credit union's current account a credit card.
    static func tokens(of name: String) -> [String] {
        let folded = name.precomposedStringWithCompatibilityMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let cleaned = String(folded.map { character in
            character.isLetter || character.isNumber ? character : " "
        })
        return cleaned.split(separator: " ")
            .map(String.init)
            .filter { !isJustDigitsOrAMask($0) }
            .map(singular)
    }

    /// "…4417", "xxxx1234" and "****" say which account, never what kind.
    private static func isJustDigitsOrAMask(_ token: String) -> Bool {
        if token.allSatisfy(\.isNumber) { return true }
        var sawMask = false
        var inDigits = false
        for character in token {
            if character == "x" || character == "*" {
                if inDigits { return false }
                sawMask = true
            } else if character.isNumber {
                inDigits = true
            } else {
                return false
            }
        }
        return sawMask
    }

    /// "savings" and "saving" are the same word; "access" and "business" are not plurals.
    private static func singular(_ token: String) -> String {
        guard token.count >= 5, token.hasSuffix("s"), !token.hasSuffix("ss") else { return token }
        return String(token.dropLast())
    }

    private static func removing(_ phrase: [String], from tokens: [String]) -> [String] {
        consuming(phrase, from: tokens) ?? tokens
    }

    /// Returns the tokens with the first run matching `phrase` removed, or nil if it is not there.
    private static func consuming(_ phrase: [String], from tokens: [String]) -> [String]? {
        guard !phrase.isEmpty, tokens.count >= phrase.count else { return nil }
        for start in 0...(tokens.count - phrase.count) where Array(tokens[start..<(start + phrase.count)]) == phrase {
            var shortened = tokens
            shortened.removeSubrange(start..<(start + phrase.count))
            return shortened
        }
        return nil
    }
}
