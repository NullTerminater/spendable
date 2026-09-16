import Foundation
import GRDB
import Testing
@testable import Spendable

@Suite("The account questions and their effect on the figure")
struct AccountPresentationTests {
    static let us = Locale(identifier: "en_US")
    static let calendar = SafeToSpendTests.chicago
    static let today = CalendarDay(year: 2026, month: 9, day: 16)
    static let now = today.startOfDay(in: calendar).addingTimeInterval(12 * 3_600)

    static func synced(_ name: String, type: AccountType?, cents: Int64) -> Account {
        var row = Account.manual(displayName: name, type: type ?? .checking, balanceCents: cents, now: now)
        row.id = 1
        row.source = .simplefin
        row.connId = "synthetic-connection"
        row.connName = "Chase"
        row.externalId = "synthetic-account"
        row.remoteName = name
        row.guessedFromName = name
        row.guessedType = type
        row.userType = nil
        row.holdingsObservedAt = Int64(now.timeIntervalSince1970)
        return row
    }

    static func sentence(_ account: Account, notices: [SyncNotice] = []) -> String {
        let classified = SafeToSpendEngine.classify(account, today: today, calendar: calendar)
        return AccountPresentation.row(account, classified: classified, notices: notices, now: now, calendar: calendar, locale: us)
    }

    @Test("unknown negative balances ask a question without assigning a type")
    func overdrawnQuestion() {
        let account = Self.synced("TOTAL ACCESS 1234", type: nil, cents: -4720)
        #expect(Self.sentence(account) == "TOTAL ACCESS 1234 is $47.20 in the red. Is this a credit card, or a checking account that's overdrawn?")
        #expect(account.guessedType == nil)
        #expect(AccountPresentation.permitsTypeChoice(account))
    }

    @Test("investments and loans never offer a type picker or savings switch")
    func forbiddenControls() {
        var investment = Self.synced("SimpleFIN Savings", type: .savings, cents: 12840000)
        investment.holdingsCount = 6
        investment.includeInSafeToSpend = true
        #expect(!AccountPresentation.permitsTypeChoice(investment))
        #expect(!AccountPresentation.offersSavingsSwitch(investment))
        #expect(Self.sentence(investment).contains("there's no switch for this one"))
        var loan = Self.synced("Chase Auto Loan", type: nil, cents: -300000)
        loan.guessClass = "loan"
        #expect(!AccountPresentation.permitsTypeChoice(loan))
        #expect(Self.sentence(loan) == "Chase Auto Loan is money you owe, not money you have, so it isn't counted here.")
    }

    @Test("a guessed credit card asks whether the guess is right, not for a statement")
    func creditGuess() {
        let account = Self.synced("CHASE SAPPHIRE PREFERRED CARD", type: .credit, cents: -118000)
        let sentence = Self.sentence(account)
        #expect(sentence.contains("It shows $1,180 owed. Is that right?"))
        #expect(!sentence.contains("statement"))
    }

    @Test("the available-balance change is explained before confirmation")
    func confirmWarning() {
        var account = Self.synced("Chase Total Checking", type: .checking, cents: 120000)
        account.availableCents = 94000
        #expect(AccountPresentation.availableWarning(account, locale: Self.us) == "If you confirm this, I'll switch to the $940 your bank says is free to spend right now instead of its $1,200 balance. The $260 difference is payments that haven't finished going through.")
        account.availableCents = 500000
        #expect(AccountPresentation.availableWarning(account, locale: Self.us) == nil)
        account.balanceCents = -120000
        account.availableCents = -94000
        account.amountsReversed = true
        #expect(AccountPresentation.availableWarning(account, locale: Self.us)?.contains("The $260 difference") == true)
        account.balanceCents = 120000
        account.availableCents = 94000
        #expect(AccountPresentation.availableWarning(account, locale: Self.us) == nil)
    }

    @Test("non-US balances always carry their own currency and warn against re-entering")
    func currency() {
        var account = Self.synced("Tangerine Savings", type: .savings, cents: 240000)
        account.currency = "CAD"
        let line = Self.sentence(account)
        #expect(line.contains("CA$2,400.00"))
        #expect(line.localizedCaseInsensitiveContains("Canadian dollar"))
        #expect(line.contains("Adding it by hand as dollars would make what you can spend wrong"))
        #expect(!AccountPresentation.offersSavingsSwitch(account))
    }

    @Test("connection authentication is distinguished from a missing account")
    func stoppedCauses() {
        var account = Self.synced("Chase Total Checking", type: .checking, cents: 316000)
        account.notUpdatingSince = Int64(Self.now.timeIntervalSince1970)
        let auth = SyncNotice(scope: .connection("synthetic-connection"), text: "Connection to Chase requires re-authentication", code: "con.auth")
        #expect(Self.sentence(account, notices: [auth]) == "Not counted. Chase needs you to sign in again on the SimpleFIN website.")
        #expect(!Self.sentence(account, notices: [auth]).contains("stopped sending"))
        #expect(Self.sentence(account).contains("It wasn't in what SimpleFIN sent"))
        account.guessClass = "investment"
        let classified = SafeToSpendEngine.classify(account, today: Self.today, calendar: Self.calendar)
        let line = AccountPresentation.connectionProblemLine(account, classified: classified, notice: auth, locale: Self.us)
        #expect(line.contains("I'll check for an updated balance on the next refresh."))
        #expect(!line.contains("start counting"))
        #expect(!line.contains("isn't counted, because"))
    }

    @Test("merge transfers metadata and bills in one transaction and does not double the figure")
    func mergeYes() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            var synced = Self.synced("CHASE TOTAL CHECKING", type: .checking, cents: 124018)
            synced.id = nil
            try synced.insert(db)
            var manual = Account.manual(displayName: "My Chase Checking", type: .checking, balanceCents: 120000, now: Self.now)
            manual.mergeCandidateFor = synced.id
            manual.ccHasCreditBalance = true
            try manual.insert(db)
            var cash = Account.manual(displayName: "Cash", type: .cash, balanceCents: 6000, now: Self.now)
            try cash.insert(db)
            var rent = RecurringCharge.manual(name: "Rent", amountCents: 50000, cadence: .monthly, nextDue: Self.today, payingAccountId: manual.id, now: Self.now, calendar: Self.calendar)
            try rent.insert(db)
            let before = SafeToSpendEngine.compute(accounts: try Account.fetchAll(db), charges: try RecurringCharge.fetchAll(db), paySchedule: nil, today: Self.today, calendar: Self.calendar)
            let manualId = try #require(manual.id)
            let mergeResult = try AccountMerge.answer(manualId: manualId, sameAccount: true, in: db, now: Self.now)
            let merged = try #require(mergeResult)
            let savedManual = try #require(try Account.fetchOne(db, key: manual.id))
            #expect(merged.displayName == "My Chase Checking")
            #expect(merged.userType == .checking)
            #expect(merged.ccHasCreditBalance)
            #expect(savedManual.archivedAt != nil && savedManual.mergeAnsweredAt != nil)
            #expect(savedManual.replacedBy == synced.id)
            #expect(try RecurringCharge.fetchOne(db)?.payingAccountId == synced.id)
            let after = SafeToSpendEngine.compute(accounts: try Account.fetchAll(db), charges: try RecurringCharge.fetchAll(db), paySchedule: nil, today: Self.today, calendar: Self.calendar)
            #expect(AccountPresentation.headline(before, kind: .calendarMonth, locale: Self.us) == "$800")
            #expect(AccountPresentation.headline(after, kind: .calendarMonth, locale: Self.us) == "$800")
            #expect(try AccountMerge.answer(manualId: manualId, sameAccount: true, in: db) == nil)
        }
    }

    @Test("a rejected merge restores the manual balance even after the bank's row is put away", arguments: [false, true])
    func mergeNo(archived: Bool) throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            var synced = Self.synced("Bank Checking", type: .checking, cents: 124018)
            synced.id = nil
            try synced.insert(db)
            var manual = Account.manual(displayName: "Other Checking", type: .checking, balanceCents: 120000, now: Self.now)
            manual.mergeCandidateFor = synced.id
            try manual.insert(db)
            if archived {
                synced.archivedAt = Int64(Self.now.timeIntervalSince1970)
                try synced.update(db)
            }
            _ = try AccountMerge.answer(manualId: try #require(manual.id), sameAccount: false, in: db, now: Self.now)
            let saved = try #require(try Account.fetchOne(db, key: manual.id))
            #expect(saved.mergeCandidateFor == nil && saved.mergeAnsweredAt != nil)
            #expect(saved.archivedAt == nil)
            #expect(SafeToSpendEngine.classify(saved, today: Self.today, calendar: Self.calendar).standing.isCounted)
        }
    }
}

@Suite("Account actions from the accounts screen")
@MainActor
struct AccountActionTests {
    @MainActor
    private final class ObservedCoverage {
        var date: String?
        var hasDelivered = false
    }

    @Test("history-only progress writes notify observations on the WITHOUT ROWID state table")
    func observesHistoryProgress() async throws {
        let database = try AppDatabase.inMemory()
        let observed = ObservedCoverage()
        let observation = ValueObservation.tracking { db in try BackfillProgress.load(db).coveredBackTo }
        let cancellable = observation.start(in: database.reader, scheduling: .async(onQueue: .main), onError: { _ in }, onChange: { date in
            Task { @MainActor in observed.date = date; observed.hasDelivered = true }
        })
        defer { cancellable.cancel() }
        for _ in 0..<200 {
            if observed.hasDelivered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(observed.hasDelivered)
        #expect(observed.date == nil)
        try await database.writer.write { db in
            var progress = BackfillProgress()
            progress.coveredBackTo = "2026-08-03"
            try progress.save(db)
        }
        for _ in 0..<200 {
            if observed.date == "2026-08-03" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed.date == "2026-08-03")
    }

    @Test("confirming the type explains the actual before and after figure", arguments: [false, true])
    func confirmChangesNumber(reversed: Bool) async throws {
        let database = try AppDatabase.inMemory()
        let calendar = SafeToSpendTests.chicago
        try await database.writer.write { db in
            var account = Account.manual(displayName: "Chase Total Checking", type: .checking, balanceCents: reversed ? -120000 : 120000)
            account.source = .simplefin
            account.userType = nil
            account.guessedType = .checking
            account.holdingsObservedAt = account.balanceDate
            account.availableCents = reversed ? -94000 : 94000
            account.amountsReversed = reversed
            try account.insert(db)
            var rent = RecurringCharge.manual(name: "Rent", amountCents: 51000, cadence: .monthly, nextDue: CalendarDay.today(in: calendar), payingAccountId: account.id, calendar: calendar)
            try rent.insert(db)
        }
        let store = SpendableStore(database: database, calendar: calendar)
        await SpendableStoreTests().waitFor(store) { store.accounts.count == 1 }
        let account = try #require(store.accounts.first)
        await store.setType(account, .checking)
        #expect(store.accounts.first?.userType == .checking)
        #expect(store.accountChangeMessage?.contains("$690 to $430") == true)
        #expect(store.accountChangeMessage?.contains("$260") == true)
        try await database.writer.write { db in try SyncState.setDate(db, SyncState.balancesSyncedAt, .now) }
        await SpendableStoreTests().waitFor(store) { store.accountChangeMessage == nil }
        #expect(store.accountChangeMessage == nil)
    }

    @Test("putting away the last account previews and keeps the bills")
    func archivePreview() async throws {
        let database = try AppDatabase.inMemory()
        let calendar = SafeToSpendTests.chicago
        try await database.writer.write { db in
            var account = Account.manual(displayName: "Chase Total Checking", type: .checking, balanceCents: 316000)
            try account.insert(db)
            for (name, amount) in [("Rent", Int64(150000)), ("Internet", Int64(20000))] {
                var charge = RecurringCharge.manual(name: name, amountCents: amount, cadence: .monthly, nextDue: CalendarDay.today(in: calendar), payingAccountId: account.id, calendar: calendar)
                try charge.insert(db)
            }
        }
        let store = SpendableStore(database: database, calendar: calendar)
        await SpendableStoreTests().waitFor(store) { store.charges.count == 2 }
        let account = try #require(store.accounts.first)
        let confirmation = store.archiveConfirmation(account)
        for amount in ["$3,160", "$1,700", "$1,460", "$0 (balance:"] { #expect(confirmation.contains(amount)) }
        #expect(store.accounts.first?.archivedAt == nil)
        await store.setType(account, .checking)
        #expect(store.accountChangeMessage != nil)
        await store.archive(account)
        await SpendableStoreTests().waitFor(store) { store.accounts.first?.archivedAt != nil }
        guard case .figures(let report) = store.result else { Issue.record("archived bills must remain computable"); return }
        #expect(report.month.remainderCents == -170000)
        #expect(store.charges.count == 2)
        #expect(store.accountChangeMessage == nil)
    }

    @Test("a returning account names its actual contribution and the explanation expires the next day")
    func returnMessageExpires() async throws {
        let database = try AppDatabase.inMemory()
        let calendar = SafeToSpendTests.chicago
        let now = Date.now
        try await database.writer.write { db in
            var account = Account.manual(displayName: "Chase Checking", type: .checking, balanceCents: -120000, now: now)
            account.source = .simplefin
            account.availableCents = -94000
            account.amountsReversed = true
            account.notUpdatingSince = Int64(now.timeIntervalSince1970) - 3600
            try account.insert(db)
        }
        let store = SpendableStore(database: database, calendar: calendar)
        await SpendableStoreTests().waitFor(store) { store.accounts.count == 1 }
        #expect(!store.classifiedAccounts.contains { $0.standing.isCounted })
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE account SET not_updating_since = NULL, resumed_updating_at = ?", arguments: [Int64(now.timeIntervalSince1970)])
        }
        await SpendableStoreTests().waitFor(store) { store.accountLinesUnderNumber.contains { $0.contains("is updating again") } }
        let line = try #require(store.accountLinesUnderNumber.first { $0.contains("is updating again") })
        #expect(line.contains("Its $940 is back in the figures."))
        #expect(!line.contains("$1,200"))

        let tomorrow = store.today.adding(days: 1, in: calendar).startOfDay(in: calendar)
        store.dayMayHaveChanged(calendar: calendar, now: tomorrow)
        #expect(store.classifiedAccounts.contains { $0.standing.isCounted })
        #expect(!store.accountLinesUnderNumber.contains { $0.contains("is updating again") })
    }
}
