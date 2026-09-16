import Foundation
import GRDB
import Testing
@testable import Spendable

@Suite("Account decisions when a bank connects")
struct AccountConnectionTests {
    static let calendar = SafeToSpendTests.chicago
    static let today = CalendarDay(year: 2026, month: 9, day: 16)
    static let now = today.startOfDay(in: calendar).addingTimeInterval(12 * 3_600)
    static let seconds = Int64(now.timeIntervalSince1970)

    static func response(
        _ name: String = "CHASE TOTAL CHECKING", id: String = "checking", connection: String = "CON-1",
        holdings: [SimpleFINHolding]? = [], errors: [SimpleFINServerError] = [],
        connections: [SimpleFINConnection]? = nil
    ) -> SimpleFINAccountSet {
        SimpleFINAccountSet(errlist: errors, errors: nil,
            connections: connections ?? [SimpleFINConnection(connId: connection, name: "Chase", orgId: "ORG", orgName: "Chase Bank", orgUrl: nil, sfinUrl: nil)],
            accounts: [SimpleFINAccount(id: id, name: name, connId: connection, currency: "USD", balance: "1240.18", availableBalance: "940.00", balanceDate: seconds,
                                        transactions: [], holdings: holdings)])
    }

    static func classified(_ account: Account) -> ClassifiedAccount {
        SafeToSpendEngine.classify(account, today: today, calendar: calendar)
    }

    @Test("v4 upgrades an existing v3 row without losing history or corrections")
    func migrationPreservesRows() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3-sync-bookkeeping")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO account (id, source, display_name, user_type, balance_cents, balance_date, created_at)
                VALUES (1, 'manual', 'My checking', 'checking', 12345, 100, 100)
                """)
            try db.execute(sql: """
                INSERT INTO bank_transaction (account_id, external_id, effective_date, amount_cents, description, first_seen_at, last_seen_at)
                VALUES (1, 'TX1', 100, -500, 'Coffee', 100, 100)
                """)
        }
        try AppDatabase.migrator.migrate(queue)
        try queue.read { db in
            let account = try #require(try Account.fetchOne(db, key: 1))
            #expect(account.displayName == "My checking")
            #expect(account.userType == .checking)
            #expect(account.balanceCents == 12345)
            #expect(account.guessedFromName == nil && account.guessClass == nil)
            #expect(account.holdingsObservedAt == nil && account.resumedUpdatingAt == nil)
            #expect(account.mergeCandidateFor == nil && account.mergeAnsweredAt == nil)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bank_transaction") == 1)
        }
    }

    @Test("only dated holdings evidence unlocks a deposit guess, and confirmation uses available")
    func holdingsEvidence() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            _ = try SimpleFINIngest.ingest(Self.response(), kind: .balances, into: db, now: Self.now)
            var account = try #require(try Account.fetchOne(db))
            #expect(account.guessedType == .checking)
            #expect(account.guessedFromName == "CHASE TOTAL CHECKING")
            #expect(account.holdingsObservedAt == nil)
            #expect(Self.classified(account).standing == .heldOut(.notLookedInsideYet))
            _ = try SimpleFINIngest.ingest(Self.response(holdings: nil), kind: .window(start: Self.today, end: Self.today), into: db, now: Self.now)
            account = try #require(try Account.fetchOne(db))
            #expect(account.holdingsObservedAt == nil)
            _ = try SimpleFINIngest.ingest(Self.response(), kind: .window(start: Self.today, end: Self.today), into: db, now: Self.now)
            account = try #require(try Account.fetchOne(db))
            #expect(account.holdingsObservedAt == Self.seconds)
            #expect(Self.classified(account).contributedCents == 124018)
            account.userType = .checking
            #expect(Self.classified(account).contributedCents == 94000)
        }
    }

    @Test("a renamed bank account keeps its original guess and owner correction")
    func renameDoesNotRetype() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            _ = try SimpleFINIngest.ingest(Self.response(), kind: .balances, into: db, now: Self.now)
            try db.execute(sql: "UPDATE account SET user_type = 'savings', display_name = 'My account'")
            _ = try SimpleFINIngest.ingest(Self.response("PLATINUM SELECT 4417"), kind: .balances, into: db, now: Self.now)
            let account = try #require(try Account.fetchOne(db))
            #expect(account.guessedFromName == "CHASE TOTAL CHECKING")
            #expect(account.guessedType == .checking)
            #expect(account.userType == .savings)
            #expect(account.remoteName == "PLATINUM SELECT 4417")
            #expect(account.displayName == "My account")
        }
    }

    @Test("holdings remain investments despite a later empty balance response or type correction")
    func investmentsCannotBeEnabled() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            _ = try SimpleFINIngest.ingest(Self.response(), kind: .balances, into: db, now: Self.now)
            _ = try SimpleFINIngest.ingest(Self.response(holdings: [SimpleFINHolding()]), kind: .window(start: Self.today, end: Self.today), into: db, now: Self.now)
            _ = try SimpleFINIngest.ingest(Self.response(), kind: .balances, into: db, now: Self.now)
            var account = try #require(try Account.fetchOne(db))
            #expect(account.guessClass == "investment")
            #expect(account.holdingsCount == 1)
            for type in AccountType.allCases {
                account.userType = type
                account.includeInSafeToSpend = true
                #expect(Self.classified(account).standing == .heldOut(.holdsInvestments))
            }
        }
    }

    @Test("loan and named investment classes do not become type questions")
    func excludedClasses() {
        var account = Account.manual(displayName: "Loan", type: .checking, balanceCents: -50000, now: Self.now)
        account.userType = nil
        account.guessClass = "loan"
        #expect(Self.classified(account).standing == .heldOut(.isALoan))
        account.guessClass = "investment"
        #expect(Self.classified(account).standing == .heldOut(.holdsInvestments))
    }

    @Test("a matching manual account keeps its bills but does not double the bank balance")
    func duplicateCandidate() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            var manual = Account.manual(displayName: "Chase Checking", type: .checking, balanceCents: 120000, now: Self.now)
            var cash = Account.manual(displayName: "Cash", type: .cash, balanceCents: 6000, now: Self.now)
            try manual.insert(db)
            try cash.insert(db)
            _ = try SimpleFINIngest.ingest(Self.response(), kind: .balances, into: db, now: Self.now)
            _ = try SimpleFINIngest.ingest(Self.response(), kind: .window(start: Self.today, end: Self.today), into: db, now: Self.now)
            let accounts = try Account.fetchAll(db)
            let candidate = try #require(accounts.first { $0.id == manual.id })
            #expect(candidate.mergeCandidateFor != nil)
            #expect(Self.classified(candidate).standing == .supersededPendingAnswer)
            #expect(accounts.first { $0.id == cash.id }?.mergeCandidateFor == nil)
            let rent = SafeToSpendTests.bill(id: 1, "Rent", 50000, due: Self.today, paying: manual.id)
            guard case .figures(let report) = SafeToSpendEngine.compute(accounts: accounts, charges: [rent], paySchedule: nil, today: Self.today, calendar: Self.calendar) else {
                Issue.record("Expected a figure"); return
            }
            #expect(report.month.remainderCents == 80018)
            #expect(report.month.subtractedCents == 50000)
            let lines = SafeToSpendNarrative.linesUnderTheNumber(report: report, figure: report.month, locale: SafeToSpendTests.us, calendar: Self.calendar)
            #expect(lines.contains { $0.contains("hand-entered") && $0.contains("still being subtracted") })
            #expect(lines.contains { $0.contains("Rent") })
        }
    }

    @Test("a declined duplicate is not offered again when another matching account arrives")
    func declinedDuplicateIsPermanent() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            var manual = Account.manual(displayName: "Chase Checking", type: .checking, balanceCents: 100000, now: Self.now)
            manual.mergeAnsweredAt = Self.seconds
            try manual.insert(db)
            _ = try SimpleFINIngest.ingest(Self.response(), kind: .balances, into: db, now: Self.now)
            #expect(try Account.fetchOne(db, key: manual.id)?.mergeCandidateFor == nil)
        }
    }

    @Test("a vanished account records recovery only when an error-free current balance arrives")
    func recovery() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            _ = try SimpleFINIngest.ingest(Self.response(), kind: .balances, into: db, now: Self.now)
            try db.execute(sql: "UPDATE account SET not_updating_since = ?", arguments: [Self.seconds - 3600])
            let errors = [SimpleFINServerError(code: "con.auth", msg: "Sign in again", connId: "CON-1", accountId: nil)]
            _ = try SimpleFINIngest.ingest(Self.response(errors: errors), kind: .balances, into: db, now: Self.now)
            let troubled = try #require(try Account.fetchOne(db))
            #expect(troubled.notUpdatingSince == Self.seconds - 3600)
            #expect(troubled.resumedUpdatingAt == nil)
            _ = try SimpleFINIngest.ingest(Self.response(), kind: .balances, into: db, now: Self.now)
            let recovered = try #require(try Account.fetchOne(db))
            #expect(recovered.notUpdatingSince == nil)
            #expect(recovered.resumedUpdatingAt == Self.seconds)
        }
    }

    @Test("archiving the final counted account does not erase its bills")
    func archivedBillsRemainKnown() {
        var account = Account.manual(displayName: "Checking", type: .checking, balanceCents: 316000, now: Self.now)
        account.id = 1
        account.archivedAt = Self.seconds
        let bill = SafeToSpendTests.bill(id: 1, "Rent", 170000, due: Self.today, paying: 1)
        guard case .figures(let report) = SafeToSpendEngine.compute(accounts: [account], charges: [bill], paySchedule: nil, today: Self.today, calendar: Self.calendar) else {
            Issue.record("Archiving cannot erase an outstanding bill"); return
        }
        #expect(report.month.remainderCents == -170000)
        account.archivedAt = nil
        account.notUpdatingSince = Self.seconds
        guard case .nothingCountable = SafeToSpendEngine.compute(accounts: [account], charges: [bill], paySchedule: nil, today: Self.today, calendar: Self.calendar) else {
            Issue.record("Missing balance means unknown, not a zero pool"); return
        }
    }

    @Test("guessed card disclosure asks about the type before asking for a statement")
    func guessedCardWording() {
        var card = Account.manual(displayName: "Sapphire Card", type: .credit, balanceCents: -118000, now: Self.now)
        card.id = 1
        card.userType = nil
        card.guessedType = .credit
        var cash = Account.manual(displayName: "Cash", type: .cash, balanceCents: 6000, now: Self.now)
        cash.id = 2
        guard case .figures(let report) = SafeToSpendEngine.compute(accounts: [card, cash], charges: [], paySchedule: nil, today: Self.today, calendar: Self.calendar) else { return }
        let lines = SafeToSpendNarrative.leftOut(report: report, figure: report.month, locale: SafeToSpendTests.us, calendar: Self.calendar)
        #expect(lines.contains { $0.contains("I think Sapphire Card") && $0.contains("Is that right?") })
        #expect(!lines.contains { $0.contains("statement balance") })
    }
    @Test("two live bank logins with the same account id stay separate")
    func liveConnectionsNeverAdoptEachOther() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            _ = try SimpleFINIngest.ingest(Self.response(), kind: .balances, into: db, now: Self.now)
            let connections = ["CON-1", "CON-2"].map {
                SimpleFINConnection(connId: $0, name: "Chase", orgId: "ORG", orgName: "Chase Bank", orgUrl: nil, sfinUrl: nil)
            }
            let second = Self.response(connection: "CON-2", connections: connections)
            let both = SimpleFINAccountSet(errlist: [], errors: nil, connections: connections,
                                          accounts: Self.response().accounts + second.accounts)
            _ = try SimpleFINIngest.ingest(both, kind: .balances, into: db, now: Self.now)
            let accounts = try Account.fetchAll(db)
            #expect(accounts.count == 2)
            #expect(Set(accounts.compactMap(\.connId)) == ["CON-1", "CON-2"])
        }
    }

}
