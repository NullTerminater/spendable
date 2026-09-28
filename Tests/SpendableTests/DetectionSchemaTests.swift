import Foundation
import GRDB
import Testing
@testable import Spendable

/// Schema v5 (`docs/reviews/milestone-5-review.md`, decisions 5, 8, 23 and 24).
@Suite("Schema v5: detection tables, triggers and the monthly column (in-memory only)")
struct DetectionSchemaTests {
    private static func migratedToV4() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v4-account-type-guess")
        return queue
    }

    private static func insertTransaction(
        _ db: Database, account: Int64 = 1, externalId: String, amount: Int64, key: String?,
        posted: Int64 = 1_790_000_000, transactedAt: Int64? = nil
    ) throws {
        try db.execute(sql: """
            INSERT INTO bank_transaction (account_id, external_id, posted, transacted_at, effective_date,
                amount_cents, description, first_seen_at, last_seen_at, merchant_normalized)
            VALUES (?, ?, ?, ?, ?, ?, 'SYNTHETIC', 0, 0, ?)
            """, arguments: [account, externalId, posted, transactedAt, posted, amount, key])
    }

    private static func dirty(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT account_id || ':' || merchant_key FROM detection_dirty ORDER BY 1")
    }

    @Test("a v4 database upgrades keeping every row, and the migration queues nothing")
    func upgradesFromV4() throws {
        let queue = try Self.migratedToV4()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO account (source, display_name, user_type, currency, balance_cents, balance_date, created_at)
                VALUES ('manual', 'Wallet', 'cash', 'USD', 4000, 1789000000, 1789000000)
                """)
            try db.execute(sql: """
                INSERT INTO account (source, display_name, user_type, currency, balance_cents, balance_date, created_at)
                VALUES ('manual', 'Euro cash', 'cash', 'EUR', 4000, 1789000000, 1789000000)
                """)
            try db.execute(sql: """
                INSERT INTO recurring_charge (source, kind, name, amount_cents, cadence, next_expected_date,
                    anchor_date, paying_account_id, status, created_at, updated_at)
                VALUES ('manual', 'bill', 'Rent', 50000, 'monthly', 1790000000, 1790000000, 1, 'confirmed', 0, 0),
                       ('manual', 'bill', 'Locker', 1200, 'monthly', 1790000000, 1790000000, 2, 'confirmed', 0, 0)
                """)
            try Self.insertTransaction(db, externalId: "a", amount: -999, key: "SPOTIFY")
        }
        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account") == 2)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recurring_charge") == 2)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bank_transaction") == 1)
            #expect(try String.fetchAll(db, sql: "SELECT currency FROM recurring_charge ORDER BY id") == ["USD", "EUR"])
            #expect(try Int64.fetchOne(db, sql: "SELECT monthly_cents FROM recurring_charge WHERE id = 1") == 50000)
            #expect(try Self.dirty(db).isEmpty)
            // Not connected, so there is no history to walk again.
            #expect(try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?",
                                        arguments: [AppDatabase.billsRewalkKey]) == nil)
        }
    }

    @Test("a connected database restarts its history walk to record real coverage")
    func connectedUpgradeRewalks() throws {
        let queue = try Self.migratedToV4()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO account (source, conn_id, external_id, display_name, currency, balance_cents, balance_date, created_at)
                VALUES ('simplefin', 'CONN-SYNTH', 'ACT-1', 'Synthetic Checking', 'USD', 0, 1789000000, 1789000000)
                """)
            var finished = BackfillProgress()
            finished.state = .exhausted
            try finished.save(db)
        }
        try AppDatabase.migrator.migrate(queue)
        try queue.read { db in
            #expect(try BackfillProgress.load(db).state == .running)
            #expect(try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?",
                                        arguments: [AppDatabase.billsRewalkKey]) == "1")
        }
    }

    @Test("triggers queue real changes only, including the bulk void and account corrections")
    func triggersQueueRealChanges() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO account (source, display_name, user_type, currency, balance_cents, balance_date, created_at)
                VALUES ('manual', 'Synthetic', 'checking', 'USD', 0, 0, 0)
                """)
            try Self.insertTransaction(db, externalId: "a", amount: -999, key: "SPOTIFY")
            #expect(try Self.dirty(db) == ["1:SPOTIFY"])
            try db.execute(sql: "DELETE FROM detection_dirty")

            // Every sync rewrites its overlap with identical values. That must queue nothing.
            try db.execute(sql: """
                UPDATE bank_transaction SET amount_cents = amount_cents, description = description,
                    pending = pending, last_seen_at = 99 WHERE external_id = 'a'
                """)
            #expect(try Self.dirty(db).isEmpty)

            // A row moving between merchants queues both.
            try db.execute(sql: "UPDATE bank_transaction SET merchant_normalized = 'SPOTIFY USA' WHERE external_id = 'a'")
            #expect(try Self.dirty(db) == ["1:SPOTIFY", "1:SPOTIFY USA"])
            try db.execute(sql: "DELETE FROM detection_dirty")

            // The age-out void is set-based and names no ids.
            try db.execute(sql: "UPDATE bank_transaction SET voided_at = 1 WHERE account_id = 1")
            #expect(try Self.dirty(db) == ["1:SPOTIFY USA"])
            try db.execute(sql: "DELETE FROM detection_dirty")

            // An account correction reconsiders the whole account; a balance refresh does not.
            try db.execute(sql: "UPDATE account SET balance_cents = 5, tx_synced_through = 9 WHERE id = 1")
            #expect(try Self.dirty(db).isEmpty)
            try db.execute(sql: "UPDATE account SET amounts_reversed = 1 WHERE id = 1")
            #expect(try Self.dirty(db) == ["1:*"])

            // Queueing again lifts a quarantine.
            try db.execute(sql: "UPDATE detection_dirty SET attempts = 3, failed_at = 9")
            try db.execute(sql: "UPDATE account SET holdings_count = 2 WHERE id = 1")
            #expect(try Int64.fetchOne(db, sql: "SELECT failed_at FROM detection_dirty") == nil)
            #expect(try Int64.fetchOne(db, sql: "SELECT attempts FROM detection_dirty") == 0)
            try db.execute(sql: "DELETE FROM detection_dirty")

            try db.execute(sql: "INSERT INTO tx_coverage VALUES (1, 0, 100, 0, 0)")
            #expect(try Self.dirty(db) == ["1:*coverage"])
        }
    }

    @Test("the detection day prefers a plausible transaction date and is never invented")
    func detectionDay() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO account (source, display_name, user_type, currency, balance_cents, balance_date, created_at)
                VALUES ('manual', 'Synthetic', 'checking', 'USD', 0, 0, 0)
                """)
            let posted: Int64 = 1_790_000_000
            try Self.insertTransaction(db, externalId: "plausible", amount: -1, key: "K", posted: posted, transactedAt: posted - 2 * 86_400)
            try Self.insertTransaction(db, externalId: "too-early", amount: -1, key: "K", posted: posted, transactedAt: posted - 30 * 86_400)
            try Self.insertTransaction(db, externalId: "after", amount: -1, key: "K", posted: posted, transactedAt: posted + 86_400)
            try Self.insertTransaction(db, externalId: "undated", amount: -1, key: "K", posted: 0, transactedAt: nil)
            let days = try Row.fetchAll(db, sql: "SELECT external_id, detect_at FROM bank_transaction ORDER BY id")
            #expect(days[0]["detect_at"] as Int64? == posted - 2 * 86_400)
            #expect(days[1]["detect_at"] as Int64? == posted)
            #expect(days[2]["detect_at"] as Int64? == posted)
            #expect(days[3]["detect_at"] as Int64? == nil)
        }
    }

    @Test("detection queries use the account/merchant/day index, not the merchant index")
    func queryPlanUsesDetectionIndex() throws {
        let db = try AppDatabase.inMemory()
        let plan = try db.reader.read { db in
            // EXPLAIN QUERY PLAN answers id, parent, notused, detail: the plan is in `detail`.
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + DetectionQueries.countForKey, arguments: [1, "K", 0])
                .map { $0["detail"] as String }.joined(separator: "\n")
        }
        #expect(plan.contains("bank_transaction_detect"))
        #expect(!plan.contains("bank_transaction_merchant"))
    }

    @Test("SQL monthly cents equal Swift's for every cadence")
    func monthlyCentsParity() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            var generator = SystemRandomNumberGenerator()
            try db.execute(sql: """
                INSERT INTO recurring_charge (source, kind, name, amount_cents, cadence, status, created_at, updated_at)
                VALUES ('manual', 'bill', 'Probe', 1, 'monthly', 'suggested', 0, 0)
                """)
            for cadence in Cadence.allCases {
                let amounts: [Int64] = [1, 2, 5, 6, 999, 13900] + (0..<2_000).map { _ in Int64.random(in: 1...10_000_000, using: &generator) }
                for amount in amounts {
                    try db.execute(sql: "UPDATE recurring_charge SET amount_cents = ?, cadence = ?",
                                   arguments: [amount, cadence.rawValue])
                    let sql = try Int64.fetchOne(db, sql: "SELECT monthly_cents FROM recurring_charge")
                    #expect(sql == cadence.monthlyEquivalentCents(of: amount), "\(cadence) \(amount)")
                }
            }
        }
        #expect(Cadence.annual.monthlyEquivalentCents(of: 13900) == 1158)
    }
}
