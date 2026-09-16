import Foundation
import GRDB
import Testing
@testable import Spendable

@Suite("Deciding whether to ask at all")
struct SyncPolicyTests {
    static let now = Date(timeIntervalSince1970: 1_789_520_400)

    static func policy(
        balances: TimeInterval? = nil, transactions: TimeInterval? = nil, attempted: TimeInterval? = nil,
        failures: Int = 0, connected: Bool = true, warned: Bool = false, remaining: Int = 14
    ) -> SyncPolicy {
        var policy = SyncPolicy()
        policy.balancesSyncedAt = balances.map { now.addingTimeInterval(-$0) }
        policy.transactionsPulledAt = transactions.map { now.addingTimeInterval(-$0) }
        policy.attemptedAt = attempted.map { now.addingTimeInterval(-$0) }
        policy.failuresInARow = failures
        policy.isConnected = connected
        policy.serverWarnedAboutTheRate = warned
        policy.requestsRemaining = remaining
        return policy
    }

    @Test("an app with no bank connected does no work at all")
    func notConnected() {
        for trigger in [SyncPolicy.Trigger.launch, .scheduled, .wake, .dayChanged, .manual] {
            #expect(Self.policy(connected: false).decide(trigger: trigger, now: Self.now)
                == .skip("no bank connected"))
        }
    }

    @Test("opening the app ten times in an afternoon asks once")
    func launchPolling() {
        // Never synced: the first launch asks.
        #expect(Self.policy().decide(trigger: .launch, now: Self.now) == .sync(.balancesAndTransactions))
        // Synced an hour ago: nothing to gain.
        #expect(Self.policy(balances: 3_600, transactions: 3_600, attempted: 3_600)
            .decide(trigger: .launch, now: Self.now) == .skip("balances are recent"))
        // Seven hours later it is due again, and balances alone are enough.
        #expect(Self.policy(balances: 7 * 3_600, transactions: 7 * 3_600, attempted: 7 * 3_600)
            .decide(trigger: .launch, now: Self.now) == .sync(.balancesOnly))
    }

    @Test("transactions are pulled once a day, balances more often")
    func transactionCadence() {
        // Balances due, transactions pulled recently: balances only.
        #expect(Self.policy(balances: 7 * 3_600, transactions: 2 * 3_600, attempted: 7 * 3_600)
            .decide(trigger: .scheduled, now: Self.now) == .sync(.balancesOnly))
        // Transactions a day old: pull them too.
        #expect(Self.policy(balances: 7 * 3_600, transactions: 25 * 3_600, attempted: 7 * 3_600)
            .decide(trigger: .scheduled, now: Self.now) == .sync(.balancesAndTransactions))
        // Never pulled at all.
        #expect(Self.policy(balances: 7 * 3_600, attempted: 7 * 3_600)
            .decide(trigger: .scheduled, now: Self.now) == .sync(.balancesAndTransactions))
    }

    @Test("a Mac waking again and again with no network does not drain the day")
    func backOffAfterFailures() {
        // Tried five minutes ago: quiet, whatever the trigger.
        #expect(Self.policy(attempted: 300).decide(trigger: .wake, now: Self.now) == .skip("tried recently"))
        // Half an hour later, with no failures behind it, it may try.
        #expect(Self.policy(attempted: 31 * 60).decide(trigger: .wake, now: Self.now) == .sync(.balancesAndTransactions))
        // Three failures in a row: two hours of quiet.
        #expect(Self.policy(attempted: 31 * 60, failures: 3).decide(trigger: .wake, now: Self.now)
            == .skip("tried recently"))
        #expect(Self.policy(attempted: 3 * 3_600, failures: 3).decide(trigger: .wake, now: Self.now)
            == .sync(.balancesAndTransactions))
        // A long run of failures tops out at six hours rather than growing forever.
        #expect(SyncState.backOff(afterFailures: 9) == 6 * 3_600)
        #expect(SyncState.backOff(afterFailures: 0) == 0)
    }

    @Test("the owner asking is not the app deciding")
    func manualIgnoresTheQuietPeriod() {
        // Everything that silences a scheduled trigger leaves a manual one alone.
        #expect(Self.policy(balances: 60, transactions: 60, attempted: 60)
            .decide(trigger: .manual, now: Self.now) == .sync(.balancesOnly))
        #expect(Self.policy(attempted: 60, failures: 5)
            .decide(trigger: .manual, now: Self.now) == .sync(.balancesAndTransactions))
        // A manual refresh with a spent budget is still refused, because the budget is the thing
        // protecting the owner's access token.
        #expect(Self.policy(remaining: 0).decide(trigger: .manual, now: Self.now)
            == .skip("no requests left today"))
    }

    @Test("the server warning about the rate stops everything scheduled, but not the owner")
    func serverWarning() {
        #expect(Self.policy(warned: true).decide(trigger: .scheduled, now: Self.now)
            == .skip("SimpleFIN warned about the rate"))
        #expect(Self.policy(warned: true).decide(trigger: .manual, now: Self.now)
            == .sync(.balancesAndTransactions))
    }

    @Test("a spent budget stops every scheduled trigger")
    func budgetSpent() {
        for trigger in [SyncPolicy.Trigger.launch, .scheduled, .wake, .dayChanged] {
            #expect(Self.policy(remaining: 0).decide(trigger: trigger, now: Self.now)
                == .skip("no requests left today"))
        }
    }

    @Test("whether the app is connected is a database fact, never a keychain read")
    func connectionIsADatabaseFact() throws {
        let database = try AppDatabase.inMemory()
        // Nothing at all.
        #expect(try database.reader.read { db in try SyncPolicy.load(db, now: Self.now) }.isConnected == false)

        // A stored credential records the fact here, so a locked keychain cannot make the app
        // forget it is connected.
        try database.writer.write { db in try SyncState.setDate(db, SyncState.connectedAt, Self.now) }
        #expect(try database.reader.read { db in try SyncPolicy.load(db, now: Self.now) }.isConnected)

        // So does the existence of a synced account.
        let second = try AppDatabase.inMemory()
        try second.writer.write { db in
            try db.execute(sql: """
                INSERT INTO account (source, conn_id, external_id, display_name, currency, balance_cents, balance_date, created_at)
                VALUES ('simplefin', 'CON-A', 'ACT-1', 'Checking', 'USD', 0, 0, 0)
                """)
        }
        #expect(try second.reader.read { db in try SyncPolicy.load(db, now: Self.now) }.isConnected)
    }

    @Test("the state the gates read is written where the fact becomes true")
    func stateRoundTrips() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try SyncState.setDate(db, SyncState.balancesSyncedAt, Self.now)
            try SyncState.setInteger(db, SyncState.failuresInARow, 3)
        }
        let loaded = try database.reader.read { db in try SyncPolicy.load(db, now: Self.now) }
        #expect(loaded.balancesSyncedAt?.timeIntervalSince1970 == Self.now.timeIntervalSince1970)
        #expect(loaded.failuresInARow == 3)
        #expect(loaded.transactionsPulledAt == nil)

        try database.writer.write { db in try SyncState.clear(db, SyncState.balancesSyncedAt) }
        #expect(try database.reader.read { db in try SyncState.date(db, SyncState.balancesSyncedAt) } == nil)
    }
}

@Suite("A connection that is working, and one that is not")
struct SyncReportTests {
    @Test("running out of budget while filling in history is not a broken connection")
    func budgetRefusalIsNotAFailure() {
        var report = SyncReport()
        report.balancesRefreshed = true
        report.refusal = .backfillIsFullForToday
        report.stillFillingHistory = true
        #expect(report.connectionIsWorking)
        #expect(!report.needsAttention)
    }

    @Test("a rejected credential does need the owner")
    func credentialProblemNeedsAttention() {
        var report = SyncReport()
        report.credentialProblem = "No bank connection saved yet."
        #expect(!report.connectionIsWorking)
        #expect(report.needsAttention)
    }

    @Test("a failure before any balance arrived needs the owner; one after does not")
    func failureBeforeOrAfterBalances() {
        var early = SyncReport()
        early.failure = .couldNotReachServer(.offline)
        #expect(early.needsAttention)

        var late = SyncReport()
        late.balancesRefreshed = true
        late.failure = .couldNotReachServer(.offline)
        #expect(!late.needsAttention)
        #expect(late.connectionIsWorking)
    }

    @Test("a skipped run is not a failure")
    func skipped() {
        let report = SyncReport(skippedBecause: "balances are recent")
        #expect(report.connectionIsWorking)
        #expect(!report.needsAttention)
    }
}
