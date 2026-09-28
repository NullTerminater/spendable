#if DEBUG
import Foundation
import GRDB
import os

/// Synthetic data for milestone 5's acceptance run and measurements. Debug builds only, and only
/// against a scratch container (`SPENDABLE_DEBUG_CONTAINER`): nothing here may ever write into the
/// owner's real database. Every merchant, amount and id is made up.
///
/// - `SPENDABLE_DEBUG_DETECTION=seed`: a synthetic connected account with thirteen months of history
///   covering every case in PLAN milestone 5's acceptance list, then one detection drain.
/// - `SPENDABLE_DEBUG_DETECTION=bench`: 6,000 settled synthetic rows, a timed full drain with its
///   footprint change, then 30 more rows and a timed incremental drain, and the query plan. Results
///   go to `<container>/measurements.log`.
enum DebugDetection {
    private static let log = Logger(subsystem: StorePaths.bundleIdentifier, category: "debug")

    @MainActor
    static func apply(model: AppModel, mode: String) {
        guard ProcessInfo.processInfo.environment["SPENDABLE_DEBUG_CONTAINER"] != nil else {
            DebugMeasurementLog.append("detection \(mode) refused: set SPENDABLE_DEBUG_CONTAINER first")
            return
        }
        Task {
            for _ in 0..<200 where model.database == nil { try? await Task.sleep(for: .milliseconds(50)) }
            guard let database = model.database else { return }
            switch mode {
            case "seed": await seed(database)
            case "bench": await bench(database)
            default: DebugMeasurementLog.append("detection: unknown mode")
            }
        }
    }

    // MARK: Acceptance fixture

    private static func seed(_ database: AppDatabase) async {
        let now = Date()
        do {
            try await database.writer.write { db in
                guard try Account.fetchCount(db) == 0 else { return }
                let checking = try insertAccount(db, id: "SYN-CHK", name: "Synthetic Checking", type: "checking")
                let savings = try insertAccount(db, id: "SYN-SAV", name: "Synthetic Savings", type: "savings")
                let today = CalendarDay.today(in: CalendarDay.utc, now: now)
                let start = today.adding(months: -12, in: CalendarDay.utc)
                var serial = 0
                func add(_ account: Int64, _ day: CalendarDay, _ cents: Int64, _ description: String, memo: String? = nil) throws {
                    guard day <= today else { return }
                    serial += 1
                    try insertRow(db, account: account, id: "SYN\(serial)", day: day, cents: cents, description: description, memo: memo, now: now)
                }
                for month in 0...12 {
                    let base = start.adding(months: month, in: CalendarDay.utc)
                    // Spotify, going up in the eighth month: one series with a price change.
                    try add(checking, base.adding(days: 11, in: CalendarDay.utc), month < 8 ? -999 : -1099, "PAYPAL *SPOTIFY")
                    // Two Apple subscriptions at different prices.
                    try add(checking, base.adding(days: 4, in: CalendarDay.utc), -299, "APPLE.COM/BILL")
                    try add(checking, base.adding(days: 19, in: CalendarDay.utc), -999, "APPLE.COM/BILL")
                    // A gym that stopped two months ago: flagged "maybe cancelled?", still counted.
                    if month <= 10 { try add(checking, base.adding(days: 6, in: CalendarDay.utc), -4000, "PLANET FITNESS 0014") }
                    // A fixed move to savings, arriving there the same day: shown as a likely move.
                    try add(checking, base.adding(days: 1, in: CalendarDay.utc), -50000, "ONLINE TRANSFER TO SAV")
                    try add(savings, base.adding(days: 1, in: CalendarDay.utc), 50000, "ONLINE TRANSFER FROM CHK")
                    // Marketplace noise, never a bill.
                    try add(checking, base.adding(days: 9 + month % 5, in: CalendarDay.utc), -(1500 + Int64(month) * 137), "AMZN Mktp US*SYN\(month)X")
                }
                // A biweekly class, and pay coming in every two weeks, which must never be a bill.
                var day = start.adding(days: 2, in: CalendarDay.utc)
                while day <= today {
                    try add(checking, day, -2500, "SQ *CLIMBING CLASS")
                    try add(checking, day.adding(days: 3, in: CalendarDay.utc), 250000, "PAYROLL SYNTHETIC CO")
                    day = day.adding(days: 14, in: CalendarDay.utc)
                }
                // Once a year: Prime at $139 and a Costco renewal. Suggestions only.
                try add(checking, today.adding(days: -40, in: CalendarDay.utc), -13900, "Amazon Prime*SYN9Q")
                try add(checking, today.adding(days: -120, in: CalendarDay.utc), -6500, "COSTCO MEMBERSHIP RENEWAL")
                // Twice only: a suggestion, not counted.
                try add(checking, today.adding(days: -45, in: CalendarDay.utc), -1299, "NEWSPAPER DIGITAL")
                try add(checking, today.adding(days: -15, in: CalendarDay.utc), -1299, "NEWSPAPER DIGITAL")
                // A refund that cancels one charge.
                try add(checking, today.adding(days: -8, in: CalendarDay.utc), 1099, "PAYPAL *SPOTIFY")

                let from = start.adding(days: -5, in: CalendarDay.utc).utcMidnight
                let to = today.adding(days: 1, in: CalendarDay.utc).utcMidnight
                let seconds = Int64(now.timeIntervalSince1970)
                for account in [checking, savings] {
                    try SimpleFINIngest.recordCoverage(db, accountId: account, start: from, end: to, nowSeconds: seconds)
                }
                try SyncState.setDate(db, SyncState.balancesSyncedAt, now)
            }
            let report = DetectionWorker.drainNow(database: database, calendar: .current, now: { Date() })
            DebugMeasurementLog.append("detection seed: \(report.keysProcessed) merchants read, \(report.quarantined) set aside")
        } catch {
            log.error("detection seed failed: \(String(describing: type(of: error)), privacy: .public)")
            DebugMeasurementLog.append("detection seed failed")
        }
    }

    // MARK: Measurements

    private static func bench(_ database: AppDatabase) async {
        let now = Date()
        do {
            let account = try await database.writer.write { db -> Int64 in
                let id = try insertAccount(db, id: "SYN-BENCH", name: "Synthetic Bench", type: "checking")
                let today = CalendarDay.today(in: CalendarDay.utc, now: now)
                var serial = 0
                // 6,000 settled rows over thirteen months: 40 monthly merchants, 10 weekly ones, and
                // the rest spread across 150 one-off shops.
                for month in 0..<13 {
                    for merchant in 0..<40 {
                        serial += 1
                        try insertRow(db, account: id, id: "B\(serial)", day: today.adding(months: -month, in: CalendarDay.utc).adding(days: -merchant % 20, in: CalendarDay.utc),
                                      cents: -Int64(500 + merchant * 37), description: "SYNTHETIC SERVICE \(merchantName(merchant))", memo: nil, now: now)
                    }
                }
                for week in 0..<56 {
                    for merchant in 0..<10 {
                        serial += 1
                        try insertRow(db, account: id, id: "B\(serial)", day: today.adding(days: -7 * week - merchant, in: CalendarDay.utc),
                                      cents: -Int64(900 + merchant * 11), description: "SYNTHETIC WEEKLY \(merchantName(merchant))", memo: nil, now: now)
                    }
                }
                var index = 0
                while serial < 6_000 {
                    serial += 1
                    index += 1
                    try insertRow(db, account: id, id: "B\(serial)", day: today.adding(days: -(index % 395), in: CalendarDay.utc),
                                  cents: -Int64(300 + (index * 7919) % 20_000), description: "SYNTHETIC SHOP \(merchantName(index % 150))", memo: nil, now: now)
                }
                try SimpleFINIngest.recordCoverage(db, accountId: id, start: today.adding(days: -400, in: CalendarDay.utc).utcMidnight,
                                                   end: today.adding(days: 1, in: CalendarDay.utc).utcMidnight, nowSeconds: Int64(now.timeIntervalSince1970))
                return id
            }
            let before = MemoryFootprint.physicalMegabytesText()
            let fullStart = Date()
            let full = DetectionWorker.drainNow(database: database, calendar: .current, now: { Date() })
            let fullMs = Date().timeIntervalSince(fullStart) * 1_000
            let after = MemoryFootprint.physicalMegabytesText()
            DebugMeasurementLog.append(String(format: "detection full: 6000 rows, %d merchants, %.1f ms, footprint %@ -> %@",
                                              full.keysProcessed, fullMs, before, after))

            try await database.writer.write { db in
                let today = CalendarDay.today(in: CalendarDay.utc, now: now)
                for row in 0..<30 {
                    try insertRow(db, account: account, id: "INC\(row)", day: today, cents: -Int64(500 + (row % 10) * 37),
                                  description: "SYNTHETIC SERVICE \(merchantName(row % 10))", memo: nil, now: now)
                }
            }
            let incrementalStart = Date()
            let incremental = DetectionWorker.drainNow(database: database, calendar: .current, now: { Date() })
            let incrementalMs = Date().timeIntervalSince(incrementalStart) * 1_000
            let plan = try await database.reader.read { db in
                try String.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + DetectionQueries.rowsForKey,
                                    arguments: [account, "SYNTHETIC SERVICE", 0]).joined(separator: " | ")
            }
            DebugMeasurementLog.append(String(format: "detection incremental: 30 rows, %d merchants, %.1f ms; plan: %@",
                                              incremental.keysProcessed, incrementalMs, plan))
        } catch {
            DebugMeasurementLog.append("detection bench failed")
        }
    }

    // MARK: Rows

    /// Letters only, so the merchant key keeps it: digits would be stripped as a reference number.
    private static func merchantName(_ index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return String(letters[index % 26]) + String(letters[(index / 26) % 26]) + "CO"
    }

    private static func insertAccount(_ db: Database, id: String, name: String, type: String) throws -> Int64 {
        let seconds = Int64(Date().timeIntervalSince1970)
        try db.execute(sql: """
            INSERT INTO account (source, conn_id, external_id, remote_name, display_name, user_type, currency,
                                 balance_cents, available_cents, balance_date, last_seen_in_sync_at,
                                 holdings_observed_at, created_at)
            VALUES ('simplefin', 'CONN-SYNTHETIC-M5', ?, ?, ?, ?, 'USD', 350000, 350000, ?, ?, ?, ?)
            """, arguments: [id, name, name, type, seconds, seconds, seconds, seconds])
        return db.lastInsertedRowID
    }

    private static func insertRow(
        _ db: Database, account: Int64, id: String, day: CalendarDay, cents: Int64,
        description: String, memo: String?, now: Date
    ) throws {
        let posted = day.utcMidnight + 15 * 3_600
        let key = MerchantKey.normalize(payee: nil, description: description)
        try db.execute(sql: """
            INSERT INTO bank_transaction (account_id, external_id, posted, transacted_at, effective_date, amount_cents,
                description, memo, pending, first_seen_at, last_seen_at, merchant_normalized, merchant_alt, normalizer_version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
            """, arguments: [account, id, posted, posted - 86_400, posted, cents, description, memo,
                             Int64(now.timeIntervalSince1970), Int64(now.timeIntervalSince1970),
                             key.key, key.alternate, MerchantKey.version])
    }
}
#endif
