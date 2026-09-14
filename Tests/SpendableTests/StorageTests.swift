import Foundation
import GRDB
import Testing
@testable import Spendable

@Suite("Schema v1 and the Account record (in-memory database only)")
struct StorageTests {
    @Test("migrates an empty database to schema v1")
    func migratesEmptyDatabase() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        let expected: Set<String> = [
            "account", "bank_transaction", "recurring_charge", "pay_schedule",
            "balance_snapshot", "safe_to_spend_snapshot", "sync_state", "settings",
        ]
        #expect(expected.isSubset(of: Set(tables)))

        let indexes = try db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(indexes.contains("bank_transaction_account_effective"))
        #expect(indexes.contains("bank_transaction_merchant"))
        #expect(indexes.contains("account_natural_key"))

        let primaryFigure = try db.reader.read { db in
            try String.fetchOne(db, sql: "SELECT primary_figure FROM settings WHERE id = 1")
        }
        #expect(primaryFigure == "calendarMonth")

        let foreignKeys = try db.reader.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") }
        #expect(foreignKeys == 1)

        let applied = try db.reader.read { db in try AppDatabase.migrator.appliedIdentifiers(db) }
        #expect(applied == ["v1", "v2-recurring-anchor-destination-and-paid"])
    }

    @Test("a database already at v1 upgrades to v2 keeping its rows, and the new columns work")
    func upgradesFromV1WithRows() throws {
        // Milestone 1 is tagged and the owner may already have accounts and a database at v1.
        let queue = try DatabaseQueue()
        var v1Only = DatabaseMigrator()
        v1Only.registerMigration("v1") { db in try db.execute(sql: AppDatabase.schemaV1) }
        try v1Only.migrate(queue)

        let accountId = try queue.write { db -> Int64 in
            var account = Account.manual(displayName: "Chase Checking", type: .checking, balanceCents: 124_000)
            try account.insert(db)
            try db.execute(sql: """
                INSERT INTO recurring_charge (source, kind, name, amount_cents, cadence, next_expected_date, status, created_at, updated_at)
                VALUES ('manual', 'bill', 'Rent', 50000, 'monthly', 1790000000, 'confirmed', 0, 0)
                """)
            return account.id!
        }

        try AppDatabase.migrator.migrate(queue)

        let applied = try queue.read { db in try AppDatabase.migrator.appliedIdentifiers(db) }
        #expect(applied == ["v1", "v2-recurring-anchor-destination-and-paid"])

        let charge = try #require(try queue.read { db in try RecurringCharge.fetchOne(db) })
        #expect(charge.name == "Rent")
        #expect(charge.amountCents == 50_000)
        // The existing row's anchor is backfilled from its marker, so it keeps its day of the month.
        #expect(charge.anchorDate == 1_790_000_000)
        #expect(charge.destinationAccountId == nil)
        #expect(try queue.read { db in try Account.fetchCount(db) } == 1)

        // The added foreign key really is enforced: deleting the destination clears the reference.
        try queue.write { db in
            try db.execute(sql: "UPDATE recurring_charge SET destination_account_id = ?", arguments: [accountId])
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [accountId])
        }
        let after = try #require(try queue.read { db in try RecurringCharge.fetchOne(db) })
        #expect(after.destinationAccountId == nil)
    }

    @Test("a manual account round-trips through the database unchanged")
    func manualAccountRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var account = Account.manual(displayName: "Wallet", type: .cash, balanceCents: 4_000, now: now)
        try db.writer.write { db in try account.insert(db) }
        let id = try #require(account.id)

        let fetched = try #require(try db.reader.read { db in try Account.fetchOne(db, key: id) })
        #expect(fetched == account)
        #expect(fetched.source == .manual)
        #expect(fetched.effectiveType == .cash)
        #expect(fetched.userType == .cash)
        #expect(fetched.guessedType == nil)
        #expect(fetched.balanceCents == 4_000)
        #expect(fetched.balanceDate == 1_700_000_000)
        #expect(fetched.manualUpdatedAt == 1_700_000_000)
        #expect(fetched.currency == "USD")
        #expect(fetched.archivedAt == nil)
        #expect(fetched.amountsReversed == false)
        #expect(fetched.includeInSafeToSpend == nil)
    }

    @Test("the owner's type correction wins over the guess")
    func effectiveType() {
        var account = Account.manual(displayName: "Card", type: .credit, balanceCents: -41_200)
        account.userType = nil
        account.guessedType = .checking
        #expect(account.effectiveType == .checking)
        account.userType = .credit
        #expect(account.effectiveType == .credit)
    }

    @Test("active accounts exclude archived rows and list newest first")
    func activeOrdered() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            var old = Account.manual(displayName: "Old", type: .checking, balanceCents: 1, now: Date(timeIntervalSince1970: 1_000))
            var archived = Account.manual(displayName: "Gone", type: .checking, balanceCents: 2, now: Date(timeIntervalSince1970: 2_000))
            var new = Account.manual(displayName: "New", type: .checking, balanceCents: 3, now: Date(timeIntervalSince1970: 3_000))
            archived.archivedAt = 2_500
            try old.insert(db)
            try archived.insert(db)
            try new.insert(db)
        }
        let names = try db.reader.read { db in try Account.activeOrdered().fetchAll(db).map(\.displayName) }
        #expect(names == ["New", "Old"])
    }

    @Test("SimpleFIN accounts are unique per (source, connection, external id); manual accounts are not constrained")
    func naturalKey() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO account (source, conn_id, external_id, display_name, balance_date, created_at)
                VALUES ('simplefin', 'CON-1', 'ACT-1', 'A', 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO account (source, conn_id, external_id, display_name, balance_date, created_at)
                VALUES ('simplefin', 'CON-2', 'ACT-1', 'Same id, other connection', 0, 0)
                """)
            var one = Account.manual(displayName: "Manual", type: .cash, balanceCents: 0)
            var two = Account.manual(displayName: "Manual", type: .cash, balanceCents: 0)
            try one.insert(db)
            try two.insert(db)
        }
        #expect(throws: DatabaseError.self) {
            try db.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO account (source, conn_id, external_id, display_name, balance_date, created_at)
                    VALUES ('simplefin', 'CON-1', 'ACT-1', 'Duplicate', 0, 0)
                    """)
            }
        }
    }

    @Test("transaction ids are unique within an account, not across accounts")
    func transactionUniqueness() throws {
        let db = try AppDatabase.inMemory()
        let (first, second) = try db.writer.write { db -> (Int64, Int64) in
            var a = Account.manual(displayName: "A", type: .checking, balanceCents: 0)
            var b = Account.manual(displayName: "B", type: .checking, balanceCents: 0)
            try a.insert(db)
            try b.insert(db)
            return (a.id!, b.id!)
        }
        let insert = """
            INSERT INTO bank_transaction (account_id, external_id, effective_date, amount_cents, description, first_seen_at, last_seen_at)
            VALUES (?, ?, 0, -100, 'x', 0, 0)
            """
        try db.writer.write { db in
            try db.execute(sql: insert, arguments: [first, "TX-1"])
            try db.execute(sql: insert, arguments: [second, "TX-1"])
        }
        #expect(throws: DatabaseError.self) {
            try db.writer.write { db in try db.execute(sql: insert, arguments: [first, "TX-1"]) }
        }
        let count = try db.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bank_transaction") }
        #expect(count == 2)
    }

    @Test("the schema rejects unknown account types and out-of-range due days")
    func checkConstraints() throws {
        let db = try AppDatabase.inMemory()
        #expect(throws: DatabaseError.self) {
            try db.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO account (source, display_name, user_type, balance_date, created_at)
                    VALUES ('manual', 'X', 'brokerage', 0, 0)
                    """)
            }
        }
        #expect(throws: DatabaseError.self) {
            try db.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO account (source, display_name, cc_due_day, balance_date, created_at)
                    VALUES ('manual', 'X', 32, 0, 0)
                    """)
            }
        }
    }

    @Test("deleting an account cascades to its transactions")
    func cascade() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            var a = Account.manual(displayName: "A", type: .checking, balanceCents: 0)
            try a.insert(db)
            try db.execute(sql: """
                INSERT INTO bank_transaction (account_id, external_id, effective_date, amount_cents, description, first_seen_at, last_seen_at)
                VALUES (?, 'TX-1', 0, -100, 'x', 0, 0)
                """, arguments: [a.id!])
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [a.id!])
        }
        let count = try db.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bank_transaction") }
        #expect(count == 0)
    }
}
