import AppKit
import Foundation
import GRDB
import Observation
import os

/// Watches the handful of tables the figures depend on, and recomputes them when anything changes
/// — including when the calendar day rolls over, which changes nothing in the database but moves
/// both windows.
@MainActor
@Observable
final class SpendableStore {
    private(set) var result: SafeToSpendResult = .noAccountsYet
    private(set) var accounts: [Account] = []
    private(set) var charges: [RecurringCharge] = []
    private(set) var paySchedule: PaySchedule?
    private(set) var today: CalendarDay
    private(set) var failure: String?

    /// Which figure the owner is looking at. Settings makes this stick in milestone 9.
    var shownFigure: FigureKind = .calendarMonth

    private let database: AppDatabase
    private var cancellable: AnyDatabaseCancellable?
    private var dayObservers: [any NSObjectProtocol] = []
    private static let log = Logger(subsystem: StorePaths.bundleIdentifier, category: "figures")

    init(database: AppDatabase, calendar: Calendar = .current) {
        self.database = database
        self.today = CalendarDay.today(in: calendar)
        #if DEBUG
        if ProcessInfo.processInfo.environment["SPENDABLE_DEBUG_FIGURE"] == "payday" {
            shownFigure = .untilPayday
        }
        #endif
        start()
        watchForTheDayChanging()
    }

    deinit {
        // Observers are torn down with the store; the observation cancels itself when released.
    }

    private struct Snapshot: Equatable, Sendable {
        var accounts: [Account] = []
        var charges: [RecurringCharge] = []
        var paySchedule: PaySchedule?

        init(_ db: Database) throws {
            // Archived accounts are fetched too: a bill still pointing at one has to be accounted
            // for, and the engine needs the row to name it.
            accounts = try Account.fetchAll(db)
            charges = try RecurringCharge.fetchAll(db)
            paySchedule = try PaySchedule.fetch(db)
        }
    }

    private func start() {
        let observation = ValueObservation
            .tracking { db in try Snapshot(db) }
            .removeDuplicates()
        cancellable = observation.start(
            in: database.reader,
            scheduling: .async(onQueue: .main),
            onError: { [weak self] _ in
                Task { @MainActor in
                    self?.failure = "Spendable stopped keeping this up to date. Quit and open it again."
                }
            },
            onChange: { [weak self] snapshot in
                Task { @MainActor in self?.apply(snapshot) }
            })
    }

    private func apply(_ snapshot: Snapshot) {
        accounts = snapshot.accounts
        charges = snapshot.charges
        paySchedule = snapshot.paySchedule
        recompute()
    }

    private func recompute(calendar: Calendar = .current) {
        result = SafeToSpendEngine.compute(
            accounts: accounts, charges: charges, paySchedule: paySchedule,
            today: today, calendar: calendar)
    }

    /// A day changing writes nothing to the database, so no observation fires. These do.
    private func watchForTheDayChanging() {
        let centre = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange,
        ]
        for name in names {
            dayObservers.append(centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.dayMayHaveChanged() }
            })
        }
        dayObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dayMayHaveChanged() }
        })
    }

    /// Recomputes only when the date has actually moved, so waking the Mac ten times in an evening
    /// costs nothing.
    func dayMayHaveChanged(calendar: Calendar = .current, now: Date = Date()) {
        let current = CalendarDay.today(in: calendar, now: now)
        guard current != today else { return }
        Self.log.info("day rolled over; recomputing")
        today = current
        recompute(calendar: calendar)
    }

    // MARK: Writing

    func savePayAnchor(_ day: CalendarDay) async {
        await write { db in
            try PaySchedule(anchor: day).save(db)
        }
    }

    func save(_ charge: RecurringCharge) async {
        await write { db in
            var row = charge
            if row.id == nil {
                try row.insert(db)
            } else {
                try row.update(db)
            }
        }
    }

    func delete(_ charge: RecurringCharge) async {
        guard let id = charge.id else { return }
        await write { db in
            _ = try RecurringCharge.deleteOne(db, key: id)
        }
    }

    /// Records that a bill has been paid, and optionally takes it off the balance it came from in
    /// the same step, so the number cannot rise before the money does.
    func markPaid(
        _ charge: RecurringCharge,
        alsoReduceBalance: Bool,
        calendar: Calendar = .current,
        now: Date = .now
    ) async {
        let updated = charge.markingPaidOnce(
            balanceAlreadyUpdated: alsoReduceBalance, in: calendar, now: now)
        let payingId = charge.payingAccountId
        let amount = charge.amountCents
        await write { db in
            try updated.update(db)
            if alsoReduceBalance, let payingId, var account = try Account.fetchOne(db, key: payingId),
               account.source == .manual {
                account.balanceCents -= amount
                account.balanceDate = Int64(now.timeIntervalSince1970)
                account.manualUpdatedAt = account.balanceDate
                try account.update(db)
            }
        }
    }

    func setIncludeInSafeToSpend(_ account: Account, _ include: Bool) async {
        guard let id = account.id else { return }
        await write { db in
            try db.execute(
                sql: "UPDATE account SET include_in_safe_to_spend = ? WHERE id = ?",
                arguments: [include, id])
        }
    }

    private func write(_ body: @escaping @Sendable (Database) throws -> Void) async {
        do {
            try await database.writer.write(body)
        } catch {
            failure = "Spendable couldn't save that. Try again."
            Self.log.error("write failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}
