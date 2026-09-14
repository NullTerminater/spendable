import Foundation
import Testing
@testable import Spendable

@Suite("AsOf phrasing and staleness")
struct AsOfTests {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// 2026-09-14 (a Monday) at noon UTC.
    static let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 12))!

    static func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Int64 {
        Int64(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!.timeIntervalSince1970)
    }

    @Test("phrases recent days in words and older ones as dates")
    func phrases() {
        let c = Self.calendar
        #expect(AsOf.dayPhrase(epochSeconds: Self.day(2026, 9, 14), now: Self.now, calendar: c) == "today")
        #expect(AsOf.dayPhrase(epochSeconds: Self.day(2026, 9, 14, hour: 1), now: Self.now, calendar: c) == "today")
        #expect(AsOf.dayPhrase(epochSeconds: Self.day(2026, 9, 13), now: Self.now, calendar: c) == "yesterday")
        #expect(AsOf.dayPhrase(epochSeconds: Self.day(2026, 9, 11), now: Self.now, calendar: c) == "Friday")
        #expect(AsOf.dayPhrase(epochSeconds: Self.day(2026, 9, 8), now: Self.now, calendar: c) == "Tuesday")
        #expect(AsOf.dayPhrase(epochSeconds: Self.day(2026, 9, 7), now: Self.now, calendar: c) == "Sep 7")
        #expect(AsOf.dayPhrase(epochSeconds: Self.day(2025, 9, 7), now: Self.now, calendar: c) == "Sep 7, 2025")
    }

    @Test("future timestamps read as today, never as 'in 1 day'")
    func futureClamps() {
        let c = Self.calendar
        #expect(AsOf.dayPhrase(epochSeconds: Self.day(2026, 9, 20), now: Self.now, calendar: c) == "today")
        #expect(AsOf.isStale(epochSeconds: Self.day(2026, 9, 20), thresholdDays: 0, now: Self.now, calendar: c) == false)
    }

    @Test("staleness counts whole calendar days, strictly beyond the threshold")
    func staleness() {
        let c = Self.calendar
        #expect(AsOf.isStale(epochSeconds: Self.day(2026, 9, 12), thresholdDays: 2, now: Self.now, calendar: c) == false)
        #expect(AsOf.isStale(epochSeconds: Self.day(2026, 9, 11), thresholdDays: 2, now: Self.now, calendar: c) == true)
        #expect(AsOf.isStale(epochSeconds: Self.day(2026, 9, 11), thresholdDays: 3, now: Self.now, calendar: c) == false)
        #expect(AsOf.isStale(epochSeconds: Self.day(2026, 9, 10), thresholdDays: 3, now: Self.now, calendar: c) == true)
        // 23:59 two days ago is still "2 days", regardless of the hour.
        #expect(AsOf.isStale(epochSeconds: Self.day(2026, 9, 12, hour: 23), thresholdDays: 2, now: Self.now, calendar: c) == false)
    }
}
