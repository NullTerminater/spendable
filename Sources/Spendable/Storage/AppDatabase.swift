import Foundation
import GRDB

/// Owns the GRDB connection and the schema. One instance per process; the widget never creates one.
///
/// Every amount is an INTEGER count of cents and every timestamp an INTEGER of Unix epoch seconds.
/// Migrations are forward-only. The schema is written once, in v1, with every column the later
/// milestones need, so that no later milestone has to migrate the owner's real data.
final class AppDatabase: Sendable {
    let writer: any DatabaseWriter

    /// Opens, creating if needed, the database file at `url` as a WAL-mode pool.
    static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        return try AppDatabase(pool)
    }

    /// An in-memory database. Tests only.
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue(configuration: configuration()))
    }

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    var reader: any DatabaseReader { writer }

    private static func configuration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        // Statement arguments hold balances and descriptions; they must never reach a log.
        config.publicStatementArguments = false
        return config
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: schemaV1)
        }
        return migrator
    }

    /// Schema v1. Column names are snake_case; records map them with `convertFromSnakeCase`.
    static let schemaV1 = """
    CREATE TABLE account (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source TEXT NOT NULL CHECK (source IN ('simplefin', 'manual')),
        conn_id TEXT,
        external_id TEXT,
        remote_name TEXT,
        conn_name TEXT,
        org_id TEXT,
        org_name TEXT,
        display_name TEXT NOT NULL,
        guessed_type TEXT CHECK (guessed_type IN ('checking', 'savings', 'cash', 'credit')),
        user_type TEXT CHECK (user_type IN ('checking', 'savings', 'cash', 'credit')),
        currency TEXT NOT NULL DEFAULT 'USD',
        balance_cents INTEGER NOT NULL DEFAULT 0,
        available_cents INTEGER,
        balance_date INTEGER NOT NULL,
        last_seen_in_sync_at INTEGER,
        tx_synced_through INTEGER,
        backfilled_through INTEGER,
        history_coverage_start INTEGER,
        manual_updated_at INTEGER,
        archived_at INTEGER,
        replaced_by INTEGER REFERENCES account(id) ON DELETE SET NULL,
        amounts_reversed INTEGER NOT NULL DEFAULT 0,
        include_in_safe_to_spend INTEGER,
        cc_due_day INTEGER CHECK (cc_due_day IS NULL OR (cc_due_day BETWEEN 1 AND 31)),
        cc_minimum_cents INTEGER,
        cc_statement_cents INTEGER,
        cc_statement_entered_at INTEGER,
        cc_has_credit_balance INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
    );
    CREATE UNIQUE INDEX account_natural_key
        ON account(source, conn_id, external_id) WHERE external_id IS NOT NULL;
    CREATE INDEX account_archived ON account(archived_at);

    CREATE TABLE recurring_charge (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source TEXT NOT NULL CHECK (source IN ('manual', 'detected')),
        kind TEXT NOT NULL DEFAULT 'subscription' CHECK (kind IN ('subscription', 'bill', 'transfer')),
        name TEXT NOT NULL,
        merchant_normalized TEXT,
        amount_cents INTEGER NOT NULL,
        cadence TEXT NOT NULL CHECK (cadence IN ('weekly', 'biweekly', 'monthly', 'quarterly', 'annual')),
        next_expected_date INTEGER,
        paying_account_id INTEGER REFERENCES account(id) ON DELETE SET NULL,
        status TEXT NOT NULL CHECK (status IN ('confirmed', 'suggested', 'dismissed', 'cancelled')),
        confirmed_by TEXT CHECK (confirmed_by IS NULL OR confirmed_by IN ('user', 'auto')),
        amount_changed_on INTEGER,
        last_seen_at INTEGER,
        fingerprint TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
    );
    CREATE INDEX recurring_charge_status ON recurring_charge(status);
    CREATE INDEX recurring_charge_paying_account ON recurring_charge(paying_account_id);
    CREATE UNIQUE INDEX recurring_charge_fingerprint
        ON recurring_charge(fingerprint) WHERE fingerprint IS NOT NULL;

    CREATE TABLE bank_transaction (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        account_id INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
        external_id TEXT NOT NULL,
        posted INTEGER,
        transacted_at INTEGER,
        effective_date INTEGER NOT NULL,
        amount_cents INTEGER NOT NULL,
        description TEXT NOT NULL,
        payee TEXT,
        memo TEXT,
        mcc TEXT,
        pending INTEGER NOT NULL DEFAULT 0,
        merchant_normalized TEXT,
        category TEXT,
        recurring_charge_id INTEGER REFERENCES recurring_charge(id) ON DELETE SET NULL,
        first_seen_at INTEGER NOT NULL,
        last_seen_at INTEGER NOT NULL,
        superseded_by INTEGER REFERENCES bank_transaction(id) ON DELETE SET NULL,
        voided_at INTEGER,
        UNIQUE (account_id, external_id)
    );
    CREATE INDEX bank_transaction_account_effective
        ON bank_transaction(account_id, effective_date DESC);
    CREATE INDEX bank_transaction_merchant ON bank_transaction(merchant_normalized);
    CREATE INDEX bank_transaction_pending ON bank_transaction(account_id) WHERE pending = 1;
    CREATE INDEX bank_transaction_recurring ON bank_transaction(recurring_charge_id);

    CREATE TABLE pay_schedule (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        anchor_day TEXT NOT NULL
    );

    CREATE TABLE balance_snapshot (
        account_id INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
        day TEXT NOT NULL,
        balance_cents INTEGER NOT NULL,
        available_cents INTEGER,
        PRIMARY KEY (account_id, day)
    ) WITHOUT ROWID;

    CREATE TABLE safe_to_spend_snapshot (
        day TEXT PRIMARY KEY,
        cents INTEGER NOT NULL,
        until_payday_cents INTEGER
    ) WITHOUT ROWID;

    CREATE TABLE sync_state (
        key TEXT PRIMARY KEY,
        value TEXT
    ) WITHOUT ROWID;

    CREATE TABLE settings (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        primary_figure TEXT NOT NULL DEFAULT 'calendarMonth'
            CHECK (primary_figure IN ('calendarMonth', 'untilPayday')),
        sync_interval_hours INTEGER NOT NULL DEFAULT 6,
        show_number_in_menu_bar INTEGER NOT NULL DEFAULT 1,
        open_at_login INTEGER NOT NULL DEFAULT 0
    );
    INSERT INTO settings (id) VALUES (1);
    """
}
