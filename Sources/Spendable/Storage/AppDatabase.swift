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

    /// Every migration, in order. Forward-only: a shipped one is never edited, because editing it
    /// is a silent no-op on a database that has already applied it.
    static let allMigrations = [
        "v1",
        "v2-recurring-anchor-destination-and-paid",
        "v3-sync-bookkeeping",
        "v4-account-type-guess",
    ]

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: schemaV1)
        }
        migrator.registerMigration("v2-recurring-anchor-destination-and-paid") { db in
            // anchor_date: the charge's first occurrence, which every later occurrence is measured
            // from. Without it, advancing next_expected_date one step at a time lets a bill due on
            // the 31st land on the 28th in February and stay there for good.
            try db.execute(sql: "ALTER TABLE recurring_charge ADD COLUMN anchor_date INTEGER")
            // destination_account_id: where a transfer goes. Whether a transfer leaves the money
            // the owner can spend depends entirely on which account receives it.
            try db.execute(sql: """
                ALTER TABLE recurring_charge
                ADD COLUMN destination_account_id INTEGER REFERENCES account(id) ON DELETE SET NULL
                """)
            // last_marked_paid_at / paid_reflected_in_balance: when the owner says they have paid a
            // bill but has not yet updated the balance it came out of, the money is gone from the
            // account and not yet gone from the number. Keeping the bill subtracted until the
            // balance catches up is the only way the figure does not jump up by the bill's amount.
            // Its own column, never updated_at, which a rename would also touch.
            try db.execute(sql: "ALTER TABLE recurring_charge ADD COLUMN last_marked_paid_at INTEGER")
            try db.execute(sql: """
                ALTER TABLE recurring_charge
                ADD COLUMN paid_reflected_in_balance INTEGER NOT NULL DEFAULT 1
                """)
            try db.execute(sql: "UPDATE recurring_charge SET anchor_date = next_expected_date WHERE anchor_date IS NULL")
        }
        migrator.registerMigration("v3-sync-bookkeeping") { db in
            // holdings_count: SimpleFIN carries no account type, and holdings are the strongest
            // signal in the whole response that a balance is a market value rather than money. The
            // demo's savings account holds six figures of Apple stock and is called "SimpleFIN
            // Savings", so a name-based guess would make it spendable.
            try db.execute(sql: "ALTER TABLE account ADD COLUMN holdings_count INTEGER NOT NULL DEFAULT 0")
            // not_updating_since: an account that vanishes from an otherwise successful response is
            // not updating from that moment, not after a week of its balance ageing. This is the
            // failure the owner's specification warns about most.
            try db.execute(sql: "ALTER TABLE account ADD COLUMN not_updating_since INTEGER")
            // Why a pending row stopped counting, so the reason survives in the history.
            try db.execute(sql: "ALTER TABLE bank_transaction ADD COLUMN voided_reason TEXT")
        }
        migrator.registerMigration("v4-account-type-guess") { db in
            try db.execute(sql: "ALTER TABLE account ADD COLUMN guessed_from_name TEXT")
            try db.execute(sql: "ALTER TABLE account ADD COLUMN guess_class TEXT CHECK (guess_class IS NULL OR guess_class IN ('investment','loan'))")
            try db.execute(sql: "ALTER TABLE account ADD COLUMN holdings_observed_at INTEGER")
            try db.execute(sql: "ALTER TABLE account ADD COLUMN resumed_updating_at INTEGER")
            try db.execute(sql: "ALTER TABLE account ADD COLUMN merge_candidate_for INTEGER REFERENCES account(id) ON DELETE SET NULL")
            try db.execute(sql: "ALTER TABLE account ADD COLUMN merge_answered_at INTEGER")
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
