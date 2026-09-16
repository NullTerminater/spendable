import Foundation
import GRDB
import Testing
@testable import Spendable

@Suite("Turning SimpleFIN's answers into rows")
struct SimpleFINIngestTests {
    static var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    static func day(_ y: Int, _ m: Int, _ d: Int) -> CalendarDay { CalendarDay(year: y, month: m, day: d) }

    static func set(_ json: String) throws -> SimpleFINAccountSet {
        try SimpleFINAccountSet.decode(Data(json.utf8))
    }

    static func fixture(_ name: String) throws -> SimpleFINAccountSet {
        try SimpleFINAccountSet.decode(try FixtureTests.load("Demo/\(name)"))
    }

    /// One account the app already knows about, so a window has something to attach to.
    @discardableResult
    static func seedAccount(
        _ db: Database, connId: String = "CON-SIMPLEFIN-DEMO", externalId: String = "Demo Checking",
        balance: Int64 = 2_595_111, balanceDate: Int64 = 1_789_516_800, name: String = "SimpleFIN Checking"
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO account (source, conn_id, external_id, remote_name, display_name, currency,
                                 balance_cents, available_cents, balance_date, created_at)
            VALUES ('simplefin', ?, ?, ?, ?, 'USD', ?, ?, ?, 0)
            """, arguments: [connId, externalId, name, name, balance, balance, balanceDate])
        return db.lastInsertedRowID
    }

    // MARK: Decoding

    @Test("the captured demo responses decode, hyphenated keys and all")
    func decodesFixtures() throws {
        let balances = try Self.fixture("v2-balances-only.json")
        #expect(balances.accounts.count == 3)
        #expect(balances.errlist.isEmpty)
        #expect(balances.connections?.first?.connId == "CON-SIMPLEFIN-DEMO")
        for account in balances.accounts {
            // These two are the hyphenated keys a snake_case strategy silently leaves nil.
            #expect(account.balanceDate > 0)
            #expect(account.availableBalance != nil)
            #expect(account.connId == "CON-SIMPLEFIN-DEMO")
        }

        let window = try Self.fixture("v2-window.json")
        let transactions = window.accounts.flatMap { $0.transactions ?? [] }
        #expect(transactions.count > 100)
        #expect(transactions.allSatisfy { !$0.id.isEmpty })
        // The Bridge's extras.
        #expect(transactions.contains { $0.payee != nil })
        #expect(transactions.contains { $0.mcc != nil })
        // The demo carries holdings on its savings account and none on checking.
        #expect(window.accounts.contains { ($0.holdings?.count ?? 0) > 0 })
    }

    @Test("a snake_case key strategy would silently lose both balance fields")
    func whyThereIsNoKeyStrategy() throws {
        // This is the mistake the explicit CodingKeys exist to prevent: it does not throw, it just
        // leaves the balance nil, and "unknown keys are ignored" turns that into silence.
        struct Loose: Decodable {
            struct Account: Decodable {
                let id: String
                let availableBalance: String?
                let connId: String?
            }
            let accounts: [Account]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let loose = try decoder.decode(Loose.self, from: try FixtureTests.load("Demo/v2-balances-only.json"))
        #expect(loose.accounts.allSatisfy { $0.connId != nil })       // snake_case works
        #expect(loose.accounts.allSatisfy { $0.availableBalance == nil }) // hyphenated does not
        // The real decoder gets it right.
        let strict = try Self.fixture("v2-balances-only.json")
        #expect(strict.accounts.allSatisfy { $0.availableBalance != nil })
    }

    @Test("a missing errlist is a decoding failure, never taken to mean nothing is wrong")
    func missingErrlistThrows() {
        #expect(throws: (any Error).self) {
            try Self.set(#"{"accounts":[],"connections":[]}"#)
        }
    }

    @Test("a capped range and a recommendation warning are told apart")
    func cappedVersusRecommended() throws {
        #expect(try Self.fixture("v2-range-capped.json").wasRangeCapped)
        #expect(try !Self.fixture("v2-window.json").wasRangeCapped)
        #expect(try Self.fixture("v2-bad-credentials.json").hasGeneralAuthFailure)
    }

    @Test("a quota warning is noticed in either place the server might put it")
    func quotaWarning() throws {
        #expect(try Self.set(#"{"errlist":[{"code":"gen.api","msg":"You have made 20 of 24 allowed requests today"}],"accounts":[],"connections":[]}"#).carriesQuotaWarning)
        #expect(try Self.set(#"{"errlist":[],"errors":["You are approaching your request limit"],"accounts":[],"connections":[]}"#).carriesQuotaWarning)
        #expect(try !Self.fixture("v2-window.json").carriesQuotaWarning)
    }

    // MARK: Balances

    @Test("a balances answer writes balances and names the bank from the connections list")
    func balancesAreWritten() throws {
        let database = try AppDatabase.inMemory()
        let set = try Self.fixture("v2-balances-only.json")
        let outcome = try database.writer.write { db in
            try SimpleFINIngest.ingest(set, kind: .balances, into: db, now: Date(timeIntervalSince1970: 1_789_600_000))
        }
        #expect(outcome.accountsInserted == 3)

        let accounts = try database.reader.read { db in try Account.fetchAll(db) }
        #expect(accounts.count == 3)
        let checking = try #require(accounts.first { $0.externalId == "Demo Checking" })
        #expect(checking.balanceCents == 2_595_111)
        #expect(checking.source == .simplefin)
        // The connection's own name, not org_name, which on the demo reads "SimpleFIN Bridge" and
        // would tell the owner nothing about which login to fix.
        #expect(checking.connName == "SimpleFIN Demo")
        // The name supplies a guess, but only a dated answer can establish holdings evidence.
        #expect(checking.effectiveType == .checking)
        #expect(checking.userType == nil)
        #expect(checking.holdingsObservedAt == nil)
        // A balances-only answer returns an empty holdings array for every account, which is the
        // same shape as an account that genuinely holds none. So the count stays at zero until a
        // full pull actually lists them — an empty array is never read as a statement.
        let savings = try #require(accounts.first { $0.externalId == "Demo Savings" })
        #expect(savings.holdingsCount == 0)
        #expect(checking.holdingsCount == 0)
    }

    @Test("a second balances answer updates the balance without touching anything the owner set")
    func balancesDoNotClobberOwnerColumns() throws {
        let database = try AppDatabase.inMemory()
        let set = try Self.fixture("v2-balances-only.json")
        try database.writer.write { db in
            _ = try SimpleFINIngest.ingest(set, kind: .balances, into: db, now: Date(timeIntervalSince1970: 1_789_600_000))
        }
        // The owner renames it, types it, opts it in, and history gets filled in.
        try database.writer.write { db in
            try db.execute(sql: """
                UPDATE account SET display_name = 'My Emergency Fund', user_type = 'checking',
                                   include_in_safe_to_spend = 1, cc_statement_cents = 41200,
                                   backfilled_through = 12345, amounts_reversed = 1
                 WHERE external_id = 'Demo Savings'
                """)
        }
        try database.writer.write { db in
            _ = try SimpleFINIngest.ingest(set, kind: .balances, into: db, now: Date(timeIntervalSince1970: 1_789_700_000))
        }

        let savings = try #require(try database.reader.read { db in
            try Account.filter(Column("external_id") == "Demo Savings").fetchOne(db)
        })
        #expect(savings.displayName == "My Emergency Fund")
        #expect(savings.userType == .checking)
        #expect(savings.includeInSafeToSpend == true)
        #expect(savings.ccStatementCents == 41_200)
        #expect(savings.backfilledThrough == 12_345)
        #expect(savings.amountsReversed)
        // The server's own columns did update.
        #expect(savings.remoteName == "SimpleFIN Savings")
        #expect(try database.reader.read { db in try Account.fetchCount(db) } == 3)
    }

    @Test("an older balance never overwrites a newer one")
    func staleBalanceIsRefused() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            _ = try Self.seedAccount(db, balance: 100_000, balanceDate: 1_789_516_800)
        }
        let older = try Self.set("""
            {"errlist":[],"connections":[{"conn_id":"CON-SIMPLEFIN-DEMO","name":"SimpleFIN Demo"}],
             "accounts":[{"id":"Demo Checking","name":"SimpleFIN Checking","conn_id":"CON-SIMPLEFIN-DEMO",
             "currency":"USD","balance":"1.00","balance-date":1700000000,"transactions":[]}]}
            """)
        try database.writer.write { db in
            _ = try SimpleFINIngest.ingest(older, kind: .balances, into: db, now: Date(timeIntervalSince1970: 1_789_600_000))
        }
        let account = try #require(try database.reader.read { db in try Account.fetchOne(db) })
        #expect(account.balanceCents == 100_000)
        #expect(account.balanceDate == 1_789_516_800)
    }

    // MARK: A window must never write a balance

    @Test("a window answer stores transactions and leaves every balance alone")
    func windowNeverWritesBalances() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            _ = try Self.seedAccount(db, externalId: "Demo Checking", balance: 2_595_111, balanceDate: 1_789_516_800)
            _ = try Self.seedAccount(db, externalId: "Demo Savings", balance: 11_552_551, balanceDate: 1_789_516_800)
        }
        // The window's own account balance is a different, older figure.
        let window = try Self.fixture("v2-window.json")
        let outcome = try database.writer.write { db in
            try SimpleFINIngest.ingest(
                window, kind: .window(start: Self.day(2026, 8, 2), end: Self.day(2026, 9, 14)),
                into: db, now: Date(timeIntervalSince1970: 1_789_600_000), calendar: Self.chicago)
        }
        #expect(outcome.transactionsInserted > 100)

        for account in try database.reader.read({ db in try Account.fetchAll(db) }) {
            #expect(account.balanceDate == 1_789_516_800, "a window moved \(account.externalId ?? "")'s balance date")
            #expect(account.balanceCents == 2_595_111 || account.balanceCents == 11_552_551)
        }

        // The holdings that only a full answer carries do get recorded, which is how milestone 4
        // will know the savings account holds stock rather than money.
        let savings = try #require(try database.reader.read { db in
            try Account.filter(Column("external_id") == "Demo Savings").fetchOne(db)
        })
        #expect(savings.holdingsCount == 1)
    }

    @Test("an amount the app cannot read is never stepped over in silence")
    func unreadableAmountKeepsTheWindowOpen() throws {
        let database = try AppDatabase.inMemory()
        let accountId = try database.writer.write { db in try Self.seedAccount(db) }
        // Two charges, one of them in a shape the exact-cents parser refuses. The readable one must
        // still be stored, and the window must not be marked as covered — a charge missing from the
        // number is worse than a window fetched twice.
        let answer = try Self.set("""
            {"errlist": [], "accounts": [{
              "org": {"domain": "beta-bridge.simplefin.org", "sfin-url": "https://beta-bridge.simplefin.org/simplefin"},
              "id": "Demo Checking", "conn_id": "CON-SIMPLEFIN-DEMO",
              "name": "SimpleFIN Checking", "currency": "USD",
              "balance": "25951.11", "available-balance": "25951.11", "balance-date": 1789516800,
              "transactions": [
                {"id": "T-OK", "posted": 1789516800, "amount": "-64.00", "description": "WHOLEFOODS"},
                {"id": "T-BAD", "posted": 1789516800, "amount": "-1.2e3", "description": "MYSTERY"}
              ]}]}
            """)
        let outcome = try database.writer.write { db in
            try SimpleFINIngest.ingest(
                answer, kind: .window(start: Self.day(2026, 8, 2), end: Self.day(2026, 9, 14)),
                into: db, now: Date(timeIntervalSince1970: 1_789_600_000), calendar: Self.chicago)
        }

        #expect(outcome.transactionsInserted == 1)
        #expect(outcome.notices.contains { $0.scope == .account(accountId) && $0.code == "app.amount" })
        let account = try #require(try database.reader.read { db in try Account.fetchOne(db) })
        #expect(account.txSyncedThrough == nil, "the window was marked covered though a charge was lost")
    }

    @Test("a window will not invent an account it has no trustworthy balance for")
    func windowDoesNotCreateAccounts() throws {
        let database = try AppDatabase.inMemory()
        let window = try Self.fixture("v2-window.json")
        let outcome = try database.writer.write { db in
            try SimpleFINIngest.ingest(
                window, kind: .window(start: Self.day(2026, 8, 2), end: Self.day(2026, 9, 14)),
                into: db, now: Date(timeIntervalSince1970: 1_789_600_000), calendar: Self.chicago)
        }
        #expect(outcome.transactionsInserted == 0)
        #expect(try database.reader.read { db in try Account.fetchCount(db) } == 0)
    }

    @Test("a balances answer says nothing about transactions, so it moves no watermark")
    func balancesAreNotTransactionEvidence() throws {
        let database = try AppDatabase.inMemory()
        let accountId = try database.writer.write { db -> Int64 in
            let id = try Self.seedAccount(db)
            try db.execute(sql: "UPDATE account SET tx_synced_through = 5000 WHERE id = ?", arguments: [id])
            try db.execute(sql: """
                INSERT INTO bank_transaction (account_id, external_id, posted, effective_date, amount_cents,
                                              description, pending, first_seen_at, last_seen_at)
                VALUES (?, 'P-1', 0, 1000, -6400, 'WHOLEFOODS', 1, 0, 0)
                """, arguments: [id])
            return id
        }
        let set = try Self.fixture("v2-balances-only.json")
        try database.writer.write { db in
            _ = try SimpleFINIngest.ingest(set, kind: .balances, into: db, now: Date(timeIntervalSince1970: 1_789_600_000))
            _ = try SimpleFINIngest.ingest(set, kind: .balances, into: db, now: Date(timeIntervalSince1970: 1_789_700_000))
        }
        let account = try #require(try database.reader.read { db in try Account.fetchOne(db, key: accountId) })
        #expect(account.txSyncedThrough == 5_000)
        let pending = try #require(try database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT voided_at, superseded_by, pending FROM bank_transaction")
        })
        #expect(pending["voided_at"] == nil)
        #expect(pending["superseded_by"] == nil)
        #expect(pending["pending"] as Int? == 1)
    }

    // MARK: A connection that dies quietly

    @Test("a rejected credential keeps every balance and marks the accounts as not updating")
    func deadConnection() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            _ = try Self.seedAccount(db, externalId: "Demo Checking", balance: 2_595_111)
            _ = try Self.seedAccount(db, externalId: "Demo Savings", balance: 11_552_551)
        }
        // Exactly what the live server sends for a wrong password: gen.auth and an empty list.
        let set = try Self.fixture("v2-bad-credentials.json")
        let outcome = try database.writer.write { db in
            try SimpleFINIngest.ingest(set, kind: .balances, into: db, now: Date(timeIntervalSince1970: 1_789_600_000))
        }
        #expect(outcome.accountsMarkedNotUpdating == 2)
        #expect(outcome.notices.contains { $0.scope == .wholeCredential })

        let accounts = try database.reader.read { db in try Account.fetchAll(db) }
        #expect(accounts.count == 2, "an empty answer must never be read as 'you have no accounts'")
        for account in accounts {
            #expect(account.notUpdatingSince != nil)
            #expect(account.balanceCents == 2_595_111 || account.balanceCents == 11_552_551)
        }
        // And the engine refuses to give a number over it.
        let result = SafeToSpendEngine.compute(
            accounts: accounts, charges: [], paySchedule: nil,
            today: Self.day(2026, 9, 14), calendar: Self.chicago)
        if case .figures = result { Issue.record("expected no figure over a dead connection") }
    }

    // MARK: Routing errors

    @Test("an account error with no connection named is not pinned on a guess")
    func ambiguousAccountError() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            _ = try Self.seedAccount(db, connId: "CON-A", externalId: "Checking")
            _ = try Self.seedAccount(db, connId: "CON-B", externalId: "Checking")
        }
        let ambiguous = try Self.set("""
            {"errlist":[{"code":"act.failed","msg":"Failed to get all transactions. Try again later.","account_id":"Checking"}],
             "connections":[],"accounts":[]}
            """)
        let outcome = try database.writer.write { db in
            try SimpleFINIngest.ingest(ambiguous, kind: .balances, into: db, now: Date(timeIntervalSince1970: 1_789_600_000))
        }
        #expect(outcome.notices.contains { $0.scope == .everything && $0.code == "act.failed" })
        #expect(!outcome.notices.contains { if case .account = $0.scope { return true } else { return false } })

        // Named with its connection, it lands on exactly one account.
        let precise = try Self.set("""
            {"errlist":[{"code":"act.failed","msg":"Failed","account_id":"Checking","conn_id":"CON-B"}],
             "connections":[],"accounts":[]}
            """)
        let second = try database.writer.write { db in
            try SimpleFINIngest.ingest(precise, kind: .balances, into: db, now: Date(timeIntervalSince1970: 1_789_600_000))
        }
        #expect(second.notices.contains { if case .account = $0.scope { return true } else { return false } })
    }

    @Test("errors are routed by their prefix, and only gen.auth reaches the re-connect banner")
    func routingByPrefix() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in _ = try Self.seedAccount(db, connId: "CON-A", externalId: "Checking") }
        let set = try Self.set("""
            {"errlist":[
              {"code":"con.auth","msg":"Authentication failed for My Bank","conn_id":"CON-A"},
              {"code":"gen.api","msg":"Requested date range exceeds recommended range of 45 days."},
              {"code":"con.weird","msg":"Something new","conn_id":"CON-A"},
              {"code":"gen.newthing","msg":"Who knows"}
             ],"connections":[],"accounts":[]}
            """)
        let outcome = try database.writer.write { db in
            try SimpleFINIngest.ingest(set, kind: .balances, into: db, now: Date(timeIntervalSince1970: 1_789_600_000))
        }
        #expect(outcome.notices.contains { $0.scope == .connection("CON-A") && $0.code == "con.auth" })
        // An unrecognised con.* subcode still reaches the connection, per the protocol's fallback.
        #expect(outcome.notices.contains { $0.scope == .connection("CON-A") && $0.code == "con.weird" })
        // The 45-day recommendation is about how the app asked, not about the owner's money.
        #expect(outcome.notices.contains { $0.scope == .developer && $0.code == "gen.api" })
        // An unknown gen.* is shown, but never as "your connection died".
        #expect(outcome.notices.contains { $0.scope == .everything && $0.code == "gen.newthing" })
        #expect(!outcome.notices.contains { $0.scope == .wholeCredential })
    }

    // MARK: Storing transactions

    @Test("the same window twice stores the same rows once")
    func overlapDoesNotDuplicate() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            _ = try Self.seedAccount(db, externalId: "Demo Checking")
            _ = try Self.seedAccount(db, externalId: "Demo Savings")
        }
        let window = try Self.fixture("v2-window.json")
        let kind = SimpleFINRequestKind.window(start: Self.day(2026, 8, 2), end: Self.day(2026, 9, 14))
        let first = try database.writer.write { db in
            try SimpleFINIngest.ingest(window, kind: kind, into: db, now: Date(timeIntervalSince1970: 1_789_600_000), calendar: Self.chicago)
        }
        let countAfterFirst = try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bank_transaction") ?? 0
        }
        try database.writer.write { db in
            _ = try SimpleFINIngest.ingest(window, kind: kind, into: db, now: Date(timeIntervalSince1970: 1_789_700_000), calendar: Self.chicago)
        }
        let countAfterSecond = try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bank_transaction") ?? 0
        }
        #expect(countAfterFirst == countAfterSecond)
        #expect(first.transactionsInserted == countAfterFirst)
        // The demo reuses the same ids across its two accounts, which is exactly what the protocol
        // permits: ids are unique within an account, not across them.
        #expect(countAfterFirst > 150)
    }

    @Test("a charge that comes back under a new id is recognised, not stored twice")
    func idChurnIsAbsorbed() throws {
        let database = try AppDatabase.inMemory()
        let accountId = try database.writer.write { db in try Self.seedAccount(db) }
        func response(id: String) throws -> SimpleFINAccountSet {
            try Self.set("""
                {"errlist":[],"connections":[],"accounts":[{"id":"Demo Checking","name":"C",
                 "conn_id":"CON-SIMPLEFIN-DEMO","currency":"USD","balance":"1.00","balance-date":1789516800,
                 "transactions":[{"id":"\(id)","posted":1789430400,"amount":"-42.00","description":"BLUE BOTTLE"}]}]}
                """)
        }
        let kind = SimpleFINRequestKind.window(start: Self.day(2026, 9, 1), end: Self.day(2026, 9, 14))
        try database.writer.write { db in
            _ = try SimpleFINIngest.ingest(try response(id: "X1"), kind: kind, into: db, now: Date(timeIntervalSince1970: 1_789_600_000), calendar: Self.chicago)
        }
        let second = try database.writer.write { db in
            try SimpleFINIngest.ingest(try response(id: "Y1"), kind: kind, into: db, now: Date(timeIntervalSince1970: 1_789_700_000), calendar: Self.chicago)
        }
        #expect(second.transactionsMatchedByContent == 1)
        #expect(second.transactionsInserted == 0)
        let rows = try database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT external_id FROM bank_transaction WHERE account_id = ?", arguments: [accountId])
        }
        #expect(rows.count == 1)
        #expect(rows[0]["external_id"] as String? == "Y1")
    }

    @Test("two identical charges on the same day stay two charges")
    func identicalChargesAreNeverCollapsed() throws {
        let database = try AppDatabase.inMemory()
        let accountId = try database.writer.write { db in try Self.seedAccount(db) }
        // Two genuinely separate $5 coffees on the same day.
        try database.writer.write { db in
            for id in ["X1", "X2"] {
                try db.execute(sql: """
                    INSERT INTO bank_transaction (account_id, external_id, posted, effective_date, amount_cents,
                                                  description, pending, first_seen_at, last_seen_at)
                    VALUES (?, ?, 1789430400, 1789430400, -500, 'BLUE BOTTLE', 0, 0, 0)
                    """, arguments: [accountId, id])
            }
        }
        // They come back under new ids.
        let set = try Self.set("""
            {"errlist":[],"connections":[],"accounts":[{"id":"Demo Checking","name":"C",
             "conn_id":"CON-SIMPLEFIN-DEMO","currency":"USD","balance":"1.00","balance-date":1789516800,
             "transactions":[{"id":"Y1","posted":1789430400,"amount":"-5.00","description":"BLUE BOTTLE"},
                             {"id":"Y2","posted":1789430400,"amount":"-5.00","description":"BLUE BOTTLE"}]}]}
            """)
        try database.writer.write { db in
            _ = try SimpleFINIngest.ingest(
                set, kind: .window(start: Self.day(2026, 9, 1), end: Self.day(2026, 9, 14)),
                into: db, now: Date(timeIntervalSince1970: 1_789_700_000), calendar: Self.chicago)
        }
        let count = try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bank_transaction WHERE voided_at IS NULL") ?? 0
        }
        // Two before, two after: ambiguity is left alone rather than collapsed into one.
        #expect(count == 2)
    }

    // MARK: Holds

    @Test("a hold is superseded by the charge that settles it, and only by evidence")
    func pendingSupersededByEvidence() throws {
        let database = try AppDatabase.inMemory()
        let accountId = try database.writer.write { db -> Int64 in
            let id = try Self.seedAccount(db)
            try db.execute(sql: """
                INSERT INTO bank_transaction (account_id, external_id, posted, transacted_at, effective_date,
                                              amount_cents, description, pending, first_seen_at, last_seen_at)
                VALUES (?, 'P-1', 0, 1789344000, 1789344000, -6400, 'WHOLEFOODS MKT', 1, 0, 0)
                """, arguments: [id])
            return id
        }
        // The hold is gone from this answer and a settled charge of the same amount has appeared.
        let set = try Self.set("""
            {"errlist":[],"connections":[],"accounts":[{"id":"Demo Checking","name":"C",
             "conn_id":"CON-SIMPLEFIN-DEMO","currency":"USD","balance":"1.00","balance-date":1789516800,
             "transactions":[{"id":"S-1","posted":1789430400,"amount":"-64.00","description":"WHOLEFOODS MKT"}]}]}
            """)
        let outcome = try database.writer.write { db in
            try SimpleFINIngest.ingest(
                set, kind: .window(start: Self.day(2026, 9, 8), end: Self.day(2026, 9, 14)),
                into: db, now: Date(timeIntervalSince1970: 1_789_500_000), calendar: Self.chicago)
        }
        #expect(outcome.pendingSuperseded == 1)
        let live = try database.reader.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM bank_transaction
                 WHERE account_id = ? AND voided_at IS NULL AND superseded_by IS NULL
                """, arguments: [accountId]) ?? 0
        }
        #expect(live == 1, "the hold and its charge must not both count")
    }

    @Test("a hold the bank is still reporting is never superseded")
    func stillReportedHoldSurvives() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let id = try Self.seedAccount(db)
            try db.execute(sql: """
                INSERT INTO bank_transaction (account_id, external_id, posted, transacted_at, effective_date,
                                              amount_cents, description, pending, first_seen_at, last_seen_at)
                VALUES (?, 'P-1', 0, 1789344000, 1789344000, -6400, 'WHOLEFOODS MKT', 1, 0, 0)
                """, arguments: [id])
        }
        // Both in the same answer: a hold the bank still calls pending has not posted, whatever
        // else in the response looks like it.
        let set = try Self.set("""
            {"errlist":[],"connections":[],"accounts":[{"id":"Demo Checking","name":"C",
             "conn_id":"CON-SIMPLEFIN-DEMO","currency":"USD","balance":"1.00","balance-date":1789516800,
             "transactions":[{"id":"P-1","posted":0,"transacted_at":1789344000,"amount":"-64.00","description":"WHOLEFOODS MKT","pending":true},
                             {"id":"S-9","posted":1789430400,"amount":"-64.00","description":"WHOLEFOODS MKT"}]}]}
            """)
        let outcome = try database.writer.write { db in
            try SimpleFINIngest.ingest(
                set, kind: .window(start: Self.day(2026, 9, 8), end: Self.day(2026, 9, 14)),
                into: db, now: Date(timeIntervalSince1970: 1_789_500_000), calendar: Self.chicago)
        }
        #expect(outcome.pendingSuperseded == 0)
    }

    @Test("a hold nothing ever settles is written off by age, with its reason kept")
    func staleHoldIsAgedOut() throws {
        let database = try AppDatabase.inMemory()
        let now = Int64(1_789_500_000)
        try database.writer.write { db in
            let id = try Self.seedAccount(db)
            try db.execute(sql: """
                INSERT INTO bank_transaction (account_id, external_id, posted, transacted_at, effective_date,
                                              amount_cents, description, pending, first_seen_at, last_seen_at)
                VALUES (?, 'AUTH-77', 0, ?, ?, -40000, 'MARRIOTT HOTELS', 1, 0, ?)
                """, arguments: [id, now - 12 * 86_400, now - 12 * 86_400, now - 11 * 86_400])
        }
        let set = try Self.set("""
            {"errlist":[],"connections":[],"accounts":[{"id":"Demo Checking","name":"C",
             "conn_id":"CON-SIMPLEFIN-DEMO","currency":"USD","balance":"1.00","balance-date":1789516800,
             "transactions":[]}]}
            """)
        let outcome = try database.writer.write { db in
            try SimpleFINIngest.ingest(
                set, kind: .window(start: Self.day(2026, 9, 8), end: Self.day(2026, 9, 14)),
                into: db, now: Date(timeIntervalSince1970: TimeInterval(now)), calendar: Self.chicago)
        }
        #expect(outcome.pendingVoided == 1)
        let row = try #require(try database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT voided_at, voided_reason FROM bank_transaction")
        })
        #expect(row["voided_at"] != nil)
        #expect((row["voided_reason"] as String?)?.contains("stopped reporting") == true)
        // Never deleted: the owner's history is not the app's to throw away.
        #expect(try database.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bank_transaction") } == 1)
    }

    @Test("a recent hold is not written off just for being absent from one answer")
    func recentHoldSurvivesAbsence() throws {
        let database = try AppDatabase.inMemory()
        let now = Int64(1_789_500_000)
        try database.writer.write { db in
            let id = try Self.seedAccount(db)
            try db.execute(sql: """
                INSERT INTO bank_transaction (account_id, external_id, posted, transacted_at, effective_date,
                                              amount_cents, description, pending, first_seen_at, last_seen_at)
                VALUES (?, 'P-2', 0, ?, ?, -6400, 'CORNER SHOP', 1, 0, ?)
                """, arguments: [id, now - 2 * 86_400, now - 2 * 86_400, now - 86_400])
        }
        let set = try Self.set("""
            {"errlist":[],"connections":[],"accounts":[{"id":"Demo Checking","name":"C",
             "conn_id":"CON-SIMPLEFIN-DEMO","currency":"USD","balance":"1.00","balance-date":1789516800,
             "transactions":[]}]}
            """)
        let outcome = try database.writer.write { db in
            try SimpleFINIngest.ingest(
                set, kind: .window(start: Self.day(2026, 9, 8), end: Self.day(2026, 9, 14)),
                into: db, now: Date(timeIntervalSince1970: TimeInterval(now)), calendar: Self.chicago)
        }
        #expect(outcome.pendingVoided == 0)
    }

    // MARK: Watermarks

    @Test("an account the server complained about keeps its watermark, so the gap is asked for again")
    func troubledAccountKeepsItsWatermark() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let good = try Self.seedAccount(db, connId: "CON-A", externalId: "Good")
            let bad = try Self.seedAccount(db, connId: "CON-A", externalId: "Bad")
            try db.execute(sql: "UPDATE account SET tx_synced_through = 1000 WHERE id IN (?, ?)", arguments: [good, bad])
        }
        let set = try Self.set("""
            {"errlist":[{"code":"act.failed","msg":"Failed to get all transactions.","account_id":"Bad","conn_id":"CON-A"}],
             "connections":[{"conn_id":"CON-A","name":"My Bank"}],
             "accounts":[
               {"id":"Good","name":"Good","conn_id":"CON-A","currency":"USD","balance":"1.00","balance-date":1789516800,"transactions":[]},
               {"id":"Bad","name":"Bad","conn_id":"CON-A","currency":"USD","balance":"1.00","balance-date":1789516800,"transactions":[]}]}
            """)
        try database.writer.write { db in
            _ = try SimpleFINIngest.ingest(
                set, kind: .window(start: Self.day(2026, 9, 1), end: Self.day(2026, 9, 14)),
                into: db, now: Date(timeIntervalSince1970: 1_789_600_000), calendar: Self.chicago)
        }
        let accounts = try database.reader.read { db in try Account.fetchAll(db) }
        let good = try #require(accounts.first { $0.externalId == "Good" })
        let bad = try #require(accounts.first { $0.externalId == "Bad" })
        #expect(good.txSyncedThrough == Self.day(2026, 9, 14).epochSeconds(in: Self.chicago))
        #expect(bad.txSyncedThrough == 1_000)
    }
}

@Suite("Asking no more often than allowed")
struct RequestBudgetTests {
    static var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    @Test("the budget is a rolling day, not a calendar one")
    func rollingWindow() throws {
        let database = try AppDatabase.inMemory()
        let evening = Date(timeIntervalSince1970: 1_789_520_400) // roughly 7pm Chicago

        try database.writer.write { db in
            for index in 0..<RequestBudget.maxInRollingDay {
                _ = try RequestBudget.reserve(db, purpose: .refresh, now: evening.addingTimeInterval(Double(index)))
            }
        }
        // Full.
        #expect(throws: RequestBudget.Refusal.dayIsFull) {
            try database.writer.write { db in
                _ = try RequestBudget.reserve(db, purpose: .refresh, now: evening.addingTimeInterval(60))
            }
        }
        // Just after local midnight, a calendar-day budget would have reset. A rolling one has not,
        // and that is the whole point: twelve late one evening plus twelve early the next morning
        // is twenty-four inside one server day, which is the number that disables the token.
        let justAfterMidnight = evening.addingTimeInterval(6 * 3_600)
        #expect(throws: RequestBudget.Refusal.dayIsFull) {
            try database.writer.write { db in
                _ = try RequestBudget.reserve(db, purpose: .refresh, now: justAfterMidnight)
            }
        }
        // A full day later, the oldest has fallen out.
        try database.writer.write { db in
            _ = try RequestBudget.reserve(db, purpose: .refresh, now: evening.addingTimeInterval(24 * 3_600 + 10))
        }
    }

    @Test("history windows have their own smaller share, so a backfill cannot eat the day")
    func backfillHasItsOwnShare() throws {
        let database = try AppDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_789_520_400)
        try database.writer.write { db in
            for index in 0..<RequestBudget.maxBackfillInRollingDay {
                _ = try RequestBudget.reserve(db, purpose: .backfill, now: now.addingTimeInterval(Double(index)))
            }
        }
        #expect(throws: RequestBudget.Refusal.backfillIsFullForToday) {
            try database.writer.write { db in
                _ = try RequestBudget.reserve(db, purpose: .backfill, now: now.addingTimeInterval(100))
            }
        }
        // Ordinary refreshes still have room, which is why they are counted separately.
        try database.writer.write { db in
            _ = try RequestBudget.reserve(db, purpose: .refresh, now: now.addingTimeInterval(101))
        }
        let remaining = try database.reader.read { db in
            try RequestBudget.remaining(db, purpose: .refresh, now: now.addingTimeInterval(102))
        }
        #expect(remaining == RequestBudget.maxInRollingDay - RequestBudget.maxBackfillInRollingDay - 1)
    }

    @Test("a reservation is taken before the request, so a crash can only over-count")
    func reservationIsUpFront() throws {
        let database = try AppDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_789_520_400)
        try database.writer.write { db in _ = try RequestBudget.reserve(db, purpose: .refresh, now: now) }
        // Nothing reports success or failure afterwards; the count already moved.
        let remaining = try database.reader.read { db in try RequestBudget.remaining(db, now: now) }
        #expect(remaining == RequestBudget.maxInRollingDay - 1)
    }

    @Test("the server's own warning stops the day, and says so")
    func serverWarningStopsTheDay() throws {
        let database = try AppDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_789_520_400)
        try database.writer.write { db in try RequestBudget.recordServerQuotaWarning(db, now: now) }
        #expect(try database.reader.read { db in try RequestBudget.serverWarnedAboutTheRate(db, now: now) })
        #expect(throws: RequestBudget.Refusal.serverWarnedAboutTheRate) {
            try database.writer.write { db in
                _ = try RequestBudget.reserve(db, purpose: .refresh, now: now.addingTimeInterval(3_600))
            }
        }
        // A day later it lifts.
        try database.writer.write { db in
            _ = try RequestBudget.reserve(db, purpose: .refresh, now: now.addingTimeInterval(25 * 3_600))
        }
    }
}

@Suite("Planning which spans of days to ask for")
struct BackfillPlanTests {
    static var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    @Test("no window is ever longer than the app promised, and they overlap by five days")
    func windowShape() {
        let today = CalendarDay(year: 2026, month: 9, day: 14)
        let windows = BackfillPlan.windows(endingOn: today, calendar: Self.chicago)
        #expect(!windows.isEmpty)
        for window in windows {
            let span = window.lowerBound.days(to: window.upperBound, in: Self.chicago)
            #expect(span <= SimpleFINClient.longestWindowDays - 1, "a window spanned \(span + 1) days")
        }
        for (earlier, later) in zip(windows.dropFirst(), windows) {
            // Each window ends five days inside the one after it.
            let overlap = later.lowerBound.days(to: earlier.upperBound, in: Self.chicago) + 1
            #expect(overlap == BackfillPlan.overlapDays)
        }
        #expect(windows.first?.upperBound == today)
    }

    @Test("the walk reaches back over a year, in a countable number of windows")
    func reachesThirteenMonths() {
        let today = CalendarDay(year: 2026, month: 9, day: 14)
        let windows = BackfillPlan.windows(endingOn: today, calendar: Self.chicago)
        let earliest = try! #require(windows.last?.lowerBound)
        #expect(earliest.days(to: today, in: Self.chicago) >= 395)
        #expect(windows.count <= 12)
        #expect(windows.count >= 10)
    }

    @Test("a limit is honoured, and reported rather than silently truncating")
    func limitIsHonoured() {
        let today = CalendarDay(year: 2026, month: 9, day: 14)
        #expect(BackfillPlan.windows(endingOn: today, limit: 3, calendar: Self.chicago).count == 3)
        #expect(BackfillPlan.windows(endingOn: today, limit: 0, calendar: Self.chicago).isEmpty)
    }

    @Test("an ordinary sync asks from the watermark back five days, unless the gap is too wide")
    func incrementalWindows() {
        let today = CalendarDay(year: 2026, month: 9, day: 14)
        let recent = BackfillPlan.incrementalWindow(
            since: CalendarDay(year: 2026, month: 9, day: 10), today: today, calendar: Self.chicago)
        #expect(recent?.lowerBound == CalendarDay(year: 2026, month: 9, day: 5))
        #expect(recent?.upperBound == today)

        // A gap wider than one window is not asked for in one go: the server would trim it and
        // still answer 200, leaving a hole nobody would ever notice.
        let wide = BackfillPlan.incrementalWindow(
            since: CalendarDay(year: 2026, month: 1, day: 1), today: today, calendar: Self.chicago)
        #expect(wide == nil)

        #expect(BackfillPlan.incrementalWindow(since: nil, today: today, calendar: Self.chicago) == nil)
    }

    @Test("progress through the walk survives a restart")
    func progressRoundTrips() throws {
        let database = try AppDatabase.inMemory()
        var progress = BackfillProgress()
        progress.nextWindowIndex = 4
        progress.consecutiveEmptyWindows = 1
        progress.coveredBackTo = "2026-05-01"
        try database.writer.write { db in try progress.save(db) }

        let loaded = try database.reader.read { db in try BackfillProgress.load(db) }
        #expect(loaded == progress)
        #expect(loaded.state == .running)

        // A database that has never run a backfill starts at the beginning rather than throwing.
        let fresh = try AppDatabase.inMemory()
        #expect(try fresh.reader.read { db in try BackfillProgress.load(db) }.nextWindowIndex == 0)
    }
}
