import Foundation

/// Sentences shared by the accounts screen and its acceptance tests. All amounts come from the
/// same account classification that drives the engine; server messages remain attributed text.
enum AccountPresentation {
    static func amount(_ cents: Int64, currency: String = "USD", locale: Locale = .current) -> String {
        let formatted = Cents.format(cents, locale: locale, currency: currency)
        guard cents % 100 == 0 else { return formatted }
        let separator = locale.decimalSeparator ?? "."
        return formatted.replacingOccurrences(of: separator + "00", with: "")
    }

    static func permitsTypeChoice(_ account: Account) -> Bool {
        account.holdingsCount == 0 && account.guessClass == nil && account.archivedAt == nil
    }

    static func offersSavingsSwitch(_ account: Account) -> Bool {
        account.effectiveType == .savings && permitsTypeChoice(account)
            && account.currency.uppercased() == "USD"
            && (account.source == .manual || account.holdingsObservedAt != nil)
    }

    static func notice(for account: Account, in notices: [SyncNotice]) -> SyncNotice? {
        notices.first {
            switch $0.scope {
            case .account(let id): return account.id == id
            case .connection(let id): return account.connId == id
            default: return false
            }
        }
    }

    static func connectionName(_ account: Account) -> String {
        account.connName ?? account.orgName ?? "Your bank"
    }

    static func problemAction(_ account: Account, notice: SyncNotice) -> String {
        if notice.code.contains("auth") {
            return "\(connectionName(account)) needs you to sign in again on the SimpleFIN website."
        }
        return "\(connectionName(account)) couldn't update this account. SimpleFIN said: \"\(notice.text)\""
    }

    static func connectionProblemLine(_ account: Account, classified: ClassifiedAccount, notice: SyncNotice, locale: Locale = .current) -> String {
        let intro = classified.standing == .heldOut(.stoppedUpdating)
            ? "\(amount(classified.balanceCents, currency: account.currency, locale: locale)) in \(account.displayName) isn't counted, because "
            : "\(account.displayName) couldn't update. "
        let attribution = notice.code.contains("auth") ? " SimpleFIN said: \"\(notice.text)\"" : ""
        return intro + problemAction(account, notice: notice) + attribution + " I'll check for an updated balance on the next refresh."
    }

    static func typeQuestion(_ account: Account, locale: Locale = .current) -> String {
        if account.balanceCents < 0 {
            return "\(account.displayName) is \(Cents.format(Int64(clamping: account.balanceCents.magnitude), locale: locale, currency: account.currency)) in the red. Is this a credit card, or a checking account that's overdrawn?"
        }
        return "What kind of account is \(account.displayName)? I can't count it until I know."
    }

    static func row(
        _ account: Account, classified: ClassifiedAccount, notices: [SyncNotice] = [],
        now: Date = .now, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let name = account.displayName
        let day = AsOf.dayPhrase(epochSeconds: account.balanceDate, now: now, calendar: calendar)
        let dated = CalendarDay(epochSeconds: account.balanceDate, in: calendar).shortPhrase(in: calendar)
        switch classified.standing {
        case .heldOut(.isALoan):
            return "\(name) is money you owe, not money you have, so it isn't counted here."
        case .heldOut(.holdsInvestments):
            return "\(name) holds shares and funds, not money. What it's worth goes up and down with the market, so I never count it — there's no switch for this one."
        case .heldOut(.notLookedInsideYet):
            return "I haven't looked inside \(name) yet, so I don't know whether it holds money or shares and funds. I'll know once I've fetched its transactions — usually within a few minutes, and by tomorrow at the latest."
        case .heldOut(.typeNotSet): return typeQuestion(account, locale: locale)
        case .heldOut(.notUSDollars):
            let currency = locale.localizedString(forCurrencyCode: account.currency) ?? account.currency
            return "\(name) holds \(Cents.format(account.balanceCents, locale: locale, currency: account.currency)) in \(currency). I only work in US dollars and I won't guess an exchange rate, so this one stays out of every total. Adding it by hand as dollars would make what you can spend wrong, so I'd leave it as it is."
        case .heldOut(.stoppedUpdating):
            if let problem = notice(for: account, in: notices) {
                return "Not counted. \(problemAction(account, notice: problem))"
            }
            if account.source == .manual {
                return "You last updated this on \(dated). Update it and I'll count it again."
            }
            if let vanished = account.notUpdatingSince,
               !AsOf.isStale(epochSeconds: account.balanceDate, thresholdDays: 7, now: now, calendar: calendar) {
                return "\(name) held \(amount(account.balanceCents, currency: account.currency, locale: locale)) on \(dated), and that's the last figure I have. It wasn't in what SimpleFIN sent at \(timePhrase(vanished, now: now, calendar: calendar)), so I've stopped counting it until it comes back."
            }
            return "Your bank stopped sending new balances on \(dated), so I don't know what's in it now."
        case .heldOut(.savingsNotCounted):
            return "Savings, not counted towards what you can spend. As of \(day)."
        case .creditCard:
            if account.userType == nil {
                return "I think \(name) is a credit card, going by its name, so I'm not counting it as money you have. It shows \(amount(Int64(clamping: account.balanceCents.magnitude), currency: account.currency, locale: locale)) owed. Is that right?"
            }
            return "Money you owe, never counted as money you have. As of \(day)."
        case .supersededPendingAnswer:
            return "Not counted while I wait to hear whether this is the same account your bank sent. Its bills are still being subtracted."
        case .archived: return "Put away."
        case .counted(.fresh):
            return account.source == .manual ? "Entered by hand, as of \(day)." : "As of \(day)."
        case .counted(.stale):
            return account.source == .manual
                ? "Entered by hand on \(dated). Update it when you get a chance."
                : "As of \(day), which is a few days ago."
        }
    }

    static func timePhrase(_ seconds: Int64, now: Date = .now, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        return "\(date.formatted(style.hour().minute())) \(AsOf.dayPhrase(epochSeconds: seconds, now: now, calendar: calendar))"
    }

    static func correctedAmounts(_ account: Account) -> (balance: Int64, available: Int64?) {
        let sign: Int64 = account.amountsReversed ? -1 : 1
        return (sign * account.balanceCents, account.availableCents.map { sign * $0 })
    }

    static func availableWarning(_ account: Account, locale: Locale = .current) -> String? {
        let corrected = correctedAmounts(account)
        guard account.currency == "USD", account.effectiveType == .checking, account.userType != .checking,
              let available = corrected.available, available < corrected.balance else { return nil }
        return "If you confirm this, I'll switch to the \(amount(available, locale: locale)) your bank says is free to spend right now instead of its \(amount(corrected.balance, locale: locale)) balance. The \(amount(corrected.balance - available, locale: locale)) difference is payments that haven't finished going through."
    }

    static func summary(accounts: [Account], classified: [ClassifiedAccount], locale: Locale = .current) -> [String] {
        let visible = accounts.filter { $0.archivedAt == nil }
        let counted = classified.filter { $0.standing.isCounted }
        let unknown = classified.filter { $0.standing == .heldOut(.typeNotSet) }
        var lines: [String] = []
        if !unknown.isEmpty {
            // Different currencies are never summed into dollars; currency classification precedes type.
            let total = unknown.reduce(Int64(0)) { $0 + $1.balanceCents }
            let count = unknown.count == 1 ? "One account is" : "\(unknown.count) accounts are"
            lines.append("\(count) waiting for you to say what kind \(unknown.count == 1 ? "it is" : "they are"). Until you do, \(unknown.count == 1 ? "its" : "their") \(amount(total, locale: locale)) isn't part of what you can spend.")
        }
        var summary = "\(counted.count) of your \(visible.count) accounts \(counted.count == 1 ? "is" : "are") in what you can spend"
        summary += counted.isEmpty ? "." : ": \(SafeToSpendNarrative.sentenceList(counted.map(\.name)))."
        for item in classified where item.standing != .archived && !item.standing.isCounted {
            switch item.standing {
            case .heldOut(.savingsNotCounted): summary += " \(item.name) isn't, because you haven't asked me to count savings."
            case .heldOut(.typeNotSet): summary += " \(item.name) isn't, because I don't know what kind of account it is."
            case .creditCard: summary += " \(item.name) \(item.isTypeConfirmed ? "is" : "looks like") a card, so what's on it is money you owe."
            case .heldOut(.holdsInvestments): summary += " \(item.name) holds shares or funds, so it never counts."
            case .heldOut(.isALoan): summary += " \(item.name) is money you owe, so it doesn't count."
            case .heldOut(.notLookedInsideYet): summary += " I haven't looked inside \(item.name) yet, so the total is incomplete."
            case .heldOut(.notUSDollars): summary += " \(item.name) isn't in US dollars."
            case .heldOut(.stoppedUpdating): summary += " \(item.name) stopped updating — see its note below."
            case .supersededPendingAnswer: summary += " \(item.name) may be the same account your bank sent, so I'm counting only one."
            default: break
            }
        }
        lines.append(summary)
        return lines
    }

    static func headline(_ result: SafeToSpendResult, kind: FigureKind, locale: Locale = .current) -> String {
        guard case .figures(let report) = result else { return "an incomplete total" }
        return SafeToSpendDisplay.headline((report.figure(kind) ?? report.month).remainderCents, locale: locale)
    }
}
