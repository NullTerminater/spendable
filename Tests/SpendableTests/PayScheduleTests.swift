import Foundation
import Testing
@testable import Spendable

@Suite("Pay schedule: when the next paycheck lands")
struct PayScheduleTests {
    static var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    static func day(_ year: Int, _ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: year, month: month, day: day)
    }

    @Test("finds the next payday from an anchor in the past")
    func nextFromPastAnchor() {
        let c = Self.chicago
        let schedule = PaySchedule(anchor: Self.day(2026, 9, 11))
        #expect(schedule.nextPayday(after: Self.day(2026, 9, 14), in: c) == Self.day(2026, 9, 25))
        #expect(schedule.nextPayday(after: Self.day(2026, 9, 24), in: c) == Self.day(2026, 9, 25))
    }

    @Test("on payday itself the answer is the following payday, never today")
    func paydayItself() {
        let c = Self.chicago
        let schedule = PaySchedule(anchor: Self.day(2026, 9, 11))
        #expect(schedule.nextPayday(after: Self.day(2026, 9, 11), in: c) == Self.day(2026, 9, 25))
        #expect(schedule.nextPayday(after: Self.day(2026, 9, 25), in: c) == Self.day(2026, 10, 9))
    }

    @Test("works when the anchor is in the future")
    func futureAnchor() {
        let c = Self.chicago
        let schedule = PaySchedule(anchor: Self.day(2026, 9, 25))
        #expect(schedule.nextPayday(after: Self.day(2026, 9, 14), in: c) == Self.day(2026, 9, 25))
        #expect(schedule.nextPayday(after: Self.day(2026, 9, 24), in: c) == Self.day(2026, 9, 25))
        #expect(schedule.nextPayday(after: Self.day(2026, 8, 20), in: c) == Self.day(2026, 8, 28))
    }

    @Test("works when the anchor is years old")
    func oldAnchor() {
        let c = Self.chicago
        let schedule = PaySchedule(anchor: Self.day(2020, 1, 3))
        let next = schedule.nextPayday(after: Self.day(2026, 9, 14), in: c)
        let nextDay = try! #require(next)
        #expect(nextDay > Self.day(2026, 9, 14))
        #expect(nextDay.days(to: Self.day(2026, 9, 14), in: c) >= -14)
        // Still on the 14-day grid from the anchor.
        #expect(Self.day(2020, 1, 3).days(to: nextDay, in: c) % 14 == 0)
    }

    @Test("the payday grid survives daylight saving, staying exactly 14 days apart")
    func acrossDaylightSaving() {
        let c = Self.chicago
        let schedule = PaySchedule(anchor: Self.day(2026, 2, 27))
        // Clocks go forward on 8 March 2026.
        let first = try! #require(schedule.nextPayday(after: Self.day(2026, 2, 27), in: c))
        #expect(first == Self.day(2026, 3, 13))
        let second = try! #require(schedule.nextPayday(after: first, in: c))
        #expect(second == Self.day(2026, 3, 27))
        #expect(first.days(to: second, in: c) == 14)
    }

    @Test("finds the most recent payday on or before a day")
    func mostRecent() {
        let c = Self.chicago
        let schedule = PaySchedule(anchor: Self.day(2026, 9, 11))
        #expect(schedule.mostRecentPayday(onOrBefore: Self.day(2026, 9, 14), in: c) == Self.day(2026, 9, 11))
        #expect(schedule.mostRecentPayday(onOrBefore: Self.day(2026, 9, 11), in: c) == Self.day(2026, 9, 11))
        #expect(schedule.mostRecentPayday(onOrBefore: Self.day(2026, 9, 10), in: c) == Self.day(2026, 8, 28))
    }

    @Test("an unreadable anchor yields no payday rather than a wrong one")
    func brokenAnchor() {
        let c = Self.chicago
        let schedule = PaySchedule(anchorDay: "not a date")
        #expect(schedule.anchor == nil)
        #expect(schedule.nextPayday(after: Self.day(2026, 9, 14), in: c) == nil)
        #expect(schedule.mostRecentPayday(onOrBefore: Self.day(2026, 9, 14), in: c) == nil)
    }

    @Test("rounds toward negative infinity so a future anchor never skips a payday")
    func floorDivision() {
        #expect(PaySchedule.floorDivide(0, by: 14) == 0)
        #expect(PaySchedule.floorDivide(13, by: 14) == 0)
        #expect(PaySchedule.floorDivide(14, by: 14) == 1)
        #expect(PaySchedule.floorDivide(-1, by: 14) == -1)
        #expect(PaySchedule.floorDivide(-14, by: 14) == -1)
        #expect(PaySchedule.floorDivide(-15, by: 14) == -2)
    }
}
