import Foundation
import GRDB

/// When the owner gets paid. One row: they are paid every two weeks, so one date they were paid on
/// fixes the whole series forwards and backwards.
struct PaySchedule: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pay_schedule"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    /// Days between paydays. The owner is paid every two weeks.
    static let intervalDays = 14

    var id: Int64 = 1
    /// A day the owner was paid, as `yyyy-mm-dd`.
    var anchorDay: String

    init(id: Int64 = 1, anchorDay: String) {
        self.id = id
        self.anchorDay = anchorDay
    }

    init(anchor: CalendarDay) {
        self.id = 1
        self.anchorDay = anchor.isoString
    }

    /// The anchor as a day, or nil if the stored text is not a date.
    var anchor: CalendarDay? { CalendarDay(isoString: anchorDay) }

    /// The next payday strictly after `today`.
    ///
    /// Strictly after, so on payday itself the answer is the following payday rather than today:
    /// a figure covering zero days would divide by zero and tell the owner nothing.
    /// Works for an anchor in the future as well as the past.
    func nextPayday(after today: CalendarDay, in calendar: Calendar = .current) -> CalendarDay? {
        guard let anchor else { return nil }
        let apart = anchor.days(to: today, in: calendar)
        let steps = Self.floorDivide(apart, by: Self.intervalDays) + 1
        return anchor.adding(days: Self.intervalDays * steps, in: calendar)
    }

    /// The most recent payday on or before `today`.
    func mostRecentPayday(onOrBefore today: CalendarDay, in calendar: Calendar = .current) -> CalendarDay? {
        guard let anchor else { return nil }
        let apart = anchor.days(to: today, in: calendar)
        let steps = Self.floorDivide(apart, by: Self.intervalDays)
        return anchor.adding(days: Self.intervalDays * steps, in: calendar)
    }

    /// Integer division that rounds toward negative infinity, so an anchor in the future works.
    /// Swift's `/` rounds toward zero, which would skip a payday for negative day counts.
    static func floorDivide(_ value: Int, by divisor: Int) -> Int {
        let quotient = value / divisor
        let hasRemainder = value % divisor != 0
        let signsDiffer = (value < 0) != (divisor < 0)
        return hasRemainder && signsDiffer ? quotient - 1 : quotient
    }

    /// Reads the single row, if the owner has set one.
    static func fetch(_ db: Database) throws -> PaySchedule? {
        try PaySchedule.fetchOne(db, key: 1)
    }
}
