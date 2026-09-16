import Foundation

/// Money is `Int64` cents everywhere in Spendable. This is the only file that turns text into
/// cents and cents back into text. No `Double` anywhere; `Decimal` appears only inside the
/// formatter, at the display edge.
enum Cents {
    enum ParseError: Error, Equatable {
        case empty
        case invalidCharacter
        case tooManyFractionDigits
        case overflow
        case malformed
    }

    /// Exact parse of a decimal string such as `"-33293.43"`, `"100"`, `"0.5"`, `"-05.50"`, `"+7"`.
    ///
    /// Accepts an optional sign, digits, and at most two fractional digits. Rejects exponents,
    /// thousands separators, currency symbols, more than two fractional digits, and anything else.
    static func parse(_ text: String) throws -> Int64 {
        var scalars = Substring(text).unicodeScalars[...]
        while let first = scalars.first, isSpace(first) { scalars.removeFirst() }
        while let last = scalars.last, isSpace(last) { scalars.removeLast() }
        guard !scalars.isEmpty else { throw ParseError.empty }

        var negative = false
        if scalars.first == "-" {
            negative = true
            scalars.removeFirst()
        } else if scalars.first == "+" {
            scalars.removeFirst()
        }

        var whole: Int64 = 0
        var wholeDigits = 0
        var fraction: [Int64] = []
        var seenPoint = false

        for scalar in scalars {
            if scalar == "." {
                guard !seenPoint else { throw ParseError.malformed }
                seenPoint = true
                continue
            }
            guard let digit = digitValue(scalar) else { throw ParseError.invalidCharacter }
            if seenPoint {
                guard fraction.count < 2 else { throw ParseError.tooManyFractionDigits }
                fraction.append(digit)
            } else {
                let (times10, overflow1) = whole.multipliedReportingOverflow(by: 10)
                let (plusDigit, overflow2) = times10.addingReportingOverflow(digit)
                guard !overflow1, !overflow2 else { throw ParseError.overflow }
                whole = plusDigit
                wholeDigits += 1
            }
        }
        guard wholeDigits > 0 || !fraction.isEmpty else { throw ParseError.malformed }

        let fractionCents: Int64 = switch fraction.count {
        case 0: 0
        case 1: fraction[0] * 10
        default: fraction[0] * 10 + fraction[1]
        }
        let (scaled, overflow3) = whole.multipliedReportingOverflow(by: 100)
        guard !overflow3 else { throw ParseError.overflow }
        let (total, overflow4) = scaled.addingReportingOverflow(fractionCents)
        guard !overflow4 else { throw ParseError.overflow }
        return negative ? -total : total
    }

    /// Whole dollars, floored toward negative infinity: 123456 cents → 1234, -12050 → -121.
    /// Flooring keeps a headline from ever looking a cent more generous than the truth.
    static func flooredDollars(_ cents: Int64) -> Int64 {
        let quotient = cents / 100
        if cents < 0, cents % 100 != 0 { return quotient - 1 }
        return quotient
    }

    /// "$1,234.56" in the given locale. Exact cents, for disclosures and lists.
    ///
    /// `currency` is US dollars unless a caller says otherwise. Every number the engine produces is
    /// in US dollars by construction — an account in any other currency is held out — so the only
    /// callers that pass anything else are the ones showing a held-out account's own balance. A
    /// Canadian balance printed with a dollar sign invites the owner to retype it as US dollars.
    static func format(_ cents: Int64, locale: Locale = .current, currency: String = "USD") -> String {
        let formatter = currencyFormatter(locale: locale, currency: currency)
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let magnitude = Decimal(cents.magnitude)
        let decimal = Decimal(sign: cents < 0 ? .minus : .plus, exponent: -2, significand: magnitude)
        return formatter.string(from: decimal as NSDecimalNumber) ?? "$\(cents)"
    }

    /// "$1,234" for headlines: whole dollars, floored. Negative values keep their sign; the
    /// `$0 (balance: −$X)` rule for safe-to-spend is applied by the caller, not here.
    static func formatWholeDollars(_ cents: Int64, locale: Locale = .current) -> String {
        let formatter = currencyFormatter(locale: locale, currency: "USD")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        let dollars = flooredDollars(cents)
        return formatter.string(from: NSNumber(value: dollars)) ?? "$\(dollars)"
    }

    private static func currencyFormatter(locale: Locale, currency: String) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        // An unknown or empty code would make the formatter fall back to the locale's own currency,
        // which is the one mistake this parameter exists to prevent.
        formatter.currencyCode = currency.count == 3 ? currency.uppercased() : "USD"
        return formatter
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
    }

    private static func digitValue(_ scalar: Unicode.Scalar) -> Int64? {
        guard scalar.value >= 0x30, scalar.value <= 0x39 else { return nil }
        return Int64(scalar.value - 0x30)
    }
}
