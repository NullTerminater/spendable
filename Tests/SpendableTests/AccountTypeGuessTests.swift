import Foundation
import Testing
@testable import Spendable

/// The names in this suite are real US bank and credit-union account names. They come from the
/// design review that ran before the guesser was written, which found that both obvious
/// implementations are wrong in opposite directions: splitting on whitespace misses
/// "CHECKING-4417", and substring matching calls "CARDINAL CHECKING" a credit card.
@Suite("Guessing what kind of account the bank sent")
struct AccountTypeGuessTests {
    static func guess(_ name: String, _ institutions: [String] = []) -> AccountTypeGuess.Guess {
        AccountTypeGuess.guess(remoteName: name, institutionNames: institutions)
    }

    @Test("names that say plainly what they are", arguments: [
        ("CHASE TOTAL CHECKING", AccountType.checking),
        ("Capital One 360 Checking", .checking),
        ("Chase Total Checking®", .checking),
        ("CHECKING-4417", .checking),
        ("TOTAL CHKG/4417", .checking),
        ("SHARE DRAFT", .checking),
        ("Discover Cashback Debit", .checking),
        ("Checking (…4417)", .checking),
        ("Cuenta Corriente", .checking),
        ("Ally Online Savings", .savings),
        ("SHARE SAVINGS", .savings),
        ("REGULAR SHARES", .savings),
        ("12 MONTH CERTIFICATE", .savings),
        ("SAVINGS xxxx1234", .savings),
        ("Cuenta de Ahorros", .savings),
        ("PETTY CASH", .cash),
        ("CHASE SAPPHIRE PREFERRED CARD", .credit),
        ("Costco Anywhere Visa", .credit),
        ("CREDIT CARD ...9921", .credit),
        ("Tarjeta de Crédito", .credit),
    ])
    func unambiguousNames(name: String, expected: AccountType) {
        let result = Self.guess(name)
        #expect(result.type == expected, "\(name) guessed \(String(describing: result.type))")
        #expect(result.accountClass == nil)
        #expect(result.fromName == name)
    }

    @Test("the bank's own name is stripped before anything is matched")
    func institutionWordsAreNotEvidence() {
        // "credit union" must never leave a bare "credit" behind: this is a current account.
        #expect(Self.guess("ALLIANT CREDIT UNION CHECKING ...4417").type == .checking)
        #expect(Self.guess("NAVY FEDERAL CREDIT UNION - EVERYDAY CHECKING",
                           ["Navy Federal Credit Union"]).type == .checking)
        // "American Express" is card evidence, but not when it is simply who the bank is.
        #expect(Self.guess("AMERICAN EXPRESS HIGH YIELD SAVINGS ...1234",
                           ["American Express National Bank"]).type == .savings)
        #expect(Self.guess("DISCOVER ONLINE SAVINGS", ["Discover Bank"]).type == .savings)
        // And "CARDINAL" is not "card": matching is by whole word, never by substring.
        #expect(Self.guess("CARDINAL CHECKING ...4417", ["Cardinal Credit Union"]).type == .checking)
    }

    @Test("two strong categories at once is a question, never a guess", arguments: [
        "SAVINGS SECURED VISA",
        "MONEY MARKET CHECKING",
        "VISA DEBIT ...4417",
    ])
    func collisionsAsk(name: String) {
        let result = Self.guess(name)
        #expect(result.type == nil, "\(name) should have asked, guessed \(String(describing: result.type))")
        #expect(result.accountClass == nil)
        #expect(result.isAsking)
    }

    @Test("marketing words are never evidence on their own", arguments: [
        "PLATINUM SELECT 4417", "CHASE SAPPHIRE RESERVE", "CITI DOUBLE CASH ...4417",
        "CITI CUSTOM CASH", "BLUE CASH EVERYDAY ...41007", "CASH MAGNET",
        "TOTAL ACCESS ...1234", "Acct 4412", "Chase Freedom Unlimited", "Venture Rewards",
        "FIDELITY GOVERNMENT CASH RESERVES", "SoFi Money",
    ])
    func marketingWordsAsk(name: String) {
        let result = Self.guess(name)
        #expect(result.isAsking, "\(name) guessed \(String(describing: result.type)) / \(String(describing: result.accountClass))")
    }

    @Test("a weak word next to a strong one neither guesses nor blocks")
    func weakWordsDoNotBlock() {
        // "Platinum" is meaningless; "savings" is not.
        #expect(Self.guess("WELLS FARGO PLATINUM SAVINGS", ["Wells Fargo Bank"]).type == .savings)
        // "Student" is not a loan word: this is a real current account.
        #expect(Self.guess("WELLS FARGO STUDENT CHECKING").type == .checking)
    }

    @Test("shares and funds are recognised, and are never money", arguments: [
        "FIDELITY CASH MANAGEMENT ...4412", "VANGUARD SETTLEMENT FUND", "SCHWAB BROKERAGE",
        "ROTH IRA", "MONEY MARKET FUND",
    ])
    func investments(name: String) {
        let result = Self.guess(name)
        #expect(result.accountClass == .investment, "\(name) gave \(String(describing: result.accountClass))")
        #expect(result.type == nil)
    }

    @Test("money owed is recognised as owed", arguments: [
        "CHASE AUTO LOAN", "HELOC", "Sallie Mae Student Loan",
    ])
    func loans(name: String) {
        let result = Self.guess(name)
        #expect(result.accountClass == .loan, "\(name) gave \(String(describing: result.accountClass))")
        #expect(result.type == nil)
    }

    @Test("the longest phrase wins, so a fund is not read as savings")
    func longestPhraseWins() {
        // "money market fund" (investment) must beat "money market" (savings).
        #expect(Self.guess("MONEY MARKET FUND").accountClass == .investment)
        #expect(Self.guess("PRIME MONEY MARKET").type == .savings)
    }

    @Test("account numbers and masks say which account, never what kind")
    func masksAreIgnored() {
        #expect(AccountTypeGuess.tokens(of: "CHECKING ...4417") == ["checking"])
        #expect(AccountTypeGuess.tokens(of: "SAVINGS xxxx1234") == ["saving"])
        #expect(AccountTypeGuess.tokens(of: "Acct ****") == ["acct"])
        #expect(AccountTypeGuess.tokens(of: "4412") == [])
    }

    @Test("plurals fold, but words that merely end in s do not")
    func pluralFolding() {
        #expect(AccountTypeGuess.tokens(of: "SAVINGS") == ["saving"])
        #expect(AccountTypeGuess.tokens(of: "SHARES") == ["share"])
        #expect(AccountTypeGuess.tokens(of: "RESERVES") == ["reserve"])
        // Not plurals: these must survive intact or "access" would become "acces".
        #expect(AccountTypeGuess.tokens(of: "ACCESS") == ["access"])
        #expect(AccountTypeGuess.tokens(of: "BUSINESS") == ["business"])
        // Too short to be worth folding.
        #expect(AccountTypeGuess.tokens(of: "CDS") == ["cds"])
    }

    @Test("the balance is not an input, so an overdrawn account still asks")
    func balanceIsNotEvidence() {
        // Whatever the balance, the name is all there is. An overdrawn current account and a card
        // look identical to the protocol, so the app asks rather than deciding.
        #expect(Self.guess("TOTAL ACCESS 1234").isAsking)
        #expect(Self.guess("PREMIER PLUS 1224").isAsking)
    }

    @Test("the name the guess was made from is kept, so a rename can be noticed")
    func recordsItsSource() {
        let result = Self.guess("CHASE TOTAL CHECKING")
        #expect(result.fromName == "CHASE TOTAL CHECKING")
    }
}
