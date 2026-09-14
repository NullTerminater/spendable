import Foundation
import Observation
import os

/// App-wide state: the open database and the credential store. Created once by `SpendableApp`.
///
/// The database is opened *after* the menu bar item is visible and off the main actor, so the
/// launch-to-bar time never includes SQLite or migrations.
@MainActor
@Observable
final class AppModel {
    private(set) var database: AppDatabase?
    private(set) var startupError: String?
    let credentialStore: any CredentialStore

    private var started = false
    private static let log = Logger(subsystem: StorePaths.bundleIdentifier, category: "startup")

    init(credentialStore: any CredentialStore = KeychainCredentialStore()) {
        self.credentialStore = credentialStore
    }

    /// For tests and previews: a model whose database is already open.
    init(database: AppDatabase, credentialStore: any CredentialStore = InMemoryCredentialStore()) {
        self.database = database
        self.credentialStore = credentialStore
        self.started = true
    }

    /// Opens the store. Idempotent. Safe to call from the menu bar label's first appearance.
    func start() {
        guard !started else { return }
        started = true
        // The hosted test bundle must never open the owner's real store; tests use in-memory databases.
        if ProcessInfo.processInfo.isRunningTests { return }
        Task.detached(priority: .userInitiated) {
            let opened: Result<AppDatabase, any Error> = Result {
                let paths = try StorePaths.live()
                return try AppDatabase.open(at: paths.databaseURL)
            }
            await MainActor.run {
                switch opened {
                case .success(let database):
                    self.database = database
                    Self.log.info("database ready")
                case .failure(let error):
                    // Error descriptions here carry a path at most, never data.
                    self.startupError = Self.plainMessage(for: error)
                    Self.log.error("database failed to open: \(String(describing: type(of: error)), privacy: .public)")
                }
            }
        }
    }

    private static func plainMessage(for error: any Error) -> String {
        if let pathsError = error as? StorePaths.Error, pathsError == .noGroupContainer {
            return "Spendable can't find its storage folder. The app is probably not signed correctly; rebuild it from Xcode."
        }
        return "Spendable couldn't open its storage. Quit and open it again; if this keeps happening, tell the developer."
    }
}
