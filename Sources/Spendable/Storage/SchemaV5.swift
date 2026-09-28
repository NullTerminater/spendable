import Foundation
import GRDB

/// Schema v5: recurring-charge detection (milestone 5).
///
/// Every table and column here is specified by `docs/reviews/milestone-5-review.md`; the decision
/// numbers in the comments refer to it. v1-v4 are untouched, as they must be.
extension AppDatabase {
    /// The key the migration leaves in `sync_state` so the history walk it restarts can say why.
    static let billsRewalkKey = "bills-rewalk"

    static func migrateV5(_ db: Database) throws {
        try db.execute(sql: schemaV5)
        // Decision 3: the two coverage scalars cannot show a gap, so nothing is converted from
        // them. Instead the history walk runs once more, inside the existing budget, and records
        // real intervals as it goes. Only a connected database has anything to re-walk.
        let connected = try Bool.fetchOne(
            db, sql: "SELECT EXISTS (SELECT 1 FROM account WHERE source = 'simplefin' AND archived_at IS NULL)") ?? false
        if connected {
            try db.execute(sql: "DELETE FROM sync_state WHERE key = ?", arguments: [BackfillProgress.key])
            try db.execute(sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, '1')",
                           arguments: [billsRewalkKey])
        }
    }

    /// Tables, columns and triggers. The triggers are last, so nothing the migration itself writes
    /// is queued for detection. Every trigger carries an `IS NOT` guard: SQLite fires `UPDATE OF`
    /// even when the value is unchanged, and every sync rewrites each row in its overlap.
    static let schemaV5 = """
    CREATE TABLE tx_coverage (
        account_id INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
        start_at INTEGER NOT NULL,
        end_at INTEGER NOT NULL,
        first_fetched_at INTEGER NOT NULL,
        last_fetched_at INTEGER NOT NULL,
        CHECK (end_at > start_at),
        PRIMARY KEY (account_id, start_at)
    ) WITHOUT ROWID;

    CREATE TABLE detection_dirty (
        account_id INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
        merchant_key TEXT NOT NULL,
        enqueued_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        failed_at INTEGER,
        PRIMARY KEY (account_id, merchant_key)
    ) WITHOUT ROWID;

    ALTER TABLE recurring_charge ADD COLUMN detected_amount_cents INTEGER;
    ALTER TABLE recurring_charge ADD COLUMN detected_cadence TEXT CHECK (detected_cadence IS NULL OR detected_cadence IN ('weekly','biweekly','monthly','quarterly','annual'));
    ALTER TABLE recurring_charge ADD COLUMN detected_anchor_date INTEGER;
    ALTER TABLE recurring_charge ADD COLUMN detected_last_seen_day TEXT;
    ALTER TABLE recurring_charge ADD COLUMN detected_member_count INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE recurring_charge ADD COLUMN amount_changed_from_cents INTEGER;
    ALTER TABLE recurring_charge ADD COLUMN owner_overrides INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE recurring_charge ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE recurring_charge ADD COLUMN statement_merchant TEXT;
    ALTER TABLE recurring_charge ADD COLUMN statement_merchant_key TEXT;
    ALTER TABLE recurring_charge ADD COLUMN detection_account_id INTEGER REFERENCES account(id) ON DELETE SET NULL;
    ALTER TABLE recurring_charge ADD COLUMN currency TEXT NOT NULL DEFAULT 'USD';
    ALTER TABLE recurring_charge ADD COLUMN announced_at INTEGER;
    ALTER TABLE recurring_charge ADD COLUMN inferred_inactive_since TEXT;
    ALTER TABLE recurring_charge ADD COLUMN inference_checked_through TEXT;
    ALTER TABLE recurring_charge ADD COLUMN still_active_through TEXT;
    ALTER TABLE recurring_charge ADD COLUMN evidence_changed INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE recurring_charge ADD COLUMN transfer_evidence_account_id INTEGER REFERENCES account(id) ON DELETE SET NULL;
    ALTER TABLE recurring_charge ADD COLUMN cancelled_on TEXT;
    ALTER TABLE recurring_charge ADD COLUMN monthly_cents INTEGER GENERATED ALWAYS AS (
        CASE cadence
            WHEN 'weekly' THEN (amount_cents * 52 + 6) / 12
            WHEN 'biweekly' THEN (amount_cents * 26 + 6) / 12
            WHEN 'monthly' THEN amount_cents
            WHEN 'quarterly' THEN (amount_cents + 1) / 3
            WHEN 'annual' THEN (amount_cents + 6) / 12
        END) VIRTUAL;
    CREATE INDEX recurring_charge_monthly ON recurring_charge(monthly_cents DESC, id);
    CREATE INDEX recurring_charge_detection_key ON recurring_charge(detection_account_id, merchant_normalized);

    CREATE TABLE recurring_occurrence (
        transaction_id INTEGER PRIMARY KEY REFERENCES bank_transaction(id) ON DELETE CASCADE,
        recurring_charge_id INTEGER NOT NULL REFERENCES recurring_charge(id),
        occurrence_day TEXT,
        role TEXT NOT NULL CHECK (role IN ('evidence', 'payment', 'pending_payment')),
        linked_amount_cents INTEGER NOT NULL,
        linked_by TEXT NOT NULL CHECK (linked_by IN ('detector', 'owner')),
        created_at INTEGER NOT NULL
    );
    CREATE INDEX recurring_occurrence_charge ON recurring_occurrence(recurring_charge_id, occurrence_day);
    CREATE UNIQUE INDEX recurring_occurrence_one_payment
        ON recurring_occurrence(recurring_charge_id, occurrence_day)
        WHERE role IN ('payment', 'pending_payment');

    CREATE TABLE recurring_link_rejection (
        transaction_id INTEGER NOT NULL REFERENCES bank_transaction(id) ON DELETE CASCADE,
        recurring_charge_id INTEGER NOT NULL REFERENCES recurring_charge(id) ON DELETE CASCADE,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (transaction_id, recurring_charge_id)
    ) WITHOUT ROWID;

    CREATE TABLE detection_suppression (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        account_id INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
        merchant_key TEXT NOT NULL,
        cadence TEXT NOT NULL CHECK (cadence IN ('weekly','biweekly','monthly','quarterly','annual')),
        band_low_cents INTEGER NOT NULL,
        band_high_cents INTEGER NOT NULL,
        charge_id INTEGER NOT NULL REFERENCES recurring_charge(id),
        kind TEXT NOT NULL CHECK (kind IN ('dismissed', 'cancelled')),
        created_at INTEGER NOT NULL,
        undone_at INTEGER
    );
    CREATE INDEX detection_suppression_key
        ON detection_suppression(account_id, merchant_key, cadence) WHERE undone_at IS NULL;

    ALTER TABLE bank_transaction ADD COLUMN normalizer_version INTEGER;
    ALTER TABLE bank_transaction ADD COLUMN merchant_alt TEXT;
    ALTER TABLE bank_transaction ADD COLUMN detect_at INTEGER GENERATED ALWAYS AS (
        CASE
            WHEN transacted_at > 0 AND posted > 0 AND transacted_at <= posted
                 AND posted - transacted_at <= 864000 THEN transacted_at
            WHEN posted > 0 THEN posted
            WHEN transacted_at > 0 THEN transacted_at
            ELSE NULL
        END) VIRTUAL;
    CREATE INDEX bank_transaction_detect
        ON bank_transaction(account_id, merchant_normalized, detect_at)
        WHERE voided_at IS NULL AND superseded_by IS NULL;

    UPDATE recurring_charge
       SET currency = COALESCE((SELECT a.currency FROM account a WHERE a.id = recurring_charge.paying_account_id), 'USD');

    CREATE TRIGGER detection_dirty_on_insert AFTER INSERT ON bank_transaction
    WHEN NEW.merchant_normalized IS NOT NULL
    BEGIN
        INSERT INTO detection_dirty (account_id, merchant_key, enqueued_at)
        VALUES (NEW.account_id, NEW.merchant_normalized, CAST(strftime('%s', 'now') AS INTEGER))
        ON CONFLICT (account_id, merchant_key) DO UPDATE SET attempts = 0, failed_at = NULL;
    END;

    CREATE TRIGGER detection_dirty_on_update AFTER UPDATE OF
        account_id, posted, transacted_at, amount_cents, description, payee, memo, pending,
        merchant_normalized, superseded_by, voided_at ON bank_transaction
    WHEN OLD.account_id IS NOT NEW.account_id OR OLD.posted IS NOT NEW.posted
      OR OLD.transacted_at IS NOT NEW.transacted_at OR OLD.amount_cents IS NOT NEW.amount_cents
      OR OLD.description IS NOT NEW.description OR OLD.payee IS NOT NEW.payee
      OR OLD.memo IS NOT NEW.memo OR OLD.pending IS NOT NEW.pending
      OR OLD.merchant_normalized IS NOT NEW.merchant_normalized
      OR OLD.superseded_by IS NOT NEW.superseded_by OR OLD.voided_at IS NOT NEW.voided_at
    BEGIN
        INSERT INTO detection_dirty (account_id, merchant_key, enqueued_at)
        SELECT OLD.account_id, OLD.merchant_normalized, CAST(strftime('%s', 'now') AS INTEGER)
         WHERE OLD.merchant_normalized IS NOT NULL
        ON CONFLICT (account_id, merchant_key) DO UPDATE SET attempts = 0, failed_at = NULL;
        INSERT INTO detection_dirty (account_id, merchant_key, enqueued_at)
        SELECT NEW.account_id, NEW.merchant_normalized, CAST(strftime('%s', 'now') AS INTEGER)
         WHERE NEW.merchant_normalized IS NOT NULL
        ON CONFLICT (account_id, merchant_key) DO UPDATE SET attempts = 0, failed_at = NULL;
    END;

    CREATE TRIGGER detection_dirty_on_account AFTER UPDATE OF
        amounts_reversed, user_type, currency, archived_at, replaced_by, holdings_count, guess_class ON account
    WHEN OLD.amounts_reversed IS NOT NEW.amounts_reversed OR OLD.user_type IS NOT NEW.user_type
      OR OLD.currency IS NOT NEW.currency OR OLD.archived_at IS NOT NEW.archived_at
      OR OLD.replaced_by IS NOT NEW.replaced_by OR OLD.holdings_count IS NOT NEW.holdings_count
      OR OLD.guess_class IS NOT NEW.guess_class
    BEGIN
        INSERT INTO detection_dirty (account_id, merchant_key, enqueued_at)
        VALUES (NEW.id, '*', CAST(strftime('%s', 'now') AS INTEGER))
        ON CONFLICT (account_id, merchant_key) DO UPDATE SET attempts = 0, failed_at = NULL;
    END;

    CREATE TRIGGER detection_dirty_on_manual_bill AFTER UPDATE OF
        statement_merchant_key, paying_account_id, cadence, amount_cents, status ON recurring_charge
    WHEN NEW.source = 'manual' AND (
           OLD.statement_merchant_key IS NOT NEW.statement_merchant_key
        OR OLD.paying_account_id IS NOT NEW.paying_account_id OR OLD.cadence IS NOT NEW.cadence
        OR OLD.amount_cents IS NOT NEW.amount_cents OR OLD.status IS NOT NEW.status)
    BEGIN
        INSERT INTO detection_dirty (account_id, merchant_key, enqueued_at)
        SELECT OLD.paying_account_id, OLD.statement_merchant_key, CAST(strftime('%s', 'now') AS INTEGER)
         WHERE OLD.paying_account_id IS NOT NULL AND OLD.statement_merchant_key IS NOT NULL
        ON CONFLICT (account_id, merchant_key) DO UPDATE SET attempts = 0, failed_at = NULL;
        INSERT INTO detection_dirty (account_id, merchant_key, enqueued_at)
        SELECT NEW.paying_account_id, NEW.statement_merchant_key, CAST(strftime('%s', 'now') AS INTEGER)
         WHERE NEW.paying_account_id IS NOT NULL AND NEW.statement_merchant_key IS NOT NULL
        ON CONFLICT (account_id, merchant_key) DO UPDATE SET attempts = 0, failed_at = NULL;
    END;

    CREATE TRIGGER detection_dirty_on_manual_bill_insert AFTER INSERT ON recurring_charge
    WHEN NEW.source = 'manual' AND NEW.paying_account_id IS NOT NULL AND NEW.statement_merchant_key IS NOT NULL
    BEGIN
        INSERT INTO detection_dirty (account_id, merchant_key, enqueued_at)
        VALUES (NEW.paying_account_id, NEW.statement_merchant_key, CAST(strftime('%s', 'now') AS INTEGER))
        ON CONFLICT (account_id, merchant_key) DO UPDATE SET attempts = 0, failed_at = NULL;
    END;

    CREATE TRIGGER detection_dirty_on_coverage AFTER INSERT ON tx_coverage
    BEGIN
        INSERT INTO detection_dirty (account_id, merchant_key, enqueued_at)
        VALUES (NEW.account_id, '*coverage', CAST(strftime('%s', 'now') AS INTEGER))
        ON CONFLICT (account_id, merchant_key) DO UPDATE SET attempts = 0, failed_at = NULL;
    END;
    """
}
