import Foundation

/// Turning a figure into words. Every sentence the owner reads about their money is built here and
/// nowhere else, so the headline, the panel, the widget and the explanation can never disagree.
///
/// House style: plain, factual, never cheerful, never a judgement about spending. A number always
/// arrives inside a sentence, except in the menu bar and the small widget, where there is no room
/// and the sentence is one click away.

// MARK: - Showing a number

enum SafeToSpendDisplay {
    /// The headline. Never a negative number: being short of the month's bills is debt, not
    /// spending money, and a negative headline invites the reader to treat it as a budget.
    static func headline(_ cents: Int64, locale: Locale = .current) -> String {
        if cents < 0 {
            return "$0 (balance: \(shortfall(cents, locale: locale)))"
        }
        // Under a dollar is shown to the cent, so a real 75 cents never reads as the same "$0" the
        // shortfall state uses.
        if cents < 100 {
            return Cents.format(cents, locale: locale)
        }
        return Cents.formatWholeDollars(cents, locale: locale)
    }

    /// A shortfall, rounded away from zero so it is never understated, and shown to the cent when
    /// it is under a dollar.
    static func shortfall(_ cents: Int64, locale: Locale = .current) -> String {
        let magnitude = Int64(cents.magnitude)
        if magnitude < 100 {
            return Cents.format(-magnitude, locale: locale)
        }
        let dollars = (magnitude + 99) / 100
        return Cents.formatWholeDollars(-dollars * 100, locale: locale)
    }

    /// "about $57.27 a day", or nothing at all when the daily share rounds to nothing while money
    /// is left. "$0 a day" is only ever said when there is nothing left.
    static func perDay(_ cents: Int64?, remainderCents: Int64, locale: Locale = .current) -> String? {
        guard let cents else { return nil }
        if remainderCents <= 0 { return "$0 a day" }
        guard cents > 0 else { return nil }
        return "about \(Cents.format(cents, locale: locale)) a day"
    }

    /// What the menu bar and the small widget show. The warning mark is explained by the first
    /// line of the panel behind it.
    static func compact(_ cents: Int64, needsAttention: Bool, locale: Locale = .current) -> String {
        let number = cents < 0
            ? "$0 (\(shortfall(cents, locale: locale)))"
            : headline(cents, locale: locale)
        return needsAttention ? "\(number) ⚠" : number
    }
}

// MARK: - Sections of the explanation

struct DisclosureSection: Equatable, Sendable, Identifiable {
    let id: Int
    let heading: String?
    let lines: [String]
}

enum SafeToSpendNarrative {
    // MARK: Labels

    /// "Safe to spend this month (Sep 1–30)" or "Until payday (Oct 3)".
    static func label(for figure: SpendableFigure, calendar: Calendar = .current) -> String {
        switch figure.kind {
        case .calendarMonth:
            let start = figure.windowStart.dayOfMonthPhrase(in: calendar)
            let end = figure.windowEnd.dayOfMonthPhrase(in: calendar)
            return "Safe to spend this month (\(start)–\(end))"
        case .untilPayday:
            guard let payday = figure.payday else { return "Until payday" }
            return "Until payday (\(payday.shortPhrase(in: calendar)))"
        }
    }

    /// The lines that sit directly under the number, where a caveat cannot be missed.
    static func linesUnderTheNumber(
        report: SafeToSpendReport, figure: SpendableFigure,
        locale: Locale = .current, calendar: Calendar = .current
    ) -> [String] {
        var lines: [String] = []

        if let oldest = report.accounts.filter({ $0.standing == .counted(.stale) }).map(\.asOf).min() {
            lines.append("These balances are from \(oldest.relativePhrase(now: report.today, in: calendar)) and may have changed.")
        }

        for block in figure.heldOutBlocks where block.reason == .stoppedUpdating {
            lines.append(heldOutSentence(block, locale: locale, calendar: calendar, today: report.today))
        }

        // A held-out account that owes more than it holds is promoted out of the explanation: a
        // clean number with a hole behind it is worse than no number.
        for block in figure.heldOutBlocks where block.reason != .stoppedUpdating && block.netCents < 0 {
            lines.append(heldOutSentence(block, locale: locale, calendar: calendar, today: report.today))
        }

        if figure.payPending, let payday = figure.paydayForPending,
           let newest = report.accounts.filter({ $0.standing.isCounted }).map(\.asOf).max() {
            lines.append("Your pay from \(payday.shortPhrase(in: calendar)) isn't in these balances yet — the newest balance here is from \(newest.shortPhrase(in: calendar)).")
        }

        if let holdBack = figure.holdBack, figure.kind == .untilPayday {
            lines.append(holdBackSentence(holdBack, locale: locale, calendar: calendar))
        }

        return lines
    }

    private static func heldOutSentence(
        _ block: HeldOutBlock, locale: Locale, calendar: Calendar, today: CalendarDay
    ) -> String {
        let balance = Cents.format(block.balanceCents, locale: locale)
        let head: String
        switch block.reason {
        case .stoppedUpdating:
            head = block.source == .manual
                ? "\(balance) in \(block.accountName) isn't counted. You last updated it on \(block.asOf.shortPhrase(in: calendar))."
                : "\(balance) in \(block.accountName) isn't counted. Your bank stopped sending new balances on \(block.asOf.shortPhrase(in: calendar)), so I don't know what's in it now."
        case .savingsNotCounted:
            head = "\(balance) in \(block.accountName) isn't counted, because you haven't asked me to count that savings account."
        case .typeNotSet:
            head = "\(balance) in \(block.accountName) isn't counted until you tell me what kind of account it is."
        case .notUSDollars:
            head = "\(block.accountName) isn't in US dollars, so it isn't counted."
        case .holdsInvestments:
            head = "\(block.accountName) holds investments rather than money, so it isn't counted. What it's worth moves with the market, and it isn't there to spend this month."
        }
        guard block.obligationsCents > 0 else { return head }
        let owed = Cents.format(block.obligationsCents, locale: locale)
        if block.netCents < 0 {
            return "\(head) \(owed) of bills come out of it, which is \(Cents.format(-block.netCents, locale: locale)) more than it holds."
        }
        return "\(head) \(owed) of bills come out of it, leaving \(Cents.format(block.netCents, locale: locale)) on those last figures."
    }

    private static func holdBackSentence(_ holdBack: HoldBack, locale: Locale, calendar: Calendar) -> String {
        let total = Cents.format(holdBack.totalCents, locale: locale)
        let day = holdBack.firstDueDay.shortPhrase(in: calendar)
        let named: String
        switch holdBack.names.count {
        case 0: named = ""
        case 1: named = " (\(holdBack.names[0]), \(day))"
        default:
            let list = holdBack.names.joined(separator: ", ")
            let more = holdBack.count > holdBack.names.count ? " and \(holdBack.count - holdBack.names.count) more" : ""
            named = " (\(list)\(more); the first on \(day))"
        }
        return "Then \(total) more is due before the month ends\(named)."
    }

    // MARK: The explanation

    static func disclosure(
        report: SafeToSpendReport, figure: SpendableFigure,
        locale: Locale = .current, calendar: Calendar = .current
    ) -> [DisclosureSection] {
        var sections: [DisclosureSection] = []
        var index = 0
        func add(_ heading: String?, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            sections.append(DisclosureSection(id: index, heading: heading, lines: lines))
            index += 1
        }

        add("What you have", whatYouHave(report: report, locale: locale, calendar: calendar))
        add("What's still due", whatIsDue(report: report, figure: figure, locale: locale, calendar: calendar))
        add(nil, [answer(figure: figure, report: report, locale: locale, calendar: calendar)])
        add("What I left out", leftOut(report: report, figure: figure, locale: locale, calendar: calendar))
        return sections
    }

    static func whatYouHave(
        report: SafeToSpendReport, locale: Locale, calendar: Calendar
    ) -> [String] {
        let counted = report.accounts.filter { $0.standing.isCounted }
        guard !counted.isEmpty else { return [] }

        var lines: [String] = []
        if counted.count > 1 {
            let total = counted.reduce(Int64(0)) { $0 + $1.contributedCents }
            var parts: [String] = []
            for type in [AccountType.checking, .cash] {
                let sum = counted.filter { $0.type == type }.reduce(Int64(0)) { $0 + $1.contributedCents }
                if sum != 0 { parts.append("\(Cents.format(sum, locale: locale)) in \(type == .checking ? "checking" : "cash")") }
            }
            for savings in counted.filter({ $0.type == .savings }) {
                parts.append("\(Cents.format(savings.contributedCents, locale: locale)) in \(savings.name), which you asked me to count")
            }
            if !parts.isEmpty {
                lines.append("You have \(Cents.format(total, locale: locale)): \(sentenceList(parts)).")
            }
        }
        for account in counted.sorted(by: { $0.contributedCents > $1.contributedCents }) {
            lines.append(accountLine(account, today: report.today, locale: locale, calendar: calendar))
        }
        return lines
    }

    private static func accountLine(
        _ account: ClassifiedAccount, today: CalendarDay, locale: Locale, calendar: Calendar
    ) -> String {
        let amount = Cents.format(account.contributedCents, locale: locale)
        let asOf = account.asOf.relativePhrase(now: today, in: calendar)
        let gloss: String
        if account.usedAvailableBalance {
            gloss = "what your bank says is free to spend right now, which leaves out payments that haven't finished going through"
        } else if account.source == .manual {
            gloss = "the amount you entered by hand"
        } else {
            gloss = "your bank's balance, which may not have caught up with payments still going through"
        }
        return "\(account.name) \(amount) — \(gloss), as of \(asOf)."
    }

    static func whatIsDue(
        report: SafeToSpendReport, figure: SpendableFigure, locale: Locale, calendar: Calendar
    ) -> [String] {
        if report.hasNoBillsAtAll {
            return ["You haven't told me about any bills yet, so I haven't subtracted anything. Until you add your rent and the bills that come out automatically, this number is just what's in your accounts."]
        }

        var lines: [String] = []
        let subtracted = figure.subtractedObligations
        let paid = subtracted.filter { if case .paidButStillCounted = $0.treatment { return true } else { return false } }
        let outstanding = subtracted.filter { if case .paidButStillCounted = $0.treatment { return false } else { return true } }

        if outstanding.isEmpty && paid.isEmpty {
            lines.append(figure.kind == .calendarMonth
                ? "None of your bills are due between now and the end of the month."
                : "None of your bills are due between now and your payday.")
        } else if !outstanding.isEmpty {
            let total = outstanding.reduce(Int64(0)) { $0 + $1.amountCents }
            lines.append(figure.kind == .calendarMonth
                ? "\(Cents.format(total, locale: locale)) of your bills comes out of the money above."
                : "\(Cents.format(total, locale: locale)) of bills are due between now and your payday on \(figure.payday?.shortPhrase(in: calendar) ?? "payday").")
            lines.append(contentsOf: outstanding.map { obligationLine($0, today: report.today, locale: locale, calendar: calendar) })
        }

        if !paid.isEmpty {
            let total = paid.reduce(Int64(0)) { $0 + $1.amountCents }
            lines.append("You've already paid \(Cents.format(total, locale: locale)) of this, and I'm still counting it:")
            lines.append(contentsOf: paid.map { obligationLine($0, today: report.today, locale: locale, calendar: calendar) })
        }

        let listed = figure.listedNotSubtracted
        if !listed.isEmpty {
            let reasons = listed.map { notSubtractedLine($0, locale: locale, calendar: calendar) }
            lines.append(listed.count == 1
                ? "One more bill is due, but it doesn't come out of the money above: \(reasons[0])"
                : "\(listed.count) more bills are due, but they don't come out of the money above: \(sentenceList(reasons))")
        }
        return lines
    }

    private static func obligationLine(
        _ obligation: Obligation, today: CalendarDay, locale: Locale, calendar: Calendar
    ) -> String {
        let amount = Cents.format(obligation.amountCents, locale: locale)
        if case .paidButStillCounted(let accountName, let markedOn) = obligation.treatment {
            // A charge that names no paying account falls back to "your accounts", which cannot
            // take "the" in front of it.
            let whose = accountName == SafeToSpendEngine.unnamedAccountPhrase
                ? "the balance I have"
                : "the \(accountName) balance I have"
            return "\(obligation.name) \(amount) — you told me you paid this on \(markedOn.shortPhrase(in: calendar)), and \(whose) still includes it."
        }
        let cardNote: String
        if case .subtractedOnCardWithoutStatement(let cardName) = obligation.treatment {
            cardNote = " (charged to your \(cardName), which has no statement entered, so it's counted here)"
        } else {
            cardNote = ""
        }
        if obligation.dueDay == today {
            return "\(obligation.name) \(amount) — due today\(cardNote)."
        }
        if obligation.dueDay < today {
            return "\(obligation.name) \(amount) — was due \(obligation.dueDay.shortPhrase(in: calendar))\(cardNote). I'm still subtracting it until you mark it paid."
        }
        return "\(obligation.name) \(amount) — due \(obligation.dueDay.shortPhrase(in: calendar))\(cardNote)."
    }

    private static func notSubtractedLine(_ obligation: Obligation, locale: Locale, calendar: Calendar) -> String {
        let amount = Cents.format(obligation.amountCents, locale: locale)
        guard case .notSubtracted(let reason) = obligation.treatment else { return "\(obligation.name) \(amount)" }
        switch reason {
        case .fromAccountNotCounted(let accountName, let heldOut):
            let why: String
            switch heldOut {
            case .stoppedUpdating: why = "which isn't counted because it stopped updating"
            case .savingsNotCounted: why = "which isn't counted here"
            case .typeNotSet: why = "which isn't counted until you tell me what kind of account it is"
            case .notUSDollars: why = "which isn't in US dollars and isn't counted"
            case .holdsInvestments: why = "which holds investments rather than money"
            }
            return "\(obligation.name) \(amount) comes out of \(accountName), \(why)"
        case .onCardWithStatement(let cardName):
            return "\(obligation.name) \(amount) is charged to your \(cardName) — counted through that card"
        case .onCardPaidByTransfer(let cardName):
            return "\(obligation.name) \(amount) is charged to your \(cardName) — counted through the payment you make to that card"
        case .movesIntoCountedAccount(let accountName):
            return "\(obligation.name) \(amount) moves into \(accountName), which is already counted"
        }
    }

    static func answer(
        figure: SpendableFigure, report: SafeToSpendReport, locale: Locale, calendar: Calendar
    ) -> String {
        if figure.remainderCents <= 0, figure.payPending, let landedOn = figure.paydayForPending {
            // A paycheck that has arrived but has not reached any balance yet would otherwise read
            // as a shortfall the owner does not have. The cause comes first, then the arithmetic,
            // and the bare "you're short" sentence is not said at all in this state.
            let newest = report.accounts.filter { $0.standing.isCounted }.map(\.asOf).max()
            let newestPhrase = newest.map { " — the newest balance here is from \($0.shortPhrase(in: calendar))" } ?? ""
            let due = Cents.format(figure.subtractedCents, locale: locale)
            let have = Cents.format(figure.contributedCents, locale: locale)
            let window = figure.kind == .untilPayday && figure.payday != nil
                ? "the bills due before \(figure.payday!.shortPhrase(in: calendar))"
                : "this month's bills"
            return "Your pay from \(landedOn.shortPhrase(in: calendar)) isn't in these balances yet\(newestPhrase). Counted without it, \(window) come to \(due) against the \(have) your accounts last showed."
        }
        if figure.remainderCents < 0 {
            let short = SafeToSpendDisplay.shortfall(figure.remainderCents, locale: locale)
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "\u{2212}", with: "")
            let scoped = figure.heldOutBlocks.isEmpty ? "" : "Of the accounts I can see, "
            if figure.kind == .untilPayday, let payday = figure.payday {
                return "\(scoped.isEmpty ? "You're" : scoped + "you're") \(short) short of the bills due before your payday on \(payday.shortPhrase(in: calendar))."
            }
            return "\(scoped.isEmpty ? "You're" : scoped + "you're") \(short) short of this month's bills."
        }
        if figure.remainderCents == 0 {
            return "That leaves \(Cents.format(0, locale: locale)) — nothing left."
        }
        if report.hasNoBillsAtAll {
            return "That leaves the whole \(Cents.format(figure.remainderCents, locale: locale)) — but only because nothing has been subtracted."
        }
        let amount = Cents.format(figure.remainderCents, locale: locale)
        if figure.kind == .untilPayday, let payday = figure.payday {
            if let perDay = SafeToSpendDisplay.perDay(figure.perDayAllowanceCents, remainderCents: figure.remainderCents, locale: locale) {
                return "That leaves \(amount) to last until \(payday.shortPhrase(in: calendar)) — \(perDay)."
            }
            return "That leaves \(amount) to last until \(payday.shortPhrase(in: calendar))."
        }
        return "That leaves \(amount)."
    }

    static func leftOut(
        report: SafeToSpendReport, figure: SpendableFigure, locale: Locale, calendar: Calendar
    ) -> [String] {
        var lines: [String] = []

        for block in figure.heldOutBlocks {
            lines.append(heldOutSentence(block, locale: locale, calendar: calendar, today: report.today))
        }

        for account in report.accounts where account.ignoredAvailableBalance {
            lines.append("\(account.name)'s \"available\" balance is higher than its balance, which looks like a credit line rather than money, so I used the balance.")
        }

        let cards = report.accounts.filter { $0.standing == .creditCard && $0.balanceCents != 0 }
        for card in cards {
            let owed = Cents.format(Int64(clamping: card.balanceCents.magnitude), locale: locale)
            lines.append("You owe \(owed) on \(card.name). No number here subtracts that — tell me its statement balance and the day it's due and I'll count the payment.")
        }

        // A bill still pointing at an account the owner has put away has to come from somewhere,
        // so it is subtracted — but they should be told, because the app picked for them.
        let archivedIds = Set(report.accounts.filter { $0.standing == .archived }.map(\.id))
        for obligation in figure.obligations where obligation.payingAccountId.map(archivedIds.contains) == true {
            let name = report.accounts.first { $0.id == obligation.payingAccountId }?.name ?? "an account"
            lines.append("\(obligation.name) \(Cents.format(obligation.amountCents, locale: locale)) still comes out of \(name), which you've put away — tell me which account pays it now.")
        }

        for charge in report.undatedCharges {
            lines.append("\(charge.name) \(Cents.format(charge.amountCents, locale: locale)) — I don't know when this is next due, so it isn't subtracted.")
        }

        lines.append(figure.kind == .untilPayday && figure.payday != nil
            ? "This is only money you have now. Your paycheck on \(figure.payday!.shortPhrase(in: calendar)) isn't part of it."
            : "This doesn't count your next paycheck.")
        return lines
    }

    /// "a, b and c" — the way a person writes a list.
    static func sentenceList(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: "\(items.dropLast().joined(separator: ", ")) and \(items.last!)"
        }
    }
}

// MARK: - Days in words

extension CalendarDay {
    /// "September 25".
    func shortPhrase(in calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        return startOfDay(in: calendar).formatted(style.month(.wide).day())
    }

    /// "Sep 1", for the compact window label.
    func dayOfMonthPhrase(in calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        return startOfDay(in: calendar).formatted(style.month(.abbreviated).day())
    }

    /// "today", "yesterday", "Thursday", or a date for anything older.
    func relativePhrase(now: CalendarDay, in calendar: Calendar = .current) -> String {
        AsOf.dayPhrase(epochSeconds: epochSeconds(in: calendar), now: now.startOfDay(in: calendar), calendar: calendar)
    }
}
