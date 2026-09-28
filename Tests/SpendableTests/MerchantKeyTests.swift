import Foundation
import Testing
@testable import Spendable

/// Decision 7 of `docs/reviews/milestone-5-review.md`. A key is an identity, so every rule is pinned.
@Suite("Merchant keys")
struct MerchantKeyTests {
    @Test("descriptions become the keys the review pins", arguments: [
        ("SQ *BLUE BOTTLE COFFEE OAKLAND CA", "BLUE BOTTLE COFFEE"),
        ("PAYPAL *SPOTIFY", "SPOTIFY"),
        ("TST* JOES PIZZA", "JOES PIZZA"),
        ("Netflix.com", "NETFLIX"),
        ("NETFLIX.COM", "NETFLIX"),
        ("APPLE.COM/BILL", "APPLE"),
        ("AMZN Mktp US*2K4LQ09", "AMZN MKTP"),
        ("Amazon Prime*2K4LQ09", "AMAZON PRIME"),
        ("1PASSWORD", "1PASSWORD"),
        ("23andMe", "23ANDME"),
        ("7-Eleven #1234", "7ELEVEN"),
        ("CITY OF SPRINGFIELD UTILITIES", "CITY SPRINGFIELD UTILITIES"),
        ("CITY OF SPRINGFIELD PARKING", "CITY SPRINGFIELD PARKING"),
        ("SPOTIFY USA NEW YORK NY", "SPOTIFY NEW YORK"),
        ("ACME CO", "ACME"),
        ("SQ *PAYPAL *X", "X"),
        ("CHECKCARD 0914 NETFLIX", "NETFLIX"),
        ("POS DEBIT CARD PURCHASE GYM", "GYM"),
        ("GOOGLE *YouTube", "YOUTUBE"),
        ("XX1234 CITY POWER", "CITY POWER"),
        ("Café Olé", "CAFE OLE"),
        ("PLANET FITNESS 09/14", "PLANET FITNESS"),
        ("WWW.HULU.COM/BILL", "HULU"),
        ("APL* ITUNES.COM/BILL", "ITUNES"),
    ])
    func keys(description: String, expected: String) {
        #expect(MerchantKey.normalize(payee: nil, description: description).key == expected)
    }

    @Test("marketplace and Prime never share a key")
    func marketplaceIsNotPrime() {
        let marketplace = MerchantKey.normalize(payee: nil, description: "AMZN Mktp US*2K4LQ09").key
        let prime = MerchantKey.normalize(payee: nil, description: "Amazon Prime*7Q1ZZ83").key
        #expect(marketplace != prime)
        #expect(prime == MerchantKey.normalize(payee: nil, description: "AMAZON PRIME*2K4LQ09").key)
    }

    @Test("nothing usable left means no key, so the row never groups")
    func emptyKeys() {
        #expect(MerchantKey.normalize(payee: nil, description: "12345").key == nil)
        #expect(MerchantKey.normalize(payee: nil, description: "DEBIT CARD PURCHASE").key == nil)
        #expect(MerchantKey.normalize(payee: "   ", description: "").key == nil)
    }

    @Test("uppercasing never depends on the owner's language settings")
    func localeFree() {
        // A Turkish or Azerbaijani locale uppercases i to a dotted capital I.
        #expect(MerchantKey.normalize(payee: nil, description: "spotify").key == "SPOTIFY")
        #expect(MerchantKey.fold("istanbul") == "ISTANBUL")
    }

    @Test("the payee wins, and the description is kept as the alternate key")
    func payeeAndAlternate() {
        let result = MerchantKey.normalize(payee: "City Power", description: "ACH DEBIT CITYPOWER UTIL 0452")
        #expect(result.key == "CITY POWER")
        #expect(result.alternate == "ACH DEBIT CITYPOWER")
        let same = MerchantKey.normalize(payee: "NETFLIX", description: "NETFLIX.COM")
        #expect(same.alternate == nil)
    }

    @Test("yearly wording is recognised in any field, and ordinary wording is not")
    func yearlyKeywords() {
        #expect(MerchantKey.hasYearlyKeyword(payee: nil, description: "COSTCO MEMBERSHIP RENEWAL", memo: nil))
        #expect(MerchantKey.hasYearlyKeyword(payee: nil, description: "SOMEAPP", memo: "one year plan"))
        #expect(MerchantKey.hasYearlyKeyword(payee: nil, description: "SUBSCRIPTION SVC", memo: nil))
        #expect(!MerchantKey.hasYearlyKeyword(payee: nil, description: "BLUE BOTTLE COFFEE", memo: nil))
    }
}
