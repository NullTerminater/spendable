import Foundation
import Testing
@testable import Spendable

@Suite("CalendarDay: whole-day arithmetic")
struct CalendarDayTests {
    /// The owner's real setup: US Central, which observes daylight saving.
    static var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    @Test("reads and writes yyyy-mm-dd")
    func isoRoundTrip() throws {
        let day = CalendarDay(year: 2026, month: 9, day: 14)
        #expect(day.isoString == "2026-09-14")
        #expect(CalendarDay(isoString: "2026-09-14") == day)
        #expect(CalendarDay(isoString: "2026-01-02")?.isoString == "2026-01-02")
        for bad in ["", "2026-9-14", "2026/09/14", "26-09-14", "2026-13-01", "2026-09-32", "today", "2026-09"] {
            #expect(CalendarDay(isoString: bad) == nil, "should reject \(bad)")
        }
    }

    @Test("orders by year, then month, then day")
    func ordering() {
        #expect(CalendarDay(year: 2026, month: 9, day: 1) < CalendarDay(year: 2026, month: 9, day: 2))
        #expect(CalendarDay(year: 2026, month: 9, day: 30) < CalendarDay(year: 2026, month: 10, day: 1))
        #expect(CalendarDay(year: 2025, month: 12, day: 31) < CalendarDay(year: 2026, month: 1, day: 1))
        #expect(!(CalendarDay(year: 2026, month: 9, day: 14) < CalendarDay(year: 2026, month: 9, day: 14)))
    }

    @Test("adds days across month, year and daylight-saving boundaries")
    func addingDays() {
        let c = Self.chicago
        #expect(CalendarDay(year: 2026, month: 9, day: 14).adding(days: 1, in: c) == CalendarDay(year: 2026, month: 9, day: 15))
        #expect(CalendarDay(year: 2026, month: 9, day: 30).adding(days: 1, in: c) == CalendarDay(year: 2026, month: 10, day: 1))
        #expect(CalendarDay(year: 2026, month: 12, day: 31).adding(days: 1, in: c) == CalendarDay(year: 2027, month: 1, day: 1))
        #expect(CalendarDay(year: 2026, month: 9, day: 14).adding(days: -1, in: c) == CalendarDay(year: 2026, month: 9, day: 13))
        #expect(CalendarDay(year: 2026, month: 1, day: 1).adding(days: -1, in: c) == CalendarDay(year: 2025, month: 12, day: 31))
        // Spring forward: 8 March 2026 is 23 hours long in Chicago. Fourteen days is still 14 days.
        #expect(CalendarDay(year: 2026, month: 3, day: 1).adding(days: 14, in: c) == CalendarDay(year: 2026, month: 3, day: 15))
        // Fall back: 1 November 2026 is 25 hours long.
        #expect(CalendarDay(year: 2026, month: 10, day: 25).adding(days: 14, in: c) == CalendarDay(year: 2026, month: 11, day: 8))
        #expect(CalendarDay(year: 2026, month: 2, day: 28).adding(days: 1, in: c) == CalendarDay(year: 2026, month: 3, day: 1))
        #expect(CalendarDay(year: 2028, month: 2, day: 28).adding(days: 1, in: c) == CalendarDay(year: 2028, month: 2, day: 29))
    }

    @Test("counts whole days between dates, ignoring the time of day")
    func daysBetween() {
        let c = Self.chicago
        let base = CalendarDay(year: 2026, month: 9, day: 14)
        #expect(base.days(to: base, in: c) == 0)
        #expect(base.days(to: CalendarDay(year: 2026, month: 9, day: 15), in: c) == 1)
        #expect(base.days(to: CalendarDay(year: 2026, month: 9, day: 13), in: c) == -1)
        #expect(base.days(to: CalendarDay(year: 2026, month: 10, day: 14), in: c) == 30)
        // Across spring forward, 14 calendar days is 14, not 13.96 rounded down.
        #expect(CalendarDay(year: 2026, month: 3, day: 1).days(to: CalendarDay(year: 2026, month: 3, day: 15), in: c) == 14)
        #expect(CalendarDay(year: 2026, month: 10, day: 25).days(to: CalendarDay(year: 2026, month: 11, day: 8), in: c) == 14)
    }

    @Test("a late-evening and an early-morning timestamp on the same date are the same day")
    func timeOfDayIsIrrelevant() {
        let c = Self.chicago
        let lateEvening = c.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 23, minute: 59))!
        let earlyMorning = c.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 0, minute: 1))!
        #expect(CalendarDay(lateEvening, in: c) == CalendarDay(earlyMorning, in: c))
        #expect(CalendarDay(lateEvening, in: c).days(to: CalendarDay(year: 2026, month: 9, day: 14), in: c) == 1)
        #expect(CalendarDay(earlyMorning, in: c).days(to: CalendarDay(year: 2026, month: 9, day: 14), in: c) == 1)
    }

    @Test("adds months keeping the day of the month, clamped to the month's length")
    func addingMonths() {
        let c = Self.chicago
        let jan31 = CalendarDay(year: 2026, month: 1, day: 31)
        #expect(jan31.adding(months: 1, in: c) == CalendarDay(year: 2026, month: 2, day: 28))
        #expect(jan31.adding(months: 2, in: c) == CalendarDay(year: 2026, month: 3, day: 31))
        #expect(jan31.adding(months: 3, in: c) == CalendarDay(year: 2026, month: 4, day: 30))
        #expect(jan31.adding(months: 12, in: c) == CalendarDay(year: 2027, month: 1, day: 31))
        // 2028 is a leap year.
        #expect(CalendarDay(year: 2028, month: 1, day: 31).adding(months: 1, in: c) == CalendarDay(year: 2028, month: 2, day: 29))
        #expect(CalendarDay(year: 2026, month: 1, day: 29).adding(months: 1, in: c) == CalendarDay(year: 2026, month: 2, day: 28))
        #expect(CalendarDay(year: 2026, month: 1, day: 30).adding(months: 1, in: c) == CalendarDay(year: 2026, month: 2, day: 28))
        #expect(CalendarDay(year: 2026, month: 3, day: 15).adding(months: -1, in: c) == CalendarDay(year: 2026, month: 2, day: 15))
        #expect(CalendarDay(year: 2026, month: 3, day: 31).adding(months: -1, in: c) == CalendarDay(year: 2026, month: 2, day: 28))
        #expect(CalendarDay(year: 2026, month: 1, day: 15).adding(months: -1, in: c) == CalendarDay(year: 2025, month: 12, day: 15))
    }

    @Test("stepping n months from the anchor keeps the 31st; stepping one month at a time loses it")
    func anchorDoesNotDrift() {
        let c = Self.chicago
        let anchor = CalendarDay(year: 2026, month: 12, day: 31)
        let fromAnchor = (0...4).map { anchor.adding(months: $0, in: c) }
        #expect(fromAnchor == [
            CalendarDay(year: 2026, month: 12, day: 31),
            CalendarDay(year: 2027, month: 1, day: 31),
            CalendarDay(year: 2027, month: 2, day: 28),
            CalendarDay(year: 2027, month: 3, day: 31),
            CalendarDay(year: 2027, month: 4, day: 30),
        ])
        // The same sequence built by repeatedly adding one month to the previous result drifts to
        // the 28th and never comes back. This is why occurrences are always measured from the anchor.
        var walked: [CalendarDay] = [anchor]
        for _ in 0..<4 { walked.append(walked.last!.adding(months: 1, in: c)) }
        #expect(walked[3] == CalendarDay(year: 2027, month: 3, day: 28))
        #expect(walked != fromAnchor)
    }

    @Test("finds the first and last day of the month, including February")
    func monthBounds() {
        let c = Self.chicago
        let mid = CalendarDay(year: 2026, month: 9, day: 14)
        #expect(mid.startOfMonth(in: c) == CalendarDay(year: 2026, month: 9, day: 1))
        #expect(mid.endOfMonth(in: c) == CalendarDay(year: 2026, month: 9, day: 30))
        #expect(CalendarDay(year: 2026, month: 2, day: 10).endOfMonth(in: c) == CalendarDay(year: 2026, month: 2, day: 28))
        #expect(CalendarDay(year: 2028, month: 2, day: 10).endOfMonth(in: c) == CalendarDay(year: 2028, month: 2, day: 29))
        #expect(CalendarDay(year: 2026, month: 1, day: 31).endOfMonth(in: c) == CalendarDay(year: 2026, month: 1, day: 31))
        #expect(CalendarDay(year: 2026, month: 12, day: 25).endOfMonth(in: c) == CalendarDay(year: 2026, month: 12, day: 31))
    }

    @Test("round-trips through epoch seconds, which is how the schema stores a day")
    func epochRoundTrip() {
        let c = Self.chicago
        for day in [CalendarDay(year: 2026, month: 9, day: 14),
                    CalendarDay(year: 2026, month: 3, day: 8),   // spring forward
                    CalendarDay(year: 2026, month: 11, day: 1),  // fall back
                    CalendarDay(year: 2028, month: 2, day: 29)] {
            #expect(CalendarDay(epochSeconds: day.epochSeconds(in: c), in: c) == day)
        }
    }
}
