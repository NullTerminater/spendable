import Foundation
import GRDB
import Testing
@testable import Spendable

/// What ingestion must now do for detection (`docs/reviews/milestone-5-review.md`, decisions 3, 7
/// and 27). Synthetic rows only.
@Suite("Ingestion feeds detection")
struct DetectionIngestTests {
    private static func transaction(
        _ id: String, amount: String = "-9.99", description: String = "PAYPAL *SPOTIFY", payee: String? = nil,
        posted: Int64 = 1_790_000_000, pending: Bool? = nil
    ) -> SimpleFINTransaction {
        SimpleFINTransaction(id: id, posted: posted, amount: amount, description: description, payee: payee,
                             memo: nil, transactedAt: nil, pending: pending, mcc: nil)
    }

    @Test("every stored row gets its merchant key, and a payee arriving later moves it")
    func keysAreWritten() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            let account = try SimpleFINIngestTests.seedAccount(db)
            var outcome = SyncOutcome()
            try SimpleFINIngest.store([Self.transaction("T1")], accountId: account, db: db,
                                      nowSeconds: 1_790_000_100, outcome: &outcome, calendar: .current)
            #expect(try String.fetchOne(db, sql: "SELECT merchant_normalized FROM bank_transaction") == "SPOTIFY")
            #expect(try Int.fetchOne(db, sql: "SELECT normalizer_version FROM bank_transaction") == MerchantKey.version)
            #expect(try String.fetchAll(db, sql: "SELECT merchant_key FROM detection_dirty") == ["SPOTIFY"])

            try db.execute(sql: "DELETE FROM detection_dirty")
            try SimpleFINIngest.store([Self.transaction("T1", payee: "Spotify USA")], accountId: account, db: db,
                                      nowSeconds: 1_790_000_200, outcome: &outcome, calendar: .current)
            #expect(try String.fetchOne(db, sql: "SELECT merchant_normalized FROM bank_transaction") == "SPOTIFY")
            #expect(try String.fetchOne(db, sql: "SELECT merchant_alt FROM bank_transaction") == nil)

            // The same answer again changes nothing and queues nothing.
            try db.execute(sql: "DELETE FROM detection_dirty")
            try SimpleFINIngest.store([Self.transaction("T1", payee: "Spotify USA")], accountId: account, db: db,
                                      nowSeconds: 1_790_000_300, outcome: &outcome, calendar: .current)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM detection_dirty") == 0)
        }
    }

    @Test("a hold written off by age that the bank reports again comes back")
    func ageOutIsUndone() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            let account = try SimpleFINIngestTests.seedAccount(db)
            var outcome = SyncOutcome()
            try SimpleFINIngest.store([Self.transaction("G17", pending: true)], accountId: account, db: db,
                                      nowSeconds: 1_790_000_100, outcome: &outcome, calendar: .current)
            try db.execute(sql: "UPDATE bank_transaction SET voided_at = 1, voided_reason = ?",
                           arguments: [SimpleFINIngest.ageOutReason])
            try SimpleFINIngest.store([Self.transaction("G17", pending: false)], accountId: account, db: db,
                                      nowSeconds: 1_791_000_000, outcome: &outcome, calendar: .current)
            let row = try Row.fetchOne(db, sql: "SELECT voided_at, voided_reason, pending FROM bank_transaction")
            #expect(row?["voided_at"] as Int64? == nil)
            #expect(row?["voided_reason"] as String? == nil)
            #expect(row?["pending"] as Int? == 0)
        }
    }

    @Test("a void for any other reason stands when the row is reported again")
    func otherVoidsStand() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            let account = try SimpleFINIngestTests.seedAccount(db)
            var outcome = SyncOutcome()
            try SimpleFINIngest.store([Self.transaction("X1")], accountId: account, db: db,
                                      nowSeconds: 1_790_000_100, outcome: &outcome, calendar: .current)
            try db.execute(sql: "UPDATE bank_transaction SET voided_at = 1, voided_reason = 'synthetic other reason'")
            try SimpleFINIngest.store([Self.transaction("X1")], accountId: account, db: db,
                                      nowSeconds: 1_790_000_200, outcome: &outcome, calendar: .current)
            #expect(try Int64.fetchOne(db, sql: "SELECT voided_at FROM bank_transaction") == 1)
        }
    }

    @Test("coverage merges overlapping and touching spans, and keeps a real gap")
    func coverageMerges() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            let account = try SimpleFINIngestTests.seedAccount(db)
            let day: Int64 = 86_400
            try SimpleFINIngest.recordCoverage(db, accountId: account, start: 100 * day, end: 144 * day, nowSeconds: 1)
            try SimpleFINIngest.recordCoverage(db, accountId: account, start: 139 * day, end: 183 * day, nowSeconds: 2)
            try SimpleFINIngest.recordCoverage(db, accountId: account, start: 183 * day, end: 190 * day, nowSeconds: 3)
            try SimpleFINIngest.recordCoverage(db, accountId: account, start: 10 * day, end: 20 * day, nowSeconds: 4)
            let rows = try Row.fetchAll(db, sql: "SELECT start_at, end_at, first_fetched_at, last_fetched_at FROM tx_coverage ORDER BY start_at")
            #expect(rows.count == 2)
            #expect(rows[0]["start_at"] as Int64? == 10 * day)
            #expect(rows[1]["start_at"] as Int64? == 100 * day)
            #expect(rows[1]["end_at"] as Int64? == 190 * day)
            #expect(rows[1]["first_fetched_at"] as Int64? == 1)
            #expect(rows[1]["last_fetched_at"] as Int64? == 3)
            #expect(try DetectionQueries.covered(db, accountId: account, from: 105 * day, to: 185 * day))
            #expect(try !DetectionQueries.covered(db, accountId: account, from: 15 * day, to: 105 * day))
        }
    }
}
