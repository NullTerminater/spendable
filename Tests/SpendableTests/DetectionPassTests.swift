import Foundation
import GRDB
import Testing
@testable import Spendable

/// Detection end to end on an in-memory database: `docs/reviews/milestone-5-review.md` test cases.
/// Synthetic rows only; nothing here resembles a real account.
@Suite("Detection against the database")
struct DetectionPassTests {
    static var chicago: Calendar { SimpleFINIngestTests.chicago }
    static let now = Date(timeIntervalSince1970: 1_790_500_000)   // 2026-09-27

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> CalendarDay { CalendarDay(year: y, month: m, day: d) }

    /// A synced checking account, confirmed, with a fresh balance.
    @discardableResult
    static func seedAccount(_ db: Database, externalId: String = "ACT-SYN-1", holdings: Int = 0) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO account (source, conn_id, external_id, remote_name, display_name, user_type, currency,
                                 balance_cents, available_cents, balance_date, last_seen_in_sync_at, holdings_count,
                                 holdings_observed_at, created_at)
            VALUES ('simplefin', 'CONN-SYN', ?, 'Synthetic Checking', 'Synthetic Checking', 'checking', 'USD',
                    500000, 500000, ?, ?, ?, 1, 0)
            """, arguments: [externalId, Int64(now.timeIntervalSince1970), Int64(now.timeIntervalSince1970), holdings])
        return db.lastInsertedRowID
    }

    /// A settled debit on `day`, posted that day at noon UTC, keyed as ingestion would key it.
    static func charge(_ db: Database, account: Int64, _ id: String, _ day: CalendarDay, cents: Int64,
                       description: String = "PAYPAL *SPOTIFY", pending: Bool = false) throws {
        let posted = day.utcMidnight + 12 * 3_600
        let key = MerchantKey.normalize(payee: nil, description: description)
        try db.execute(sql: """
            INSERT INTO bank_transaction (account_id, external_id, posted, effective_date, amount_cents, description,
                pending, first_seen_at, last_seen_at, merchant_normalized, merchant_alt, normalizer_version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [account, id, pending ? 0 : posted, posted, cents, description, pending,
                             posted, posted, key.key, key.alternate, MerchantKey.version])
    }

    static func monthly(_ db: Database, account: Int64, prefix: String, from start: CalendarDay, count: Int,
                        cents: Int64, description: String = "PAYPAL *SPOTIFY") throws {
        for index in 0..<count {
            try charge(db, account: account, "\(prefix)\(index)", start.adding(months: index, in: CalendarDay.utc),
                       cents: cents, description: description)
        }
    }

    /// Covers the whole year before `now`, as a finished history walk would.
    static func coverYear(_ db: Database, account: Int64) throws {
        try SimpleFINIngest.recordCoverage(db, accountId: account, start: Int64(now.timeIntervalSince1970) - 400 * 86_400,
                                           end: Int64(now.timeIntervalSince1970) + 86_400, nowSeconds: Int64(now.timeIntervalSince1970))
    }

    @discardableResult
    static func drain(_ database: AppDatabase) -> DetectionWorker.Report {
        DetectionWorker.drainNow(database: database, calendar: chicago, now: { now })
    }

    static func bills(_ database: AppDatabase) throws -> [RecurringCharge] {
        try database.reader.read { db in try RecurringCharge.fetchAll(db, sql: "SELECT * FROM recurring_charge ORDER BY id") }
    }

    @Test("three monthly charges become one counted bill, badged, with its payments linked")
    func threeChargesConfirm() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let account = try Self.seedAccount(db)
            try Self.monthly(db, account: account, prefix: "S", from: Self.day(2026, 6, 12), count: 3, cents: -999)
        }
        Self.drain(database)
        let bills = try Self.bills(database)
        #expect(bills.count == 1)
        let bill = try #require(bills.first)
        #expect(bill.source == .detected)
        #expect(bill.status == .confirmed)
        #expect(bill.confirmedBy == .auto)
        #expect(bill.announcedAt == nil)
        #expect(bill.amountCents == 999)
        #expect(bill.cadence == .monthly)
        #expect(bill.nextExpectedDate != nil)
        #expect(bill.fingerprint == "s\(bill.id ?? 0)")
        let payments = try database.reader.read { db in try BankPaymentQueries.load(db, oldestBalanceInstant: nil) }
        #expect(payments.latestPaid[bill.id ?? 0] == Self.day(2026, 8, 12))
        // The marker the engine uses moves past the last charge the bank has shown.
        #expect(bill.occurrence(after: Self.day(2026, 8, 12), in: Self.chicago) == Self.day(2026, 9, 12))
    }

    @Test("a queue drained twice changes nothing the second time")
    func idempotentReplay() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let account = try Self.seedAccount(db)
            try Self.monthly(db, account: account, prefix: "S", from: Self.day(2026, 6, 12), count: 4, cents: -999)
        }
        Self.drain(database)
        let first = try Self.bills(database)
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO detection_dirty (account_id, merchant_key, enqueued_at) VALUES (1, 'SPOTIFY', 0)")
        }
        Self.drain(database)
        #expect(try Self.bills(database) == first)
    }

    @Test("dismissed stays dismissed when older, cheaper history arrives later")
    func dismissalSurvivesBackfill() async throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let account = try Self.seedAccount(db)
            try Self.monthly(db, account: account, prefix: "N", from: Self.day(2026, 4, 12), count: 5, cents: -1099)
        }
        Self.drain(database)
        let store = await SpendableStore(database: database)
        let bill = try #require(try Self.bills(database).first)
        _ = await store.apply(.dismiss, to: bill)

        // The older half of the history walk arrives: the same subscription at its old price.
        try database.writer.write { db in
            try Self.monthly(db, account: 1, prefix: "O", from: Self.day(2025, 11, 12), count: 5, cents: -999)
        }
        Self.drain(database)
        let after = try Self.bills(database)
        #expect(after.count == 1)
        #expect(after.first?.status == .dismissed)
    }

    @Test("two plans at the same price are two bills and never wedge the queue")
    func twoPlansNoCollision() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let account = try Self.seedAccount(db)
            try Self.monthly(db, account: account, prefix: "A", from: Self.day(2026, 3, 3), count: 6, cents: -99, description: "APPLE.COM/BILL")
            try Self.monthly(db, account: account, prefix: "B", from: Self.day(2026, 3, 19), count: 6, cents: -99, description: "APPLE.COM/BILL")
        }
        let report = Self.drain(database)
        #expect(report.quarantined == 0)
        let bills = try Self.bills(database)
        #expect(bills.count == 2)
        #expect(bills.allSatisfy { $0.cadence == .monthly })
    }

    @Test("nothing is found on an account holding shares or funds")
    func noBillsOnInvestments() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let account = try Self.seedAccount(db, holdings: 4)
            try Self.monthly(db, account: account, prefix: "F", from: Self.day(2026, 3, 1), count: 6, cents: -50000, description: "FUND PURCHASE")
        }
        Self.drain(database)
        #expect(try Self.bills(database).isEmpty)
    }

    @Test("an owner's corrected amount survives a price change the bank shows")
    func ownerOverrideSurvives() async throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let account = try Self.seedAccount(db)
            try Self.monthly(db, account: account, prefix: "S", from: Self.day(2026, 4, 12), count: 3, cents: -999)
        }
        Self.drain(database)
        let store = await SpendableStore(database: database)
        var bill = try #require(try Self.bills(database).first)
        bill.amountCents = 1500
        #expect(await store.save(bill) == .saved)
        try database.writer.write { db in
            try Self.charge(db, account: 1, "S3", Self.day(2026, 7, 12), cents: -1099)
            try Self.charge(db, account: 1, "S4", Self.day(2026, 8, 12), cents: -1099)
        }
        Self.drain(database)
        let after = try #require(try Self.bills(database).first)
        #expect(after.amountCents == 1500)
        #expect(after.detectedAmountCents == 1099)
        #expect(after.ownerOverrides & OwnerOverride.amount != 0)
    }

    @Test("a form opened before detection wrote the bill reloads instead of overwriting it")
    func staleFormIsRefused() async throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let account = try Self.seedAccount(db)
            try Self.monthly(db, account: account, prefix: "S", from: Self.day(2026, 4, 12), count: 3, cents: -999)
        }
        Self.drain(database)
        let store = await SpendableStore(database: database)
        var opened = try #require(try Self.bills(database).first)
        try database.writer.write { db in
            try Self.charge(db, account: 1, "S3", Self.day(2026, 7, 12), cents: -999)
        }
        Self.drain(database)
        opened.name = "Renamed from an old form"
        #expect(await store.save(opened) == .changedSinceOpened)
        #expect(await store.markPaid(opened, alsoReduceBalance: true) == .changedSinceOpened)
        #expect(try Self.bills(database).first?.name != "Renamed from an old form")
    }

    @Test("a voided payment stops paying its occurrence at once, before detection runs again")
    func voidReversesPayment() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let account = try Self.seedAccount(db)
            try Self.monthly(db, account: account, prefix: "S", from: Self.day(2026, 6, 12), count: 3, cents: -999)
        }
        Self.drain(database)
        try database.writer.write { db in
            try db.execute(sql: "UPDATE bank_transaction SET voided_at = 1 WHERE external_id = 'S2'")
        }
        let payments = try database.reader.read { db in try BankPaymentQueries.load(db, oldestBalanceInstant: nil) }
        #expect(payments.latestPaid.values.first == Self.day(2026, 7, 12))
    }

    @Test("a status only moves towards counting: a refund does not un-confirm a bill")
    func statusIsMonotone() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let account = try Self.seedAccount(db)
            try Self.monthly(db, account: account, prefix: "S", from: Self.day(2026, 6, 12), count: 3, cents: -999)
        }
        Self.drain(database)
        try database.writer.write { db in
            try Self.charge(db, account: 1, "R1", Self.day(2026, 8, 20), cents: 999)
        }
        Self.drain(database)
        let bill = try #require(try Self.bills(database).first)
        #expect(bill.status == .confirmed)
        #expect(bill.evidenceChanged)
    }

    @Test("a bill that looks cancelled is flagged and still counted")
    func maybeCancelledStillCounts() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let account = try Self.seedAccount(db)
            try Self.coverYear(db, account: account)
            try Self.monthly(db, account: account, prefix: "G", from: Self.day(2026, 3, 7), count: 4, cents: -4000, description: "PLANET FITNESS")
        }
        Self.drain(database)
        let bill = try #require(try Self.bills(database).first)
        #expect(bill.inferredInactiveSince == "2026-07-07")
        #expect(bill.status == .confirmed)
        let total = try database.reader.read { db in try BillsQueries.monthlyTotal(db) }
        #expect(total == 4000)
    }

    @Test("a missing charge is not proven missing without fetched history around it")
    func noCoverageNoFlag() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let account = try Self.seedAccount(db)
            try Self.monthly(db, account: account, prefix: "G", from: Self.day(2026, 3, 7), count: 4, cents: -4000, description: "PLANET FITNESS")
        }
        Self.drain(database)
        #expect(try Self.bills(database).first?.inferredInactiveSince == nil)
    }

    @Test("a missing charge paid under another name is not missing")
    func renamedChargeIsNotMissing() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            let account = try Self.seedAccount(db)
            try Self.coverYear(db, account: account)
            try Self.monthly(db, account: account, prefix: "U", from: Self.day(2026, 3, 9), count: 4, cents: -8000, description: "CITYPOWER UTIL")
            try Self.monthly(db, account: account, prefix: "V", from: Self.day(2026, 7, 9), count: 3, cents: -8000, description: "CITY POWER ELECTRIC")
        }
        Self.drain(database)
        let old = try Self.bills(database).first { $0.merchantNormalized == "CITYPOWER UTIL" }
        #expect(old?.inferredInactiveSince == nil)
    }

    @Test("the monthly total is a sum of rounded rows and ignores suggestions and moves between accounts")
    func monthlyTotal() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO recurring_charge (source, kind, name, amount_cents, cadence, status, created_at, updated_at, transfer_evidence_account_id)
                VALUES ('manual', 'subscription', 'Prime', 13900, 'annual', 'confirmed', 0, 0, NULL),
                       ('manual', 'bill', 'Rent', 140000, 'monthly', 'confirmed', 0, 0, NULL),
                       ('detected', 'subscription', 'Maybe', 999, 'monthly', 'suggested', 0, 0, NULL),
                       ('detected', 'subscription', 'To savings', 50000, 'monthly', 'confirmed', 0, 0, NULL),
                       ('manual', 'transfer', 'Card', 30000, 'monthly', 'confirmed', 0, 0, NULL)
                """)
            try Self.seedAccount(db)
            try db.execute(sql: "UPDATE recurring_charge SET transfer_evidence_account_id = 1 WHERE name = 'To savings'")
        }
        let total = try database.reader.read { db in try BillsQueries.monthlyTotal(db) }
        #expect(total == 140000 + 1158)
        let page = try database.reader.read { db in try BillsQueries.rows(db, count: 2) }
        #expect(page.rows.count == 2)
        #expect(page.hasMore)
        let all = try database.reader.read { db in try BillsQueries.rows(db, count: 50) }
        #expect(all.rows.map(\.section) == [.bills, .bills, .mightBeBills, .movesBetweenAccounts, .transfers])
    }
}

/// The engine's side of bank payments: decisions 13, 15 and 16.
@Suite("Bank payments in the safe-to-spend figure")
struct BankPaymentEngineTests {
    static var chicago: Calendar { SimpleFINIngestTests.chicago }
    static let today = CalendarDay(year: 2026, month: 9, day: 14)

    static func account(id: Int64 = 1, type: AccountType = .checking, balanceDate: Int64, available: Int64? = nil) -> Account {
        var account = Account.manual(displayName: type == .credit ? "Synthetic Card" : "Synthetic Checking", type: type, balanceCents: 300000)
        account.id = id
        account.source = .simplefin
        account.userType = type
        account.balanceDate = balanceDate
        account.lastSeenInSyncAt = balanceDate
        account.availableCents = available
        account.holdingsObservedAt = 1
        return account
    }

    static func netflix(paying: Int64 = 1) -> RecurringCharge {
        var charge = RecurringCharge.manual(name: "Netflix", kind: .subscription, amountCents: 1549, cadence: .monthly,
                                            nextDue: CalendarDay(year: 2026, month: 9, day: 12), payingAccountId: paying,
                                            calendar: chicago)
        charge.id = 7
        charge.source = .detected
        return charge
    }

    static func month(_ result: SafeToSpendResult) -> SpendableFigure? {
        if case .figures(let report) = result { return report.month }
        return nil
    }

    @Test("a payment the balance already includes takes the bill off; one it doesn't include stays counted")
    func paymentFoundAwaitingBalance() throws {
        let posted = CalendarDay(year: 2026, month: 9, day: 12).utcMidnight + 12 * 3_600
        let payments = BankPayments(
            latestPaid: [7: CalendarDay(year: 2026, month: 9, day: 12)],
            recent: [BankPayment(chargeId: 7, occurrence: CalendarDay(year: 2026, month: 9, day: 12), amountCents: 1549,
                                 pending: false, postedInstant: posted, firstSeenAt: posted)])

        // Balance from the next day: the payment is in it, so September's Netflix is paid.
        let caughtUp = SafeToSpendEngine.compute(
            accounts: [Self.account(balanceDate: posted + 86_400)], charges: [Self.netflix()], paySchedule: nil,
            today: Self.today, calendar: Self.chicago, payments: payments)
        #expect(Self.month(caughtUp)?.remainderCents == 300000)

        // Balance from the same UTC day, an hour before it posted: still subtracted, once, with the
        // sentence. Local time zones do not enter into it.
        let behind = SafeToSpendEngine.compute(
            accounts: [Self.account(balanceDate: posted - 3_600)], charges: [Self.netflix()], paySchedule: nil,
            today: Self.today, calendar: Self.chicago, payments: payments)
        let figure = try #require(Self.month(behind))
        #expect(figure.remainderCents == 300000 - 1549)
        #expect(figure.obligations.contains { if case .paymentFoundAwaitingBalance = $0.treatment { true } else { false } })
    }

    @Test("a charge on a card with no statement never takes the bill off the number")
    func cardChargeDoesNotRaiseTheFigure() {
        let posted = CalendarDay(year: 2026, month: 9, day: 12).utcMidnight
        let payments = BankPayments(latestPaid: [7: CalendarDay(year: 2026, month: 9, day: 12)], recent: [])
        let accounts = [Self.account(balanceDate: posted + 86_400),
                        Self.account(id: 2, type: .credit, balanceDate: posted + 86_400)]
        let with = SafeToSpendEngine.compute(accounts: accounts, charges: [Self.netflix(paying: 2)], paySchedule: nil,
                                             today: Self.today, calendar: Self.chicago, payments: payments)
        let without = SafeToSpendEngine.compute(accounts: accounts, charges: [Self.netflix(paying: 2)], paySchedule: nil,
                                                today: Self.today, calendar: Self.chicago, payments: .none)
        #expect(Self.month(with)?.remainderCents == Self.month(without)?.remainderCents)
    }

    @Test("a hold removes one occurrence only from an available balance fetched after it")
    func pendingSuppression() {
        let seen = CalendarDay(year: 2026, month: 9, day: 12).utcMidnight + 6 * 3_600
        let payments = BankPayments(latestPaid: [:], recent: [
            BankPayment(chargeId: 7, occurrence: CalendarDay(year: 2026, month: 9, day: 12), amountCents: 1549,
                        pending: true, postedInstant: nil, firstSeenAt: seen),
        ])
        func remainder(balanceAt: Int64) -> Int64? {
            let account = Self.account(balanceDate: balanceAt, available: 290000)
            return Self.month(SafeToSpendEngine.compute(
                accounts: [account], charges: [Self.netflix()], paySchedule: nil,
                today: Self.today, calendar: Self.chicago, payments: payments))?.remainderCents
        }
        #expect(remainder(balanceAt: seen + 3_600) == 290000)
        #expect(remainder(balanceAt: seen - 3_600) == 290000 - 1549)
    }

    @Test("a bill flagged maybe cancelled is still subtracted, and says why")
    func flaggedStillCounted() {
        var charge = Self.netflix()
        charge.inferredInactiveSince = "2026-08-12"
        charge.detectedLastSeenDay = "2026-07-05"
        let result = SafeToSpendEngine.compute(
            accounts: [Self.account(balanceDate: Self.today.utcMidnight)], charges: [charge], paySchedule: nil,
            today: Self.today, calendar: Self.chicago)
        let figure = Self.month(result)
        #expect(figure?.remainderCents == 300000 - 1549)
        #expect(figure?.obligations.first?.notSeenSince == CalendarDay(year: 2026, month: 7, day: 5))
    }
}
