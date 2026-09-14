import Foundation

/// The one place that knows where Spendable keeps its files.
///
/// Everything lives in the App Group container so the widget can read the summary file the app
/// writes. The database is app-only by convention: the widget never opens it (see docs/PLAN.md).
struct StorePaths: Sendable, Equatable {
    static let groupIdentifier = "UW2KV7XB66.spendable"
    static let bundleIdentifier = "com.nullterminater.spendable"
    /// Keychain service of the SimpleFIN credential item. Reserved: nothing else may use it.
    static let keychainService = "com.nullterminater.spendable.simplefin"

    let containerURL: URL

    var databaseURL: URL {
        containerURL.appendingPathComponent("spendable.sqlite", isDirectory: false)
    }

    var widgetSummaryURL: URL {
        containerURL.appendingPathComponent("widget-summary.json", isDirectory: false)
    }

    enum Error: Swift.Error, Equatable {
        /// The app is running without the App Group entitlement (wrong signature).
        case noGroupContainer
    }

    /// The real container. Fails only if the app is signed without the App Group entitlement.
    ///
    /// Debug builds honour `SPENDABLE_DEBUG_CONTAINER=/some/dir` so measurement runs and sample
    /// data never touch the owner's real database.
    static func live(fileManager: FileManager = .default) throws -> StorePaths {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["SPENDABLE_DEBUG_CONTAINER"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return StorePaths(containerURL: url)
        }
        #endif
        guard let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            throw Error.noGroupContainer
        }
        return StorePaths(containerURL: url)
    }

    /// A throwaway container under the temporary directory. Tests only.
    static func temporary(fileManager: FileManager = .default) throws -> StorePaths {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("spendable-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return StorePaths(containerURL: url)
    }
}
