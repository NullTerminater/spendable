import Foundation
import GRDB

/// The Bills & subscriptions screen's reads (`docs/reviews/milestone-5-review.md`, decisions 24,
/// 25 and 3). Sections and the total are decided in SQL, so what is on screen never depends on how
/// many pages have been loaded.
enum BillsQueries {
    /// The screen's sections, in order.
    enum Section: Int, CaseIterable, Sendable {
        case bills = 1
        case maybeCancelled = 2
        case mightBeBills = 3
        case yearly = 4
        case movesBetweenAccounts = 5
        case transfers = 6

        var title: String {
            switch self {
            case .bills: "Bills and subscriptions"
            case .maybeCancelled: "Maybe cancelled? Still counted until you say so"
            case .mightBeBills: "These might be bills. Not counted until you confirm them"
            case .yearly: "Looks like a yearly charge. Not counted until you confirm it"
            case .movesBetweenAccounts: "Looks like a move between your accounts. Still counted until you say where it goes"
            case .transfers: "Money moved between your own accounts"
            }
        }
    }

    static let pageSize = 50

    /// Which section a row belongs in. The first matching line wins.
    static let sectionSQL = """
        CASE
            WHEN kind = 'transfer' THEN 6
            WHEN status = 'suggested' AND cadence = 'annual' AND detected_member_count <= 1 THEN 4
            WHEN status = 'suggested' THEN 3
            WHEN transfer_evidence_account_id IS NOT NULL THEN 5
            WHEN inferred_inactive_since IS NOT NULL THEN 2
            ELSE 1
        END
        """

    struct Entry: Equatable, Sendable, Identifiable {
        var section: Section
        var charge: RecurringCharge
        var id: Int64 { charge.id ?? 0 }
    }

    struct Page: Equatable, Sendable {
        var rows: [Entry]
        var hasMore: Bool
    }

    /// The first `count` rows, biggest monthly cost first within each section, then by id so the
    /// order is stable. One more row than asked for says whether there is another page.
    static func rows(_ db: Database, count: Int) throws -> Page {
        let fetched = try Row.fetchAll(db, sql: """
            SELECT *, \(sectionSQL) AS section_rank FROM recurring_charge
             WHERE status IN ('confirmed', 'suggested')
             ORDER BY section_rank ASC, monthly_cents DESC, id ASC
             LIMIT ?
            """, arguments: [count + 1])
        let rows = try fetched.prefix(count).map { row -> Entry in
            let rank: Int = row["section_rank"]
            return Entry(section: Section(rawValue: rank) ?? .bills, charge: try RecurringCharge(row: row))
        }
        return Page(rows: rows, hasMore: fetched.count > count)
    }

    /// What the owner's bills come to a month, in US dollars: one SQL sum of per-row rounded monthly
    /// cents over confirmed bills and subscriptions. A bill flagged "maybe cancelled?" is still in
    /// it; suggestions, transfers, likely moves between accounts, other currencies and anything paid
    /// from an account holding shares or funds, or a loan, are not.
    static func monthlyTotal(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(c.monthly_cents), 0) FROM recurring_charge c
              LEFT JOIN account a ON a.id = c.paying_account_id
             WHERE c.status = 'confirmed' AND c.kind <> 'transfer' AND c.transfer_evidence_account_id IS NULL
               AND c.currency = 'USD'
               AND NOT (a.id IS NOT NULL AND (a.holdings_count > 0 OR COALESCE(a.guess_class, '') IN ('investment', 'loan')))
            """) ?? 0
    }

    /// "I've checked your Chase Checking back to April 3", from the fetched spans alone, clipped at
    /// the oldest charge the bank has ever sent. An older separate span adds "and some of January".
    static func coverageLines(_ db: Database, calendar: Calendar = .current) throws -> [String] {
        var lines: [String] = []
        let accounts = try Account.fetchAll(db, sql: "SELECT * FROM account WHERE source = 'simplefin' AND archived_at IS NULL ORDER BY display_name")
        for account in accounts {
            guard let id = account.id else { continue }
            let spans = try Row.fetchAll(db, sql: "SELECT start_at, end_at FROM tx_coverage WHERE account_id = ? ORDER BY end_at DESC", arguments: [id])
            guard let newest = spans.first else {
                lines.append("I haven't checked any of \(account.displayName)'s past spending yet, so I can't find its bills.")
                continue
            }
            let floor = try DetectionQueries.evidenceFloor(db, accountId: id) ?? (newest["end_at"] as Int64)
            let start = max(newest["start_at"] as Int64, floor)
            let day = CalendarDay(epochSeconds: start, in: CalendarDay.utc)
            var line = "I've checked \(account.displayName) back to \(day.shortPhrase(in: calendar))"
            if spans.count > 1, let older = spans.dropFirst().first, (older["end_at"] as Int64) > floor {
                let olderDay = CalendarDay(epochSeconds: older["start_at"] as Int64, in: CalendarDay.utc)
                line += ", and some of \(olderDay.monthName(in: calendar))"
            }
            lines.append(line + ". Yearly charges only show up once I've seen a whole year.")
        }
        return lines
    }

    /// Things the Bills screen says once, above the list.
    struct Notices: Equatable, Sendable {
        /// Detection failed on some merchant three times and set it aside.
        var detectionFailed = false
        /// The newest fetched span is more than three days old while balances are fresh (B-04).
        var noNewTransactionsSince: CalendarDay?
        /// Places paid too often to read, by merchant key.
        var denseMerchants: [String] = []
    }

    static func notices(_ db: Database, now: Date = .now) throws -> Notices {
        var notices = Notices()
        notices.detectionFailed = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM detection_dirty WHERE failed_at IS NOT NULL)") ?? false
        let nowSeconds = Int64(now.timeIntervalSince1970)
        if let newest = try Int64.fetchOne(db, sql: """
            SELECT MAX(c.last_fetched_at) FROM tx_coverage c JOIN account a ON a.id = c.account_id
             WHERE a.archived_at IS NULL AND a.not_updating_since IS NULL
            """),
           let balances = try SyncState.date(db, SyncState.balancesSyncedAt),
           nowSeconds - newest > 3 * 86_400,
           nowSeconds - Int64(balances.timeIntervalSince1970) < 86_400 {
            notices.noNewTransactionsSince = CalendarDay(epochSeconds: newest)
        }
        notices.denseMerchants = try String.fetchAll(db, sql: "SELECT value FROM sync_state WHERE key LIKE 'detection-dense:%' ORDER BY value")
        return notices
    }
}

extension CalendarDay {
    /// "January", for "and some of January".
    func monthName(in calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return formatter.string(from: startOfDay(in: calendar))
    }
}
