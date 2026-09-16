import Foundation
import GRDB

/// How often the app is allowed to ask.
///
/// SimpleFIN expects at most 24 requests a day and **disables the access token** beyond that, which
/// would cost the owner a hand-made setup token to recover from. So the app counts a rolling 24
/// hours rather than a calendar day: a per-day ceiling of twelve permits twenty-four inside one
/// server day by spending twelve late one evening and twelve early the next morning, and a
/// time-zone change resets it for free.
enum RequestBudget {
    /// Ten below the threshold that disables the token.
    static let maxInRollingDay = 14
    /// Of those, how many may be history windows, so filling in history spreads over two days
    /// instead of colliding with the day's ordinary refreshes.
    static let maxBackfillInRollingDay = 6

    static let timestampsKey = "request-timestamps"
    static let backfillTimestampsKey = "backfill-request-timestamps"
    static let quotaTrippedKey = "quota-tripped-at"

    enum Purpose: Equatable, Sendable {
        case refresh
        case backfill
    }

    enum Refusal: Error, Equatable {
        case dayIsFull
        case backfillIsFullForToday
        case serverWarnedAboutTheRate

        var ownerFacingMessage: String {
            switch self {
            case .dayIsFull:
                "Already refreshed today. SimpleFIN only gets new bank data about once a day, so there's nothing new to fetch."
            case .backfillIsFullForToday:
                "I'll carry on filling in your history tomorrow — SimpleFIN limits how much I can ask for in a day."
            case .serverWarnedAboutTheRate:
                "SimpleFIN warned that I've been asking too often, so I've stopped for today to keep your connection working."
            }
        }
    }

    /// Takes one request from the budget **before** it is sent, and commits that immediately.
    ///
    /// Reserving up front means a crash or a timeout between spending and recording can only ever
    /// over-count, which is safe. Counting successes instead would under-count, and the server
    /// counts every request it served whether or not the answer arrived.
    @discardableResult
    static func reserve(_ db: Database, purpose: Purpose, now: Date = .now) throws -> Date {
        if let trippedAt = try timestamps(db, key: quotaTrippedKey).first,
           now.timeIntervalSince1970 - trippedAt < 24 * 3_600 {
            throw Refusal.serverWarnedAboutTheRate
        }

        let cutoff = now.timeIntervalSince1970 - 24 * 3_600
        var recent = try timestamps(db, key: timestampsKey).filter { $0 > cutoff }
        guard recent.count < maxInRollingDay else { throw Refusal.dayIsFull }

        if purpose == .backfill {
            var recentBackfill = try timestamps(db, key: backfillTimestampsKey).filter { $0 > cutoff }
            guard recentBackfill.count < maxBackfillInRollingDay else { throw Refusal.backfillIsFullForToday }
            recentBackfill.append(now.timeIntervalSince1970)
            try write(db, key: backfillTimestampsKey, recentBackfill)
        }

        recent.append(now.timeIntervalSince1970)
        try write(db, key: timestampsKey, recent)
        return now
    }

    /// How many requests remain in the trailing 24 hours.
    static func remaining(_ db: Database, purpose: Purpose = .refresh, now: Date = .now) throws -> Int {
        let cutoff = now.timeIntervalSince1970 - 24 * 3_600
        let spent = try timestamps(db, key: timestampsKey).filter { $0 > cutoff }.count
        let overall = maxInRollingDay - spent
        guard purpose == .backfill else { return max(0, overall) }
        let spentOnBackfill = try timestamps(db, key: backfillTimestampsKey).filter { $0 > cutoff }.count
        let backfill = maxBackfillInRollingDay - spentOnBackfill
        return max(0, min(overall, backfill))
    }

    /// Records that the server itself warned about the rate. Scheduled and manual checks stop
    /// for a rolling day, with the warning explained when the owner asks to refresh.
    static func recordServerQuotaWarning(_ db: Database, now: Date = .now) throws {
        try write(db, key: quotaTrippedKey, [now.timeIntervalSince1970])
    }

    static func serverWarnedAboutTheRate(_ db: Database, now: Date = .now) throws -> Bool {
        guard let trippedAt = try timestamps(db, key: quotaTrippedKey).first else { return false }
        return now.timeIntervalSince1970 - trippedAt < 24 * 3_600
    }

    private static func timestamps(_ db: Database, key: String) throws -> [TimeInterval] {
        guard let text = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [key]),
              let data = text.data(using: .utf8),
              let values = try? JSONDecoder().decode([TimeInterval].self, from: data)
        else { return [] }
        return values
    }

    private static func write(_ db: Database, key: String, _ values: [TimeInterval]) throws {
        // Only the most recent matter, and the list must not grow without bound.
        let trimmed = Array(values.sorted().suffix(maxInRollingDay * 2))
        let text = String(data: try JSONEncoder().encode(trimmed), encoding: .utf8) ?? "[]"
        try SyncState.set(db, key, text)
    }
}

/// Which spans of days to ask for when filling in history.
enum BackfillPlan {
    /// Never more than the Bridge's recommended range. Above this it warns, and above 90 days it
    /// silently trims the answer while still returning HTTP 200.
    static let windowDays = SimpleFINClient.longestWindowDays
    /// The Bridge's own advice, for transactions that post a few days late.
    static let overlapDays = 5
    /// Thirteen months, so a year of annual charges is reachable.
    static let reachDays = 396

    /// Windows from `today` backwards, newest first, each overlapping the one before it.
    static func windows(
        endingOn today: CalendarDay,
        reachingBack days: Int = reachDays,
        limit: Int = 12,
        calendar: Calendar = .current
    ) -> [ClosedRange<CalendarDay>] {
        guard limit > 0, days > 0 else { return [] }
        let earliest = today.adding(days: -(days - 1), in: calendar)
        var windows: [ClosedRange<CalendarDay>] = []
        var end = today
        while windows.count < limit {
            let start = end.adding(days: -(windowDays - 1), in: calendar)
            windows.append(start...end)
            if start <= earliest { break }
            // Step back by a window less the overlap.
            end = start.adding(days: overlapDays - 1, in: calendar)
        }
        return windows
    }

    /// The span for an ordinary incremental sync, or nil when the gap is too wide to ask for at
    /// once — in which case the backwards walk is planned instead, rather than a single request the
    /// server would trim.
    static func incrementalWindow(
        since watermark: CalendarDay?, today: CalendarDay, calendar: Calendar = .current
    ) -> ClosedRange<CalendarDay>? {
        guard let watermark else { return nil }
        let start = watermark.adding(days: -overlapDays, in: calendar)
        guard start <= today else { return today...today }
        guard start.days(to: today, in: calendar) < windowDays else { return nil }
        return start...today
    }
}

/// How the history walk is going. Kept in `sync_state` so a crash, a quit or a spent budget
/// resumes where it left off instead of starting again.
struct BackfillProgress: Codable, Equatable, Sendable {
    enum Terminal: String, Codable, Sendable {
        case running
        /// Two windows in a row held nothing new: there is no more history to find.
        case exhausted
        /// As far back as the app is willing to look.
        case reachedLimit
        case failed
    }

    var nextWindowIndex: Int = 0
    var consecutiveEmptyWindows: Int = 0
    var state: Terminal = .running
    /// The oldest day any window has actually covered.
    var coveredBackTo: String?

    static let key = "backfill-progress"

    static func load(_ db: Database) throws -> BackfillProgress {
        guard let text = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [key]),
              let data = text.data(using: .utf8),
              let progress = try? JSONDecoder().decode(BackfillProgress.self, from: data)
        else { return BackfillProgress() }
        return progress
    }

    func save(_ db: Database) throws {
        let text = String(data: try JSONEncoder().encode(self), encoding: .utf8) ?? "{}"
        try SyncState.set(db, Self.key, text)
    }
}
