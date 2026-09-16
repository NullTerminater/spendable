import Foundation

/// Owner-facing connection states hold no setup token, URL or credential.
enum SetupState: Equatable {
    case checking, ready, alreadyConnected, keychainUnavailable, claiming, unsaved, connected
    case freshCredentialRejected
}

enum ConnectionBanner: Equatable {
    case unsaved
    case keychain
    case rejected(String?)
    case freshCredentialRejected(String?)

    var title: String {
        switch self {
        case .unsaved: "Your connection hasn't been saved yet"
        case .keychain: "macOS won't let me open your saved connection"
        case .rejected: "Your bank connection has stopped working"
        case .freshCredentialRejected: "SimpleFIN rejected the connection I just saved"
        }
    }
    var symbol: String {
        switch self {
        case .unsaved, .keychain: "lock.fill"
        case .rejected, .freshCredentialRejected: "exclamationmark.triangle.fill"
        }
    }
    var body: String {
        switch self {
        case .unsaved:
            "I claimed your setup token, so that token is used up now — don't make another one yet. macOS wouldn't let me save the connection, but I still have it. Unlock your login keychain and press Try again. Don't quit Spendable until this works: if you quit, the connection is lost and you'll need a new setup token."
        case .keychain:
            "Your connection is still saved — macOS wouldn't let me read it. Unlock your login keychain and press Try again. Don't make a new setup token: you don't need one."
        case .rejected(let serverMessage):
            "SimpleFIN won't accept the connection Spendable saved, so no new balances are coming in. Make a new setup token on the SimpleFIN website and paste it here."
                + (serverMessage.map { " SimpleFIN said: \"\($0)\"" } ?? "")
        case .freshCredentialRejected(let serverMessage):
            ConnectionPresentation.freshCredentialRejected
                + (serverMessage.map { " SimpleFIN said: \"\($0)\"" } ?? "")
        }
    }
}

enum ConnectionPresentation {
    static let freshCredentialRejected = "SimpleFIN rejected the credential I just stored. This is a bug in Spendable, not a problem with your token — don't generate another one. Your saved connection is still here; try Check again and tell the developer if this keeps happening."
    static let droppedClaim = "I couldn't reach SimpleFIN, so I don't know whether that setup token was used or not. Don't press Connect again with this one — if it did go through, it's already spent. Make a fresh setup token on the SimpleFIN website and paste that instead."
    static let locallyUsedToken = "That setup token has already been used — by this app, a few minutes ago, when the connection dropped. It's spent and it can't be reused. Make one new setup token on the SimpleFIN website and paste it here. Nothing has gone wrong with your bank and there's nothing to disable."
    static let emptyConnection = "Connected — your setup token worked and I've saved the connection. SimpleFIN didn't send any accounts, which usually means no bank is linked to your SimpleFIN account yet, or one is still being set up. Go to the SimpleFIN website, link a bank, then press Check again. Don't make another setup token: this one is working."

    static func message(_ report: SyncReport, lastBalances: Date?, now: Date = .now) -> String? {
        if let failure = report.failure {
            if report.balancesRefreshed, case .credentialRejected = failure { return failure.ownerFacingMessage }
            if report.balancesRefreshed {
                return "Your balances arrived, but I couldn't finish fetching your past spending. I'll carry on on the next check."
            }
            return failure.ownerFacingMessage
        }
        if report.skippedBecause == "no requests left today" || report.refusal == .dayIsFull {
            if let lastBalances, Calendar.current.isDate(lastBalances, inSameDayAs: now) {
                return "Already refreshed today — SimpleFIN only gets new bank data about once a day."
            }
            let asOf = lastBalances.map { " The balances below are from \(AsOf.dayPhrase(epochSeconds: Int64($0.timeIntervalSince1970), now: now))." } ?? " No balances have arrived yet."
            return "I've used up today's requests to SimpleFIN, so I can't fetch anything new right now." + asOf
        }
        if report.skippedBecause == "SimpleFIN warned about the rate" {
            return "SimpleFIN asked me to wait before checking again. I'll try when its request limit clears."
        }
        let date = report.coveredBackTo.flatMap(CalendarDay.init(isoString:))?.shortPhrase()
        let coverage = date.map { ", and your spending back to \($0)" } ?? ""
        if report.balancesRefreshed {
            if report.outcome.accountsSeen == 0 && report.outcome.notices.isEmpty { return emptyConnection }
            switch report.historyStopped {
            case .budget:
                return "I've got your accounts and balances\(coverage). I'll fetch the older months over the next day or two. Nothing here is waiting on you."
            case .noMoreHistory:
                return "I've got your accounts and balances\(coverage) — that's as far as your bank goes."
            case .reachedThirteenMonths:
                return "I've got your accounts and balances\(coverage) — that's the thirteen months of history this app keeps."
            case .failed:
                return "Your balances are up to date. I'll carry on filling in your history on the next check."
            case .none:
                return "Your accounts and balances are up to date."
            }
        }
        return report.credentialProblem
    }
}
