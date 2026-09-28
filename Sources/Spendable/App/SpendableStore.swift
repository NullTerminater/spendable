import AppKit
import Foundation
import GRDB
import Observation
import os

/// Watches the handful of tables the figures depend on, and recomputes them when anything changes
/// — including when the calendar day rolls over, which changes nothing in the database but moves
/// both windows.
@MainActor
@Observable
final class SpendableStore {
    private(set) var result: SafeToSpendResult = .noAccountsYet
    private(set) var accounts: [Account] = []
    private(set) var charges: [RecurringCharge] = []
    private(set) var paySchedule: PaySchedule?
    private(set) var today: CalendarDay
    private(set) var failure: String?
    private(set) var syncNotices: [SyncNotice] = []
    private(set) var balancesSyncedAt: Date?
    private(set) var accountChangeMessage: String?
    /// What the bank has shown about bills being paid (milestone-5-review decision 26).
    private(set) var payments: BankPayments = .none
    /// Set when an owner edit found the bill had changed since the form opened.
    private(set) var billChangedMessage: String?
    /// The last Confirm, Dismiss, Mark cancelled or Same bill, which Undo reverses.
    private(set) var lastBillAction: BillUndo?
    /// Called after an owner action that gives detection work to do. AppModel owns the worker.
    var detectionRequested: (@MainActor () -> Void)?
    private var returnMessages: [(id: Int64, day: CalendarDay, text: String)] = []

    /// Which figure the owner is looking at. Settings makes this stick in milestone 9.
    var shownFigure: FigureKind = .calendarMonth

    private let database: AppDatabase
    private let calendar: Calendar
    private var cancellable: AnyDatabaseCancellable?
    private var dayObservers: [any NSObjectProtocol] = []
    private static let log = Logger(subsystem: StorePaths.bundleIdentifier, category: "figures")

    init(database: AppDatabase, calendar: Calendar = .current) {
        self.database = database
        self.calendar = calendar
        self.today = CalendarDay.today(in: calendar)
        #if DEBUG
        if ProcessInfo.processInfo.environment["SPENDABLE_DEBUG_FIGURE"] == "payday" {
            shownFigure = .untilPayday
        }
        #endif
        start()
        watchForTheDayChanging()
    }

    deinit {
        // Observers are torn down with the store; the observation cancels itself when released.
    }

    private struct Snapshot: Equatable, Sendable {
        var accounts: [Account] = []
        var charges: [RecurringCharge] = []
        var paySchedule: PaySchedule?
        var notices: [SyncNotice] = []
        var balancesSyncedAt: Date?
        var payments: BankPayments = .none

        init(_ db: Database) throws {
            // Archived accounts are fetched too: a bill still pointing at one has to be accounted
            // for, and the engine needs the row to name it.
            accounts = try Account.fetchAll(db)
            charges = try RecurringCharge.fetchAll(db)
            paySchedule = try PaySchedule.fetch(db)
            let oldestBalance = accounts.filter { $0.source == .simplefin && $0.archivedAt == nil }
                .map { min($0.balanceDate, $0.lastSeenInSyncAt ?? $0.balanceDate) }.min()
            payments = try BankPaymentQueries.load(db, oldestBalanceInstant: oldestBalance)
            balancesSyncedAt = try SyncState.date(db, SyncState.balancesSyncedAt)
            if let json = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'connection-notices'"),
               let data = json.data(using: .utf8) {
                notices = (try? JSONDecoder().decode([SyncNotice].self, from: data)) ?? []
            }
        }
    }

    private func start() {
        let observation = ValueObservation
            .tracking { db in try Snapshot(db) }
            .removeDuplicates()
        cancellable = observation.start(
            in: database.reader,
            scheduling: .async(onQueue: .main),
            onError: { [weak self] _ in
                Task { @MainActor in
                    self?.failure = "Spendable stopped keeping this up to date. Quit and open it again."
                }
            },
            onChange: { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            })
    }

    private func apply(_ snapshot: Snapshot) {
        let previous = result
        let oldAccounts = accounts
        if balancesSyncedAt != snapshot.balancesSyncedAt { accountChangeMessage = nil }
        accounts = snapshot.accounts
        charges = snapshot.charges
        paySchedule = snapshot.paySchedule
        syncNotices = snapshot.notices
        balancesSyncedAt = snapshot.balancesSyncedAt
        payments = snapshot.payments
        recompute(calendar: calendar)
        if result != previous { accountChangeMessage = nil }
        for account in accounts {
            guard let id = account.id, let resumed = account.resumedUpdatingAt,
                  CalendarDay(epochSeconds: resumed, in: calendar) == today,
                  account.notUpdatingSince == nil,
                  let classified = classifiedAccounts.first(where: { $0.id == account.id }),
                  classified.standing.isCounted else { continue }
            let prior = oldAccounts.first(where: { $0.id == account.id })
            guard prior?.notUpdatingSince != nil || oldAccounts.isEmpty else { continue }
            let before = AccountPresentation.headline(previous, kind: shownFigure)
            let after = AccountPresentation.headline(result, kind: shownFigure)
            let movement = prior == nil ? "" : before == "an incomplete total"
                ? "I can work out what you can spend again: \(after)."
                : "That's why what you can spend went from \(before) to \(after)."
            returnMessages.removeAll { $0.id == id }
            returnMessages.append((id, today, "\(account.displayName) is updating again. Its \(AccountPresentation.amount(classified.contributedCents)) is back in the figures. \(movement)"))
        }
    }

    private func recompute(calendar: Calendar = .current) {
        result = SafeToSpendEngine.compute(
            accounts: accounts, charges: charges, paySchedule: paySchedule,
            today: today, calendar: calendar, payments: payments)
    }

    /// The bills with their paid-through markers moved by the payments the bank has shown, as the
    /// engine sees them. What the Bills screen and Mark paid show as "next due".
    var effectiveCharges: [RecurringCharge] {
        SafeToSpendEngine.applying(payments, to: charges, accounts: classifiedAccounts, calendar: calendar)
    }

    /// Bills confirmed automatically that the owner has not yet seen on the Bills screen.
    var newBillsFound: Int {
        charges.filter { $0.status == .confirmed && $0.confirmedBy == .auto && $0.announcedAt == nil }.count
    }

    /// A day changing writes nothing to the database, so no observation fires. These do.
    private func watchForTheDayChanging() {
        let centre = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange,
        ]
        for name in names {
            dayObservers.append(centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.dayMayHaveChanged() }
            })
        }
        dayObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dayMayHaveChanged() }
        })
    }

    /// Recomputes only when the date has actually moved, so waking the Mac ten times in an evening
    /// costs nothing.
    func dayMayHaveChanged(calendar: Calendar = .current, now: Date = Date()) {
        let current = CalendarDay.today(in: calendar, now: now)
        guard current != today else { return }
        Self.log.info("day rolled over; recomputing")
        today = current
        recompute(calendar: calendar)
    }

    // MARK: Writing

    func savePayAnchor(_ day: CalendarDay) async {
        await write { db in
            try PaySchedule(anchor: day).save(db)
        }
    }

    /// Adds a bill, or saves the owner's edit to one.
    ///
    /// An edit writes only the columns the owner owns, and only if nothing else has written the row
    /// since the form opened (milestone-5-review decision 21): a detection or payment write in the
    /// meantime means the form reloads instead of putting old values back. On a detected bill each
    /// field the owner changes becomes an override detection will not undo.
    @discardableResult
    func save(_ charge: RecurringCharge) async -> BillWriteResult {
        let statementKey = charge.statementMerchant.flatMap { MerchantKey.normalize(payee: nil, description: $0).key }
        let now = Int64(Date.now.timeIntervalSince1970)
        do {
            let outcome = try await database.writer.write { db -> BillWriteResult in
                var row = charge
                row.statementMerchantKey = statementKey
                guard let id = row.id else {
                    if let payingId = row.payingAccountId, let account = try Account.fetchOne(db, key: payingId) {
                        row.currency = account.currency
                    }
                    try row.insert(db)
                    return .saved
                }
                guard let current = try RecurringCharge.fetchOne(db, key: id) else { return .gone }
                guard current.revision == charge.revision else { return .changedSinceOpened }
                var overrides = current.ownerOverrides
                if current.source == .detected {
                    if row.amountCents != current.amountCents { overrides |= OwnerOverride.amount }
                    if row.cadence != current.cadence { overrides |= OwnerOverride.cadence }
                    if row.payingAccountId != current.payingAccountId { overrides |= OwnerOverride.account }
                    if row.anchorDate != current.anchorDate { overrides |= OwnerOverride.anchor }
                }
                try db.execute(sql: """
                    UPDATE recurring_charge
                       SET name = ?, kind = ?, amount_cents = ?, cadence = ?, anchor_date = ?,
                           next_expected_date = ?, paying_account_id = ?, destination_account_id = ?,
                           statement_merchant = ?, statement_merchant_key = ?, owner_overrides = ?,
                           revision = revision + 1, updated_at = ?
                     WHERE id = ? AND revision = ?
                    """, arguments: [
                        row.name, row.kind.rawValue, row.amountCents, row.cadence.rawValue, row.anchorDate,
                        row.nextExpectedDate, row.payingAccountId, row.destinationAccountId,
                        row.statementMerchant, statementKey, overrides, now, id, charge.revision,
                    ])
                return db.changesCount == 1 ? .saved : .changedSinceOpened
            }
            report(outcome)
            if outcome == .saved { detectionRequested?() }
            return outcome
        } catch {
            saveFailed()
            return .failed
        }
    }

    /// Only a bill the owner typed in, with no bank charges linked to it, can be deleted. A detected
    /// bill is dismissed or marked cancelled instead, so its record stops it coming back
    /// (milestone-5-review decision 22).
    func delete(_ charge: RecurringCharge) async {
        guard let id = charge.id, charge.source == .manual else { return }
        do {
            let deleted = try await database.writer.write { db -> Bool in
                let linked = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM recurring_occurrence WHERE recurring_charge_id = ?)",
                                               arguments: [id]) ?? false
                guard !linked else { return false }
                return try RecurringCharge.deleteOne(db, key: id)
            }
            if !deleted {
                failure = "Bank charges are matched to this bill, so I can't delete it. Mark it cancelled instead."
            }
        } catch { saveFailed() }
    }

    /// Records that a bill has been paid, and optionally takes it off the balance it came from in
    /// the same step, so the number cannot rise before the money does.
    ///
    /// Moves the marker from where the owner saw it (the effective one, after bank payments) and
    /// only if the bill has not been written since; the balance is reduced only if the mark landed.
    @discardableResult
    func markPaid(
        _ charge: RecurringCharge,
        alsoReduceBalance: Bool,
        calendar: Calendar = .current,
        now: Date = .now
    ) async -> BillWriteResult {
        let updated = charge.markingPaidOnce(
            balanceAlreadyUpdated: alsoReduceBalance, in: calendar, now: now)
        let payingId = charge.payingAccountId
        let amount = charge.amountCents
        guard let id = charge.id else { return .gone }
        do {
            let outcome = try await database.writer.write { db -> BillWriteResult in
                try db.execute(sql: """
                    UPDATE recurring_charge
                       SET next_expected_date = ?, last_marked_paid_at = ?, paid_reflected_in_balance = ?,
                           revision = revision + 1, updated_at = ?
                     WHERE id = ? AND revision = ?
                    """, arguments: [updated.nextExpectedDate, updated.lastMarkedPaidAt, updated.paidReflectedInBalance,
                                     updated.updatedAt, id, charge.revision])
                guard db.changesCount == 1 else { return .changedSinceOpened }
                if alsoReduceBalance, let payingId, var account = try Account.fetchOne(db, key: payingId),
                   account.source == .manual {
                    account.balanceCents -= amount
                    account.balanceDate = Int64(now.timeIntervalSince1970)
                    account.manualUpdatedAt = account.balanceDate
                    try account.update(db)
                }
                return .saved
            }
            report(outcome)
            return outcome
        } catch {
            saveFailed()
            return .failed
        }
    }

    // MARK: Detected bills (milestone-5-review decisions 2, 11, 13, 20, 25)

    @discardableResult
    func apply(_ action: BillAction, to bill: RecurringCharge, now: Date = .now) async -> BillWriteResult {
        guard let id = bill.id else { return .gone }
        let seconds = Int64(now.timeIntervalSince1970)
        let today = CalendarDay.today(in: CalendarDay.utc, now: now).isoString
        do {
            let (outcome, undo) = try await database.writer.write { db -> (BillWriteResult, BillUndo?) in
                guard let current = try RecurringCharge.fetchOne(db, key: id) else { return (.gone, nil) }
                guard current.revision == bill.revision else { return (.changedSinceOpened, nil) }
                var suppressionId: Int64?
                switch action {
                case .confirm:
                    guard current.status == .suggested else { return (.changedSinceOpened, nil) }
                    try db.execute(sql: """
                        UPDATE recurring_charge SET status = 'confirmed', confirmed_by = 'user', announced_at = ?,
                               next_expected_date = COALESCE(next_expected_date, anchor_date),
                               revision = revision + 1, updated_at = ? WHERE id = ?
                        """, arguments: [seconds, seconds, id])
                case .dismiss, .markCancelled:
                    let kind = action == .dismiss ? "dismissed" : "cancelled"
                    try db.execute(sql: """
                        UPDATE recurring_charge SET status = ?, cancelled_on = ?, announced_at = COALESCE(announced_at, ?),
                               revision = revision + 1, updated_at = ? WHERE id = ?
                        """, arguments: [kind, action == .markCancelled ? today : nil, seconds, seconds, id])
                    if current.source == .detected, let account = current.detectionAccountId, let key = current.merchantNormalized {
                        let price = current.detectedAmountCents ?? current.amountCents
                        try db.execute(sql: """
                            INSERT INTO detection_suppression
                                (account_id, merchant_key, cadence, band_low_cents, band_high_cents, charge_id, kind, created_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [account, key, (current.detectedCadence ?? current.cadence).rawValue,
                                             min(price, current.amountChangedFromCents ?? price),
                                             max(price, current.amountChangedFromCents ?? price), id, kind, seconds])
                        suppressionId = db.lastInsertedRowID
                    }
                case .stillActive:
                    try db.execute(sql: """
                        UPDATE recurring_charge SET still_active_through = ?, inferred_inactive_since = NULL,
                               revision = revision + 1, updated_at = ? WHERE id = ?
                        """, arguments: [today, seconds, id])
                }
                return (.saved, BillUndo(chargeId: id, previousStatus: current.status,
                                         previousConfirmedBy: current.confirmedBy, suppressionId: suppressionId,
                                         action: action))
            }
            report(outcome)
            if let undo { lastBillAction = undo }
            return outcome
        } catch {
            saveFailed()
            return .failed
        }
    }

    /// Reverses the last Confirm, Dismiss or Mark cancelled at once, including its suppression, and
    /// asks detection to look at that merchant again.
    func undoLastBillAction(now: Date = .now) async {
        guard let undo = lastBillAction else { return }
        let seconds = Int64(now.timeIntervalSince1970)
        await write { db in
            try db.execute(sql: """
                UPDATE recurring_charge SET status = ?, confirmed_by = ?, cancelled_on = NULL,
                       revision = revision + 1, updated_at = ? WHERE id = ?
                """, arguments: [undo.previousStatus.rawValue, undo.previousConfirmedBy?.rawValue, seconds, undo.chargeId])
            if let suppression = undo.suppressionId {
                try db.execute(sql: "UPDATE detection_suppression SET undone_at = ? WHERE id = ?", arguments: [seconds, suppression])
            }
            try db.execute(sql: """
                INSERT INTO detection_dirty (account_id, merchant_key, enqueued_at)
                SELECT detection_account_id, merchant_normalized, ? FROM recurring_charge
                 WHERE id = ? AND detection_account_id IS NOT NULL AND merchant_normalized IS NOT NULL
                ON CONFLICT (account_id, merchant_key) DO UPDATE SET attempts = 0, failed_at = NULL
                """, arguments: [seconds, undo.chargeId])
        }
        lastBillAction = nil
        detectionRequested?()
    }

    /// The owner says a detected bill and a bill they typed in are the same one. The typed one is
    /// kept, with its name, amount and paid-through date; the detected one's bank charges move to it
    /// and the detected one is dismissed, in one transaction (decision 20).
    func sameBill(detected: RecurringCharge, manual: RecurringCharge, now: Date = .now) async {
        guard let detectedId = detected.id, let manualId = manual.id, detected.source == .detected,
              manual.source == .manual else { return }
        let seconds = Int64(now.timeIntervalSince1970)
        await write { db in
            try db.execute(sql: "UPDATE recurring_occurrence SET recurring_charge_id = ? WHERE recurring_charge_id = ?",
                           arguments: [manualId, detectedId])
            try db.execute(sql: """
                UPDATE recurring_charge
                   SET statement_merchant = COALESCE(statement_merchant, ?),
                       statement_merchant_key = COALESCE(statement_merchant_key, ?),
                       revision = revision + 1, updated_at = ? WHERE id = ?
                """, arguments: [detected.name, detected.merchantNormalized, seconds, manualId])
            try db.execute(sql: """
                UPDATE recurring_charge SET status = 'dismissed', announced_at = COALESCE(announced_at, ?),
                       revision = revision + 1, updated_at = ? WHERE id = ?
                """, arguments: [seconds, seconds, detectedId])
            if let account = detected.detectionAccountId, let key = detected.merchantNormalized {
                let price = detected.detectedAmountCents ?? detected.amountCents
                try db.execute(sql: """
                    INSERT INTO detection_suppression
                        (account_id, merchant_key, cadence, band_low_cents, band_high_cents, charge_id, kind, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, 'dismissed', ?)
                    """, arguments: [account, key, detected.cadence.rawValue, price, price, detectedId, seconds])
            }
        }
        detectionRequested?()
    }

    /// "That wasn't this bill": the latest bank charge matched to it stops counting as its payment,
    /// and is never matched to it again (decision 13).
    func rejectLatestPayment(_ bill: RecurringCharge, now: Date = .now) async {
        guard let id = bill.id else { return }
        let seconds = Int64(now.timeIntervalSince1970)
        await write { db in
            guard let transactionId = try Int64.fetchOne(db, sql: """
                SELECT transaction_id FROM recurring_occurrence
                 WHERE recurring_charge_id = ? AND role IN ('payment', 'pending_payment')
                 ORDER BY occurrence_day DESC LIMIT 1
                """, arguments: [id]) else { return }
            try db.execute(sql: "DELETE FROM recurring_occurrence WHERE transaction_id = ?", arguments: [transactionId])
            try db.execute(sql: """
                INSERT OR IGNORE INTO recurring_link_rejection (transaction_id, recurring_charge_id, created_at) VALUES (?, ?, ?)
                """, arguments: [transactionId, id, seconds])
            try db.execute(sql: "UPDATE recurring_charge SET revision = revision + 1 WHERE id = ?", arguments: [id])
        }
    }

    /// The Bills screen has been seen: automatically found bills are no longer new.
    func markNewBillsSeen(now: Date = .now) async {
        guard newBillsFound > 0 else { return }
        let seconds = Int64(now.timeIntervalSince1970)
        await write { db in
            try db.execute(sql: """
                UPDATE recurring_charge SET announced_at = ?
                 WHERE announced_at IS NULL AND status = 'confirmed' AND confirmed_by = 'auto'
                """, arguments: [seconds])
        }
    }

    func clearBillChangedMessage() { billChangedMessage = nil }

    private func report(_ outcome: BillWriteResult) {
        switch outcome {
        case .changedSinceOpened:
            billChangedMessage = "This bill changed while you were looking at it. Check the details and try again."
        case .gone:
            billChangedMessage = "This bill isn't there any more."
        case .saved, .failed:
            billChangedMessage = nil
        }
    }

    func setIncludeInSafeToSpend(_ account: Account, _ include: Bool) async {
        guard let id = account.id, AccountPresentation.offersSavingsSwitch(account) else { return }
        await write { db in
            try db.execute(
                sql: "UPDATE account SET include_in_safe_to_spend = ? WHERE id = ?",
                arguments: [include, id])
        }
    }

    var classifiedAccounts: [ClassifiedAccount] {
        switch result {
        case .figures(let report): report.accounts
        case .nothingCountable(let accounts): accounts
        case .noAccountsYet: []
        }
    }

    var accountSummary: [String] {
        AccountPresentation.summary(accounts: accounts, classified: classifiedAccounts)
    }

    var connectionSummary: String? {
        let synced = accounts.filter { $0.source == .simplefin && $0.archivedAt == nil }
        let failed = Set(synced.filter { AccountPresentation.notice(for: $0, in: syncNotices) != nil }
            .map(AccountPresentation.connectionName)).sorted()
        guard !failed.isEmpty else { return nil }
        let updated = Set(synced.filter { $0.notUpdatingSince == nil && AccountPresentation.notice(for: $0, in: syncNotices) == nil }
            .map(AccountPresentation.connectionName)).sorted()
        let when = balancesSyncedAt.map { AccountPresentation.timePhrase(Int64($0.timeIntervalSince1970)) } ?? "the last check"
        let success = updated.isEmpty ? "" : "Your \(SafeToSpendNarrative.sentenceList(updated)) accounts updated at \(when). "
        return success + "Your \(SafeToSpendNarrative.sentenceList(failed)) accounts didn't — see the note on each of them."
    }

    var accountLinesUnderNumber: [String] {
        var lines = accountChangeMessage.map { [$0] } ?? []
        let countedIds = Set(classifiedAccounts.filter { $0.standing.isCounted }.map(\.id))
        lines += returnMessages.filter { $0.day == today && countedIds.contains($0.id) }.map(\.text)
        for account in accounts where account.archivedAt == nil {
            guard let notice = AccountPresentation.notice(for: account, in: syncNotices),
                  let classified = classifiedAccounts.first(where: { $0.id == account.id }) else { continue }
            lines.append(AccountPresentation.connectionProblemLine(account, classified: classified, notice: notice))
        }
        return lines
    }

    func setType(_ account: Account, _ type: AccountType) async {
        guard let id = account.id, AccountPresentation.permitsTypeChoice(account) else { return }
        let before = result
        do {
            let changed = try await database.writer.write { db in
                guard var current = try Account.fetchOne(db, key: id), AccountPresentation.permitsTypeChoice(current) else { return false }
                current.userType = type
                try current.update(db)
                return true
            }
            try await reload()
            guard changed else { return }
            let corrected = AccountPresentation.correctedAmounts(account)
            if type == .checking, account.userType != .checking,
               let available = corrected.available, available < corrected.balance,
               classifiedAccounts.first(where: { $0.id == id })?.usedAvailableBalance == true {
                accountChangeMessage = "You confirmed \(account.displayName) is a checking account, so I've switched to the \(AccountPresentation.amount(available)) your bank says is free to spend right now. That's why what you can spend went from \(AccountPresentation.headline(before, kind: shownFigure)) to \(AccountPresentation.headline(result, kind: shownFigure)) — the \(AccountPresentation.amount(corrected.balance - available)) is payments that haven't finished going through."
            } else {
                accountChangeMessage = "You confirmed \(account.displayName) is \(type == .credit ? "a credit card" : "a " + type.label.lowercased() + " account"). What you can spend is now \(AccountPresentation.headline(result, kind: shownFigure))."
            }
        } catch { saveFailed() }
    }

    func rename(_ account: Account, to name: String) async {
        guard let id = account.id else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await write { db in
            try db.execute(sql: "UPDATE account SET display_name = ? WHERE id = ?", arguments: [trimmed, id])
        }
    }

    func setAmountsReversed(_ account: Account, _ reversed: Bool) async {
        guard let id = account.id, account.effectiveType != .credit,
              AccountPresentation.permitsTypeChoice(account) else { return }
        await write { db in
            try db.execute(sql: "UPDATE account SET amounts_reversed = ? WHERE id = ?", arguments: [reversed, id])
        }
    }

    func archiveConfirmation(_ account: Account) -> String {
        var after = accounts
        if let index = after.firstIndex(where: { $0.id == account.id }) {
            after[index].archivedAt = Int64(Date.now.timeIntervalSince1970)
        }
        let preview = SafeToSpendEngine.compute(accounts: after, charges: charges, paySchedule: paySchedule, today: today, calendar: calendar, payments: payments)
        let figure: SpendableFigure?
        if case .figures(let report) = preview { figure = report.figure(shownFigure) ?? report.month } else { figure = nil }
        let bills = figure?.subtractedObligations.filter { $0.payingAccountId == account.id } ?? []
        let total = bills.reduce(Int64(0)) { $0 + $1.amountCents }
        let named = SafeToSpendNarrative.sentenceList(bills.map { "\($0.name) \(AccountPresentation.amount($0.amountCents))" })
        let contributed = classifiedAccounts.first(where: { $0.id == account.id })?.contributedCents ?? 0
        let balance = contributed != 0
            ? "Its \(AccountPresentation.amount(contributed)) stops counting straight away."
            : "Its balance is already outside what you can spend."
        let wasCounted = classifiedAccounts.first(where: { $0.id == account.id })?.standing.isCounted == true
        let billVerb = wasCounted ? "keeps being subtracted" : "will be subtracted"
        let billSentence = bills.isEmpty
            ? "There are no bills from it being subtracted in this figure."
            : "The \(AccountPresentation.amount(total)) of bills you pay from it \(billVerb), because that money still has to come from somewhere — so what you can spend goes from \(AccountPresentation.headline(result, kind: shownFigure)) to \(AccountPresentation.headline(preview, kind: shownFigure)) until you tell me which account pays \(named) now."
        return "Put \(account.displayName) away? \(balance) \(billSentence) You can bring the account back later."
    }

    func archive(_ account: Account) async {
        guard let id = account.id else { return }
        let now = Int64(Date.now.timeIntervalSince1970)
        await write { db in
            try db.execute(sql: "UPDATE account SET archived_at = ? WHERE id = ?", arguments: [now, id])
        }
    }

    func answerMerge(_ manual: Account, sameAccount: Bool) async {
        guard let id = manual.id else { return }
        let before = result
        let bankAccountWasPutAway = accounts.first(where: { $0.id == manual.mergeCandidateFor })?.archivedAt != nil
        do {
            let merged = try await database.writer.write { db in
                try AccountMerge.answer(manualId: id, sameAccount: sameAccount, in: db)
            }
            try await reload()
            if sameAccount {
                accountChangeMessage = "I'll use your bank's figures from now on, and I've kept the name, type and bills you set up. Your hand-entered \(manual.displayName) is put away."
                let corrected = merged.map { AccountPresentation.correctedAmounts($0) }
                if let merged, merged.userType == .checking, let corrected, let available = corrected.available,
                   available < corrected.balance,
                   classifiedAccounts.first(where: { $0.id == merged.id })?.usedAvailableBalance == true {
                    accountChangeMessage! += " I've switched to the \(AccountPresentation.amount(available)) your bank says is free to spend right now. What you can spend went from \(AccountPresentation.headline(before, kind: shownFigure)) to \(AccountPresentation.headline(result, kind: shownFigure)); the \(AccountPresentation.amount(corrected.balance - available)) difference is payments that haven't finished going through."
                }
            } else {
                accountChangeMessage = bankAccountWasPutAway
                    ? "Your hand-entered account is separate again. The bank's account stays put away."
                    : "I'll count both from now on."
            }
        } catch { saveFailed() }
    }

    private func reload() async throws {
        let snapshot = try await database.reader.read { db in try Snapshot(db) }
        apply(snapshot)
    }

    private func saveFailed() {
        failure = "Spendable couldn't save that. Try again."
        Self.log.error("account change failed")
    }

    private func write(_ body: @escaping @Sendable (Database) throws -> Void) async {
        do {
            try await database.writer.write(body)
        } catch {
            failure = "Spendable couldn't save that. Try again."
            Self.log.error("write failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}

/// What the owner can do to a detected or suggested bill (milestone-5-review decisions 2 and 11).
enum BillAction: Equatable, Sendable {
    /// A suggestion is a bill: start counting it.
    case confirm
    /// Not a bill. Never shown again, and neither is anything like it on the same account.
    case dismiss
    /// It stopped. Stops counting now, and a charge after today says so.
    case markCancelled
    /// Flagged as maybe cancelled, but it is still being paid. Clears the flag.
    case stillActive
}

/// What happened to an owner's write to a bill.
enum BillWriteResult: Equatable, Sendable {
    case saved
    /// Something else wrote the bill after the owner opened it; nothing was written.
    case changedSinceOpened
    case gone
    case failed
}

/// Enough to put a bill back the way it was before the owner's last action.
struct BillUndo: Equatable, Sendable {
    let chargeId: Int64
    let previousStatus: RecurringChargeStatus
    let previousConfirmedBy: ConfirmedBy?
    let suppressionId: Int64?
    let action: BillAction
}

/// The two bounded reads behind `BankPayments` (milestone-5-review decision 26). Neither reads
/// transaction history: one aggregates the payment links, the other reads links whose charge
/// posted in the last few days or is still a hold.
enum BankPaymentQueries {
    static func load(_ db: Database, oldestBalanceInstant: Int64?) throws -> BankPayments {
        var payments = BankPayments()
        for row in try Row.fetchAll(db, sql: """
            SELECT o.recurring_charge_id, MAX(o.occurrence_day) AS paid
              FROM recurring_occurrence o JOIN bank_transaction t ON t.id = o.transaction_id
             WHERE o.role = 'payment' AND t.pending = 0 AND t.voided_at IS NULL AND t.superseded_by IS NULL
               AND ABS(t.amount_cents) = o.linked_amount_cents
             GROUP BY o.recurring_charge_id
            """) {
            let id: Int64 = row["recurring_charge_id"]
            if let text: String = row["paid"], let day = CalendarDay(isoString: text) { payments.latestPaid[id] = day }
        }
        let since = (oldestBalanceInstant ?? Int64.max) - 2 * 86_400
        for row in try Row.fetchAll(db, sql: """
            SELECT o.recurring_charge_id, o.occurrence_day, o.linked_amount_cents, t.pending, t.posted, t.first_seen_at
              FROM recurring_occurrence o JOIN bank_transaction t ON t.id = o.transaction_id
             WHERE t.voided_at IS NULL AND t.superseded_by IS NULL AND ABS(t.amount_cents) = o.linked_amount_cents
               AND ((o.role = 'pending_payment' AND t.pending = 1)
                 OR (o.role = 'payment' AND t.pending = 0 AND t.effective_date >= ?))
            """, arguments: [since]) {
            guard let text: String = row["occurrence_day"], let day = CalendarDay(isoString: text) else { continue }
            let pending = (row["pending"] as Int? ?? 0) != 0
            let posted: Int64? = row["posted"]
            payments.recent.append(BankPayment(
                chargeId: row["recurring_charge_id"], occurrence: day, amountCents: row["linked_amount_cents"],
                pending: pending, postedInstant: pending ? nil : ((posted ?? 0) > 0 ? posted : nil),
                firstSeenAt: row["first_seen_at"]))
        }
        return payments
    }
}

/// Executed inside one database write transaction: bills never temporarily point at a discarded
/// balance. Already-answered pairs are idempotent and cannot be offered again by ingestion.
enum AccountMerge {
    static func answer(manualId: Int64, sameAccount: Bool, in db: Database, now: Date = .now) throws -> Account? {
        guard var manual = try Account.fetchOne(db, key: manualId), manual.source == .manual,
              manual.mergeAnsweredAt == nil, let destinationId = manual.mergeCandidateFor else { return nil }
        manual.mergeAnsweredAt = Int64(now.timeIntervalSince1970)
        if !sameAccount {
            // The owner can put the bank's row away before answering. Declining the merge must
            // still release this manual balance instead of leaving both answers as no-ops.
            manual.mergeCandidateFor = nil
            try manual.update(db)
            return nil
        }
        guard var synced = try Account.fetchOne(db, key: destinationId), synced.source == .simplefin,
              synced.archivedAt == nil else { return nil }
        // display_name is NOT NULL: an unchanged bank-provided name is the uncustomised value.
        if synced.displayName == synced.remoteName { synced.displayName = manual.displayName }
        let hadCardDetails = synced.userType != nil || synced.ccStatementEnteredAt != nil
        synced.userType = synced.userType ?? manual.userType
        synced.ccDueDay = synced.ccDueDay ?? manual.ccDueDay
        synced.ccMinimumCents = synced.ccMinimumCents ?? manual.ccMinimumCents
        synced.ccStatementCents = synced.ccStatementCents ?? manual.ccStatementCents
        synced.ccStatementEnteredAt = synced.ccStatementEnteredAt ?? manual.ccStatementEnteredAt
        synced.includeInSafeToSpend = synced.includeInSafeToSpend ?? manual.includeInSafeToSpend
        if !hadCardDetails { synced.ccHasCreditBalance = manual.ccHasCreditBalance }
        try synced.update(db)
        try db.execute(sql: "UPDATE recurring_charge SET paying_account_id = ? WHERE paying_account_id = ?", arguments: [destinationId, manualId])
        manual.archivedAt = manual.mergeAnsweredAt
        manual.replacedBy = destinationId
        try manual.update(db)
        return synced
    }
}
