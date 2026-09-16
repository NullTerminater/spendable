import Foundation
import GRDB

/// The few facts about syncing that outlive a run, kept in the `sync_state` key-value table.
///
/// Each is written **where the fact becomes true**, not where a run happens to end: a sync that
/// fetched balances and then ran out of budget for history did fetch balances, and the gates that
/// decide whether to ask again must know that.
enum SyncState {
    /// The last time balances were successfully read.
    static let balancesSyncedAt = "balances-synced-at"
    /// The last time transactions were successfully pulled.
    static let transactionsPulledAt = "transactions-pulled-at"
    /// The last time a sync was *attempted*, successful or not. Gates back-off, so a Mac waking
    /// repeatedly with no network cannot spend the whole day's budget on requests nobody answered.
    static let attemptedAt = "sync-attempted-at"
    /// How many attempts have failed in a row. Cleared by a successful balances read.
    static let failuresInARow = "sync-failures-in-a-row"
    /// When a credential was first stored. Used to decide whether to schedule at all, because
    /// asking the Keychain would turn a locked keychain into a silently unscheduled app.
    static let connectedAt = "connected-at"

    static func date(_ db: Database, _ key: String) throws -> Date? {
        guard let text = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [key]),
              let seconds = TimeInterval(text)
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func setDate(_ db: Database, _ key: String, _ value: Date) throws {
        try set(db, key, String(value.timeIntervalSince1970))
    }

    static func integer(_ db: Database, _ key: String) throws -> Int {
        guard let text = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?", arguments: [key]),
              let value = Int(text)
        else { return 0 }
        return value
    }

    static func setInteger(_ db: Database, _ key: String, _ value: Int) throws {
        try set(db, key, String(value))
    }

    static func set(_ db: Database, _ key: String, _ value: String) throws {
        try db.execute(
            sql: "INSERT INTO sync_state (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            arguments: [key, value])
        // SQLite's update hook does not report WITHOUT ROWID tables. GRDB needs this explicit
        // notification for progress, connection notices and confirmation expiry to update live.
        try db.notifyChanges(in: Table("sync_state"))
    }

    static func clear(_ db: Database, _ key: String) throws {
        try db.execute(sql: "DELETE FROM sync_state WHERE key = ?", arguments: [key])
        try db.notifyChanges(in: Table("sync_state"))
    }

    /// How long to wait after a run of failures before trying again: half an hour, then an hour,
    /// two, and six. A bank that is down for the afternoon should not cost a day of requests.
    static func backOff(afterFailures count: Int) -> TimeInterval {
        switch count {
        case 0: 0
        case 1: 30 * 60
        case 2: 60 * 60
        case 3: 2 * 3_600
        default: 6 * 3_600
        }
    }
}

/// What a sync is being asked to fetch.
enum SyncShape: Equatable, Sendable {
    /// Balances and nothing else. Cheap, and all a routine refresh needs.
    case balancesOnly
    /// Balances, then whatever transactions are missing. Once a day is enough: SimpleFIN itself
    /// only collects from banks about once a day, so asking more often cannot produce newer rows.
    case balancesAndTransactions
}

/// Whether to sync now, and what to ask for. A pure decision, so it can be tested without a clock,
/// a network or a scheduler.
struct SyncPolicy: Equatable, Sendable {
    /// How old balances may get before a routine refresh is due.
    static let balancesStaleAfter: TimeInterval = 6 * 3_600
    static let balancesStaleAfterForActivity: TimeInterval = 5 * 3_600
    /// How old the transaction history may get before the next sync pulls it too.
    static let transactionsStaleAfter: TimeInterval = 24 * 3_600
    /// How long after any attempt a non-manual trigger will not try again, so repeated wakes with
    /// no network cannot drain the day.
    static let quietAfterAnyAttempt: TimeInterval = 30 * 60

    enum Trigger: Equatable, Sendable {
        case launch
        case scheduled
        case wake
        case dayChanged
        case manual
    }

    enum Decision: Equatable, Sendable {
        case sync(SyncShape)
        case skip(String)
    }

    var balancesSyncedAt: Date?
    var transactionsPulledAt: Date?
    var attemptedAt: Date?
    var failuresInARow: Int = 0
    var isConnected: Bool = true
    var serverWarnedAboutTheRate: Bool = false
    var requestsRemaining: Int = RequestBudget.maxInRollingDay

    func decide(trigger: Trigger, now: Date) -> Decision {
        guard isConnected else { return .skip("no bank connected") }

        if serverWarnedAboutTheRate { return .skip("SimpleFIN warned about the rate") }

        // The owner asking is different from the app deciding: it only answers to the budget.
        if trigger == .manual {
            guard requestsRemaining > 0 else { return .skip("no requests left today") }
            return .sync(shapeNeeded(now: now))
        }

        if serverWarnedAboutTheRate { return .skip("SimpleFIN warned about the rate") }
        guard requestsRemaining > 0 else { return .skip("no requests left today") }

        if let attemptedAt {
            let waitFor = max(Self.quietAfterAnyAttempt, SyncState.backOff(afterFailures: failuresInARow))
            if now.timeIntervalSince(attemptedAt) < waitFor {
                return .skip("tried recently")
            }
        }

        guard let balancesSyncedAt else { return .sync(shapeNeeded(now: now)) }
        let dueAfter = trigger == .launch ? Self.balancesStaleAfter : Self.balancesStaleAfterForActivity
        guard now.timeIntervalSince(balancesSyncedAt) >= dueAfter else {
            return .skip("balances are recent")
        }
        return .sync(shapeNeeded(now: now))
    }

    private func shapeNeeded(now: Date) -> SyncShape {
        guard let transactionsPulledAt else { return .balancesAndTransactions }
        return now.timeIntervalSince(transactionsPulledAt) >= Self.transactionsStaleAfter
            ? .balancesAndTransactions : .balancesOnly
    }

    static func load(_ db: Database, now: Date = .now) throws -> SyncPolicy {
        var policy = SyncPolicy()
        policy.balancesSyncedAt = try SyncState.date(db, SyncState.balancesSyncedAt)
        policy.transactionsPulledAt = try SyncState.date(db, SyncState.transactionsPulledAt)
        policy.attemptedAt = try SyncState.date(db, SyncState.attemptedAt)
        policy.failuresInARow = try SyncState.integer(db, SyncState.failuresInARow)
        // A database fact, never a Keychain read: asking macOS would turn a locked login keychain
        // into an app that silently stops scheduling anything.
        let connected = try SyncState.date(db, SyncState.connectedAt) != nil
        policy.isConnected = connected
        policy.serverWarnedAboutTheRate = try RequestBudget.serverWarnedAboutTheRate(db, now: now)
        policy.requestsRemaining = try RequestBudget.remaining(db, now: now)
        return policy
    }
}
