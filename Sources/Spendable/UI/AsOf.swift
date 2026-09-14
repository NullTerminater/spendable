import Foundation

/// Plain-English phrasing for how old a balance is. Future dates are treated as today.
enum AsOf {
    /// "today", "yesterday", "Thursday" (within the last six days), otherwise "Sep 3" or "Sep 3, 2025".
    static func dayPhrase(epochSeconds: Int64, now: Date = .now, calendar: Calendar = .current) -> String {
        let date = min(Date(timeIntervalSince1970: TimeInterval(epochSeconds)), now)
        let days = daysBetween(date, now, calendar: calendar)
        let base = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        switch days {
        case ...0: return "today"
        case 1: return "yesterday"
        case 2...6: return date.formatted(base.weekday(.wide))
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return sameYear
                ? date.formatted(base.month(.abbreviated).day())
                : date.formatted(base.month(.abbreviated).day().year())
        }
    }

    /// Whole calendar days from `date` to `now` in the given calendar. Negative if `date` is later.
    static func daysBetween(_ date: Date, _ now: Date, calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: date)
        let to = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// True when the balance is older than `thresholdDays` whole calendar days.
    static func isStale(epochSeconds: Int64, thresholdDays: Int, now: Date = .now, calendar: Calendar = .current) -> Bool {
        daysBetween(Date(timeIntervalSince1970: TimeInterval(epochSeconds)), now, calendar: calendar) > thresholdDays
    }
}
