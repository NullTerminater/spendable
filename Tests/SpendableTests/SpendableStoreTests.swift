import Foundation
import GRDB
import Testing
@testable import Spendable

@Suite("The store that watches the data and keeps the figures current")
@MainActor
struct SpendableStoreTests {
    static var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// Waits for the observation to deliver, which it does on the main queue a moment after a write.
    func waitFor(_ store: SpendableStore, until condition: @escaping () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func seeded() throws -> AppDatabase {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            var checking = Account.manual(displayName: "Chase Checking", type: .checking, balanceCents: 124_000)
            try checking.insert(db)
            var rent = RecurringCharge.manual(
                name: "Rent", amountCents: 50_000, cadence: .monthly,
                nextDue: CalendarDay.today(in: Self.chicago).startOfMonth(in: Self.chicago),
                payingAccountId: checking.id, calendar: Self.chicago)
            try rent.insert(db)
        }
        return database
    }

    @Test("it picks up what is in the database and works out a figure")
    func loadsAndComputes() async throws {
        let store = SpendableStore(database: try seeded(), calendar: Self.chicago)
        await waitFor(store) { store.accounts.count == 1 }
        guard case .figures(let report) = store.result else {
            Issue.record("expected figures, got \(store.result)")
            return
        }
        #expect(report.month.contributedCents == 124_000)
        #expect(report.month.subtractedCents == 50_000)
        #expect(report.month.remainderCents == 74_000)
    }

    @Test("adding a bill changes the figure without anything else being touched")
    func respondsToAWrite() async throws {
        let database = try seeded()
        let store = SpendableStore(database: database, calendar: Self.chicago)
        await waitFor(store) { store.charges.count == 1 }

        let charge = RecurringCharge.manual(
            name: "Gym", amountCents: 4_500, cadence: .monthly,
            nextDue: CalendarDay.today(in: Self.chicago).startOfMonth(in: Self.chicago),
            payingAccountId: store.accounts.first?.id, calendar: Self.chicago)
        await store.save(charge)
        await waitFor(store) { store.charges.count == 2 }

        guard case .figures(let report) = store.result else {
            Issue.record("expected figures")
            return
        }
        #expect(report.month.subtractedCents == 54_500)
        #expect(report.month.remainderCents == 69_500)
    }

    @Test("the day rolling over moves the windows even though nothing was written")
    func dayRollover() async throws {
        let store = SpendableStore(database: try seeded(), calendar: Self.chicago)
        await waitFor(store) { store.accounts.count == 1 }
        let startingDay = store.today

        let twoDaysOn = Self.chicago.date(byAdding: .day, value: 2, to: Date())!
        store.dayMayHaveChanged(calendar: Self.chicago, now: twoDaysOn)

        #expect(store.today != startingDay)
        #expect(store.today == CalendarDay(twoDaysOn, in: Self.chicago))
        guard case .figures(let report) = store.result else {
            Issue.record("expected figures")
            return
        }
        #expect(report.today == store.today)
        #expect(report.month.windowStart == store.today.startOfMonth(in: Self.chicago))
        #expect(report.month.windowEnd == store.today.endOfMonth(in: Self.chicago))

        // Far enough on that the balances are too old to count. That the answer changes at all is
        // the proof the recomputation really used the new day rather than the cached one.
        let muchLater = Self.chicago.date(byAdding: .month, value: 2, to: Date())!
        store.dayMayHaveChanged(calendar: Self.chicago, now: muchLater)
        if case .figures = store.result {
            Issue.record("balances two months old should have stopped counting")
        }
    }

    @Test("being told the same day again costs nothing")
    func sameDayIsIgnored() async throws {
        let store = SpendableStore(database: try seeded(), calendar: Self.chicago)
        await waitFor(store) { store.accounts.count == 1 }
        let before = store.today
        store.dayMayHaveChanged(calendar: Self.chicago, now: Date())
        #expect(store.today == before)
    }

    @Test("marking a bill paid can take the money off the balance in the same step")
    func markPaidReducesBalance() async throws {
        let database = try seeded()
        let store = SpendableStore(database: database, calendar: Self.chicago)
        await waitFor(store) { store.charges.count == 1 }
        let rent = try #require(store.charges.first)

        await store.markPaid(rent, alsoReduceBalance: true, calendar: Self.chicago)
        await waitFor(store) { store.accounts.first?.balanceCents == 74_000 }

        #expect(store.accounts.first?.balanceCents == 74_000)
        guard case .figures(let report) = store.result else {
            Issue.record("expected figures")
            return
        }
        // The bill is gone from the window and the money is gone from the balance: the number is
        // unchanged, which is the whole point.
        #expect(report.month.subtractedCents == 0)
        #expect(report.month.remainderCents == 74_000)
    }

    @Test("marking a bill paid without updating the balance keeps the number where it was")
    func markPaidWithoutReducingBalance() async throws {
        let database = try seeded()
        let store = SpendableStore(database: database, calendar: Self.chicago)
        await waitFor(store) { store.charges.count == 1 }
        let rent = try #require(store.charges.first)

        await store.markPaid(rent, alsoReduceBalance: false, calendar: Self.chicago)
        await waitFor(store) { store.charges.first?.paidReflectedInBalance == false }

        #expect(store.accounts.first?.balanceCents == 124_000)
        guard case .figures(let report) = store.result else {
            Issue.record("expected figures")
            return
        }
        #expect(report.month.alreadyPaidCents == 50_000)
        #expect(report.month.remainderCents == 74_000)
    }

    @Test("turning on a savings account changes what is counted")
    func savingsToggle() async throws {
        let database = try seeded()
        try await database.writer.write { db in
            var savings = Account.manual(displayName: "Ally Savings", type: .savings, balanceCents: 200_000)
            try savings.insert(db)
        }
        let store = SpendableStore(database: database, calendar: Self.chicago)
        await waitFor(store) { store.accounts.count == 2 }
        let savings = try #require(store.accounts.first { $0.displayName == "Ally Savings" })

        await store.setIncludeInSafeToSpend(savings, true)
        await waitFor(store) { store.accounts.contains { $0.includeInSafeToSpend == true } }

        guard case .figures(let report) = store.result else {
            Issue.record("expected figures")
            return
        }
        #expect(report.month.contributedCents == 324_000)
    }

    @Test("a pay anchor makes the second figure appear")
    func payAnchor() async throws {
        let store = SpendableStore(database: try seeded(), calendar: Self.chicago)
        await waitFor(store) { store.accounts.count == 1 }
        guard case .figures(let before) = store.result else {
            Issue.record("expected figures")
            return
        }
        #expect(before.untilPayday == nil)

        await store.savePayAnchor(CalendarDay.today(in: Self.chicago).adding(days: -3, in: Self.chicago))
        await waitFor(store) { store.paySchedule != nil }

        guard case .figures(let after) = store.result else {
            Issue.record("expected figures")
            return
        }
        let payday = try #require(after.untilPayday)
        #expect(payday.payday != nil)
        #expect(payday.daysToPayday == 11)
    }
}
