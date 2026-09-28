import Foundation
import GRDB

/// One merchant key on one account, recomputed from its whole bounded history and reconciled with
/// the bills already stored for it. Always runs inside the caller's write transaction, together
/// with deleting that key's dirty row, so a crash can never acknowledge work it did not commit.
///
/// Every rule here is a decision in `docs/reviews/milestone-5-review.md`; the numbers in the
/// comments refer to it. The one rule above all others (decision 1): nothing in this file may raise
/// what the owner can spend. It may create and confirm bills, and link payments that the engine
/// then checks live; it never un-confirms a bill, never removes one from the number, and never
/// decides that money moved between the owner's own accounts.
enum DetectionPass {
    struct Context {
        var now: Date
        var calendar: Calendar

        var nowSeconds: Int64 { Int64(now.timeIntervalSince1970) }
        var today: CalendarDay { CalendarDay.today(in: calendar, now: now) }
        var horizon: Int64 { nowSeconds - Int64(SeriesFinder.lookBackDays) * 86_400 }
    }

    // MARK: Whole-account work

    /// `'*'`: something about the account changed (its sign, type, holdings or currency), so every
    /// key on it is reconsidered. Expanded in the same transaction that removes the `'*'` row.
    static func expandWholeAccount(_ accountId: Int64, db: Database, context: Context) throws {
        try db.execute(sql: """
            INSERT INTO detection_dirty (account_id, merchant_key, enqueued_at)
            SELECT DISTINCT account_id, merchant_normalized, ? FROM bank_transaction
             WHERE account_id = ? AND merchant_normalized IS NOT NULL
            ON CONFLICT (account_id, merchant_key) DO UPDATE SET attempts = 0, failed_at = NULL
            """, arguments: [context.nowSeconds, accountId])
        try db.execute(sql: """
            INSERT INTO detection_dirty (account_id, merchant_key, enqueued_at)
            SELECT DISTINCT detection_account_id, merchant_normalized, ? FROM recurring_charge
             WHERE detection_account_id = ? AND merchant_normalized IS NOT NULL
            ON CONFLICT (account_id, merchant_key) DO UPDATE SET attempts = 0, failed_at = NULL
            """, arguments: [context.nowSeconds, accountId])
    }

    /// `'*coverage'`: more of the account's history has been checked, which can only change whether
    /// an expected charge is proven missing. No clustering.
    static func reevaluateLateness(accountId: Int64, db: Database, context: Context) throws {
        guard let account = try Account.fetchOne(db, key: accountId) else { return }
        let series = try RecurringCharge.fetchAll(db, sql: """
            SELECT * FROM recurring_charge
             WHERE detection_account_id = ? AND source = 'detected' AND status = 'confirmed'
            """, arguments: [accountId])
        for charge in series {
            let dense = try isDense(accountId: accountId, key: charge.merchantNormalized ?? "", db: db)
            try updateLateness(charge, account: account, dense: dense, db: db, context: context)
        }
    }

    // MARK: One key

    static func run(accountId: Int64, key: String, db: Database, context: Context) throws {
        guard let account = try Account.fetchOne(db, key: accountId) else { return }

        // Shares, funds and loans are not spending money (decision 19, PLAN rule 11). The engine's
        // own classification decides, so the rule lives in one place.
        let standing = SafeToSpendEngine.classify(account, today: context.today, calendar: context.calendar).standing
        if standing == .heldOut(.holdsInvestments) || standing == .heldOut(.isALoan) { return }

        let reversed = account.amountsReversed && account.effectiveType != .credit
        let count = try Int.fetchOne(db, sql: DetectionQueries.countForKey,
                                     arguments: [accountId, key, context.horizon]) ?? 0
        // A place the owner pays very often is not read at all: no new bills, no status changes, no
        // lateness flags. Sampling it would manufacture confidence (decision 9). Existing confirmed
        // bills on it keep counting, and their occurrences stay owed.
        if count > SeriesFinder.maxRowsPerKey {
            try SyncState.set(db, denseStateKey(accountId: accountId, key: key), key)
            return
        }
        try db.execute(sql: "DELETE FROM sync_state WHERE key = ?", arguments: [denseStateKey(accountId: accountId, key: key)])

        let raw = try Row.fetchAll(db, sql: DetectionQueries.rowsForKey, arguments: [accountId, key, context.horizon])
        let rows: [DetectionRow] = raw.compactMap { row in
            guard let detectAt: Int64 = row["detect_at"] else { return nil }
            let amount: Int64 = row["amount_cents"]
            let posted: Int64? = row["posted"]
            let transacted: Int64? = row["transacted_at"]
            return DetectionRow(
                id: row["id"], amountCents: reversed ? -amount : amount,
                day: CalendarDay(epochSeconds: detectAt, in: SeriesFinder.utc),
                postedDay: (posted ?? 0) > 0 ? CalendarDay(epochSeconds: posted!, in: SeriesFinder.utc) : nil,
                dayIsTransactionDate: (transacted ?? 0) > 0 && transacted == detectAt,
                pending: (row["pending"] as Int? ?? 0) != 0)
        }

        var found = SeriesFinder.find(rows).tracks
        if found.isEmpty, let single = try singleYearlyCharge(rows: rows, accountId: accountId, db: db) {
            found = [single]
        }

        var state = try KeyState.load(accountId: accountId, key: key, rowIds: rows.map(\.id), db: db)
        for row in rows { state.magnitudes[row.id] = row.magnitude }
        for track in found {
            try reconcile(track, account: account, key: key, state: &state, db: db, context: context)
        }
        try matchPending(rows.filter { $0.pending && $0.isDebit }, state: &state, account: account, context: context)
        try writeLinks(state: state, db: db, context: context)

        for id in state.touchedSeries.union(state.seriesOnKey.keys) {
            guard let charge = try RecurringCharge.fetchOne(db, key: id) else { continue }
            try updateEvidenceHealth(charge, continuedThisPass: state.touchedSeries.contains(id), db: db)
            if charge.source == .detected {
                try updateTransferEvidence(charge, account: account, db: db, reversed: reversed)
            }
            if charge.status == .confirmed, let fresh = try RecurringCharge.fetchOne(db, key: id) {
                try updateLateness(fresh, account: account, dense: false, db: db, context: context)
            }
        }
    }

    // MARK: State for one key

    struct Link: Equatable {
        var chargeId: Int64
        var occurrenceDay: String?
        var role: String
        var amountCents: Int64
        var linkedBy: String
    }

    struct KeyState {
        var seriesOnKey: [Int64: RecurringCharge] = [:]
        var manualCandidates: [RecurringCharge] = []
        /// Existing links on the rows read, by transaction id.
        var existingLinks: [Int64: Link] = [:]
        /// Detector links on series of this key whose rows are no longer live or no longer here.
        var staleLinks: Set<Int64> = []
        /// Payment links on rows read this pass, kept unless a track decides them differently.
        var keptPayments: Set<Int64> = []
        var rejections: Set<[Int64]> = []
        var desired: [Int64: Link] = [:]
        var claimed: Set<Int64> = []
        var touchedSeries: Set<Int64> = []
        var magnitudes: [Int64: Int64] = [:]

        static func load(accountId: Int64, key: String, rowIds: [Int64], db: Database) throws -> KeyState {
            var state = KeyState()
            for charge in try RecurringCharge.fetchAll(db, sql: """
                SELECT * FROM recurring_charge WHERE source = 'detected' AND detection_account_id = ? AND merchant_normalized = ?
                """, arguments: [accountId, key]) {
                if let id = charge.id { state.seriesOnKey[id] = charge }
            }
            // A manual bill the owner has told the app how it appears on a statement (decision 20).
            state.manualCandidates = try RecurringCharge.fetchAll(db, sql: """
                SELECT * FROM recurring_charge
                 WHERE source = 'manual' AND paying_account_id = ? AND statement_merchant_key = ?
                   AND status IN ('confirmed', 'suggested')
                """, arguments: [accountId, key])
            for charge in state.manualCandidates { if let id = charge.id { state.seriesOnKey[id] = charge } }

            let rowSet = Set(rowIds)
            let seriesIds = Array(state.seriesOnKey.keys)
            var links = try Row.fetchAll(db, sql: """
                SELECT o.transaction_id, o.recurring_charge_id, o.occurrence_day, o.role, o.linked_amount_cents, o.linked_by
                  FROM recurring_occurrence o JOIN bank_transaction t ON t.id = o.transaction_id
                 WHERE t.account_id = ? AND t.merchant_normalized = ?
                   AND t.voided_at IS NULL AND t.superseded_by IS NULL AND t.detect_at >= 0
                """, arguments: [accountId, key])
            if !seriesIds.isEmpty {
                let marks = Array(repeating: "?", count: seriesIds.count).joined(separator: ",")
                links += try Row.fetchAll(db, sql: """
                    SELECT o.transaction_id, o.recurring_charge_id, o.occurrence_day, o.role, o.linked_amount_cents, o.linked_by,
                           t.merchant_normalized AS txn_key, t.account_id AS txn_account,
                           (t.voided_at IS NULL AND t.superseded_by IS NULL) AS live
                      FROM recurring_occurrence o JOIN bank_transaction t ON t.id = o.transaction_id
                     WHERE o.recurring_charge_id IN (\(marks))
                    """, arguments: StatementArguments(seriesIds))
                for row in try Row.fetchAll(db, sql: """
                    SELECT transaction_id, recurring_charge_id FROM recurring_link_rejection WHERE recurring_charge_id IN (\(marks))
                    """, arguments: StatementArguments(seriesIds)) {
                    state.rejections.insert([row["transaction_id"], row["recurring_charge_id"]])
                }
            }
            for row in links {
                let transactionId: Int64 = row["transaction_id"]
                let link = Link(chargeId: row["recurring_charge_id"], occurrenceDay: row["occurrence_day"],
                                role: row["role"], amountCents: row["linked_amount_cents"], linkedBy: row["linked_by"])
                state.existingLinks[transactionId] = link
                // Evidence that is gone, or has moved to another merchant, is let go here; the other
                // key's own pass links it there if it belongs.
                if let live: Bool = row["live"], link.linkedBy == "detector" {
                    let txnKey: String? = row["txn_key"]
                    let txnAccount: Int64? = row["txn_account"]
                    if !live || txnKey != key || txnAccount != accountId { state.staleLinks.insert(transactionId) }
                }
                // Evidence on rows read this pass is decided afresh. A payment link is only replaced
                // by a different decision, never dropped because a track briefly failed to form:
                // that would show bills the bank has shown paid as owed again.
                if rowSet.contains(transactionId), link.linkedBy == "detector" {
                    if link.role == "evidence" { state.staleLinks.insert(transactionId) } else { state.keptPayments.insert(transactionId) }
                }
            }
            return state
        }
    }

    // MARK: Matching a track to a bill (decisions 10, 11, 12, 20)

    private static func reconcile(
        _ track: FoundTrack, account: Account, key: String, state: inout KeyState, db: Database, context: Context
    ) throws {
        guard let accountId = account.id else { return }

        // 1. Charges already linked to exactly one bill continue it. Two or more: leave it alone.
        let linked = Set(track.memberIds.compactMap { id -> Int64? in
            guard let link = state.existingLinks[id], state.seriesOnKey[link.chargeId] != nil else { return nil }
            return link.chargeId
        })
        if linked.count > 1 { return }
        // A bill another track already continued in this pass is not this track's to continue:
        // two plans that once looked like one biweekly bill must end up as two bills.
        var chargeId: Int64? = linked.first.flatMap { state.claimed.contains($0) ? nil : $0 }
        var cappedByLineage = false

        // 2. A lineage continuation: the one bill on this key and cadence that ended just before.
        if chargeId == nil {
            let candidates = state.seriesOnKey.values.filter { charge in
                guard let id = charge.id, !state.claimed.contains(id), charge.source == .detected else { return false }
                return continues(track, charge, context: context)
            }
            if candidates.count == 1 { chargeId = candidates[0].id } else if candidates.count > 1 { cappedByLineage = true }
        }

        // 3. A dismissal or cancellation that covers this amount on this key and cadence.
        if chargeId == nil, !cappedByLineage {
            chargeId = try suppressingCharge(for: track, accountId: accountId, key: key, state: state, db: db, context: context)
        }

        // 4. A manual bill with this statement merchant, account, cadence, amount and due day.
        if chargeId == nil, !cappedByLineage {
            let adoptable = state.manualCandidates.filter { manual in
                guard let id = manual.id, !state.claimed.contains(id), manual.cadence == track.cadence,
                      withinBand(track.currentAmountCents, of: manual.amountCents),
                      let anchor = manual.anchorDay(in: context.calendar) ?? manual.nextExpectedDay(in: context.calendar)
                else { return false }
                return SeriesFinder.occurrencePaid(by: track.lastDay, anchor: anchor, cadence: track.cadence) != nil
            }
            if adoptable.count == 1 { chargeId = adoptable[0].id }
        }

        // 5. Otherwise a new bill.
        if chargeId == nil {
            chargeId = try insertSeries(track, account: account, key: key, suggestionOnly: cappedByLineage, db: db, context: context)
            if let id = chargeId, let fresh = try RecurringCharge.fetchOne(db, key: id) { state.seriesOnKey[id] = fresh }
        }
        guard let id = chargeId else { return }
        let known = state.seriesOnKey[id]
        guard var charge = try known ?? RecurringCharge.fetchOne(db, key: id) else { return }
        state.claimed.insert(id)
        state.touchedSeries.insert(id)

        if charge.source == .detected {
            charge = try updateDetectedSeries(charge, track: track, db: db, context: context)
            state.seriesOnKey[id] = charge
        }
        planLinks(track, for: charge, state: &state, context: context)
    }

    /// Whether `track` carries on from `charge`: the same cadence, starting within two intervals
    /// after the bill's last charge, at a price in its band or one step from it. A dismissed or
    /// cancelled bill also needs the same day of the cycle, and no overlap in time: two runs of
    /// charges at the same time are two subscriptions, however alike (decision 10).
    private static func continues(_ track: FoundTrack, _ charge: RecurringCharge, context: Context) -> Bool {
        let cadence = charge.detectedCadence ?? charge.cadence
        guard cadence == track.cadence,
              let lastText = charge.detectedLastSeenDay, let last = CalendarDay(isoString: lastText),
              let first = track.memberDays.first else { return false }
        let apart = last.days(to: first, in: SeriesFinder.utc)
        guard apart > 0, apart <= 2 * SeriesFinder.window(cadence).upperBound else { return false }
        let price = charge.detectedAmountCents ?? charge.amountCents
        let amount = track.firstAmountCents
        guard withinBand(amount, of: price) || (75 * price <= 100 * amount && 100 * amount <= 150 * price) else { return false }
        if charge.status == .dismissed || charge.status == .cancelled {
            guard let anchor = charge.anchorDay(in: context.calendar) else { return false }
            return SeriesFinder.occurrencePaid(by: first, anchor: anchor, cadence: cadence) != nil
        }
        return true
    }

    /// The dismissed or cancelled bill whose suppression covers this track, if exactly one does.
    private static func suppressingCharge(
        for track: FoundTrack, accountId: Int64, key: String, state: KeyState, db: Database, context: Context
    ) throws -> Int64? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.charge_id, s.band_low_cents, s.band_high_cents, c.detected_last_seen_day
              FROM detection_suppression s JOIN recurring_charge c ON c.id = s.charge_id
             WHERE s.account_id = ? AND s.merchant_key = ? AND s.cadence = ? AND s.undone_at IS NULL
            """, arguments: [accountId, key, track.cadence.rawValue])
        let amount = track.currentAmountCents
        let matches: [Int64] = rows.compactMap { row in
            let low: Int64 = row["band_low_cents"]
            let high: Int64 = row["band_high_cents"]
            let id: Int64 = row["charge_id"]
            guard 100 * amount >= 95 * low, 100 * amount <= 105 * high else { return nil }
            // Running at the same time as the suppressed bill's own charges proves it is another one.
            if let lastText: String = row["detected_last_seen_day"], let last = CalendarDay(isoString: lastText),
               let first = track.memberDays.first, first <= last,
               !track.memberIds.contains(where: { state.existingLinks[$0]?.chargeId == id }) {
                return nil
            }
            return state.claimed.contains(id) ? nil : id
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func insertSeries(
        _ track: FoundTrack, account: Account, key: String, suggestionOnly: Bool, db: Database, context: Context
    ) throws -> Int64? {
        let confirmed = track.confidence == .confirmed && !suggestionOnly
        let anchor = track.anchor.epochSeconds(in: context.calendar)
        let now = context.nowSeconds
        try db.execute(sql: """
            INSERT INTO recurring_charge
                (source, kind, name, merchant_normalized, amount_cents, cadence, anchor_date, next_expected_date,
                 paying_account_id, status, confirmed_by, amount_changed_on, last_seen_at, paid_reflected_in_balance,
                 created_at, updated_at, detected_amount_cents, detected_cadence, detected_anchor_date,
                 detected_last_seen_day, detected_member_count, amount_changed_from_cents, detection_account_id,
                 currency, announced_at)
            VALUES ('detected', 'subscription', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                displayName(for: key), key, track.currentAmountCents, track.cadence.rawValue, anchor, anchor,
                account.id, confirmed ? RecurringChargeStatus.confirmed.rawValue : RecurringChargeStatus.suggested.rawValue,
                confirmed ? ConfirmedBy.auto.rawValue : nil,
                track.priceChange.map { $0.on.epochSeconds(in: context.calendar) },
                track.lastDay.epochSeconds(in: context.calendar),
                now, now, track.currentAmountCents, track.cadence.rawValue, anchor,
                track.lastDay.isoString, track.memberIds.count, track.priceChange?.fromCents, account.id,
                account.currency,
                // Only an automatic confirmation is announced as "new bills found"; a suggestion is
                // listed where suggestions go.
                confirmed ? nil : now,
            ])
        let id = db.lastInsertedRowID
        // An opaque token for the v1 column and its UNIQUE index. Never derived from the data, so
        // two plans at the same price cannot collide and a price change cannot re-identify a bill.
        try db.execute(sql: "UPDATE recurring_charge SET fingerprint = ? WHERE id = ?", arguments: ["s\(id)", id])
        return id
    }

    /// Writes what detection read, and copies it into the effective columns only where the owner has
    /// not corrected them. Status only ever moves towards counting (decision 12).
    private static func updateDetectedSeries(
        _ charge: RecurringCharge, track: FoundTrack, db: Database, context: Context
    ) throws -> RecurringCharge {
        var updated = charge
        updated.detectedAmountCents = track.currentAmountCents
        updated.detectedCadence = track.cadence
        updated.detectedLastSeenDay = max(track.lastDay.isoString, charge.detectedLastSeenDay ?? "")
        updated.detectedMemberCount = track.memberIds.count
        if let change = track.priceChange {
            updated.amountChangedFromCents = change.fromCents
            updated.amountChangedOn = change.on.epochSeconds(in: context.calendar)
        }
        updated.lastSeenAt = track.lastDay.epochSeconds(in: context.calendar)
        if charge.ownerOverrides & OwnerOverride.amount == 0 { updated.amountCents = track.currentAmountCents }
        if charge.ownerOverrides & OwnerOverride.cadence == 0 { updated.cadence = track.cadence }

        switch charge.status {
        case .suggested where track.confidence == .confirmed:
            updated.status = .confirmed
            updated.confirmedBy = .auto
            updated.announcedAt = nil
        case .cancelled:
            // Charged again after the owner said it was cancelled. Only charges made after that day
            // count, so the last charge still posting is not mistaken for a new one; three of them
            // and it counts again, badged, as any new bill would.
            if let cancelledText = charge.cancelledOn, let cancelled = CalendarDay(isoString: cancelledText) {
                let after = cancelled.adding(days: SeriesFinder.tolerance(track.cadence), in: SeriesFinder.utc)
                if track.memberDays.filter({ $0 > after }).count >= 3 {
                    updated.status = .confirmed
                    updated.confirmedBy = .auto
                    updated.announcedAt = nil
                    try db.execute(sql: "UPDATE detection_suppression SET undone_at = ? WHERE charge_id = ? AND kind = 'cancelled' AND undone_at IS NULL",
                                   arguments: [context.nowSeconds, charge.id])
                }
            }
        default:
            break
        }
        guard updated != charge else { return charge }
        updated.revision += 1
        updated.updatedAt = context.nowSeconds
        try writeDetectorColumns(updated, db: db)
        return updated
    }

    /// Named columns only, never a whole-row update: an owner's form must not be overwritten by
    /// detection, and detection must not overwrite the owner's fields.
    private static func writeDetectorColumns(_ charge: RecurringCharge, db: Database) throws {
        try db.execute(sql: """
            UPDATE recurring_charge
               SET amount_cents = ?, cadence = ?, status = ?, confirmed_by = ?, announced_at = ?,
                   detected_amount_cents = ?, detected_cadence = ?, detected_last_seen_day = ?,
                   detected_member_count = ?, amount_changed_from_cents = ?, amount_changed_on = ?,
                   last_seen_at = ?, revision = ?, updated_at = ?
             WHERE id = ?
            """, arguments: [
                charge.amountCents, charge.cadence.rawValue, charge.status.rawValue, charge.confirmedBy?.rawValue,
                charge.announcedAt, charge.detectedAmountCents, charge.detectedCadence?.rawValue,
                charge.detectedLastSeenDay, charge.detectedMemberCount, charge.amountChangedFromCents,
                charge.amountChangedOn, charge.lastSeenAt, charge.revision, charge.updatedAt, charge.id,
            ])
    }

    // MARK: Links (decisions 10, 13, 16)

    private static func planLinks(_ track: FoundTrack, for charge: RecurringCharge, state: inout KeyState, context: Context) {
        guard let chargeId = charge.id, let anchor = charge.anchorDay(in: context.calendar) ?? charge.nextExpectedDay(in: context.calendar)
        else { return }
        var paid: Set<String> = Set(state.desired.values.filter { $0.chargeId == chargeId && $0.role == "payment" }.compactMap(\.occurrenceDay))
        for (index, id) in track.memberIds.enumerated() {
            if state.rejections.contains([id, chargeId]) { continue }
            if let existing = state.existingLinks[id], existing.linkedBy == "owner" { continue }
            let day = track.memberDays[index]
            let amount = state.magnitudes[id] ?? track.currentAmountCents
            if let occurrence = SeriesFinder.occurrencePaid(by: day, anchor: anchor, cadence: charge.cadence),
               !paid.contains(occurrence.isoString) {
                paid.insert(occurrence.isoString)
                state.desired[id] = Link(chargeId: chargeId, occurrenceDay: occurrence.isoString, role: "payment",
                                         amountCents: amount, linkedBy: "detector")
            } else {
                state.desired[id] = Link(chargeId: chargeId, occurrenceDay: nil, role: "evidence",
                                         amountCents: amount, linkedBy: "detector")
            }
        }
    }

    /// A hold matches a bill only uniquely: one bill, one occurrence, not already paid by a settled
    /// charge. Anything ambiguous leaves the occurrence owed (decision 16).
    private static func matchPending(_ holds: [DetectionRow], state: inout KeyState, account: Account, context: Context) throws {
        let settledPaid = Set(state.desired.values.filter { $0.role == "payment" }.map { "\($0.chargeId)|\($0.occurrenceDay ?? "")" })
        var taken: Set<String> = []
        for hold in holds {
            if let existing = state.existingLinks[hold.id], existing.linkedBy == "owner" { continue }
            var matches: [(Int64, String)] = []
            for charge in state.seriesOnKey.values where charge.status == .confirmed {
                guard let id = charge.id, !state.rejections.contains([hold.id, id]),
                      withinBand(hold.magnitude, of: charge.amountCents),
                      let anchor = charge.anchorDay(in: context.calendar) ?? charge.nextExpectedDay(in: context.calendar),
                      let occurrence = SeriesFinder.occurrencePaid(by: hold.day, anchor: anchor, cadence: charge.cadence)
                else { continue }
                let slot = "\(id)|\(occurrence.isoString)"
                if settledPaid.contains(slot) || taken.contains(slot) { continue }
                matches.append((id, occurrence.isoString))
            }
            guard matches.count == 1 else { continue }
            taken.insert("\(matches[0].0)|\(matches[0].1)")
            state.desired[hold.id] = Link(chargeId: matches[0].0, occurrenceDay: matches[0].1, role: "pending_payment",
                                          amountCents: hold.magnitude, linkedBy: "detector")
        }
    }

    /// Replaces detector links by difference, never delete-all and insert-all: owner links stay, and
    /// an unchanged link is not rewritten.
    private static func writeLinks(state: KeyState, db: Database, context: Context) throws {
        var removals: [Int64] = []
        // A payment link on a row read this pass survives unless its own bill was formed again this
        // pass without that row: then it is genuinely stale. If its bill formed no track at all, it
        // stays, so a merchant whose history briefly stops forming a series does not show bills the
        // bank has shown paid as owed again.
        var stale = state.staleLinks
        for id in state.keptPayments {
            guard let existing = state.existingLinks[id], state.touchedSeries.contains(existing.chargeId),
                  state.desired[id] != existing else { continue }
            stale.insert(id)
        }
        for id in stale where state.desired[id] != state.existingLinks[id] { removals.append(id) }
        for (id, link) in state.desired where state.existingLinks[id] != nil && state.existingLinks[id] != link {
            if state.keptPayments.contains(id), !stale.contains(id) { continue }
            if !removals.contains(id) { removals.append(id) }
        }
        for id in removals {
            try db.execute(sql: "DELETE FROM recurring_occurrence WHERE transaction_id = ? AND linked_by = 'detector'", arguments: [id])
        }
        // Settled before pending, so a settled charge always wins an occurrence's one payment slot.
        let ordered = state.desired.sorted { lhs, rhs in
            (lhs.value.role == "pending_payment" ? 1 : 0, lhs.key) < (rhs.value.role == "pending_payment" ? 1 : 0, rhs.key)
        }
        for (id, link) in ordered where state.existingLinks[id] != link || removals.contains(id) {
            if link.role != "evidence" {
                // A settled payment replaces a hold's link to the same occurrence (decision 10).
                try db.execute(sql: """
                    DELETE FROM recurring_occurrence
                     WHERE recurring_charge_id = ? AND occurrence_day = ? AND role = 'pending_payment'
                       AND linked_by = 'detector' AND transaction_id <> ?
                    """, arguments: [link.chargeId, link.occurrenceDay, id])
            }
            // OR IGNORE: if an owner link or another charge already holds this occurrence's one
            // payment slot, that occurrence is paid either way, and the key must not wedge on it.
            // The linked amount is the bank's magnitude now, so a later correction stops the link
            // counting at once, in the engine, before this pass runs again.
            try db.execute(sql: """
                INSERT OR IGNORE INTO recurring_occurrence
                    (transaction_id, recurring_charge_id, occurrence_day, role, linked_amount_cents, linked_by, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, link.chargeId, link.occurrenceDay, link.role, link.amountCents, link.linkedBy, context.nowSeconds])
        }
    }

    // MARK: Health, transfers and lateness

    /// A confirmed bill whose supporting charges have since shrunk below three keeps counting, and
    /// asks the owner to check it (decision 12).
    private static func updateEvidenceHealth(_ charge: RecurringCharge, continuedThisPass: Bool, db: Database) throws {
        guard let id = charge.id, charge.source == .detected else { return }
        // Fewer than three charges now support it, or none of this merchant's history forms it any
        // more: it keeps counting and asks to be checked.
        let supported = continuedThisPass && charge.detectedMemberCount >= 3
        let changed = charge.status == .confirmed && charge.confirmedBy == .auto && !supported
        guard changed != charge.evidenceChanged else { return }
        try db.execute(sql: "UPDATE recurring_charge SET evidence_changed = ?, revision = revision + 1 WHERE id = ?",
                       arguments: [changed, id])
    }

    /// The same amount arriving in another of the owner's accounts within three days, at least
    /// twice, is display evidence of a move between accounts (decision 18). It never makes the
    /// bill a transfer: that needs the owner to name where the money goes.
    private static func updateTransferEvidence(_ charge: RecurringCharge, account: Account, db: Database, reversed: Bool) throws {
        guard let id = charge.id, let accountId = account.id else { return }
        let members = try Row.fetchAll(db, sql: """
            SELECT t.amount_cents, t.effective_date FROM recurring_occurrence o JOIN bank_transaction t ON t.id = o.transaction_id
             WHERE o.recurring_charge_id = ? AND t.pending = 0 AND t.voided_at IS NULL AND t.superseded_by IS NULL
             ORDER BY t.effective_date DESC LIMIT 6
            """, arguments: [id])
        let others = try Account.fetchAll(db, sql: """
            SELECT * FROM account WHERE id <> ? AND source = 'simplefin' AND archived_at IS NULL
            """, arguments: [accountId])
        var receiving: Int64?
        var ambiguous = false
        for other in others {
            guard let otherId = other.id else { continue }
            let otherReversed = other.amountsReversed && other.effectiveType != .credit
            var hits = 0
            for member in members {
                let amount: Int64 = member["amount_cents"]
                let day: Int64 = member["effective_date"]
                let magnitude = abs(amount)
                let incoming = try Int64.fetchAll(db, sql: """
                    SELECT amount_cents FROM bank_transaction
                     WHERE account_id = ? AND effective_date BETWEEN ? AND ? AND voided_at IS NULL AND superseded_by IS NULL
                    """, arguments: [otherId, day - 3 * 86_400, day + 3 * 86_400])
                if incoming.contains(where: { (otherReversed ? -$0 : $0) == magnitude }) { hits += 1 }
            }
            if hits >= 2 {
                if receiving != nil { ambiguous = true }
                receiving = otherId
            }
        }
        let value = ambiguous ? nil : receiving
        guard value != charge.transferEvidenceAccountId else { return }
        try db.execute(sql: "UPDATE recurring_charge SET transfer_evidence_account_id = ?, revision = revision + 1 WHERE id = ?",
                       arguments: [value, id])
    }

    /// "Maybe cancelled?" (decisions 2 and 4). A flag and a sentence, never a subtraction removed:
    /// the bill keeps counting until the owner marks it cancelled. Set only when the two most recent
    /// expected charges (one, plus 90 days, for a yearly bill) are each proven missing: fetched with
    /// no gap, including a margin for posting, with no matching hold and no debit of that size on the
    /// account under any name.
    static func updateLateness(_ charge: RecurringCharge, account: Account, dense: Bool, db: Database, context: Context) throws {
        guard let id = charge.id, let accountId = account.id, charge.status == .confirmed else { return }
        var flag: String?
        if !dense, let lastText = charge.detectedLastSeenDay, let last = CalendarDay(isoString: lastText),
           let anchor = charge.anchorDay(in: context.calendar) {
            let cadence = charge.cadence
            let tolerance = SeriesFinder.tolerance(cadence)
            let floor = charge.stillActiveThrough.flatMap(CalendarDay.init(isoString:)) ?? last
            var expected: [CalendarDay] = []
            var index = 0
            while expected.count < 2, index < 1_200 {
                let day = SeriesFinder.occurrence(index, from: anchor, cadence: cadence)
                if day > last.adding(days: tolerance, in: SeriesFinder.utc), day > floor { expected.append(day) }
                index += 1
            }
            let needed = cadence == .annual ? Array(expected.prefix(1)) : expected
            let extra = cadence == .annual ? 90 : 0
            let reversed = account.amountsReversed && account.effectiveType != .credit
            var allMissing = !needed.isEmpty
            for day in needed where allMissing {
                let from = day.adding(days: -(tolerance + 1), in: SeriesFinder.utc).utcMidnight
                let to = day.adding(days: tolerance + 6 + extra, in: SeriesFinder.utc).utcMidnight
                let floorInstant = try DetectionQueries.evidenceFloor(db, accountId: accountId) ?? Int64.max
                guard floorInstant <= from, try DetectionQueries.covered(db, accountId: accountId, from: from, to: to) else {
                    allMissing = false
                    break
                }
                let price = charge.amountCents
                let nearby = try DetectionQueries.debitsAnywhere(
                    db, accountId: accountId, fromInstant: from, toInstant: to,
                    lowCents: (75 * price) / 100, highCents: (150 * price + 99) / 100, reversed: reversed)
                if !nearby.isEmpty { allMissing = false }
            }
            if allMissing { flag = needed.first?.isoString }
        }
        guard flag != charge.inferredInactiveSince else { return }
        try db.execute(sql: "UPDATE recurring_charge SET inferred_inactive_since = ?, revision = revision + 1 WHERE id = ?",
                       arguments: [flag, id])
    }

    // MARK: A single yearly charge (decision 28)

    private static func singleYearlyCharge(rows: [DetectionRow], accountId: Int64, db: Database) throws -> FoundTrack? {
        let debits = rows.filter { !$0.pending && $0.isDebit }
        guard debits.count == 1, let only = debits.first, only.magnitude >= 2_000 else { return nil }
        guard let text = try Row.fetchOne(db, sql: "SELECT payee, description, memo, effective_date, merchant_alt FROM bank_transaction WHERE id = ?",
                                          arguments: [only.id]) else { return nil }
        guard MerchantKey.hasYearlyKeyword(payee: text["payee"], description: text["description"], memo: text["memo"]) else { return nil }
        let instant: Int64 = text["effective_date"]
        guard let span = try DetectionQueries.coveringSpan(db, accountId: accountId, containing: instant),
              span.end - span.start >= 300 * 86_400 else { return nil }
        // No other charge from this merchant, under its alternate name either, anywhere in that span.
        if let alternate: String = text["merchant_alt"] {
            let others = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM bank_transaction
                 WHERE account_id = ? AND (merchant_normalized = ? OR merchant_alt = ?) AND id <> ?
                   AND effective_date >= ? AND effective_date < ? AND voided_at IS NULL AND superseded_by IS NULL
                """, arguments: [accountId, alternate, alternate, only.id, span.start, span.end]) ?? 0
            if others > 0 { return nil }
        }
        return FoundTrack(memberIds: [only.id], memberDays: [only.day], cadence: .annual,
                          currentAmountCents: only.magnitude, firstAmountCents: only.magnitude,
                          priceChange: nil, confidence: .suggested, anchor: only.day)
    }

    // MARK: Helpers

    /// Where a dense key is remembered, so the Bills screen can name it and lateness skips it.
    static func denseStateKey(accountId: Int64, key: String) -> String { "detection-dense:\(accountId):\(key)" }

    static func isDense(accountId: Int64, key: String, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM sync_state WHERE key = ?)",
                          arguments: [denseStateKey(accountId: accountId, key: key)]) ?? false
    }

    static func withinBand(_ amount: Int64, of price: Int64) -> Bool {
        let difference = amount > price ? amount - price : price - amount
        return difference * 100 <= 5 * price
    }

    /// "BLUE BOTTLE COFFEE" reads "Blue Bottle Coffee". The owner can rename it.
    static func displayName(for key: String) -> String {
        key.split(separator: " ").map { word in
            word.count <= 3 && word.allSatisfy(\.isLetter) && !["THE", "AND"].contains(String(word))
                ? String(word) : String(word.prefix(1)) + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
