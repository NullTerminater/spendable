import Foundation
import Testing
@testable import Spendable

/// The cases in this suite came out of an adversarial review of `docs/ENGINE.md` that ran before a
/// line of the engine was written. Each one is a number the owner could have been told wrongly.
@Suite("Safe to spend")
struct SafeToSpendTests {
    static var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    static let us = Locale(identifier: "en_US")

    static func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> CalendarDay {
        CalendarDay(year: year, month: month, day: dayOfMonth)
    }

    static func account(
        id: Int64,
        _ name: String,
        _ type: AccountType?,
        _ cents: Int64,
        asOf: CalendarDay,
        source: AccountSource = .manual,
        includeSavings: Bool? = nil,
        archived: Bool = false,
        currency: String = "USD",
        available: Int64? = nil,
        typeIsGuess: Bool = false,
        reversed: Bool = false,
        holdings: Int = 0
    ) -> Account {
        var account = Account.manual(displayName: name, type: type ?? .checking, balanceCents: cents)
        account.id = id
        account.source = source
        account.currency = currency
        account.balanceDate = asOf.epochSeconds(in: chicago)
        account.manualUpdatedAt = account.balanceDate
        account.availableCents = available
        account.includeInSafeToSpend = includeSavings
        account.archivedAt = archived ? asOf.epochSeconds(in: chicago) : nil
        account.amountsReversed = reversed
        account.holdingsCount = holdings
        if type == nil {
            account.userType = nil
            account.guessedType = nil
        } else if typeIsGuess {
            account.userType = nil
            account.guessedType = type
        }
        return account
    }

    static func bill(
        id: Int64,
        _ name: String,
        _ cents: Int64,
        cadence: Cadence = .monthly,
        due: CalendarDay,
        anchor: CalendarDay? = nil,
        paying: Int64?,
        kind: RecurringChargeKind = .bill,
        destination: Int64? = nil
    ) -> RecurringCharge {
        var charge = RecurringCharge.manual(
            name: name, kind: kind, amountCents: cents, cadence: cadence, nextDue: due,
            payingAccountId: paying, destinationAccountId: destination,
            now: Date(timeIntervalSince1970: 1_700_000_000), calendar: chicago)
        charge.id = id
        charge.anchorDate = (anchor ?? due).epochSeconds(in: chicago)
        return charge
    }

    static func report(
        accounts: [Account], charges: [RecurringCharge] = [], anchor: CalendarDay? = nil, today: CalendarDay
    ) -> SafeToSpendReport {
        let result = SafeToSpendEngine.compute(
            accounts: accounts, charges: charges,
            paySchedule: anchor.map { PaySchedule(anchor: $0) }, today: today, calendar: chicago)
        guard case .figures(let report) = result else {
            Issue.record("expected figures, got \(result)")
            fatalError("expected figures")
        }
        return report
    }

    static func text(_ report: SafeToSpendReport, _ figure: SpendableFigure) -> String {
        let sections = SafeToSpendNarrative.disclosure(report: report, figure: figure, locale: us, calendar: chicago)
        let under = SafeToSpendNarrative.linesUnderTheNumber(report: report, figure: figure, locale: us, calendar: chicago)
        return (under + sections.flatMap(\.lines)).joined(separator: "\n")
    }

    // MARK: 1–2. A bill that has been paid

    @Test("rent paid through October is not subtracted from September")
    func paidBillIsNotResubtracted() {
        let chase = Self.account(id: 1, "Chase Checking", .checking, 260_000, asOf: Self.day(2026, 9, 14))
        let rent = Self.bill(id: 1, "Rent", 140_000, due: Self.day(2026, 10, 1), anchor: Self.day(2026, 9, 1), paying: 1)
        let report = Self.report(accounts: [chase], charges: [rent], anchor: Self.day(2026, 9, 11), today: Self.day(2026, 9, 14))

        #expect(report.month.remainderCents == 260_000)
        #expect(report.month.subtractedCents == 0)
        #expect(report.untilPayday?.remainderCents == 260_000)
        #expect(report.untilPayday?.daysToPayday == 11)
        #expect(report.untilPayday?.perDayAllowanceCents == 23_636)
        #expect(Self.text(report, report.month).contains("None of your bills are due"))
    }

    @Test("a bill marked paid before the balance caught up keeps being subtracted, and says so")
    func paidButBalanceNotUpdated() {
        // The balance was entered on the morning of the 1st, before rent went out that afternoon.
        var chase = Self.account(id: 1, "Chase Checking", .checking, 400_000, asOf: Self.day(2026, 9, 1))
        chase.balanceDate = Int64(Self.day(2026, 9, 1).startOfDay(in: Self.chicago).timeIntervalSince1970) + 8 * 3_600
        var rent = Self.bill(id: 1, "Rent", 140_000, due: Self.day(2026, 9, 1), paying: 1)
        rent = rent.markingPaidOnce(
            balanceAlreadyUpdated: false, in: Self.chicago,
            now: Self.day(2026, 9, 1).startOfDay(in: Self.chicago).addingTimeInterval(14 * 3_600))

        let report = Self.report(accounts: [chase], charges: [rent], today: Self.day(2026, 9, 4))
        #expect(rent.nextExpectedDay(in: Self.chicago) == Self.day(2026, 10, 1))
        #expect(report.month.remainderCents == 260_000)
        #expect(report.month.alreadyPaidCents == 140_000)
        let words = Self.text(report, report.month)
        #expect(words.contains("already paid"))
        #expect(words.contains("still includes it"))
    }

    @Test("once the balance is updated after the payment, the bill stops being counted")
    func paidAndBalanceCaughtUp() {
        var chase = Self.account(id: 1, "Chase Checking", .checking, 260_000, asOf: Self.day(2026, 9, 2))
        chase.balanceDate = Int64(Self.day(2026, 9, 2).startOfDay(in: Self.chicago).timeIntervalSince1970)
        var rent = Self.bill(id: 1, "Rent", 140_000, due: Self.day(2026, 9, 1), paying: 1)
        rent = rent.markingPaidOnce(
            balanceAlreadyUpdated: false, in: Self.chicago,
            now: Self.day(2026, 9, 1).startOfDay(in: Self.chicago).addingTimeInterval(14 * 3_600))

        let report = Self.report(accounts: [chase], charges: [rent], today: Self.day(2026, 9, 4))
        #expect(report.month.remainderCents == 260_000)
        #expect(report.month.alreadyPaidCents == 0)
    }

    @Test("the same day, later hour: updating the balance after marking paid releases the bill")
    func paidAndBalanceCaughtUpSameDay() {
        var chase = Self.account(id: 1, "Chase Checking", .checking, 260_000, asOf: Self.day(2026, 9, 1))
        chase.balanceDate = Int64(Self.day(2026, 9, 1).startOfDay(in: Self.chicago).timeIntervalSince1970) + 18 * 3_600
        var rent = Self.bill(id: 1, "Rent", 140_000, due: Self.day(2026, 9, 1), paying: 1)
        rent = rent.markingPaidOnce(
            balanceAlreadyUpdated: false, in: Self.chicago,
            now: Self.day(2026, 9, 1).startOfDay(in: Self.chicago).addingTimeInterval(14 * 3_600))

        let report = Self.report(accounts: [chase], charges: [rent], today: Self.day(2026, 9, 4))
        #expect(report.month.alreadyPaidCents == 0)
        #expect(report.month.remainderCents == 260_000)
    }

    // MARK: 5–8. Windows

    @Test("a weekly bill falling five times in a month is counted five times")
    func weeklyFiveTimes() {
        let chase = Self.account(id: 1, "Chase Checking", .checking, 50_000, asOf: Self.day(2026, 10, 1))
        let gym = Self.bill(id: 1, "Gym", 2_500, cadence: .weekly, due: Self.day(2026, 10, 1), paying: 1)
        let report = Self.report(accounts: [chase], charges: [gym], today: Self.day(2026, 10, 1))
        #expect(report.month.subtractedCents == 12_500)
        #expect(report.month.remainderCents == 37_500)
        #expect(report.month.subtractedObligations.count == 5)
        #expect(Self.text(report, report.month).contains("Gym $25.00 — due today"))
    }

    @Test("the until-payday window reaches into next month and the month window does not")
    func crossMonthPaydayWindow() {
        let chase = Self.account(id: 1, "Chase Checking", .checking, 124_000, asOf: Self.day(2026, 9, 28))
        let rent = Self.bill(id: 1, "Rent", 50_000, due: Self.day(2026, 10, 1), anchor: Self.day(2026, 9, 1), paying: 1)
        let report = Self.report(accounts: [chase], charges: [rent], anchor: Self.day(2026, 9, 5), today: Self.day(2026, 9, 28))

        #expect(report.month.remainderCents == 124_000)
        let payday = try! #require(report.untilPayday)
        #expect(payday.payday == Self.day(2026, 10, 3))
        #expect(payday.windowEnd == Self.day(2026, 10, 2))
        #expect(payday.remainderCents == 74_000)
        #expect(payday.daysToPayday == 5)
        #expect(payday.perDayAllowanceCents == 14_800)

        let words = Self.text(report, payday)
        #expect(words.contains("October 3"))
        #expect(!words.contains("this month"))
    }

    @Test("a bill due on payday itself is left out of the payday figure and named")
    func billOnPaydayIsNamed() {
        let chase = Self.account(id: 1, "Chase Checking", .checking, 130_000, asOf: Self.day(2026, 9, 14))
        let rent = Self.bill(id: 1, "Rent", 120_000, due: Self.day(2026, 9, 25), paying: 1)
        let report = Self.report(accounts: [chase], charges: [rent], anchor: Self.day(2026, 9, 11), today: Self.day(2026, 9, 14))

        #expect(report.month.remainderCents == 10_000)
        let payday = try! #require(report.untilPayday)
        #expect(payday.remainderCents == 130_000)
        #expect(payday.perDayAllowanceCents == 11_818)
        let holdBack = try! #require(payday.holdBack)
        #expect(holdBack.totalCents == 120_000)
        #expect(holdBack.names == ["Rent"])
        #expect(Self.text(report, payday).contains("more is due before the month ends"))
    }

    @Test("bills due after payday are named with their total")
    func holdBackClause() {
        let chase = Self.account(id: 1, "Chase Checking", .checking, 240_000, asOf: Self.day(2026, 9, 14))
        let charges = [
            Self.bill(id: 1, "Rent", 140_000, due: Self.day(2026, 9, 1), paying: 1),
            Self.bill(id: 2, "Netflix", 1_599, due: Self.day(2026, 9, 8), paying: 1),
            Self.bill(id: 3, "Car insurance", 14_200, due: Self.day(2026, 9, 28), paying: 1),
        ]
        let report = Self.report(accounts: [chase], charges: charges, anchor: Self.day(2026, 9, 11), today: Self.day(2026, 9, 14))

        #expect(report.month.subtractedCents == 155_799)
        #expect(report.month.remainderCents == 84_201)
        #expect(SafeToSpendDisplay.headline(report.month.remainderCents, locale: Self.us) == "$842")

        let payday = try! #require(report.untilPayday)
        #expect(payday.subtractedCents == 141_599)
        #expect(payday.remainderCents == 98_401)
        #expect(payday.perDayAllowanceCents == 8_945)
        let holdBack = try! #require(payday.holdBack)
        #expect(holdBack.totalCents == 14_200)
        #expect(holdBack.names == ["Car insurance"])
    }

    // MARK: 9–12. Accounts that are not counted

    @Test("a dead account takes its own bills out of the sum with it")
    func deadAccountNetPositive() {
        let accounts = [
            Self.account(id: 1, "Chase Checking", .checking, 312_000, asOf: Self.day(2026, 8, 14)),
            Self.account(id: 2, "Wallet cash", .cash, 4_000, asOf: Self.day(2026, 9, 14)),
        ]
        let charges = [
            Self.bill(id: 1, "Rent", 120_000, due: Self.day(2026, 9, 1), paying: 1),
            Self.bill(id: 2, "Spotify", 1_200, due: Self.day(2026, 9, 5), paying: 1),
        ]
        let report = Self.report(accounts: accounts, charges: charges, anchor: Self.day(2026, 9, 11), today: Self.day(2026, 9, 14))

        #expect(report.month.contributedCents == 4_000)
        #expect(report.month.subtractedCents == 0)
        #expect(report.month.remainderCents == 4_000)

        let block = try! #require(report.month.heldOutBlocks.first)
        #expect(block.accountName == "Chase Checking")
        #expect(block.balanceCents == 312_000)
        #expect(block.obligationsCents == 121_200)
        #expect(block.netCents == 190_800)
        #expect(Self.text(report, report.month).contains("isn't counted"))
    }

    @Test("a dead account that owes more than it holds says so directly under the number")
    func deadAccountNetNegativeIsPromoted() {
        let accounts = [
            Self.account(id: 1, "Chase Checking", .checking, 5_000, asOf: Self.day(2026, 8, 14)),
            Self.account(id: 2, "Ally Checking", .checking, 200_000, asOf: Self.day(2026, 9, 14)),
            Self.account(id: 3, "Wallet cash", .cash, 4_000, asOf: Self.day(2026, 9, 14)),
        ]
        let charges = [Self.bill(id: 1, "Rent", 120_000, due: Self.day(2026, 9, 1), paying: 1)]
        let report = Self.report(accounts: accounts, charges: charges, today: Self.day(2026, 9, 14))

        #expect(report.month.remainderCents == 204_000)
        let block = try! #require(report.month.heldOutBlocks.first)
        #expect(block.netCents == -115_000)

        let under = SafeToSpendNarrative.linesUnderTheNumber(
            report: report, figure: report.month, locale: Self.us, calendar: Self.chicago)
        #expect(under.contains { $0.contains("Chase Checking") && $0.contains("more than it holds") })
    }

    @Test("when no account can be counted there is no number at all, not a zero")
    func everyAccountDead() {
        let accounts = [
            Self.account(id: 1, "Chase Checking", .checking, 312_000, asOf: Self.day(2026, 9, 4)),
            Self.account(id: 2, "Wallet cash", .cash, 4_000, asOf: Self.day(2026, 9, 4)),
        ]
        let charges = [Self.bill(id: 1, "Rent", 140_000, due: Self.day(2026, 9, 1), paying: 1)]
        let result = SafeToSpendEngine.compute(
            accounts: accounts, charges: charges, paySchedule: PaySchedule(anchor: Self.day(2026, 9, 11)),
            today: Self.day(2026, 9, 14), calendar: Self.chicago)

        guard case .nothingCountable(let classified) = result else {
            Issue.record("expected nothingCountable, got \(result)")
            return
        }
        #expect(classified.count == 2)
        #expect(classified.allSatisfy { $0.standing == .heldOut(.stoppedUpdating) })
    }

    @Test("archived balances stay silent, while their orphaned bills are named and still subtracted")
    func archivedAccount() {
        let accounts = [
            Self.account(id: 1, "Chase Checking", .checking, 90_000, asOf: Self.day(2026, 9, 14)),
            Self.account(id: 2, "Old Credit Union", .checking, 0, asOf: Self.day(2026, 9, 10), archived: true),
        ]
        let charges = [Self.bill(id: 1, "Gym", 8_500, due: Self.day(2026, 9, 20), paying: 2)]
        let report = Self.report(accounts: accounts, charges: charges, today: Self.day(2026, 9, 14))

        #expect(report.month.remainderCents == 81_500)
        #expect(report.month.heldOutBlocks.isEmpty)
        let under = SafeToSpendNarrative.linesUnderTheNumber(
            report: report, figure: report.month, locale: Self.us, calendar: Self.chicago)
        #expect(under.count == 1)
        #expect(under[0].contains("Gym") && under[0].contains("Old Credit Union"))
        #expect(under[0].contains("which you've put away"))
        #expect(!under.contains { $0.contains("stopped updating") || $0.contains("isn't counted") })
        #expect(Self.text(report, report.month).contains("which you've put away"))
    }

    // MARK: 13–17. Cards, transfers, untyped accounts

    @Test("bills on a card with no statement are counted here rather than nowhere")
    func cardWithoutStatement() {
        let accounts = [
            Self.account(id: 1, "Chase Checking", .checking, 240_000, asOf: Self.day(2026, 9, 14)),
            Self.account(id: 2, "Chase Sapphire", .credit, -118_000, asOf: Self.day(2026, 9, 14)),
        ]
        let charges = [
            Self.bill(id: 1, "Netflix", 1_599, due: Self.day(2026, 9, 8), paying: 2),
            Self.bill(id: 2, "Spotify", 1_199, due: Self.day(2026, 9, 12), paying: 2),
            Self.bill(id: 3, "Verizon", 8_500, due: Self.day(2026, 9, 20), paying: 2),
            Self.bill(id: 4, "Car insurance", 14_200, due: Self.day(2026, 9, 25), paying: 2),
            Self.bill(id: 5, "Rent", 140_000, due: Self.day(2026, 9, 1), paying: 1),
        ]
        let report = Self.report(accounts: accounts, charges: charges, today: Self.day(2026, 9, 14))

        #expect(report.month.contributedCents == 240_000)
        #expect(report.month.subtractedCents == 165_498)
        #expect(report.month.remainderCents == 74_502)
        #expect(SafeToSpendDisplay.headline(report.month.remainderCents, locale: Self.us) == "$745")
        let words = Self.text(report, report.month)
        #expect(words.contains("no statement entered"))
        #expect(words.contains("You owe $1,180.00 on Chase Sapphire"))
    }

    @Test("when a card is paid by a standing transfer, only that payment is counted")
    func cardPaidByTransfer() {
        let accounts = [
            Self.account(id: 1, "Chase Checking", .checking, 240_000, asOf: Self.day(2026, 9, 14)),
            Self.account(id: 2, "Chase Sapphire", .credit, -118_000, asOf: Self.day(2026, 9, 14)),
        ]
        let charges = [
            Self.bill(id: 1, "Netflix", 1_599, due: Self.day(2026, 9, 8), paying: 2),
            Self.bill(id: 2, "Spotify", 1_199, due: Self.day(2026, 9, 12), paying: 2),
            Self.bill(id: 3, "Verizon", 8_500, due: Self.day(2026, 9, 20), paying: 2),
            Self.bill(id: 4, "Car insurance", 14_200, due: Self.day(2026, 9, 25), paying: 2),
            Self.bill(id: 5, "Sapphire autopay", 50_000, due: Self.day(2026, 9, 20), paying: 1,
                      kind: .transfer, destination: 2),
        ]
        let report = Self.report(accounts: accounts, charges: charges, today: Self.day(2026, 9, 14))

        #expect(report.month.subtractedCents == 50_000)
        #expect(report.month.remainderCents == 190_000)
        #expect(report.month.listedNotSubtracted.count == 4)
        #expect(Self.text(report, report.month).contains("counted through the payment you make to that card"))
    }

    @Test("a transfer into savings that isn't counted leaves the money; into savings that is, it doesn't")
    func transferDestinationDecides() {
        func build(includeSavings: Bool?, destination: Int64?) -> SafeToSpendReport {
            let accounts = [
                Self.account(id: 1, "Chase Checking", .checking, 200_000, asOf: Self.day(2026, 9, 14)),
                Self.account(id: 2, "Ally Savings", .savings, 500_000, asOf: Self.day(2026, 9, 14),
                             includeSavings: includeSavings),
            ]
            let charges = [Self.bill(id: 1, "Savings transfer", 50_000, due: Self.day(2026, 9, 20),
                                     paying: 1, kind: .transfer, destination: destination)]
            return Self.report(accounts: accounts, charges: charges, today: Self.day(2026, 9, 14))
        }

        let excluded = build(includeSavings: nil, destination: 2)
        #expect(excluded.month.contributedCents == 200_000)
        #expect(excluded.month.remainderCents == 150_000)

        let included = build(includeSavings: true, destination: 2)
        #expect(included.month.contributedCents == 700_000)
        #expect(included.month.remainderCents == 700_000)
        #expect(Self.text(included, included.month).contains("already counted"))

        let noDestination = build(includeSavings: true, destination: nil)
        #expect(noDestination.month.remainderCents == 650_000)
        #expect(included.month.remainderCents - noDestination.month.remainderCents == 50_000)
    }

    @Test("an account with no type contributes nothing, and neither do its bills")
    func untypedAccount() {
        let accounts = [
            Self.account(id: 1, "Household 4412", nil, 400_000, asOf: Self.day(2026, 9, 14), source: .simplefin),
            Self.account(id: 2, "Chase Checking", .checking, 200_000, asOf: Self.day(2026, 9, 14)),
        ]
        let charges = [Self.bill(id: 1, "Rent", 180_000, due: Self.day(2026, 9, 1), paying: 1)]
        let report = Self.report(accounts: accounts, charges: charges, today: Self.day(2026, 9, 14))
        #expect(report.month.remainderCents == 200_000)
        #expect(Self.text(report, report.month).contains("what kind of account it is"))

        var typed = accounts
        typed[0].userType = .checking
        let after = Self.report(accounts: typed, charges: charges, today: Self.day(2026, 9, 14))
        #expect(after.month.remainderCents == 420_000)
    }

    // MARK: 18–20. Empty states

    @Test("with no accounts there is no number, and nothing that reads like one")
    func noAccounts() {
        let result = SafeToSpendEngine.compute(
            accounts: [], charges: [], paySchedule: nil, today: Self.day(2026, 9, 14), calendar: Self.chicago)
        #expect(result == .noAccountsYet)
    }

    @Test("no bills at all reads differently from no bills due")
    func noBills() {
        let chase = Self.account(id: 1, "Chase Checking", .checking, 312_000, asOf: Self.day(2026, 9, 14))
        let none = Self.report(accounts: [chase], today: Self.day(2026, 9, 14))
        #expect(none.month.remainderCents == 312_000)
        #expect(none.hasNoBillsAtAll)
        let noneWords = Self.text(none, none.month)
        #expect(noneWords.contains("haven't told me about any bills yet"))
        #expect(noneWords.contains("only because nothing has been subtracted"))

        let later = Self.report(
            accounts: [chase],
            charges: [Self.bill(id: 1, "Rent", 140_000, due: Self.day(2026, 11, 1), paying: 1)],
            today: Self.day(2026, 9, 14))
        #expect(later.month.remainderCents == 312_000)
        #expect(!later.hasNoBillsAtAll)
        let laterWords = Self.text(later, later.month)
        #expect(laterWords.contains("None of your bills are due"))
        #expect(!laterWords.contains("haven't told me about any bills yet"))
    }

    @Test("with no payday set the month figure still works and the payday figure is absent")
    func noPayAnchor() {
        let chase = Self.account(id: 1, "Chase Checking", .checking, 124_000, asOf: Self.day(2026, 9, 14))
        let rent = Self.bill(id: 1, "Rent", 50_000, due: Self.day(2026, 9, 1), paying: 1)
        let report = Self.report(accounts: [chase], charges: [rent], today: Self.day(2026, 9, 14))
        #expect(report.month.remainderCents == 74_000)
        #expect(report.untilPayday == nil)
    }

    // MARK: 21–23. Showing the number

    @Test("exactly nothing left says so, and is not the same as being short")
    func exactlyZero() {
        let chase = Self.account(id: 1, "Chase Checking", .checking, 140_000, asOf: Self.day(2026, 9, 14))
        let rent = Self.bill(id: 1, "Rent", 140_000, due: Self.day(2026, 9, 1), paying: 1)
        let report = Self.report(accounts: [chase], charges: [rent], today: Self.day(2026, 9, 14))

        #expect(report.month.remainderCents == 0)
        #expect(SafeToSpendDisplay.headline(0, locale: Self.us) == "$0.00")
        #expect(Self.text(report, report.month).contains("nothing left"))
        #expect(SafeToSpendDisplay.compact(0, needsAttention: false, locale: Self.us)
            != SafeToSpendDisplay.compact(-12_060, needsAttention: true, locale: Self.us))
    }

    @Test("being short shows zero with the shortfall beside it, rounded away from zero")
    func shortfall() {
        let chase = Self.account(id: 1, "Chase Checking", .checking, 127_940, asOf: Self.day(2026, 9, 14))
        let rent = Self.bill(id: 1, "Rent", 140_000, due: Self.day(2026, 9, 1), paying: 1)
        let report = Self.report(accounts: [chase], charges: [rent], anchor: Self.day(2026, 9, 11), today: Self.day(2026, 9, 14))

        #expect(report.month.remainderCents == -12_060)
        #expect(SafeToSpendDisplay.headline(-12_060, locale: Self.us) == "$0 (balance: -$121)")
        #expect(SafeToSpendDisplay.headline(-40, locale: Self.us) == "$0 (balance: -$0.40)")
        #expect(report.untilPayday?.perDayAllowanceCents == 0)
        #expect(SafeToSpendDisplay.perDay(0, remainderCents: -12_060, locale: Self.us) == "$0 a day")
        #expect(Self.text(report, report.month).contains("$121 short of this month's bills"))
    }

    @Test("money under a dollar is shown to the cent, never as a bare zero")
    func underADollar() {
        func remainder(_ balance: Int64) -> SpendableFigure {
            let chase = Self.account(id: 1, "Chase Checking", .checking, balance, asOf: Self.day(2026, 9, 14))
            let rent = Self.bill(id: 1, "Rent", 140_000, due: Self.day(2026, 9, 1), paying: 1)
            return Self.report(accounts: [chase], charges: [rent], anchor: Self.day(2026, 9, 11),
                               today: Self.day(2026, 9, 14)).untilPayday!
        }

        let a = remainder(140_075)
        #expect(a.remainderCents == 75)
        #expect(SafeToSpendDisplay.headline(75, locale: Self.us) == "$0.75")
        #expect(a.perDayAllowanceCents == 6)
        #expect(SafeToSpendDisplay.perDay(6, remainderCents: 75, locale: Self.us) == "about $0.06 a day")

        let b = remainder(140_005)
        #expect(b.remainderCents == 5)
        #expect(SafeToSpendDisplay.headline(5, locale: Self.us) == "$0.05")
        #expect(b.perDayAllowanceCents == 0)
        // Money is left, so the app says nothing about a daily share rather than saying "$0 a day".
        #expect(SafeToSpendDisplay.perDay(0, remainderCents: 5, locale: Self.us) == nil)

        let c = remainder(142_199)
        #expect(c.remainderCents == 2_199)
        #expect(SafeToSpendDisplay.headline(2_199, locale: Self.us) == "$21")
        #expect(c.perDayAllowanceCents == 199)
        #expect(SafeToSpendDisplay.perDay(199, remainderCents: 2_199, locale: Self.us) == "about $1.99 a day")
    }

    // MARK: 24. Freshness counts days, not hours

    @Test("how old a balance is depends on the date, not the time of day it was taken")
    func freshnessIgnoresTimeOfDay() {
        func standing(balanceAt: Date, todayIs: CalendarDay) -> AccountStanding {
            var account = Self.account(id: 1, "Chase Checking", .checking, 312_000, asOf: Self.day(2026, 9, 14))
            account.balanceDate = Int64(balanceAt.timeIntervalSince1970)
            return SafeToSpendEngine.classify(account, today: todayIs, calendar: Self.chicago).standing
        }
        let c = Self.chicago
        let lateOnTheSixth = c.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 23))!
        let startOfTheSeventh = c.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 0))!
        let lateOnTheTenth = c.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 23))!

        // Eight days: too old to count, whatever the hour.
        #expect(standing(balanceAt: lateOnTheSixth, todayIs: Self.day(2026, 9, 14)) == .heldOut(.stoppedUpdating))
        // Seven days: counted, but old enough to mention.
        #expect(standing(balanceAt: startOfTheSeventh, todayIs: Self.day(2026, 9, 14)) == .counted(.stale))
        #expect(standing(balanceAt: lateOnTheTenth, todayIs: Self.day(2026, 9, 14)) == .counted(.stale))
    }

    @Test("a balance dated in the future is treated as today, never as tomorrow")
    func futureBalanceDate() {
        let account = Self.account(id: 1, "Chase Checking", .checking, 100_000, asOf: Self.day(2026, 9, 20))
        let classified = SafeToSpendEngine.classify(account, today: Self.day(2026, 9, 14), calendar: Self.chicago)
        #expect(classified.asOf == Self.day(2026, 9, 14))
        #expect(classified.standing == .counted(.fresh))
    }

    // MARK: 25. A paycheck that has landed but is not in the balance

    @Test("pay that has not reached the balance is named instead of read as a shortfall")
    func payPending() {
        let chase = Self.account(id: 1, "Chase Checking", .checking, 30_000, asOf: Self.day(2026, 9, 24))
        let charges = [
            Self.bill(id: 1, "Rent", 140_000, due: Self.day(2026, 10, 1), paying: 1),
            Self.bill(id: 2, "Spotify", 1_200, due: Self.day(2026, 10, 5), paying: 1),
        ]
        let report = Self.report(accounts: [chase], charges: charges, anchor: Self.day(2026, 9, 25), today: Self.day(2026, 9, 25))

        let payday = try! #require(report.untilPayday)
        #expect(payday.payday == Self.day(2026, 10, 9))
        #expect(payday.windowEnd == Self.day(2026, 10, 8))
        #expect(payday.remainderCents == -111_200)
        #expect(payday.payPending)
        #expect(SafeToSpendDisplay.headline(payday.remainderCents, locale: Self.us) == "$0 (balance: -$1,112)")
        let words = Self.text(report, payday)
        #expect(words.contains("isn't in these balances yet"))
        // The cause replaces the shortfall sentence rather than sitting beside it. Telling someone
        // they are short when their wages have simply not landed in the app yet is the false alarm
        // the whole design is against.
        #expect(!words.contains("short of the bills due before"))
        #expect(!words.contains("short of this month's bills"))
        #expect(words.contains("Counted without it"))
    }

    @Test("with no pending pay, being short is still said plainly")
    func shortfallStillSaidWhenPayIsNotPending() {
        let chase = Self.account(id: 1, "Chase Checking", .checking, 127_940, asOf: Self.day(2026, 9, 14))
        let rent = Self.bill(id: 1, "Rent", 140_000, due: Self.day(2026, 9, 1), paying: 1)
        let report = Self.report(accounts: [chase], charges: [rent], anchor: Self.day(2026, 9, 11), today: Self.day(2026, 9, 14))
        #expect(report.month.payPending == false)
        #expect(Self.text(report, report.month).contains("short of this month's bills"))
    }

    @Test("pay is not reported as pending once a balance from payday or later arrives")
    func payNotPending() {
        let accounts = [
            Self.account(id: 1, "Chase Checking", .checking, 30_000, asOf: Self.day(2026, 9, 24)),
            Self.account(id: 2, "Wallet cash", .cash, 2_000, asOf: Self.day(2026, 9, 25)),
        ]
        let report = Self.report(accounts: accounts, anchor: Self.day(2026, 9, 25), today: Self.day(2026, 9, 25))
        #expect(report.untilPayday?.payPending == false)
    }

    // MARK: Balances

    @Test("the bank's available balance is used only once the owner has confirmed the account type")
    func availableBalanceGate() {
        var confirmed = Self.account(id: 1, "Chase Checking", .checking, 100_000, asOf: Self.day(2026, 9, 14),
                                     source: .simplefin, available: 90_000)
        confirmed.userType = .checking
        let a = SafeToSpendEngine.classify(confirmed, today: Self.day(2026, 9, 14), calendar: Self.chicago)
        #expect(a.contributedCents == 90_000)
        #expect(a.usedAvailableBalance)

        var guessed = Self.account(id: 1, "Chase Checking", .checking, 100_000, asOf: Self.day(2026, 9, 14),
                                   source: .simplefin, available: 90_000, typeIsGuess: true)
        // M4 has already checked that this guessed deposit account holds money, not shares.
        guessed.holdingsObservedAt = guessed.balanceDate
        let b = SafeToSpendEngine.classify(guessed, today: Self.day(2026, 9, 14), calendar: Self.chicago)
        #expect(b.contributedCents == 100_000)
        #expect(!b.usedAvailableBalance)
    }

    @Test("an available balance larger than the balance looks like a credit line and is ignored")
    func availableLargerThanBalance() {
        var account = Self.account(id: 1, "Chase Total", .checking, 30_000, asOf: Self.day(2026, 9, 14),
                                   source: .simplefin, available: 430_000)
        account.userType = .checking
        let classified = SafeToSpendEngine.classify(account, today: Self.day(2026, 9, 14), calendar: Self.chicago)
        #expect(classified.contributedCents == 30_000)
        #expect(classified.ignoredAvailableBalance)
    }

    @Test("an account marked as having its amounts reversed contributes the other sign")
    func amountsReversed() {
        let account = Self.account(id: 1, "Odd Bank", .checking, -100_000, asOf: Self.day(2026, 9, 14), reversed: true)
        let classified = SafeToSpendEngine.classify(account, today: Self.day(2026, 9, 14), calendar: Self.chicago)
        #expect(classified.contributedCents == 100_000)
    }

    @Test("a credit card is never money, whichever sign the bank uses")
    func cardsNeverCount() {
        for balance in [Int64(-118_000), Int64(118_000)] {
            let accounts = [
                Self.account(id: 1, "Chase Checking", .checking, 30_000, asOf: Self.day(2026, 9, 14)),
                Self.account(id: 2, "Chase Sapphire", .credit, balance, asOf: Self.day(2026, 9, 14)),
            ]
            let report = Self.report(accounts: accounts, today: Self.day(2026, 9, 14))
            #expect(report.month.contributedCents == 30_000)
        }
    }

    @Test("savings counts only when the owner asks for it")
    func savingsToggle() {
        let base = Self.account(id: 1, "Chase Checking", .checking, 30_000, asOf: Self.day(2026, 9, 14))
        let excluded = Self.account(id: 2, "Ally Savings", .savings, 120_000, asOf: Self.day(2026, 9, 14))
        let included = Self.account(id: 2, "Ally Savings", .savings, 120_000, asOf: Self.day(2026, 9, 14), includeSavings: true)

        #expect(Self.report(accounts: [base, excluded], today: Self.day(2026, 9, 14)).month.contributedCents == 30_000)
        let withSavings = Self.report(accounts: [base, included], today: Self.day(2026, 9, 14))
        #expect(withSavings.month.contributedCents == 150_000)
        #expect(Self.text(withSavings, withSavings.month).contains("which you asked me to count"))
    }

    @Test("an account in another currency is left out and said so")
    func nonUSD() {
        let accounts = [
            Self.account(id: 1, "Chase Checking", .checking, 30_000, asOf: Self.day(2026, 9, 14)),
            Self.account(id: 2, "Revolut EUR", .checking, 500_000, asOf: Self.day(2026, 9, 14), currency: "EUR"),
        ]
        let report = Self.report(accounts: accounts, today: Self.day(2026, 9, 14))
        #expect(report.month.contributedCents == 30_000)
        let explanation = Self.text(report, report.month)
        #expect(explanation.contains("Revolut EUR isn't in the figures above"))
        #expect(explanation.lowercased().contains("euro"))
        #expect(!explanation.contains("$5,000"))
    }

    @Test("a confirmed bill with no due date is named rather than silently dropped")
    func undatedCharge() {
        let chase = Self.account(id: 1, "Chase Checking", .checking, 100_000, asOf: Self.day(2026, 9, 14))
        var gym = Self.bill(id: 1, "Gym", 4_500, due: Self.day(2026, 9, 20), paying: 1)
        gym.nextExpectedDate = nil
        let report = Self.report(accounts: [chase], charges: [gym], today: Self.day(2026, 9, 14))
        #expect(report.month.remainderCents == 100_000)
        #expect(report.undatedCharges.count == 1)
        #expect(Self.text(report, report.month).contains("I don't know when this is next due"))
    }

    @Test("suggested and dismissed bills never move the number")
    func onlyConfirmedCounts() {
        let chase = Self.account(id: 1, "Chase Checking", .checking, 100_000, asOf: Self.day(2026, 9, 14))
        var suggested = Self.bill(id: 1, "Maybe Netflix", 1_599, due: Self.day(2026, 9, 20), paying: 1)
        suggested.status = .suggested
        var dismissed = Self.bill(id: 2, "Not a bill", 5_000, due: Self.day(2026, 9, 20), paying: 1)
        dismissed.status = .dismissed
        let report = Self.report(accounts: [chase], charges: [suggested, dismissed], today: Self.day(2026, 9, 14))
        #expect(report.month.remainderCents == 100_000)
        #expect(report.month.obligations.isEmpty)
    }

    @Test("the disclosure's own numbers add up to the headline")
    func disclosureArithmeticIsClosed() {
        let accounts = [
            Self.account(id: 1, "Chase Checking", .checking, 124_000, asOf: Self.day(2026, 9, 14)),
            Self.account(id: 2, "Wallet cash", .cash, 4_000, asOf: Self.day(2026, 9, 14)),
        ]
        let charges = [
            Self.bill(id: 1, "Rent", 50_000, due: Self.day(2026, 9, 20), paying: 1),
            Self.bill(id: 2, "Spotify", 1_200, due: Self.day(2026, 9, 22), paying: 1),
        ]
        let report = Self.report(accounts: accounts, charges: charges, today: Self.day(2026, 9, 14))
        let figure = report.month
        let listed = figure.subtractedObligations.reduce(Int64(0)) { $0 + $1.amountCents }
        #expect(figure.contributedCents == 128_000)
        #expect(listed == figure.subtractedCents)
        #expect(figure.contributedCents - figure.subtractedCents == figure.remainderCents)
        #expect(figure.remainderCents == 76_800)
    }

    // MARK: The owner's rule of 15 September 2026 — shares are never spending money

    @Test("an account holding shares is never counted, whatever it is called or typed")
    func sharesAreNeverSpendable() {
        let today = Self.day(2026, 9, 16)
        // The public demo's own savings account: six figures, one holding, and a name that reads
        // like ordinary savings. A name-based guess alone would have counted it.
        let portfolio = Self.account(id: 1, "SimpleFIN Savings", .savings, 11_538_551, asOf: today,
                                     source: .simplefin, includeSavings: true, holdings: 1)
        let spending = Self.account(id: 2, "Cash", .checking, 40_000, asOf: today)

        let result = SafeToSpendEngine.compute(
            accounts: [portfolio, spending], charges: [], paySchedule: nil,
            today: today, calendar: Self.chicago)
        guard case .figures(let report) = result else { #expect(Bool(false), "no figure"); return }

        let held = try! #require(report.accounts.first { $0.id == 1 })
        #expect(held.standing == .heldOut(.holdsInvestments))
        #expect(held.contributedCents == 0)
        // Opting in is what would have made this dangerous: the switch says "count this", and the
        // account still must not be counted.
        #expect(report.month.contributedCents == 40_000)
    }

    @Test("holdings are decided before the type is, so a share account is never asked about")
    func holdingsBeatEveryType() {
        let today = Self.day(2026, 9, 16)
        for type: AccountType? in [nil, .credit, .checking, .savings] {
            let account = Self.account(id: 1, "Fidelity Cash Management", type, 1_841_266, asOf: today,
                                       source: .simplefin, includeSavings: true, holdings: 3)
            let classified = SafeToSpendEngine.classify(account, today: today, calendar: Self.chicago)
            // Not `.typeNotSet` — that would put the four-way type question on a share portfolio,
            // and its "credit" answer prints "You owe $18,412.66" about money nobody owes. Not
            // `.creditCard` either, for the same reason.
            #expect(classified.standing == .heldOut(.holdsInvestments),
                    "holdings lost to type \(String(describing: type))")
            #expect(classified.contributedCents == 0)
        }
    }
}
