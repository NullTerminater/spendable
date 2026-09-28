import Foundation
import GRDB

/// How often a charge repeats.
enum Cadence: String, Codable, Sendable, CaseIterable, Identifiable, DatabaseValueConvertible {
    case weekly
    case biweekly
    case monthly
    case quarterly
    case annual

    var id: String { rawValue }

    /// How the owner would say it.
    var label: String {
        switch self {
        case .weekly: "Every week"
        case .biweekly: "Every 2 weeks"
        case .monthly: "Every month"
        case .quarterly: "Every 3 months"
        case .annual: "Every year"
        }
    }

    /// Short form for the end of a sentence: "$12 a month".
    var perLabel: String {
        switch self {
        case .weekly: "a week"
        case .biweekly: "every 2 weeks"
        case .monthly: "a month"
        case .quarterly: "every 3 months"
        case .annual: "a year"
        }
    }

    /// Step size in whole days, for the cadences that repeat on a fixed number of days.
    var stepDays: Int? {
        switch self {
        case .weekly: 7
        case .biweekly: 14
        case .monthly, .quarterly, .annual: nil
        }
    }

    /// Step size in whole months, for the cadences that repeat on a day of the month.
    var stepMonths: Int? {
        switch self {
        case .weekly, .biweekly: nil
        case .monthly: 1
        case .quarterly: 3
        case .annual: 12
        }
    }

    /// What this cadence costs in a month, rounded to the nearest cent.
    /// A year has 52.18 weeks, but the owner's bank charges 52 weekly payments a year, so weekly
    /// is 52 ÷ 12 and biweekly is 26 ÷ 12.
    func monthlyEquivalentCents(of amountCents: Int64) -> Int64 {
        let (numerator, denominator): (Int64, Int64) = switch self {
        case .weekly: (52, 12)
        case .biweekly: (26, 12)
        case .monthly: (1, 1)
        case .quarterly: (1, 3)
        case .annual: (1, 12)
        }
        let scaled = amountCents * numerator
        // Round half away from zero so a $139 yearly charge reads $11.58 a month, not $11.57.
        let rounded = scaled < 0 ? scaled - denominator / 2 : scaled + denominator / 2
        return rounded / denominator
    }
}

enum RecurringChargeSource: String, Codable, Sendable, DatabaseValueConvertible {
    /// The owner typed it in.
    case manual
    /// Milestone 5 spotted it in the transactions.
    case detected
}

/// What kind of money movement this is. The distinction decides whether it comes off the number.
enum RecurringChargeKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// A subscription to an outside company.
    case subscription
    /// A bill from an outside company: rent, a phone bill, a utility. Being on autopay does not
    /// make it anything else — the money still leaves.
    case bill
    /// Money moving between the owner's own accounts, including a credit-card payment.
    case transfer
}

enum RecurringChargeStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case confirmed
    case suggested
    case dismissed
    case cancelled
}

enum ConfirmedBy: String, Codable, Sendable, DatabaseValueConvertible {
    case user
    case auto
}

/// Fields the owner has corrected on a detected or adopted bill. Detection records its own reading
/// in the `detected_*` columns and copies it into an effective column only while that bit is clear.
enum OwnerOverride {
    static let amount: Int64 = 1
    static let cadence: Int64 = 2
    static let account: Int64 = 4
    static let merchant: Int64 = 8
    static let anchor: Int64 = 16
}

/// One row of `recurring_charge`: something that charges the owner again and again.
struct RecurringCharge: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "recurring_charge"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    var id: Int64?
    var source: RecurringChargeSource
    var kind: RecurringChargeKind
    var name: String
    var merchantNormalized: String?
    var amountCents: Int64
    var cadence: Cadence
    /// The first occurrence ever. Every occurrence is measured from here, so a bill due on the 31st
    /// keeps landing on the 31st in months that have one.
    var anchorDate: Int64?
    /// The paid-through marker: everything before it is settled, everything from it onward is owed.
    var nextExpectedDate: Int64?
    var payingAccountId: Int64?
    /// Where a transfer goes. Meaningless for a bill or a subscription.
    var destinationAccountId: Int64?
    var status: RecurringChargeStatus
    var confirmedBy: ConfirmedBy?
    var amountChangedOn: Int64?
    var lastSeenAt: Int64?
    var fingerprint: String?
    /// When the owner last said they had paid this. An instant, not a day: it is compared against
    /// a balance's timestamp to decide which happened first, and two things on the same day cannot
    /// be ordered by day alone.
    var lastMarkedPaidAt: Int64?
    /// False while the owner has marked this paid but has not yet updated the balance it came out
    /// of. The bill keeps being subtracted until the balance catches up, otherwise the number
    /// jumps up by the bill's amount at the moment the money actually leaves.
    var paidReflectedInBalance: Bool
    var createdAt: Int64
    var updatedAt: Int64

    // Milestone 5 (schema v5, `docs/reviews/milestone-5-review.md`). The four effective columns
    // above (amount, cadence, paying account, paid-through marker) keep their shipped meaning; what
    // detection read from the bank is kept apart below, so it can never overwrite an owner's edit.

    /// How the bill shows up on a statement, as the owner typed it, and its merchant key.
    var statementMerchant: String? = nil
    var statementMerchantKey: String? = nil
    var currency: String = "USD"
    /// Bumped by every write. An owner write names the revision it saw, so a form opened before a
    /// detection or payment write reloads instead of overwriting it (decision 21).
    var revision: Int64 = 0
    /// Which fields the owner has corrected: `OwnerOverride` bits.
    var ownerOverrides: Int64 = 0
    var detectedAmountCents: Int64? = nil
    var detectedCadence: Cadence? = nil
    var detectedAnchorDate: Int64? = nil
    var detectedLastSeenDay: String? = nil
    var detectedMemberCount: Int = 0
    var amountChangedFromCents: Int64? = nil
    /// The account and merchant key detection found this on.
    var detectionAccountId: Int64? = nil
    /// Nil until an automatically confirmed bill has been seen on the Bills screen.
    var announcedAt: Int64? = nil
    /// The first expected charge that has been proven missing. A flag only: the bill keeps counting
    /// until the owner marks it cancelled (decision 2).
    var inferredInactiveSince: String? = nil
    var inferenceCheckedThrough: String? = nil
    /// The owner said "still active": charges expected on or before this day are not held against it.
    var stillActiveThrough: String? = nil
    /// The charges this was confirmed from have since been refunded, corrected or voided.
    var evidenceChanged: Bool = false
    /// Another of the owner's accounts receives the same amount: probably a move between accounts.
    var transferEvidenceAccountId: Int64? = nil
    var cancelledOn: String? = nil

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// A bill the owner typed in. Both dates are stored at the start of the day.
    static func manual(
        name: String,
        kind: RecurringChargeKind = .bill,
        amountCents: Int64,
        cadence: Cadence,
        nextDue: CalendarDay,
        payingAccountId: Int64?,
        destinationAccountId: Int64? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> RecurringCharge {
        let seconds = Int64(now.timeIntervalSince1970)
        let due = nextDue.epochSeconds(in: calendar)
        return RecurringCharge(
            id: nil,
            source: .manual,
            kind: kind,
            name: name,
            merchantNormalized: nil,
            amountCents: amountCents,
            cadence: cadence,
            anchorDate: due,
            nextExpectedDate: due,
            payingAccountId: payingAccountId,
            destinationAccountId: destinationAccountId,
            status: .confirmed,
            confirmedBy: .user,
            amountChangedOn: nil,
            lastSeenAt: nil,
            fingerprint: nil,
            lastMarkedPaidAt: nil,
            paidReflectedInBalance: true,
            createdAt: seconds,
            updatedAt: seconds)
    }
}

// MARK: - Days

extension RecurringCharge {
    var nextExpectedDay: CalendarDay? {
        nextExpectedDate.map { CalendarDay(epochSeconds: $0) }
    }

    func nextExpectedDay(in calendar: Calendar) -> CalendarDay? {
        nextExpectedDate.map { CalendarDay(epochSeconds: $0, in: calendar) }
    }

    func anchorDay(in calendar: Calendar = .current) -> CalendarDay? {
        anchorDate.map { CalendarDay(epochSeconds: $0, in: calendar) }
    }

    /// The occurrence `index` steps after the anchor. Month-based cadences always measure from the
    /// anchor, never from the previous result, so the day of the month survives February.
    func occurrence(index: Int, anchor: CalendarDay, in calendar: Calendar = .current) -> CalendarDay {
        if let days = cadence.stepDays {
            return anchor.adding(days: days * index, in: calendar)
        }
        return anchor.adding(months: (cadence.stepMonths ?? 1) * index, in: calendar)
    }

    /// Every occurrence of this charge inside `window`, both ends included.
    ///
    /// Generation runs **forward only** from `nextExpectedDate`. That marker is what "paid through"
    /// means: stepping back past it would re-subtract bills the owner has already paid, and marking
    /// a bill paid would never move the number. A charge whose marker is past the end of the window
    /// therefore has no occurrences at all, which is exactly right for rent already paid for next
    /// month. Occurrences from before the window are missed months; they are not resurrected here,
    /// because the figure is about what is due in this window.
    func occurrences(in window: ClosedRange<CalendarDay>, calendar: Calendar = .current) -> [CalendarDay] {
        guard let marker = nextExpectedDay(in: calendar) else { return [] }
        guard marker <= window.upperBound else { return [] }

        let anchor = min(anchorDay(in: calendar) ?? marker, marker)
        let first = max(marker, window.lowerBound)
        guard first <= window.upperBound else { return [] }

        var index = max(0, estimatedIndex(from: anchor, to: first, in: calendar) - 2)
        var found: [CalendarDay] = []
        // A window is at most a couple of months, so a handful of occurrences is the normal case.
        // The cap is a backstop against a corrupt anchor, never a silent truncation of real data:
        // 600 weekly steps is over eleven years.
        var steps = 0
        while steps < 600 {
            steps += 1
            let day = occurrence(index: index, anchor: anchor, in: calendar)
            index += 1
            if day < first { continue }
            if day > window.upperBound { break }
            found.append(day)
        }
        return found
    }

    /// Roughly how many steps from `anchor` to `target`, rounded down and never negative. Used only
    /// to skip ahead cheaply; the caller backs up two steps and walks, so an underestimate is safe.
    private func estimatedIndex(from anchor: CalendarDay, to target: CalendarDay, in calendar: Calendar) -> Int {
        if let days = cadence.stepDays {
            let apart = anchor.days(to: target, in: calendar)
            return apart <= 0 ? 0 : apart / days
        }
        let months = (target.year - anchor.year) * 12 + (target.month - anchor.month)
        let step = cadence.stepMonths ?? 1
        return months <= 0 ? 0 : months / step
    }

    /// The first anchor-derived occurrence strictly after `day`. Used to move a bill past the
    /// latest occurrence a bank charge has paid (milestone-5-review decision 13).
    func occurrence(after day: CalendarDay, in calendar: Calendar = .current) -> CalendarDay {
        guard let anchor = anchorDay(in: calendar) ?? nextExpectedDay(in: calendar) else { return day }
        var index = max(0, estimatedIndex(from: anchor, to: day, in: calendar) - 2)
        var steps = 0
        while steps < 1_200 {
            steps += 1
            let candidate = occurrence(index: index, anchor: anchor, in: calendar)
            index += 1
            if candidate > day { return candidate }
        }
        return day
    }

    /// This charge with its paid-through marker moved on by one step, for when the owner says they
    /// have paid it. Measured from the anchor, so the day of the month never drifts.
    ///
    /// `balanceAlreadyUpdated` is the owner's answer to "have you already taken this off the
    /// balance it came out of?". A no keeps the bill subtracted until that balance catches up.
    func markingPaidOnce(
        balanceAlreadyUpdated: Bool = true,
        in calendar: Calendar = .current,
        now: Date = .now
    ) -> RecurringCharge {
        guard let marker = nextExpectedDay(in: calendar) else { return self }
        let anchor = min(anchorDay(in: calendar) ?? marker, marker)
        var index = max(0, estimatedIndex(from: anchor, to: marker, in: calendar) - 2)
        var next = marker
        var steps = 0
        while steps < 600 {
            steps += 1
            let day = occurrence(index: index, anchor: anchor, in: calendar)
            index += 1
            if day > marker {
                next = day
                break
            }
        }
        var updated = self
        updated.nextExpectedDate = next.epochSeconds(in: calendar)
        updated.lastMarkedPaidAt = Int64(now.timeIntervalSince1970)
        updated.paidReflectedInBalance = balanceAlreadyUpdated
        updated.updatedAt = Int64(now.timeIntervalSince1970)
        return updated
    }

    /// True while the owner has said they paid this but the balance it came out of has not been
    /// updated since. The bill stays subtracted so the number does not rise before the money does.
    func isStillCountedAfterPaying(payingAccountBalanceDate: Int64?) -> Bool {
        guard !paidReflectedInBalance, let markedAt = lastMarkedPaidAt else { return false }
        guard let balanceDate = payingAccountBalanceDate else { return true }
        return balanceDate <= markedAt
    }
}

// MARK: - Queries

extension RecurringCharge {
    /// The charges that move the number: confirmed, with a marker to measure from.
    static func confirmed() -> QueryInterfaceRequest<RecurringCharge> {
        RecurringCharge
            .filter(Column("status") == RecurringChargeStatus.confirmed.rawValue)
            .filter(Column("next_expected_date") != nil)
    }

    /// Everything the owner should see on the bills screen, biggest monthly cost first.
    static func visible() -> QueryInterfaceRequest<RecurringCharge> {
        RecurringCharge
            .filter([RecurringChargeStatus.confirmed.rawValue, RecurringChargeStatus.suggested.rawValue]
                .contains(Column("status")))
            .order(Column("amount_cents").desc)
    }
}
