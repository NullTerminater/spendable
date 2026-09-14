import Foundation
import Testing
@testable import Spendable

@Suite("Recurring charges: turning a bill into dated occurrences")
struct RecurringChargeTests {
    static var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    static func day(_ year: Int, _ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: year, month: month, day: day)
    }

    static func charge(
        _ name: String = "Rent",
        amount: Int64 = 50_000,
        cadence: Cadence = .monthly,
        anchor: CalendarDay,
        marker: CalendarDay? = nil
    ) -> RecurringCharge {
        var charge = RecurringCharge.manual(
            name: name, amountCents: amount, cadence: cadence,
            nextDue: marker ?? anchor, payingAccountId: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000), calendar: chicago)
        charge.anchorDate = anchor.epochSeconds(in: chicago)
        return charge
    }

    static func window(_ from: CalendarDay, _ to: CalendarDay) -> ClosedRange<CalendarDay> { from...to }

    // MARK: The bug the review caught: a bill already paid must not come back

    @Test("rent paid through October is not subtracted again in September")
    func paidAheadIsNotResurrected() {
        let c = Self.chicago
        // The owner pays September's rent, so the marker moves to October 1.
        let rent = Self.charge(anchor: Self.day(2026, 1, 1), marker: Self.day(2026, 10, 1))
        let september = Self.window(Self.day(2026, 9, 1), Self.day(2026, 9, 30))
        #expect(rent.occurrences(in: september, calendar: c).isEmpty)
    }

    @Test("a bill due later this month is counted exactly once")
    func markerInsideWindow() {
        let c = Self.chicago
        let rent = Self.charge(anchor: Self.day(2026, 1, 1), marker: Self.day(2026, 9, 1))
        let september = Self.window(Self.day(2026, 9, 1), Self.day(2026, 9, 30))
        #expect(rent.occurrences(in: september, calendar: c) == [Self.day(2026, 9, 1)])
    }

    @Test("a bill forgotten since June contributes one occurrence to September, not four")
    func missedMonthsDoNotPileUp() {
        let c = Self.chicago
        let rent = Self.charge(anchor: Self.day(2026, 1, 1), marker: Self.day(2026, 6, 1))
        let september = Self.window(Self.day(2026, 9, 1), Self.day(2026, 9, 30))
        #expect(rent.occurrences(in: september, calendar: c) == [Self.day(2026, 9, 1)])
    }

    @Test("an overdue bill from earlier this month stays subtracted")
    func overdueThisMonthStillCounts() {
        let c = Self.chicago
        let spotify = Self.charge("Spotify", amount: 1_200, anchor: Self.day(2026, 1, 5), marker: Self.day(2026, 9, 5))
        let september = Self.window(Self.day(2026, 9, 1), Self.day(2026, 9, 30))
        #expect(spotify.occurrences(in: september, calendar: c) == [Self.day(2026, 9, 5)])
    }

    // MARK: Month-end anchors

    @Test("a bill due on the 31st lands on the 28th only in February, then goes back to the 31st")
    func monthEndAnchorDoesNotDrift() {
        let c = Self.chicago
        let charge = Self.charge(anchor: Self.day(2026, 1, 31))
        #expect(charge.occurrences(in: Self.window(Self.day(2026, 2, 1), Self.day(2026, 2, 28)), calendar: c)
            == [Self.day(2026, 2, 28)])
        #expect(charge.occurrences(in: Self.window(Self.day(2026, 3, 1), Self.day(2026, 3, 31)), calendar: c)
            == [Self.day(2026, 3, 31)])
        #expect(charge.occurrences(in: Self.window(Self.day(2026, 4, 1), Self.day(2026, 4, 30)), calendar: c)
            == [Self.day(2026, 4, 30)])
        #expect(charge.occurrences(in: Self.window(Self.day(2026, 5, 1), Self.day(2026, 5, 31)), calendar: c)
            == [Self.day(2026, 5, 31)])
    }

    @Test("the 29th and 30th clamp in February and recover afterwards", arguments: [29, 30])
    func lateMonthAnchors(anchorDay: Int) {
        let c = Self.chicago
        let charge = Self.charge(anchor: Self.day(2026, 1, anchorDay))
        #expect(charge.occurrences(in: Self.window(Self.day(2026, 2, 1), Self.day(2026, 2, 28)), calendar: c)
            == [Self.day(2026, 2, 28)])
        #expect(charge.occurrences(in: Self.window(Self.day(2026, 3, 1), Self.day(2026, 3, 31)), calendar: c)
            == [Self.day(2026, 3, anchorDay)])
    }

    @Test("February gets the 29th in a leap year")
    func leapYear() {
        let c = Self.chicago
        let charge = Self.charge(anchor: Self.day(2028, 1, 31))
        #expect(charge.occurrences(in: Self.window(Self.day(2028, 2, 1), Self.day(2028, 2, 29)), calendar: c)
            == [Self.day(2028, 2, 29)])
    }

    @Test("marking paid walks the anchor forward without losing the day of the month")
    func markingPaidDoesNotDrift() {
        let c = Self.chicago
        var charge = Self.charge(anchor: Self.day(2026, 12, 31))
        let expected = [
            Self.day(2027, 1, 31), Self.day(2027, 2, 28), Self.day(2027, 3, 31),
            Self.day(2027, 4, 30), Self.day(2027, 5, 31),
        ]
        for day in expected {
            charge = charge.markingPaidOnce(in: c, now: Date(timeIntervalSince1970: 1_700_000_000))
            #expect(charge.nextExpectedDay(in: c) == day)
        }
        // The anchor itself never moves, which is what keeps the 31st alive.
        #expect(charge.anchorDay(in: c) == Self.day(2026, 12, 31))
    }

    // MARK: Cadences that repeat on a fixed number of days

    @Test("a weekly bill can fall five times in one month")
    func weeklyFiveTimes() {
        let c = Self.chicago
        let gym = Self.charge("Gym", amount: 1_000, cadence: .weekly, anchor: Self.day(2026, 9, 1))
        let september = Self.window(Self.day(2026, 9, 1), Self.day(2026, 9, 30))
        #expect(gym.occurrences(in: september, calendar: c) == [
            Self.day(2026, 9, 1), Self.day(2026, 9, 8), Self.day(2026, 9, 15),
            Self.day(2026, 9, 22), Self.day(2026, 9, 29),
        ])
    }

    @Test("a weekly bill counts fewer times in the shorter until-payday window")
    func weeklyInPaydayWindow() {
        let c = Self.chicago
        let gym = Self.charge("Gym", amount: 1_000, cadence: .weekly, anchor: Self.day(2026, 9, 1))
        let untilPayday = Self.window(Self.day(2026, 9, 1), Self.day(2026, 9, 24))
        #expect(gym.occurrences(in: untilPayday, calendar: c).count == 4)
    }

    @Test("a biweekly bill crosses a month boundary correctly")
    func biweeklyAcrossMonths() {
        let c = Self.chicago
        let charge = Self.charge("Cleaner", amount: 6_000, cadence: .biweekly, anchor: Self.day(2026, 9, 25))
        #expect(charge.occurrences(in: Self.window(Self.day(2026, 9, 1), Self.day(2026, 9, 30)), calendar: c)
            == [Self.day(2026, 9, 25)])
        #expect(charge.occurrences(in: Self.window(Self.day(2026, 10, 1), Self.day(2026, 10, 31)), calendar: c)
            == [Self.day(2026, 10, 9), Self.day(2026, 10, 23)])
    }

    @Test("a weekly bill keeps its 7-day rhythm through a daylight-saving change")
    func weeklyAcrossDaylightSaving() {
        let c = Self.chicago
        // Clocks go forward on 8 March 2026 in Chicago.
        let charge = Self.charge("Gym", amount: 1_000, cadence: .weekly, anchor: Self.day(2026, 3, 1))
        #expect(charge.occurrences(in: Self.window(Self.day(2026, 3, 1), Self.day(2026, 3, 31)), calendar: c)
            == [Self.day(2026, 3, 1), Self.day(2026, 3, 8), Self.day(2026, 3, 15),
                Self.day(2026, 3, 22), Self.day(2026, 3, 29)])
    }

    @Test("quarterly and annual charges appear only in the months they fall in")
    func longCadences() {
        let c = Self.chicago
        let insurance = Self.charge("Car insurance", amount: 42_000, cadence: .quarterly, anchor: Self.day(2026, 2, 15))
        #expect(insurance.occurrences(in: Self.window(Self.day(2026, 5, 1), Self.day(2026, 5, 31)), calendar: c)
            == [Self.day(2026, 5, 15)])
        #expect(insurance.occurrences(in: Self.window(Self.day(2026, 6, 1), Self.day(2026, 6, 30)), calendar: c).isEmpty)

        let prime = Self.charge("Amazon Prime", amount: 13_900, cadence: .annual, anchor: Self.day(2026, 3, 4))
        #expect(prime.occurrences(in: Self.window(Self.day(2027, 3, 1), Self.day(2027, 3, 31)), calendar: c)
            == [Self.day(2027, 3, 4)])
        #expect(prime.occurrences(in: Self.window(Self.day(2026, 9, 1), Self.day(2026, 9, 30)), calendar: c).isEmpty)
    }

    // MARK: Degenerate input

    @Test("a charge with no marker has no occurrences and cannot move a number")
    func noMarker() {
        let c = Self.chicago
        var charge = Self.charge(anchor: Self.day(2026, 9, 1))
        charge.nextExpectedDate = nil
        #expect(charge.occurrences(in: Self.window(Self.day(2026, 9, 1), Self.day(2026, 9, 30)), calendar: c).isEmpty)
        #expect(charge.markingPaidOnce(in: c).nextExpectedDate == nil)
    }

    @Test("a missing anchor falls back to the marker")
    func missingAnchor() {
        let c = Self.chicago
        var charge = Self.charge(anchor: Self.day(2026, 9, 15))
        charge.anchorDate = nil
        #expect(charge.occurrences(in: Self.window(Self.day(2026, 9, 1), Self.day(2026, 9, 30)), calendar: c)
            == [Self.day(2026, 9, 15)])
    }

    @Test("an empty window yields nothing")
    func singleDayWindow() {
        let c = Self.chicago
        let charge = Self.charge(anchor: Self.day(2026, 9, 14))
        #expect(charge.occurrences(in: Self.window(Self.day(2026, 9, 14), Self.day(2026, 9, 14)), calendar: c)
            == [Self.day(2026, 9, 14)])
        #expect(charge.occurrences(in: Self.window(Self.day(2026, 9, 13), Self.day(2026, 9, 13)), calendar: c).isEmpty)
    }

    // MARK: Monthly equivalent

    @Test("converts a cadence to what it costs a month")
    func monthlyEquivalent() {
        #expect(Cadence.annual.monthlyEquivalentCents(of: 13_900) == 1_158)   // $139/yr = $11.58/mo
        #expect(Cadence.monthly.monthlyEquivalentCents(of: 1_299) == 1_299)
        #expect(Cadence.quarterly.monthlyEquivalentCents(of: 42_000) == 14_000)
        #expect(Cadence.weekly.monthlyEquivalentCents(of: 1_000) == 4_333)    // $10/wk = $43.33/mo
        #expect(Cadence.biweekly.monthlyEquivalentCents(of: 6_000) == 13_000) // $60/2wk = $130/mo
        #expect(Cadence.annual.monthlyEquivalentCents(of: 0) == 0)
    }
}
