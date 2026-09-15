import Darwin
import Foundation
import GRDB
import Testing
@testable import Spendable

/// The specification asks for an app that is effectively free to run, and says a year of
/// transactions must never be held in memory to be stored. This pushes a synthetic year through
/// the real ingestion path and checks that nothing accumulates across windows.
///
/// What is asserted is the **live heap**, measured with `malloc_zone_statistics`, returning to
/// where it started. `phys_footprint` is reported but never asserted: freed malloc pages stay
/// resident, so it does not come back down, and inside a test host it is dominated by the rest of
/// the suite rather than by anything this test did.
@Suite("Storing a year of transactions", .serialized)
struct IngestMemoryTests {
    static var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    static func liveHeapBytes() -> UInt64 {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return UInt64(statistics.size_in_use)
    }

    /// One window's worth of JSON for four accounts, built rather than committed as a fixture.
    static func windowJSON(accounts: [String], perAccount: Int, startingAt day: Int64, seed: Int) -> Data {
        var accountBlobs: [String] = []
        for (accountIndex, name) in accounts.enumerated() {
            var rows: [String] = []
            for index in 0..<perAccount {
                let posted = day + Int64(index) * 3_600
                let cents = (seed * 7 + index * 13 + accountIndex * 3) % 9_000 + 100
                rows.append("""
                    {"id":"TX-\(seed)-\(accountIndex)-\(index)","posted":\(posted),\
                    "amount":"-\(cents / 100).\(String(format: "%02d", cents % 100))",\
                    "description":"MERCHANT \(index % 40)","payee":"Merchant \(index % 40)",\
                    "memo":"CARD PURCHASE \(index)","mcc":"5411"}
                    """)
            }
            accountBlobs.append("""
                {"id":"\(name)","name":"\(name)","conn_id":"CON-TEST","currency":"USD",\
                "balance":"1000.00","available-balance":"1000.00","balance-date":\(day),\
                "transactions":[\(rows.joined(separator: ","))]}
                """)
        }
        return Data("""
            {"errlist":[],"connections":[{"conn_id":"CON-TEST","name":"Test Bank","org_id":"ORG-TEST"}],\
            "accounts":[\(accountBlobs.joined(separator: ","))]}
            """.utf8)
    }

    @Test("a year of transactions goes in without the heap growing")
    func aYearOfTransactions() throws {
        let database = try AppDatabase.inMemory()
        let names = ["Checking", "Savings", "Card", "Cash"]
        try database.writer.write { db in
            for name in names {
                try db.execute(sql: """
                    INSERT INTO account (source, conn_id, external_id, remote_name, display_name,
                                         currency, balance_cents, balance_date, created_at)
                    VALUES ('simplefin', 'CON-TEST', ?, ?, ?, 'USD', 100000, 1789516800, 0)
                    """, arguments: [name, name, name])
            }
        }

        let today = CalendarDay(year: 2026, month: 9, day: 14)
        let windows = BackfillPlan.windows(endingOn: today, calendar: Self.chicago)
        // Roughly six thousand transactions: a year of ordinary spending across four accounts.
        let perAccountPerWindow = 6_000 / (windows.count * names.count)

        // Warm everything up first, so the baseline is not measuring one-time allocations.
        let warmUp = Self.windowJSON(accounts: names, perAccount: 5, startingAt: 1_700_000_000, seed: 999)
        try database.writer.write { db in
            var outcome = SyncOutcome()
            let set = try SimpleFINAccountSet.decode(warmUp)
            for account in set.accounts {
                _ = account
            }
            _ = outcome
        }

        let baselineHeap = Self.liveHeapBytes()
        let baselineFootprint = MemoryFootprint.physicalBytes() ?? 0

        var totalRows = 0
        for (index, window) in windows.enumerated() {
            // Each window is decoded and inserted inside its own scope, and the data goes away with
            // it. Nothing is carried to the next one.
            try autoreleasepool {
                let data = Self.windowJSON(
                    accounts: names, perAccount: perAccountPerWindow,
                    startingAt: window.lowerBound.epochSeconds(in: Self.chicago), seed: index)
                let set = try SimpleFINAccountSet.decode(data)
                let outcome = try database.writer.write { db in
                    try SimpleFINIngest.ingest(
                        set, kind: .window(start: window.lowerBound, end: window.upperBound),
                        into: db, now: Date(timeIntervalSince1970: 1_789_600_000), calendar: Self.chicago)
                }
                totalRows += outcome.transactionsInserted
            }
        }

        // Let SQLite give back what it was holding, then look at the heap.
        try database.writer.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA shrink_memory") }
        malloc_zone_pressure_relief(nil, 0)
        let afterHeap = Self.liveHeapBytes()
        let afterFootprint = MemoryFootprint.physicalBytes() ?? 0

        let stored = try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bank_transaction") ?? 0
        }
        #expect(stored == totalRows)
        #expect(stored > 4_000, "the test should push a year's worth, got \(stored)")

        let grewBy = afterHeap > baselineHeap ? afterHeap - baselineHeap : 0
        let footprintDelta = afterFootprint > baselineFootprint ? afterFootprint - baselineFootprint : 0
        // Reported for the record; the assertion is on the live heap below.
        print("""
            memory: \(stored) transactions through the real ingestion path in \(windows.count) windows
              live heap: \(baselineHeap / 1_048_576) MB -> \(afterHeap / 1_048_576) MB (grew \(grewBy / 1_024) KB)
              phys_footprint: \(baselineFootprint / 1_048_576) MB -> \(afterFootprint / 1_048_576) MB (delta \(footprintDelta / 1_048_576) MB, reported only)
            """)

        // Four megabytes of slack for SQLite's own page cache, which grows with the database and is
        // not the app holding transactions. A version that accumulated every decoded row would be
        // holding several times that.
        #expect(grewBy < 4 * 1_048_576, "the heap grew by \(grewBy / 1_024) KB storing a year")
    }

    @Test("one window's data is released as soon as its scope ends")
    func windowDataIsReleased() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO account (source, conn_id, external_id, remote_name, display_name,
                                     currency, balance_cents, balance_date, created_at)
                VALUES ('simplefin', 'CON-TEST', 'Checking', 'Checking', 'Checking', 'USD', 0, 1789516800, 0)
                """)
        }

        // A buffer that reports when it is freed, so the release is proved rather than assumed.
        final class ReleaseFlag: @unchecked Sendable {
            var freed = false
        }
        let flag = ReleaseFlag()
        let json = Self.windowJSON(accounts: ["Checking"], perAccount: 200, startingAt: 1_789_000_000, seed: 1)
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: json.count, alignment: 1)
        json.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: json.count)

        try autoreleasepool {
            let data = Data(bytesNoCopy: bytes, count: json.count, deallocator: .custom { pointer, _ in
                flag.freed = true
                pointer.deallocate()
            })
            let set = try SimpleFINAccountSet.decode(data)
            _ = try database.writer.write { db in
                try SimpleFINIngest.ingest(
                    set, kind: .window(start: CalendarDay(year: 2026, month: 9, day: 1),
                                       end: CalendarDay(year: 2026, month: 9, day: 14)),
                    into: db, now: Date(timeIntervalSince1970: 1_789_600_000), calendar: Self.chicago)
            }
            #expect(!flag.freed, "the data should still be alive while it is being ingested")
        }
        #expect(flag.freed, "the response data should be gone once its scope ends")
        #expect(try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bank_transaction") ?? 0
        } == 200)
    }
}
