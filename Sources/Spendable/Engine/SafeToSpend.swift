import Foundation

// The safe-to-spend engine. Pure: values in, values out. It opens no database, reads no clock and
// imports no GRDB, so every rule in docs/ENGINE.md can be tested with literal days and amounts.
//
// One classification of each account drives the total, the choice of which bills come off it, and
// every sentence shown. The headline and the explanation are therefore the same arithmetic by
// construction; they cannot drift apart.

// MARK: - How an account stands

enum Freshness: Equatable, Sendable {
    /// Up to date.
    case fresh
    /// Old enough to say so, recent enough to still count.
    case stale
}

/// Why an account's money is not in the total.
enum HeldOutReason: Equatable, Sendable {
    /// No new balance for over a week.
    case stoppedUpdating
    /// Savings the owner has not asked to count.
    case savingsNotCounted
    /// Nobody has said what kind of account it is.
    case typeNotSet
    /// Not in US dollars.
    case notUSDollars
}

enum AccountStanding: Equatable, Sendable {
    case counted(Freshness)
    case heldOut(HeldOutReason)
    /// A card. Its balance is debt, never money, and never enters a total.
    case creditCard
    /// Put away by the owner. Not counted and never mentioned under the number.
    case archived

    var isCounted: Bool {
        if case .counted = self { return true }
        return false
    }
}

/// An account after the engine has decided what it is and what, if anything, it contributes.
struct ClassifiedAccount: Equatable, Sendable, Identifiable {
    let id: Int64
    let name: String
    let source: AccountSource
    let type: AccountType?
    let standing: AccountStanding
    /// The day the balance is from, never later than today.
    let asOf: CalendarDay
    /// The exact moment the balance was recorded. Everything the engine does works in whole days;
    /// this is the one exception, because deciding whether a balance was updated before or after
    /// the owner said they paid a bill cannot be answered by the date alone when both happened
    /// on the same day.
    let balanceInstant: Int64
    /// What the account holds, after any "amounts look reversed" correction.
    let balanceCents: Int64
    /// What it puts into the total. Zero unless counted.
    let contributedCents: Int64
    /// True when the bank's available balance was used instead of the plain balance.
    let usedAvailableBalance: Bool
    /// True when an available balance was ignored for being larger than the balance, which is the
    /// shape of a credit line rather than money.
    let ignoredAvailableBalance: Bool

    /// How many whole days behind today this account's balance is.
    func daysOld(today: CalendarDay, calendar: Calendar) -> Int {
        asOf.days(to: today, in: calendar)
    }
}

// MARK: - What is owed

/// Why an amount that is due was not taken off the number.
enum NotSubtractedReason: Equatable, Sendable {
    /// Paid from an account whose money is not counted either.
    case fromAccountNotCounted(accountName: String, reason: HeldOutReason)
    /// On a card whose statement payment is counted instead.
    case onCardWithStatement(cardName: String)
    /// On a card, where the payment the owner makes to that card is counted instead.
    case onCardPaidByTransfer(cardName: String)
    /// Money moving into an account that is already counted, so it never leaves the total.
    case movesIntoCountedAccount(accountName: String)
}

enum ObligationTreatment: Equatable, Sendable {
    /// Taken off the number.
    case subtracted
    /// On a card with no statement entered, so counted here for want of anywhere better.
    case subtractedOnCardWithoutStatement(cardName: String)
    /// The owner says they paid it, but the balance it came out of has not been updated yet.
    case paidButStillCounted(accountName: String, markedOn: CalendarDay)
    /// Listed, explained, and not taken off the number.
    case notSubtracted(NotSubtractedReason)

    var comesOffTheNumber: Bool {
        switch self {
        case .subtracted, .subtractedOnCardWithoutStatement, .paidButStillCounted: true
        case .notSubtracted: false
        }
    }
}

/// One dated amount the owner owes inside a window.
struct Obligation: Equatable, Sendable {
    let chargeId: Int64?
    let name: String
    let amountCents: Int64
    let dueDay: CalendarDay
    let kind: RecurringChargeKind
    let payingAccountId: Int64?
    let treatment: ObligationTreatment
}

// MARK: - The answers

enum FigureKind: Equatable, Sendable {
    case calendarMonth
    case untilPayday
}

/// Bills that fall inside the month but after the next payday, which the until-payday figure
/// leaves out. Naming them is the difference between a smaller window and a misleading one.
struct HoldBack: Equatable, Sendable {
    let totalCents: Int64
    /// Up to three of the largest, for the sentence.
    let names: [String]
    let firstDueDay: CalendarDay
    let count: Int
}

/// An account whose money is not counted, shown together with the bills paid from it so the two
/// halves can never be read apart.
struct HeldOutBlock: Equatable, Sendable {
    let accountName: String
    let source: AccountSource
    let reason: HeldOutReason
    let asOf: CalendarDay
    let balanceCents: Int64
    let obligationsCents: Int64

    /// What the account would have left after its own bills, on the last figures known.
    var netCents: Int64 { balanceCents - obligationsCents }
}

struct SpendableFigure: Equatable, Sendable {
    let kind: FigureKind
    let windowStart: CalendarDay
    let windowEnd: CalendarDay
    let contributedCents: Int64
    /// Everything taken off, including bills the owner has paid whose balance has not caught up.
    let subtractedCents: Int64
    /// Of the above, the part the owner has already paid.
    let alreadyPaidCents: Int64
    let remainderCents: Int64
    let obligations: [Obligation]
    let heldOutBlocks: [HeldOutBlock]
    /// Only for the until-payday figure.
    let payday: CalendarDay?
    let daysToPayday: Int?
    let perDayAllowanceCents: Int64?
    let holdBack: HoldBack?
    /// The newest counted balance predates the last payday, so a paycheck that has landed is not
    /// in these numbers yet.
    let payPending: Bool
    let paydayForPending: CalendarDay?

    var isShort: Bool { remainderCents < 0 }

    /// Obligations that came off the number, biggest first.
    var subtractedObligations: [Obligation] {
        obligations.filter(\.treatment.comesOffTheNumber).sorted { $0.amountCents > $1.amountCents }
    }

    /// Obligations that are due but were not taken off, biggest first.
    var listedNotSubtracted: [Obligation] {
        obligations.filter { !$0.treatment.comesOffTheNumber }.sorted { $0.amountCents > $1.amountCents }
    }
}

/// What the engine can say about the owner's money.
enum SafeToSpendResult: Equatable, Sendable {
    /// No accounts at all.
    case noAccountsYet
    /// Accounts exist but not one of them can be counted, so there is no number to give. The engine
    /// never answers "$0" here: "nothing left" and "I don't know" are different things.
    case nothingCountable([ClassifiedAccount])
    case figures(SafeToSpendReport)
}

struct SafeToSpendReport: Equatable, Sendable {
    let today: CalendarDay
    let accounts: [ClassifiedAccount]
    let month: SpendableFigure
    /// Absent until the owner says when they are next paid.
    let untilPayday: SpendableFigure?
    /// Confirmed bills with no due date, which cannot be placed in any window.
    let undatedCharges: [(name: String, amountCents: Int64)]
    /// The owner has entered no bills at all, which reads very differently from "none are due".
    let hasNoBillsAtAll: Bool

    static func == (lhs: SafeToSpendReport, rhs: SafeToSpendReport) -> Bool {
        lhs.today == rhs.today && lhs.accounts == rhs.accounts && lhs.month == rhs.month
            && lhs.untilPayday == rhs.untilPayday && lhs.hasNoBillsAtAll == rhs.hasNoBillsAtAll
            && lhs.undatedCharges.map(\.name) == rhs.undatedCharges.map(\.name)
            && lhs.undatedCharges.map(\.amountCents) == rhs.undatedCharges.map(\.amountCents)
    }

    func figure(_ kind: FigureKind) -> SpendableFigure? {
        switch kind {
        case .calendarMonth: month
        case .untilPayday: untilPayday
        }
    }
}

// MARK: - The engine

enum SafeToSpendEngine {
    /// How many whole days a balance may be behind before the app says so.
    static func staleAfterDays(for source: AccountSource) -> Int {
        source == .manual ? 3 : 2
    }

    /// How many whole days a balance may be behind before it stops counting at all.
    static let deadAfterDays = 7

    static func compute(
        accounts: [Account],
        charges: [RecurringCharge],
        paySchedule: PaySchedule?,
        today: CalendarDay,
        calendar: Calendar = .current
    ) -> SafeToSpendResult {
        guard !accounts.isEmpty else { return .noAccountsYet }

        let classified = accounts.map { classify($0, today: today, calendar: calendar) }
        let counted = classified.filter { $0.standing.isCounted }

        // An account that is held out but holds nothing and owes nothing is noise, not a reason to
        // refuse to answer.
        let holdsSomething = classified.contains { account in
            switch account.standing {
            case .counted: true
            case .heldOut, .creditCard:
                account.balanceCents != 0 || charges.contains { $0.payingAccountId == account.id }
            case .archived: false
            }
        }
        if counted.isEmpty {
            return holdsSomething ? .nothingCountable(classified) : .nothingCountable(classified)
        }

        let confirmed = charges.filter { $0.status == .confirmed }
        let datable = confirmed.filter { $0.nextExpectedDate != nil }
        let undated = confirmed.filter { $0.nextExpectedDate == nil }
            .map { (name: $0.name, amountCents: $0.amountCents) }

        let monthWindow = today.startOfMonth(in: calendar)...today.endOfMonth(in: calendar)
        let month = figure(
            kind: .calendarMonth, window: monthWindow, accounts: classified, counted: counted,
            charges: datable, today: today, calendar: calendar, payday: nil, paySchedule: paySchedule)

        var untilPayday: SpendableFigure?
        if let payday = paySchedule?.nextPayday(after: today, in: calendar) {
            let window = today.startOfMonth(in: calendar)...payday.adding(days: -1, in: calendar)
            untilPayday = figure(
                kind: .untilPayday, window: window, accounts: classified, counted: counted,
                charges: datable, today: today, calendar: calendar, payday: payday, paySchedule: paySchedule)
        }

        return .figures(SafeToSpendReport(
            today: today,
            accounts: classified,
            month: month,
            untilPayday: untilPayday,
            undatedCharges: undated,
            hasNoBillsAtAll: confirmed.isEmpty))
    }

    // MARK: Classifying an account

    static func classify(_ account: Account, today: CalendarDay, calendar: Calendar) -> ClassifiedAccount {
        let id = account.id ?? 0
        // A balance dated in the future is a clock difference, not a prediction.
        let rawDay = CalendarDay(epochSeconds: account.balanceDate, in: calendar)
        let asOf = min(rawDay, today)
        let daysOld = asOf.days(to: today, in: calendar)

        let sign: Int64 = account.amountsReversed ? -1 : 1
        let balance = sign * account.balanceCents
        let available = account.availableCents.map { sign * $0 }
        let type = account.effectiveType

        // The bank's available balance reflects holds, so it is the truer number to spend from —
        // but only once the owner has confirmed the account really is a current account, and only
        // when it is not larger than the balance, which is the shape of a credit line.
        let mayUseAvailable = account.userType == .checking && available != nil
        let availableLooksLikeCredit = mayUseAvailable && available! > balance
        let useAvailable = mayUseAvailable && !availableLooksLikeCredit
        let contributed = useAvailable ? available! : balance

        let standing: AccountStanding
        if account.archivedAt != nil {
            standing = .archived
        } else if account.currency != "USD" {
            standing = .heldOut(.notUSDollars)
        } else if type == nil {
            standing = .heldOut(.typeNotSet)
        } else if type == .credit {
            standing = .creditCard
        } else if type == .savings && account.includeInSafeToSpend != true {
            standing = .heldOut(.savingsNotCounted)
        } else if daysOld > deadAfterDays {
            standing = .heldOut(.stoppedUpdating)
        } else {
            standing = .counted(daysOld > staleAfterDays(for: account.source) ? .stale : .fresh)
        }

        return ClassifiedAccount(
            id: id,
            name: account.displayName,
            source: account.source,
            type: type,
            standing: standing,
            asOf: asOf,
            balanceInstant: account.balanceDate,
            balanceCents: balance,
            contributedCents: standing.isCounted ? contributed : 0,
            usedAvailableBalance: standing.isCounted && useAvailable,
            ignoredAvailableBalance: availableLooksLikeCredit)
    }

    // MARK: Working out one figure

    private static func figure(
        kind: FigureKind,
        window: ClosedRange<CalendarDay>,
        accounts: [ClassifiedAccount],
        counted: [ClassifiedAccount],
        charges: [RecurringCharge],
        today: CalendarDay,
        calendar: Calendar,
        payday: CalendarDay?,
        paySchedule: PaySchedule?
    ) -> SpendableFigure {
        let contributed = counted.reduce(Int64(0)) { $0 + $1.contributedCents }
        let byId = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })

        // Which card, if any, is paid by a standing transfer. That payment stands in for every
        // bill charged to the card, so the card's spending is counted once, not twice.
        let cardsPaidByTransfer = Set(charges.compactMap { charge -> Int64? in
            guard charge.kind == .transfer, let destination = charge.destinationAccountId,
                  byId[destination]?.standing == .creditCard else { return nil }
            return destination
        })

        var obligations: [Obligation] = []
        for charge in charges {
            let treatment = treatment(
                for: charge, accounts: byId, cardsPaidByTransfer: cardsPaidByTransfer, calendar: calendar)

            // A bill the owner has paid, whose balance has not caught up yet, is counted once on
            // the day they said they paid it — not on the date it was due, which has passed.
            if let retained = retainedObligation(
                for: charge, accounts: byId, window: window, calendar: calendar) {
                obligations.append(retained)
            }

            for day in charge.occurrences(in: window, calendar: calendar) {
                obligations.append(Obligation(
                    chargeId: charge.id, name: charge.name, amountCents: charge.amountCents,
                    dueDay: day, kind: charge.kind, payingAccountId: charge.payingAccountId,
                    treatment: treatment))
            }
        }

        let subtracted = obligations.filter(\.treatment.comesOffTheNumber)
            .reduce(Int64(0)) { $0 + $1.amountCents }
        let alreadyPaid = obligations.filter {
            if case .paidButStillCounted = $0.treatment { return true }
            return false
        }.reduce(Int64(0)) { $0 + $1.amountCents }

        let remainder = contributed - subtracted

        // Bills paid from an account that is not counted: shown with that account's balance so the
        // two are never read apart.
        var blocks: [HeldOutBlock] = []
        for account in accounts {
            guard case .heldOut(let reason) = account.standing else { continue }
            let owed = charges
                .filter { $0.payingAccountId == account.id }
                .reduce(Int64(0)) { total, charge in
                    total + Int64(charge.occurrences(in: window, calendar: calendar).count) * charge.amountCents
                }
            guard account.balanceCents != 0 || owed != 0 else { continue }
            blocks.append(HeldOutBlock(
                accountName: account.name, source: account.source, reason: reason,
                asOf: account.asOf, balanceCents: account.balanceCents, obligationsCents: owed))
        }

        var days: Int?
        var allowance: Int64?
        var holdBack: HoldBack?
        if kind == .untilPayday, let payday {
            let count = max(1, today.days(to: payday, in: calendar))
            days = count
            allowance = remainder > 0 ? remainder / Int64(count) : 0
            holdBack = heldBackBills(
                charges: charges, accounts: byId, cardsPaidByTransfer: cardsPaidByTransfer,
                from: payday, to: today.endOfMonth(in: calendar), calendar: calendar)
        }

        // A paycheck that has landed but is not in any balance yet would otherwise read as a
        // shortfall the owner does not have.
        var payPending = false
        var pendingPayday: CalendarDay?
        if let last = paySchedule?.mostRecentPayday(onOrBefore: today, in: calendar),
           let newest = counted.map(\.asOf).max(), newest < last {
            payPending = true
            pendingPayday = last
        }

        return SpendableFigure(
            kind: kind, windowStart: window.lowerBound, windowEnd: window.upperBound,
            contributedCents: contributed, subtractedCents: subtracted, alreadyPaidCents: alreadyPaid,
            remainderCents: remainder, obligations: obligations, heldOutBlocks: blocks,
            payday: payday, daysToPayday: days, perDayAllowanceCents: allowance, holdBack: holdBack,
            payPending: payPending, paydayForPending: pendingPayday)
    }

    /// Whether a charge's money leaves the pool the figure just added up, and if not, why not.
    private static func treatment(
        for charge: RecurringCharge,
        accounts: [Int64: ClassifiedAccount],
        cardsPaidByTransfer: Set<Int64>,
        calendar: Calendar
    ) -> ObligationTreatment {
        // Money moving between the owner's own accounts.
        if charge.kind == .transfer {
            guard let destinationId = charge.destinationAccountId,
                  let destination = accounts[destinationId] else {
                // Nobody said where it goes, so assume it is gone.
                return .subtracted
            }
            switch destination.standing {
            case .counted:
                return .notSubtracted(.movesIntoCountedAccount(accountName: destination.name))
            case .creditCard, .heldOut, .archived:
                // Into a card, or into savings that is not counted: the money leaves.
                return .subtracted
            }
        }

        guard let payingId = charge.payingAccountId, let paying = accounts[payingId] else {
            // No account named, or the account is gone: it still has to be paid from somewhere,
            // and the only money on the table is money that is counted.
            return .subtracted
        }

        switch paying.standing {
        case .counted:
            return .subtracted
        case .archived:
            // A closed account cannot pay anything, so the bill comes out of money that is counted.
            return .subtracted
        case .heldOut(let reason):
            return .notSubtracted(.fromAccountNotCounted(accountName: paying.name, reason: reason))
        case .creditCard:
            if hasLiveStatement(paying) {
                return .notSubtracted(.onCardWithStatement(cardName: paying.name))
            }
            if cardsPaidByTransfer.contains(paying.id) {
                return .notSubtracted(.onCardPaidByTransfer(cardName: paying.name))
            }
            // Nothing else counts this card's spending, so it is counted here rather than nowhere.
            return .subtractedOnCardWithoutStatement(cardName: paying.name)
        }
    }

    /// True once the owner has entered a statement for a card and its due date has not passed.
    /// Always false until milestone 6 adds the fields.
    private static func hasLiveStatement(_ account: ClassifiedAccount) -> Bool {
        false
    }

    private static func retainedObligation(
        for charge: RecurringCharge,
        accounts: [Int64: ClassifiedAccount],
        window: ClosedRange<CalendarDay>,
        calendar: Calendar
    ) -> Obligation? {
        guard let markedAt = charge.lastMarkedPaidAt, !charge.paidReflectedInBalance else { return nil }
        let paying = charge.payingAccountId.flatMap { accounts[$0] }
        // Only while that account is still counted; a held-out account's bills are held out too.
        guard paying == nil || paying!.standing.isCounted else { return nil }
        guard charge.isStillCountedAfterPaying(payingAccountBalanceDate: paying?.balanceInstant) else { return nil }

        let markedDay = CalendarDay(epochSeconds: markedAt, in: calendar)
        guard markedDay <= window.upperBound else { return nil }
        let day = max(markedDay, window.lowerBound)
        return Obligation(
            chargeId: charge.id, name: charge.name, amountCents: charge.amountCents, dueDay: day,
            kind: charge.kind, payingAccountId: charge.payingAccountId,
            treatment: .paidButStillCounted(accountName: paying?.name ?? "your accounts", markedOn: markedDay))
    }

    /// Bills due between payday and the end of the month, which the until-payday window leaves out.
    private static func heldBackBills(
        charges: [RecurringCharge],
        accounts: [Int64: ClassifiedAccount],
        cardsPaidByTransfer: Set<Int64>,
        from payday: CalendarDay,
        to endOfMonth: CalendarDay,
        calendar: Calendar
    ) -> HoldBack? {
        guard payday <= endOfMonth else { return nil }
        let window = payday...endOfMonth
        var total: Int64 = 0
        var entries: [(String, Int64, CalendarDay)] = []
        for charge in charges {
            let treatment = treatment(
                for: charge, accounts: accounts, cardsPaidByTransfer: cardsPaidByTransfer, calendar: calendar)
            guard treatment.comesOffTheNumber else { continue }
            for day in charge.occurrences(in: window, calendar: calendar) {
                total += charge.amountCents
                entries.append((charge.name, charge.amountCents, day))
            }
        }
        guard !entries.isEmpty else { return nil }
        let biggest = entries.sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
        let earliest = entries.map(\.2).min() ?? payday
        return HoldBack(totalCents: total, names: Array(biggest), firstDueDay: earliest, count: entries.count)
    }
}
