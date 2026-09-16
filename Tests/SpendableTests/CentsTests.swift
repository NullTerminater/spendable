import Foundation
import Testing
@testable import Spendable

@Suite("Cents: exact parsing and display formatting")
struct CentsTests {
    @Test("parses SimpleFIN-style decimal strings exactly", arguments: [
        ("-33293.43", Int64(-3_329_343)),
        ("100", 10_000),
        ("100.23", 10_023),
        ("75.23", 7_523),
        ("0.5", 50),
        ("-05.50", -550),
        ("+7", 700),
        (".5", 50),
        ("5.", 500),
        ("0", 0),
        ("-0.00", 0),
        (" 12.34 ", 1_234),
        ("0.05", 5),
        ("115525.51", 11_552_551),
        ("92233720368547758.07", Int64.max),
    ])
    func parses(text: String, expected: Int64) throws {
        #expect(try Cents.parse(text) == expected)
    }

    @Test("rejects anything that is not a plain decimal", arguments: [
        "", "   ", "1,234.56", "$12", "12.345", "1e3", "abc", "--1", "1.2.3", ".", "-", "+", "12 34", "１２", "0x10", "NaN",
    ])
    func rejects(text: String) {
        #expect(throws: Cents.ParseError.self) { try Cents.parse(text) }
    }

    @Test("reports the specific problem")
    func errorKinds() {
        #expect(throws: Cents.ParseError.empty) { try Cents.parse("") }
        #expect(throws: Cents.ParseError.tooManyFractionDigits) { try Cents.parse("1.234") }
        #expect(throws: Cents.ParseError.invalidCharacter) { try Cents.parse("1,2") }
        #expect(throws: Cents.ParseError.malformed) { try Cents.parse("1.2.3") }
        #expect(throws: Cents.ParseError.overflow) { try Cents.parse("99999999999999999999") }
        #expect(throws: Cents.ParseError.overflow) { try Cents.parse("92233720368547758.08") }
    }

    @Test("floors whole dollars toward negative infinity")
    func flooring() {
        #expect(Cents.flooredDollars(123_456) == 1_234)
        #expect(Cents.flooredDollars(99) == 0)
        #expect(Cents.flooredDollars(0) == 0)
        #expect(Cents.flooredDollars(-1) == -1)
        #expect(Cents.flooredDollars(-12_000) == -120)
        #expect(Cents.flooredDollars(-12_050) == -121)
    }

    @Test("formats US dollars in the en_US locale")
    func formatting() {
        let us = Locale(identifier: "en_US")
        #expect(Cents.format(123_456, locale: us) == "$1,234.56")
        #expect(Cents.format(5, locale: us) == "$0.05")
        #expect(Cents.format(-12_050, locale: us) == "-$120.50")
        #expect(Cents.formatWholeDollars(123_456, locale: us) == "$1,234")
        #expect(Cents.formatWholeDollars(-12_050, locale: us) == "-$121")
        #expect(Cents.formatWholeDollars(0, locale: us) == "$0")
    }

    @Test("round-trips through parse and format")
    func roundTrip() throws {
        let us = Locale(identifier: "en_US")
        for cents: Int64 in [0, 1, 99, 100, 1_234_567, -1, -99, -123_456] {
            let text = Cents.format(cents, locale: us)
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
            #expect(try Cents.parse(text) == cents)
        }
    }

    @Test("a balance that is not in US dollars is not shown with a plain dollar sign")
    func formatsTheAccountsOwnCurrency() {
        let us = Locale(identifier: "en_US")
        #expect(Cents.format(240_000, locale: us) == "$2,400.00")
        #expect(Cents.format(240_000, locale: us, currency: "CAD") != "$2,400.00")
        #expect(Cents.format(240_000, locale: us, currency: "CAD").contains("2,400.00"))
        #expect(Cents.format(240_000, locale: us, currency: "EUR").contains("€"))
        // A code the formatter would not recognise must fall back to US dollars rather than to
        // whatever currency the owner's locale happens to use.
        #expect(Cents.format(240_000, locale: us, currency: "") == "$2,400.00")
        #expect(Cents.format(240_000, locale: us, currency: "cad") == Cents.format(240_000, locale: us, currency: "CAD"))
    }
}
