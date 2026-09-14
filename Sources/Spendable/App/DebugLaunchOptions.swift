#if DEBUG
import AppKit
import Foundation
import GRDB
import os

/// Environment switches honoured by Debug builds only, so the measurement scripts and the builder
/// can drive the app without UI scripting. Nothing here exists in Release builds.
///
/// - `SPENDABLE_DEBUG_OPEN_WINDOW=1`: open the main window as soon as the menu bar item is up.
/// - `SPENDABLE_DEBUG_SEED_SAMPLE=1`: if there are no accounts, add three made-up manual ones.
/// - `SPENDABLE_DEBUG_MEMORY_CYCLE=N`: log the footprint at idle, then N times open the main
///   window, log, close it, log. The app stays running afterwards.
enum DebugLaunchOptions {
    private static let log = Logger(subsystem: StorePaths.bundleIdentifier, category: "debug")

    @MainActor
    static func apply(model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        if environment["SPENDABLE_DEBUG_SEED_SAMPLE"] != nil {
            Task { await seedSampleAccounts(model) }
        }
        if environment["SPENDABLE_DEBUG_OPEN_WINDOW"] != nil {
            MainWindowController.show(model: model)
        }
        if let cycles = environment["SPENDABLE_DEBUG_MEMORY_CYCLE"].flatMap(Int.init) {
            Task { await memoryCycle(model, cycles: max(1, cycles)) }
        }
    }

    @MainActor
    private static func waitForDatabase(_ model: AppModel) async -> AppDatabase? {
        for _ in 0..<200 {
            if let database = model.database { return database }
            if model.startupError != nil { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    @MainActor
    private static func seedSampleAccounts(_ model: AppModel) async {
        guard let database = await waitForDatabase(model) else { return }
        do {
            try await database.writer.write { db in
                guard try Account.fetchCount(db) == 0 else { return }
                var wallet = Account.manual(displayName: "Wallet cash", type: .cash, balanceCents: 4_000)
                var savings = Account.manual(displayName: "Ally Savings", type: .savings, balanceCents: 120_000)
                var checking = Account.manual(displayName: "Chase Checking", type: .checking, balanceCents: 124_000)
                try wallet.insert(db)
                try savings.insert(db)
                try checking.insert(db)
            }
            log.notice("seeded sample accounts")
        } catch {
            log.error("seeding failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    @MainActor
    private static func memoryCycle(_ model: AppModel, cycles: Int) async {
        guard await waitForDatabase(model) != nil else { return }
        try? await Task.sleep(for: .seconds(3))
        logFootprint("idle, menu bar only")
        for cycle in 1...cycles {
            MainWindowController.show(model: model)
            try? await Task.sleep(for: .seconds(3))
            logFootprint("cycle \(cycle): main window open")
            MainWindowController.closeForMeasurement()
            try? await Task.sleep(for: .seconds(3))
            logFootprint("cycle \(cycle): after window closed, window released = \(!MainWindowController.isOpen)")
        }
        log.notice("memory cycle done")
        DebugMeasurementLog.append("memory cycle done")
    }

    @MainActor
    private static func logFootprint(_ stage: String) {
        let text = MemoryFootprint.physicalMegabytesText()
        log.notice("footprint \(stage, privacy: .public): \(text, privacy: .public)")
        DebugMeasurementLog.append("footprint \(stage): \(text)")
    }
}
#endif
