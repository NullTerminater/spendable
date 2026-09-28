import Foundation
import Testing
@testable import Spendable

/// The pure part of detection: decision 9 of `docs/reviews/milestone-5-review.md`, plus the
/// refund rule (17) and the anchor rule (14). Synthetic amounts and dates only.
@Suite("Finding repeating charges in one merchant's history")
struct SeriesFinderTests {
    private final class Ids { var next: Int64 = 0 }

    private static func rows(_ entries: [(CalendarDay, Int64)], ids: Ids = Ids()) -> [DetectionRow] {
        entries.sorted { $0.0 < $1.0 }.map { day, amount in
            ids.next += 1
            return DetectionRow(id: ids.next, amountCents: amount, day: day, postedDay: day,
                                dayIsTransactionDate: true, pending: false)
        }
    }

    private static func monthly(from start: CalendarDay, count: Int, amount: Int64, skipping: Set<Int> = []) -> [(CalendarDay, Int64)] {
        (0..<count).filter { !skipping.contains($0) }.map { (start.adding(months: $0, in: CalendarDay.utc), amount) }
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: year, month: month, day: day)
    }

    @Test("Spotify going from 9.99 to 10.99 is one series with a price change")
    func priceChange() throws {
        let entries = Self.monthly(from: Self.day(2025, 10, 12), count: 10, amount: -999)
            + (10..<12).map { (Self.day(2025, 10, 12).adding(months: $0, in: CalendarDay.utc), Int64(-1099)) }
        let tracks = SeriesFinder.find(Self.rows(entries)).tracks
        #expect(tracks.count == 1)
        let track = try #require(tracks.first)
        #expect(track.cadence == .monthly)
        #expect(track.confidence == .confirmed)
        #expect(track.currentAmountCents == 1099)
        #expect(track.firstAmountCents == 999)
        #expect(track.priceChange?.fromCents == 999)
        #expect(track.priceChange?.on == Self.day(2026, 8, 12))
    }

    @Test("Apple at 2.99 and 9.99 are two subscriptions")
    func twoApplePrices() {
        let entries = Self.monthly(from: Self.day(2026, 1, 5), count: 6, amount: -299)
            + Self.monthly(from: Self.day(2026, 1, 20), count: 6, amount: -999)
        let tracks = SeriesFinder.find(Self.rows(entries)).tracks
        #expect(tracks.map(\.currentAmountCents).sorted() == [299, 999])
        #expect(tracks.allSatisfy { $0.cadence == .monthly && $0.confidence == .confirmed })
    }

    @Test("two plans at the same price on the 3rd and the 19th are two monthly series, never one biweekly")
    func twoPlansSamePrice() {
        let entries = Self.monthly(from: Self.day(2026, 1, 3), count: 6, amount: -99)
            + Self.monthly(from: Self.day(2026, 1, 19), count: 6, amount: -99)
        let tracks = SeriesFinder.find(Self.rows(entries)).tracks
        #expect(tracks.count == 2)
        #expect(tracks.allSatisfy { $0.cadence == .monthly && $0.memberIds.count == 6 })
    }

    @Test("a gym with a skipped month is still monthly, and a biweekly gym is biweekly")
    func skippedMonthAndBiweekly() {
        let skipped = SeriesFinder.find(Self.rows(Self.monthly(from: Self.day(2026, 1, 7), count: 6, amount: -4000, skipping: [3]))).tracks
        #expect(skipped.map(\.cadence) == [.monthly])
        #expect(skipped.first?.confidence == .confirmed)

        let biweekly = (0..<10).map { (Self.day(2026, 1, 2).adding(days: 14 * $0, in: CalendarDay.utc), Int64(-2500)) }
        let found = SeriesFinder.find(Self.rows(biweekly)).tracks
        #expect(found.map(\.cadence) == [.biweekly])
        #expect(found.first?.confidence == .confirmed)
    }

    @Test("pay coming in is never a bill")
    func paydaysAreNotBills() {
        let pay = (0..<10).map { (Self.day(2026, 1, 2).adding(days: 14 * $0, in: CalendarDay.utc), Int64(250_000)) }
        #expect(SeriesFinder.find(Self.rows(pay)).tracks.isEmpty)
    }

    @Test("two charges suggest, three confirm")
    func twoSuggestThreeConfirm() {
        let two = SeriesFinder.find(Self.rows(Self.monthly(from: Self.day(2026, 1, 5), count: 2, amount: -1500))).tracks
        #expect(two.map(\.confidence) == [.suggested])
        let three = SeriesFinder.find(Self.rows(Self.monthly(from: Self.day(2026, 1, 5), count: 3, amount: -1500))).tracks
        #expect(three.map(\.confidence) == [.confirmed])
    }

    @Test("a refund cancels exactly one charge, and an ambiguous one cancels none")
    func refundsOneToOne() {
        let entries = Self.monthly(from: Self.day(2026, 1, 5), count: 3, amount: -1500) + [(Self.day(2026, 3, 9), Int64(1500))]
        let result = SeriesFinder.find(Self.rows(entries))
        #expect(result.refunded.count == 1)
        #expect(result.tracks.map(\.confidence) == [.suggested])

        let ambiguous = Self.rows([(Self.day(2026, 3, 5), -1500), (Self.day(2026, 3, 6), -1500), (Self.day(2026, 3, 9), 1500)])
        #expect(SeriesFinder.pairRefunds(ambiguous).isEmpty)

        let tooLate = Self.rows([(Self.day(2026, 3, 5), -1500), (Self.day(2026, 4, 20), 1500)])
        #expect(SeriesFinder.pairRefunds(tooLate).isEmpty)
    }

    @Test("gap rules for small histories", arguments: [
        ([30, 58], Cadence?.none),
        ([30, 60, 31], Cadence?.some(.monthly)),
        ([30, 31, 29, 45], Cadence?.none),
    ])
    func gapRules(gaps: [Int], expected: Cadence?) {
        var days = [Self.day(2026, 1, 1)]
        for gap in gaps { days.append(days[days.count - 1].adding(days: gap, in: CalendarDay.utc)) }
        #expect(SeriesFinder.fitCadence(days)?.cadence == expected)
    }

    @Test("a bill on the 31st first seen on February 28th is anchored to the 31st")
    func monthEndAnchor() {
        let days = [Self.day(2026, 2, 28), Self.day(2026, 3, 31), Self.day(2026, 4, 30)]
        #expect(SeriesFinder.anchor(days: days, cadence: .monthly) == Self.day(2026, 3, 31))
        #expect(SeriesFinder.occurrence(2, from: Self.day(2026, 3, 31), cadence: .monthly) == Self.day(2026, 5, 31))
    }

    @Test("a charge pays an occurrence only within tolerance, so a late one never pays the next")
    func settleTolerance() {
        let anchor = Self.day(2026, 1, 5)
        #expect(SeriesFinder.occurrencePaid(by: Self.day(2026, 3, 8), anchor: anchor, cadence: .monthly) == Self.day(2026, 3, 5))
        #expect(SeriesFinder.occurrencePaid(by: Self.day(2026, 3, 20), anchor: anchor, cadence: .monthly) == nil)
        // An annual renewal twelve days late still settles.
        #expect(SeriesFinder.occurrencePaid(by: Self.day(2027, 1, 17), anchor: anchor, cadence: .annual) == Self.day(2027, 1, 5))
    }
}
