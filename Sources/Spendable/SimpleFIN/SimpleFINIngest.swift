import Foundation
import GRDB

/// Something worth telling the owner about a sync, already attributed to whoever it is about.
struct SyncNotice: Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        case account(Int64)
        case connection(String)
        /// True of the whole connection: the saved credential no longer works.
        case wholeCredential
        /// Nobody in particular. Shown once, attributed to SimpleFIN.
        case everything
        /// For the log only. About how the app asked, not about the owner's money.
        case developer
    }

    let scope: Scope
    let text: String
    let code: String
}

struct SyncOutcome: Equatable, Sendable {
    var accountsSeen: Int = 0
    var accountsInserted: Int = 0
    var transactionsInserted: Int = 0
    var transactionsMatchedByContent: Int = 0
    var pendingSuperseded: Int = 0
    var pendingVoided: Int = 0
    var accountsMarkedNotUpdating: Int = 0
    var notices: [SyncNotice] = []
    var quotaWarned: Bool = false
}

/// Turning an answer from SimpleFIN into rows.
///
/// Every rule here depends on **which question was asked**, so the request kind travels with the
/// response rather than being guessed from its contents. A balances-only answer returns an empty
/// transactions array for every account, which is indistinguishable from "this account had no
/// transactions" — and reading that as fact would void live pending charges and march the
/// watermarks forward over data nobody ever fetched.
enum SimpleFINIngest {
    /// How long a pending charge is kept before it is written off, if nothing ever settles it and
    /// the bank stops reporting it.
    static let pendingAgeOutDays = 10
    /// How far apart a hold and the charge that settles it may be.
    static let supersedeWindowDays = 10

    static func ingest(
        _ set: SimpleFINAccountSet,
        kind: SimpleFINRequestKind,
        into db: Database,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> SyncOutcome {
        var outcome = SyncOutcome()
        outcome.accountsSeen = set.accounts.count
        let nowSeconds = Int64(now.timeIntervalSince1970)

        if set.carriesQuotaWarning {
            try RequestBudget.recordServerQuotaWarning(db, now: now)
            outcome.quotaWarned = true
        }

        // Which accounts the server said something was wrong with. Their watermarks stay put, so
        // the next sync asks for the same span again instead of stepping over a gap.
        let existing = try Account.filter(Column("source") == AccountSource.simplefin.rawValue).fetchAll(db)
        let routed = route(set.errlist, over: existing, in: set)
        outcome.notices = routed.notices
        let troubled = routed.accountsWithTrouble

        switch kind {
        case .balances:
            try ingestBalances(set, db: db, existing: existing, troubled: troubled,
                               nowSeconds: nowSeconds, outcome: &outcome, calendar: calendar)
        case .window(let start, let end):
            try ingestWindow(set, db: db, window: start...end, troubled: troubled,
                             nowSeconds: nowSeconds, outcome: &outcome, calendar: calendar)
        }
        return outcome
    }

    // MARK: Errors

    private struct Routed {
        var notices: [SyncNotice] = []
        var accountsWithTrouble: Set<Int64> = []
    }

    /// Attaches each error to whoever it is actually about.
    ///
    /// An account id is unique only *within* a connection, so it is resolved by the pair. With no
    /// connection given, an error is attached only when exactly one account in the whole database
    /// carries that id; otherwise it is shown once against the response, without claiming which
    /// account it concerns. Guessing would put a bank's warning on the wrong account.
    private static func route(
        _ errors: [SimpleFINServerError], over accounts: [Account], in set: SimpleFINAccountSet
    ) -> Routed {
        var routed = Routed()
        for error in errors {
            switch error.prefix {
            case "act":
                let matches = accounts.filter { account in
                    guard account.externalId == error.accountId else { return false }
                    if let connId = error.connId { return account.connId == connId }
                    return true
                }
                if matches.count == 1, let id = matches[0].id {
                    routed.notices.append(SyncNotice(scope: .account(id), text: error.msg, code: error.code))
                    routed.accountsWithTrouble.insert(id)
                } else {
                    routed.notices.append(SyncNotice(scope: .everything, text: error.msg, code: error.code))
                }
            case "con":
                if let connId = error.connId {
                    let matches = accounts.filter { $0.connId == connId }
                    // A connection error that matches no account in *this* response still belongs
                    // to the accounts already stored for it. Routing it to nobody is the same as
                    // hiding a dead connection.
                    routed.notices.append(SyncNotice(scope: .connection(connId), text: error.msg, code: error.code))
                    for account in matches { if let id = account.id { routed.accountsWithTrouble.insert(id) } }
                } else {
                    routed.notices.append(SyncNotice(scope: .everything, text: error.msg, code: error.code))
                }
            case "gen":
                if error.code == "gen.auth" || error.code == "gen.auth." {
                    routed.notices.append(SyncNotice(scope: .wholeCredential, text: error.msg, code: error.code))
                } else if error.code.hasPrefix("gen.api") && !error.isQuotaWarning {
                    // About how the app asked, not about the owner's money.
                    routed.notices.append(SyncNotice(scope: .developer, text: error.msg, code: error.code))
                } else {
                    routed.notices.append(SyncNotice(scope: .everything, text: error.msg, code: error.code))
                }
            default:
                routed.notices.append(SyncNotice(scope: .everything, text: error.msg, code: error.code))
            }
        }
        for text in set.errors ?? [] {
            routed.notices.append(SyncNotice(scope: .everything, text: text, code: "errors"))
        }
        return routed
    }

    // MARK: Balances

    /// The only path that may write a balance, insert an account, or decide an account has stopped
    /// updating. A request carrying an end-date is answered with the balance **as of that date**,
    /// so a history window would otherwise overwrite today's balance with a ten-month-old one.
    private static func ingestBalances(
        _ set: SimpleFINAccountSet, db: Database, existing: [Account], troubled: Set<Int64>,
        nowSeconds: Int64, outcome: inout SyncOutcome, calendar: Calendar
    ) throws {
        var seen: Set<Int64> = []

        for incoming in set.accounts {
            let connection = set.connection(incoming.connId)
            let rowId = try upsertAccount(incoming, connection: connection, db: db,
                                          nowSeconds: nowSeconds, outcome: &outcome)
            seen.insert(rowId)

            guard let balance = try? Cents.parse(incoming.balance) else {
                // A balance that will not parse fails that account: it keeps what it had, is marked
                // as not updating, and the rest of the response carries on.
                try db.execute(
                    sql: "UPDATE account SET not_updating_since = COALESCE(not_updating_since, ?) WHERE id = ?",
                    arguments: [nowSeconds, rowId])
                outcome.notices.append(SyncNotice(
                    scope: .account(rowId),
                    text: "SimpleFIN sent a balance I couldn't read, so I've kept the last one I had.",
                    code: "app.balance"))
                continue
            }
            let available = incoming.availableBalance.flatMap { try? Cents.parse($0) }

            // The trailing guard stops a late answer from putting back an older balance.
            try db.execute(sql: """
                UPDATE account
                   SET balance_cents = ?, available_cents = ?, balance_date = ?,
                       last_seen_in_sync_at = ?, not_updating_since = NULL
                 WHERE id = ? AND ? >= balance_date
                """, arguments: [
                    balance, available, incoming.balanceDate, nowSeconds,
                    rowId, incoming.balanceDate,
                ])
            try recordHoldings(incoming, rowId: rowId, db: db)
            // Even when the balance was too old to write, the account was seen.
            try db.execute(
                sql: "UPDATE account SET last_seen_in_sync_at = ? WHERE id = ?",
                arguments: [nowSeconds, rowId])
        }

        // An account that was there before and is not there now has stopped updating — from this
        // moment, not after a week of its balance ageing. A sync that returns nothing at all is
        // never read as "you have no accounts".
        for account in existing {
            guard let id = account.id, !seen.contains(id), account.archivedAt == nil else { continue }
            let hadTrouble = troubled.contains(id)
            let credentialDead = set.hasGeneralAuthFailure
            guard hadTrouble || credentialDead || !set.accounts.isEmpty else { continue }
            if account.notUpdatingSince == nil {
                try db.execute(
                    sql: "UPDATE account SET not_updating_since = ? WHERE id = ?",
                    arguments: [nowSeconds, id])
                outcome.accountsMarkedNotUpdating += 1
            }
        }
        for id in troubled where seen.contains(id) {
            try db.execute(
                sql: "UPDATE account SET not_updating_since = COALESCE(not_updating_since, ?) WHERE id = ?",
                arguments: [nowSeconds, id])
        }
    }

    /// Notes how many holdings the bank reports, when it reports any at all.
    ///
    /// A balances-only answer returns an empty holdings array for every account, the same shape as
    /// an account that genuinely holds none, so an empty one is never taken as a statement. Only a
    /// response that actually lists holdings is allowed to set the count — which means the fact
    /// arrives with the first full transaction pull rather than the first balance check.
    private static func recordHoldings(_ incoming: SimpleFINAccount, rowId: Int64, db: Database) throws {
        guard let holdings = incoming.holdings, !holdings.isEmpty else { return }
        try db.execute(
            sql: "UPDATE account SET holdings_count = ? WHERE id = ?",
            arguments: [holdings.count, rowId])
    }

    /// Writes only the columns the server owns.
    ///
    /// `INSERT OR REPLACE` is not used and must never be: it deletes the row first, and
    /// `ON DELETE CASCADE` would take the owner's entire transaction history with it. GRDB's
    /// `save`/`upsert` is avoided for the smaller version of the same problem — its untargeted
    /// update writes every column, so a routine refresh would quietly undo the owner's account-type
    /// correction and reset how far back history has been filled in.
    private static func upsertAccount(
        _ incoming: SimpleFINAccount, connection: SimpleFINConnection?, db: Database,
        nowSeconds: Int64, outcome: inout SyncOutcome
    ) throws -> Int64 {
        let connId = incoming.connId ?? connection?.connId
        let institution = connection.map { $0.name.isEmpty ? ($0.orgName ?? incoming.name) : $0.name }

        if let existing = try Account
            .filter(Column("source") == AccountSource.simplefin.rawValue)
            .filter(Column("conn_id") == connId)
            .filter(Column("external_id") == incoming.id)
            .fetchOne(db), let id = existing.id {
            try db.execute(sql: """
                UPDATE account SET remote_name = ?, conn_name = ?, org_id = ?, org_name = ?, currency = ?
                 WHERE id = ?
                """, arguments: [incoming.name, institution, connection?.orgId, connection?.orgName,
                                 incoming.currency, id])
            return id
        }

        // A replaced credential can hand the same bank a new connection id. Adopting the existing
        // row keeps the owner's corrections and their history, where inserting would double every
        // balance for a week and then drop it.
        if let orgId = connection?.orgId {
            let liveConnIds = Set((try? Account.fetchAll(db))?.compactMap(\.connId) ?? [])
            _ = liveConnIds
            let candidates = try Account
                .filter(Column("source") == AccountSource.simplefin.rawValue)
                .filter(Column("org_id") == orgId)
                .filter(Column("external_id") == incoming.id)
                .filter(Column("archived_at") == nil)
                .fetchAll(db)
            let stale = candidates.filter { $0.connId != connId }
            if stale.count == 1, let id = stale[0].id {
                try db.execute(sql: """
                    UPDATE account SET conn_id = ?, remote_name = ?, conn_name = ?, org_name = ?, currency = ?
                     WHERE id = ?
                    """, arguments: [connId, incoming.name, institution, connection?.orgName, incoming.currency, id])
                return id
            }
        }

        var account = Account.manual(displayName: incoming.name, type: .checking, balanceCents: 0)
        account.source = .simplefin
        account.connId = connId
        account.externalId = incoming.id
        account.remoteName = incoming.name
        account.connName = institution
        account.orgId = connection?.orgId
        account.orgName = connection?.orgName
        account.currency = incoming.currency
        // The type is not known yet. Milestone 4 guesses it and lets the owner correct it; until
        // then the engine holds the account out of every total rather than guessing silently.
        account.userType = nil
        account.guessedType = nil
        account.balanceDate = incoming.balanceDate
        account.manualUpdatedAt = nil
        account.createdAt = nowSeconds
        try account.insert(db)
        outcome.accountsInserted += 1
        return account.id ?? 0
    }

    // MARK: Transactions

    private static func ingestWindow(
        _ set: SimpleFINAccountSet, db: Database, window: ClosedRange<CalendarDay>,
        troubled: Set<Int64>, nowSeconds: Int64, outcome: inout SyncOutcome, calendar: Calendar
    ) throws {
        for incoming in set.accounts {
            let connId = incoming.connId
            // A window may not create an account: it cannot supply a balance date worth trusting.
            guard let account = try Account
                .filter(Column("source") == AccountSource.simplefin.rawValue)
                .filter(Column("conn_id") == connId)
                .filter(Column("external_id") == incoming.id)
                .fetchOne(db), let accountId = account.id
            else { continue }

            // Holdings usually arrive with a full pull rather than a balance check, so the count is
            // taken from whichever answer actually carries them.
            try recordHoldings(incoming, rowId: accountId, db: db)

            let rows = incoming.transactions ?? []
            let everyAmountRead = try store(rows, accountId: accountId, db: db, nowSeconds: nowSeconds,
                                            outcome: &outcome, calendar: calendar)

            // Only an account the server answered for, with nothing wrong with it, may move its
            // watermark. An account that errored asks for the same span again next time — and so
            // does one whose answer carried an amount the app could not read, because a charge
            // missing from the number is worse than a window fetched twice.
            guard !troubled.contains(accountId), everyAmountRead else { continue }
            let through = window.upperBound.epochSeconds(in: calendar)
            try db.execute(sql: """
                UPDATE account
                   SET tx_synced_through = MAX(COALESCE(tx_synced_through, 0), ?),
                       history_coverage_start = MIN(COALESCE(history_coverage_start, ?), ?)
                 WHERE id = ?
                """, arguments: [through, window.lowerBound.epochSeconds(in: calendar),
                                 window.lowerBound.epochSeconds(in: calendar), accountId])
        }
    }

    /// Stores one account's transactions, and reconciles what was pending.
    ///
    /// Answers false when a row's amount could not be read. The rows it could read are still
    /// stored — a charge arriving twice is handled, a charge arriving never is not — but the caller
    /// leaves the watermark where it was, so the span is asked for again instead of the missing
    /// charge being written off in silence.
    @discardableResult
    static func store(
        _ rows: [SimpleFINTransaction], accountId: Int64, db: Database, nowSeconds: Int64,
        outcome: inout SyncOutcome, calendar: Calendar
    ) throws -> Bool {
        let idsInThisResponse = Set(rows.map(\.id))
        /// Amount, day and description together: what makes two lines the same charge to a reader.
        struct Signature: Hashable {
            let amount: Int64
            let effective: Int64
            let description: String
        }
        var unknown: [Signature: [(row: SimpleFINTransaction, amount: Int64, effective: Int64)]] = [:]

        var everyAmountRead = true
        for row in rows {
            let amount: Int64
            do { amount = try Cents.parse(row.amount) } catch {
                // One notice for the account, however many rows in this answer are unreadable.
                if everyAmountRead {
                    outcome.notices.append(SyncNotice(
                        scope: .account(accountId),
                        text: "SimpleFIN sent an amount I couldn't read, so at least one charge on this account is missing. I'll ask for it again.",
                        code: "app.amount"))
                }
                everyAmountRead = false
                continue
            }
            let effective = effectiveDate(row, nowSeconds: nowSeconds)

            // The fast path: the id the app already knows.
            if let existingId = try Int64.fetchOne(
                db, sql: "SELECT id FROM bank_transaction WHERE account_id = ? AND external_id = ?",
                arguments: [accountId, row.id]) {
                try db.execute(sql: """
                    UPDATE bank_transaction
                       SET posted = ?, transacted_at = ?, effective_date = ?, amount_cents = ?,
                           description = ?, payee = ?, memo = ?, mcc = ?, pending = ?, last_seen_at = ?
                     WHERE id = ?
                    """, arguments: [row.posted, row.transactedAt, effective, amount, row.description,
                                     row.payee, row.memo, row.mcc, row.isPending, nowSeconds, existingId])
                continue
            }
            unknown[Signature(amount: amount, effective: effective, description: row.description),
                    default: []].append((row, amount, effective))
        }

        // A transaction id is a hint, not an identity. The protocol promises it is unique within an
        // account, never that it is stable between two answers, and a hold that posts comes back
        // re-keyed. So rows the app cannot place by id are matched on what they *are*.
        //
        // Matched in groups rather than one at a time, and paired off greedily: two identical
        // coffees on the same day are a real thing, and both collapsing them into one and storing
        // four are wrong. Pairing min(existing, incoming) gets every case right — two and two stay
        // two, one and two become two, two and one stay two.
        for (signature, incoming) in unknown {
            var free = try Row.fetchAll(db, sql: """
                SELECT id, external_id FROM bank_transaction
                 WHERE account_id = ? AND amount_cents = ? AND effective_date = ? AND description = ?
                   AND voided_at IS NULL AND superseded_by IS NULL
                 ORDER BY id ASC
                """, arguments: [accountId, signature.amount, signature.effective, signature.description])
                .filter { row in
                    guard let externalId: String = row["external_id"] else { return false }
                    return !idsInThisResponse.contains(externalId)
                }

            for candidate in incoming {
                if !free.isEmpty {
                    let adopted = free.removeFirst()
                    let adoptedId: Int64 = adopted["id"] ?? 0
                    try db.execute(sql: """
                        UPDATE bank_transaction
                           SET external_id = ?, posted = ?, transacted_at = ?, payee = ?, memo = ?,
                               mcc = ?, pending = ?, last_seen_at = ?
                         WHERE id = ?
                        """, arguments: [candidate.row.id, candidate.row.posted, candidate.row.transactedAt,
                                         candidate.row.payee, candidate.row.memo, candidate.row.mcc,
                                         candidate.row.isPending, nowSeconds, adoptedId])
                    outcome.transactionsMatchedByContent += 1
                    continue
                }
                try db.execute(sql: """
                    INSERT INTO bank_transaction
                        (account_id, external_id, posted, transacted_at, effective_date, amount_cents,
                         description, payee, memo, mcc, pending, first_seen_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [accountId, candidate.row.id, candidate.row.posted,
                                     candidate.row.transactedAt, candidate.effective, candidate.amount,
                                     candidate.row.description, candidate.row.payee, candidate.row.memo,
                                     candidate.row.mcc, candidate.row.isPending, nowSeconds, nowSeconds])
                outcome.transactionsInserted += 1
            }
        }

        try reconcilePending(db: db, accountId: accountId, idsInThisResponse: idsInThisResponse,
                             nowSeconds: nowSeconds, outcome: &outcome, calendar: calendar)
        return everyAmountRead
    }

    /// Holds that have settled, and holds that never will.
    ///
    /// A pending row is never written off merely for being absent from one answer: the app asks for
    /// a five-day overlap, so an older hold falls outside the window it asked for and its absence
    /// says nothing. It is resolved by evidence — a settled charge that matches it — or by age.
    private static func reconcilePending(
        db: Database, accountId: Int64, idsInThisResponse: Set<String>, nowSeconds: Int64,
        outcome: inout SyncOutcome, calendar: Calendar
    ) throws {
        let pending = try Row.fetchAll(db, sql: """
            SELECT id, external_id, amount_cents, effective_date, description FROM bank_transaction
             WHERE account_id = ? AND pending = 1 AND voided_at IS NULL AND superseded_by IS NULL
             ORDER BY effective_date ASC, id ASC
            """, arguments: [accountId])
        guard !pending.isEmpty else { return }

        let settled = try Row.fetchAll(db, sql: """
            SELECT id, amount_cents, effective_date, description FROM bank_transaction
             WHERE account_id = ? AND pending = 0 AND voided_at IS NULL AND superseded_by IS NULL
             ORDER BY effective_date ASC, id ASC
            """, arguments: [accountId])

        var claimedSettled: Set<Int64> = []
        var claimedPending: Set<Int64> = []
        let windowSeconds = Int64(supersedeWindowDays) * 86_400

        for hold in pending {
            guard let holdId: Int64 = hold["id"], let externalId: String = hold["external_id"] else { continue }
            // A hold the bank is still reporting has not posted, whatever else looks like it.
            if idsInThisResponse.contains(externalId) { continue }
            guard let amount: Int64 = hold["amount_cents"],
                  let effective: Int64 = hold["effective_date"],
                  let description: String = hold["description"] else { continue }

            let matches = settled.filter { row in
                guard let id: Int64 = row["id"], !claimedSettled.contains(id) else { return false }
                guard let settledAmount: Int64 = row["amount_cents"], settledAmount == amount else { return false }
                guard let settledDescription: String = row["description"], settledDescription == description else { return false }
                guard let settledDate: Int64 = row["effective_date"] else { return false }
                return abs(settledDate - effective) <= windowSeconds
            }
            // Ambiguity is left alone: showing a hold for one more day is better than attributing a
            // charge to the wrong one and losing a real one.
            guard matches.count == 1, let settledId: Int64 = matches[0]["id"] else { continue }
            try db.execute(
                sql: "UPDATE bank_transaction SET superseded_by = ? WHERE id = ?",
                arguments: [settledId, holdId])
            claimedSettled.insert(settledId)
            claimedPending.insert(holdId)
            outcome.pendingSuperseded += 1
        }

        // A hold nothing ever settled, that the bank stopped reporting, is written off with its
        // reason recorded. It is never deleted: the owner's history is not the app's to throw away.
        let ageOut = nowSeconds - Int64(pendingAgeOutDays) * 86_400
        let voided = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM bank_transaction
             WHERE account_id = ? AND pending = 1 AND voided_at IS NULL AND superseded_by IS NULL
               AND effective_date < ? AND last_seen_at < ?
            """, arguments: [accountId, ageOut, nowSeconds]) ?? 0
        if voided > 0 {
            try db.execute(sql: """
                UPDATE bank_transaction
                   SET voided_at = ?, voided_reason = 'the bank stopped reporting this hold and nothing settled it'
                 WHERE account_id = ? AND pending = 1 AND voided_at IS NULL AND superseded_by IS NULL
                   AND effective_date < ? AND last_seen_at < ?
                """, arguments: [nowSeconds, accountId, ageOut, nowSeconds])
            outcome.pendingVoided += voided
        }
    }

    /// The day a transaction belongs to. `posted` is 0 while a charge is still a hold.
    static func effectiveDate(_ row: SimpleFINTransaction, nowSeconds: Int64) -> Int64 {
        if row.posted > 0 { return row.posted }
        if let transacted = row.transactedAt, transacted > 0 { return transacted }
        return nowSeconds
    }
}
