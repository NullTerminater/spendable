import Foundation
import GRDB

/// Drains detection work (`docs/reviews/milestone-5-review.md`, decision 6).
///
/// One drain at a time, like the sync coordinator: a second trigger while one is running waits for
/// it and shares its result. It runs after every transaction pull that wrote anything, once at
/// launch if work is waiting, and after owner actions that queue work. There is no timer and no
/// retry loop: "it will try again" means the next pull, launch or owner action.
actor DetectionWorker {
    struct Report: Equatable, Sendable {
        var keysProcessed = 0
        var rowsKeyed = 0
        /// Keys that failed three times and are set aside until something queues them again.
        var quarantined = 0
    }

    /// Keys per write transaction: small enough that the main queue sees results promptly and a
    /// failing batch costs little to retry one key at a time.
    static let batchSize = 25
    /// Rows re-keyed per backfill transaction.
    static let backfillBatch = 500
    static let backfillStateKey = "merchant-backfill"

    private let database: AppDatabase
    private let calendar: Calendar
    private var current: Task<Report, Never>?

    init(database: AppDatabase, calendar: Calendar = .current) {
        self.database = database
        self.calendar = calendar
    }

    /// True when a launch should start a drain: work is queued, or the merchant backfill has not
    /// finished for the current rules. One indexed read on a clean launch.
    nonisolated static func hasWork(_ db: Database) throws -> Bool {
        let queued = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM detection_dirty WHERE failed_at IS NULL)") ?? false
        return try queued || !BackfillCursor.load(db).isFinished
    }

    func drain(now: @escaping @Sendable () -> Date = { Date() }) async -> Report {
        if let current { return await current.value }
        let database = self.database
        let calendar = self.calendar
        let task = Task.detached(priority: .utility) {
            Self.drainNow(database: database, calendar: calendar, now: now)
        }
        current = task
        let report = await task.value
        current = nil
        return report
    }

    /// The drain itself, synchronous and off the main actor. Tests call it directly.
    nonisolated static func drainNow(database: AppDatabase, calendar: Calendar, now: () -> Date) -> Report {
        var report = Report()
        // 1. Keys first: clustering waits until every row carries a key from the current rules,
        //    or a half-keyed merchant would look like a bill with missing charges.
        while true {
            let keyed = (try? database.writer.write { db in try backfillBatch(db) }) ?? -1
            if keyed <= 0 { break }
            report.rowsKeyed += keyed
        }
        let finished = (try? database.reader.read { db in try BackfillCursor.load(db).isFinished }) ?? false
        guard finished else { return report }

        // 2. Keys in batches. A batch that throws is rolled back and its keys retried one per
        //    transaction; a key that fails three times is quarantined, not retried in a loop.
        var guardCount = 0
        while guardCount < 10_000 {
            guardCount += 1
            let keys: [(Int64, String)] = (try? database.reader.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT account_id, merchant_key FROM detection_dirty WHERE failed_at IS NULL
                     ORDER BY CASE merchant_key WHEN '*' THEN 0 ELSE 1 END, enqueued_at, account_id, merchant_key
                     LIMIT ?
                    """, arguments: [batchSize]).map { row -> (Int64, String) in (row["account_id"], row["merchant_key"]) }
            }) ?? []
            if keys.isEmpty { break }
            let context = DetectionPass.Context(now: now(), calendar: calendar)
            do {
                try database.writer.write { db in
                    for (account, key) in keys { try process(account: account, key: key, db: db, context: context) }
                }
                report.keysProcessed += keys.count
            } catch {
                for (account, key) in keys {
                    do {
                        try database.writer.write { db in try process(account: account, key: key, db: db, context: context) }
                        report.keysProcessed += 1
                    } catch {
                        // Only a static string reaches the log; never an amount, name or row.
                        try? database.writer.write { db in
                            try db.execute(sql: """
                                UPDATE detection_dirty
                                   SET attempts = attempts + 1,
                                       failed_at = CASE WHEN attempts + 1 >= 3 THEN ? ELSE failed_at END
                                 WHERE account_id = ? AND merchant_key = ?
                                """, arguments: [Int64(now().timeIntervalSince1970), account, key])
                        }
                    }
                }
            }
        }
        report.quarantined = (try? database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM detection_dirty WHERE failed_at IS NOT NULL")
        }) ?? 0
        return report
    }

    /// One queued key, and removing it from the queue, in the caller's transaction.
    nonisolated static func process(account: Int64, key: String, db: Database, context: DetectionPass.Context) throws {
        switch key {
        case "*":
            try DetectionPass.expandWholeAccount(account, db: db, context: context)
        case "*coverage":
            try DetectionPass.reevaluateLateness(accountId: account, db: db, context: context)
        default:
            try DetectionPass.run(accountId: account, key: key, db: db, context: context)
        }
        try db.execute(sql: "DELETE FROM detection_dirty WHERE account_id = ? AND merchant_key = ?",
                       arguments: [account, key])
    }

    // MARK: Merchant-key backfill (decision 7)

    struct BackfillCursor: Codable, Equatable {
        var version: Int = 0
        var afterId: Int64 = 0
        var done: Bool = false

        var isFinished: Bool { done && version == MerchantKey.version }

        static func load(_ db: Database) throws -> BackfillCursor {
            guard let text = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?",
                                                 arguments: [DetectionWorker.backfillStateKey]),
                  let cursor = try? JSONDecoder().decode(BackfillCursor.self, from: Data(text.utf8)),
                  cursor.version == MerchantKey.version
            else { return BackfillCursor(version: MerchantKey.version) }
            return cursor
        }

        func save(_ db: Database) throws {
            let text = String(data: try JSONEncoder().encode(self), encoding: .utf8) ?? "{}"
            try SyncState.set(db, DetectionWorker.backfillStateKey, text)
        }
    }

    /// Keys up to 500 rows past the cursor, writing only rows whose key actually changes, and moves
    /// the cursor in the same transaction. Answers how many rows it looked at; zero when finished.
    nonisolated static func backfillBatch(_ db: Database) throws -> Int {
        var cursor = try BackfillCursor.load(db)
        if cursor.isFinished { return 0 }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, payee, description, merchant_normalized, merchant_alt, normalizer_version
              FROM bank_transaction WHERE id > ? ORDER BY id LIMIT ?
            """, arguments: [cursor.afterId, backfillBatch])
        for row in rows {
            let result = MerchantKey.normalize(payee: row["payee"], description: row["description"])
            let version: Int? = row["normalizer_version"]
            let key: String? = row["merchant_normalized"]
            let alternate: String? = row["merchant_alt"]
            guard version != MerchantKey.version || key != result.key || alternate != result.alternate else { continue }
            try db.execute(sql: """
                UPDATE bank_transaction SET merchant_normalized = ?, merchant_alt = ?, normalizer_version = ? WHERE id = ?
                """, arguments: [result.key, result.alternate, MerchantKey.version, row["id"] as Int64])
        }
        if let last = rows.last?["id"] as Int64? { cursor.afterId = last }
        if rows.count < backfillBatch { cursor.done = true }
        try cursor.save(db)
        return rows.count
    }
}
