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

        init(_ db: Database) throws {
            // Archived accounts are fetched too: a bill still pointing at one has to be accounted
            // for, and the engine needs the row to name it.
            accounts = try Account.fetchAll(db)
            charges = try RecurringCharge.fetchAll(db)
            paySchedule = try PaySchedule.fetch(db)
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
            today: today, calendar: calendar)
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

    func save(_ charge: RecurringCharge) async {
        await write { db in
            var row = charge
            if row.id == nil {
                try row.insert(db)
            } else {
                try row.update(db)
            }
        }
    }

    func delete(_ charge: RecurringCharge) async {
        guard let id = charge.id else { return }
        await write { db in
            _ = try RecurringCharge.deleteOne(db, key: id)
        }
    }

    /// Records that a bill has been paid, and optionally takes it off the balance it came from in
    /// the same step, so the number cannot rise before the money does.
    func markPaid(
        _ charge: RecurringCharge,
        alsoReduceBalance: Bool,
        calendar: Calendar = .current,
        now: Date = .now
    ) async {
        let updated = charge.markingPaidOnce(
            balanceAlreadyUpdated: alsoReduceBalance, in: calendar, now: now)
        let payingId = charge.payingAccountId
        let amount = charge.amountCents
        await write { db in
            try updated.update(db)
            if alsoReduceBalance, let payingId, var account = try Account.fetchOne(db, key: payingId),
               account.source == .manual {
                account.balanceCents -= amount
                account.balanceDate = Int64(now.timeIntervalSince1970)
                account.manualUpdatedAt = account.balanceDate
                try account.update(db)
            }
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
        let preview = SafeToSpendEngine.compute(accounts: after, charges: charges, paySchedule: paySchedule, today: today, calendar: calendar)
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
