import Foundation
import GRDB

/// The bounded queries detection is allowed to make. None of them reads an account's history
/// unbounded, and the per-key ones repeat the partial index's predicate verbatim so SQLite uses
/// `bank_transaction_detect` (`docs/reviews/milestone-5-review.md`, decisions 8 and 9).
enum DetectionQueries {
    /// Live rows for one key since a horizon, counted from the index alone.
    static let countForKey = """
        SELECT COUNT(*) FROM bank_transaction
         WHERE account_id = ? AND merchant_normalized = ?
           AND voided_at IS NULL AND superseded_by IS NULL AND detect_at >= ?
        """

    /// The same rows, oldest first. Only run after `countForKey` has said there are few enough.
    static let rowsForKey = """
        SELECT id, amount_cents, detect_at, posted, transacted_at, pending FROM bank_transaction
         WHERE account_id = ? AND merchant_normalized = ?
           AND voided_at IS NULL AND superseded_by IS NULL AND detect_at >= ?
         ORDER BY detect_at ASC, id ASC
        """

    /// True when one fetched span covers all of [from, to): coverage rows never overlap, so one
    /// row is both necessary and sufficient (decision 3).
    static func covered(_ db: Database, accountId: Int64, from: Int64, to: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM tx_coverage WHERE account_id = ? AND start_at <= ? AND end_at >= ?)
            """, arguments: [accountId, from, to]) ?? false
    }

    /// The oldest settled row the bank has ever sent for the account. A clean answer about a period
    /// the bank does not keep proves nothing, so coverage never counts from before this (B-03).
    static func evidenceFloor(_ db: Database, accountId: Int64) throws -> Int64? {
        try Int64.fetchOne(db, sql: """
            SELECT MIN(effective_date) FROM bank_transaction
             WHERE account_id = ? AND pending = 0 AND voided_at IS NULL AND superseded_by IS NULL
            """, arguments: [accountId])
    }

    /// The coverage span that contains `instant`, clipped at the evidence floor.
    static func coveringSpan(_ db: Database, accountId: Int64, containing instant: Int64) throws -> (start: Int64, end: Int64)? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT start_at, end_at FROM tx_coverage WHERE account_id = ? AND start_at <= ? AND end_at > ?
            """, arguments: [accountId, instant, instant]) else { return nil }
        let start: Int64 = row["start_at"]
        let end: Int64 = row["end_at"]
        let floor = try evidenceFloor(db, accountId: accountId) ?? end
        return (max(start, floor), end)
    }

    /// Any live debit on the account, under any merchant key, in an amount band and a span of
    /// posting instants. This is how "charged under a different name" is caught (decision 4). It
    /// uses the account/day index; the amount filter is applied to the few rows in the span.
    static func debitsAnywhere(
        _ db: Database, accountId: Int64, fromInstant: Int64, toInstant: Int64,
        lowCents: Int64, highCents: Int64, reversed: Bool
    ) throws -> [(id: Int64, key: String?, pending: Bool)] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, amount_cents, merchant_normalized, pending FROM bank_transaction
             WHERE account_id = ? AND effective_date >= ? AND effective_date < ?
               AND voided_at IS NULL AND superseded_by IS NULL
            """, arguments: [accountId, fromInstant, toInstant])
        return rows.compactMap { row in
            let raw: Int64 = row["amount_cents"]
            let signed = reversed ? -raw : raw
            guard signed < 0, -signed >= lowCents, -signed <= highCents else { return nil }
            return (row["id"], row["merchant_normalized"], (row["pending"] as Int? ?? 0) != 0)
        }
    }
}
