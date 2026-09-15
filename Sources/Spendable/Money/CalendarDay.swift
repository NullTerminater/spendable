import Foundation

/// One calendar day, as a person means it: "the 14th of September 2026", not an instant.
///
/// Every date rule in Spendable is about days — a bill is due on a day, a balance is as of a day,
/// payday falls on a day — so the engine works in this type and converts to `Date` only at the
/// edges. Arithmetic in whole days means a daylight-saving change cannot move a bill, and a
/// balance taken at 11pm is not "a day older" than one taken at 1am on the same date.
struct CalendarDay: Hashable, Sendable, Codable {
    let year: Int
    let month: Int
    let day: Int

    /// The day `date` falls on in `calendar`.
    init(_ date: Date, in calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        year = parts.year ?? 1
        month = parts.month ?? 1
        day = parts.day ?? 1
    }

    /// A day from its parts. Not validated against the calendar: use it for literals you know.
    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day an epoch timestamp falls on.
    init(epochSeconds: Int64, in calendar: Calendar = .current) {
        self.init(Date(timeIntervalSince1970: TimeInterval(epochSeconds)), in: calendar)
    }

    /// Midnight at the start of this day.
    func startOfDay(in calendar: Calendar = .current) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        // A day a calendar skips entirely (a daylight-saving jump at midnight in some zones)
        // resolves to the following instant, which is still inside the intended day.
        return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    /// Midnight at the start of this day, as epoch seconds, for the schema's INTEGER columns.
    func epochSeconds(in calendar: Calendar = .current) -> Int64 {
        Int64(startOfDay(in: calendar).timeIntervalSince1970)
    }

    /// Midnight UTC on this date, which is what goes on the wire.
    ///
    /// Never local midnight. Local midnight moves by an hour across a daylight-saving change and by
    /// hours when the owner travels, and a server that keys its answer off the date it was given
    /// would then return a different set of rows for what is meant to be the same window.
    var utcMidnight: Int64 {
        Int64(startOfDay(in: Self.utc).timeIntervalSince1970)
    }

    /// A UTC calendar, for the values that go on the wire rather than in front of a person.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// This day moved by whole days.
    func adding(days: Int, in calendar: Calendar = .current) -> CalendarDay {
        guard days != 0 else { return self }
        guard let moved = calendar.date(byAdding: .day, value: days, to: startOfDay(in: calendar)) else { return self }
        return CalendarDay(moved, in: calendar)
    }

    /// This day moved by whole months, keeping the day of the month and clamping to the length of
    /// the month it lands in: the 31st of January plus one month is the 28th (or 29th) of February.
    ///
    /// Always step from the original anchor rather than from the last result. Adding one month
    /// twice to the 31st of December gives the 28th of February; adding two months at once gives
    /// the 28th as well, but adding one month to *that* gives the 28th of March, which has quietly
    /// lost the 31st forever.
    func adding(months: Int, in calendar: Calendar = .current) -> CalendarDay {
        guard months != 0 else { return self }
        guard let moved = calendar.date(byAdding: .month, value: months, to: startOfDay(in: calendar)) else { return self }
        return CalendarDay(moved, in: calendar)
    }

    /// Whole calendar days from this day to `other`. Negative when `other` is earlier.
    func days(to other: CalendarDay, in calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: startOfDay(in: calendar), to: other.startOfDay(in: calendar)).day ?? 0
    }

    /// The first day of this day's month.
    func startOfMonth(in calendar: Calendar = .current) -> CalendarDay {
        CalendarDay(year: year, month: month, day: 1)
    }

    /// The last day of this day's month: the 28th, 29th, 30th or 31st.
    func endOfMonth(in calendar: Calendar = .current) -> CalendarDay {
        let start = startOfMonth(in: calendar)
        guard let range = calendar.range(of: .day, in: .month, for: start.startOfDay(in: calendar)) else { return start }
        return CalendarDay(year: year, month: month, day: range.upperBound - 1)
    }

    /// Today.
    static func today(in calendar: Calendar = .current, now: Date = Date()) -> CalendarDay {
        CalendarDay(now, in: calendar)
    }

    /// "2026-09-14", for the columns that store a day as text and for stable test names.
    var isoString: String {
        let paddedMonth = month < 10 ? "0\(month)" : "\(month)"
        let paddedDay = day < 10 ? "0\(day)" : "\(day)"
        return "\(year)-\(paddedMonth)-\(paddedDay)"
    }

    /// Reads "2026-09-14". Returns nil for anything else, including an empty string.
    init?(isoString: String) {
        let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }
}

extension CalendarDay: Comparable {
    static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension CalendarDay: CustomStringConvertible {
    var description: String { isoString }
}
