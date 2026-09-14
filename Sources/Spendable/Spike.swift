#if DEBUG
import Foundation
import Security
import os

/// Milestone 1 feasibility spike. Writes a sentinel into the App Group container (so the widget
/// stub can prove it reads the same container from inside its sandbox) and round-trips a DUMMY
/// generic-password item through the login keychain (to prove that rebuilding with the same
/// signature does not trigger an access prompt). Writes a plain-text report next to the sentinel
/// for the builder to read. Nothing here touches real data. Deleted before the v0.1 tag.
enum Spike {
    static let groupIdentifier = "UW2KV7XB66.spendable"
    private static let log = Logger(subsystem: "com.nullterminater.spendable", category: "spike")

    static func run() {
        var lines: [String] = []
        let fm = FileManager.default
        let container = fm.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)

        if let container {
            lines.append("container: \(container.path)")
            do {
                try fm.createDirectory(at: container, withIntermediateDirectories: true)
                let sentinel = container.appendingPathComponent("spike.txt")
                try "ok \(Date().timeIntervalSince1970)".write(to: sentinel, atomically: true, encoding: .utf8)
                lines.append("sentinel: written")
            } catch {
                lines.append("sentinel: FAILED \(error)")
            }
        } else {
            lines.append("container: nil")
        }

        lines.append(contentsOf: keychainRoundTrip())

        let report = lines.joined(separator: "\n")
        log.info("\(report, privacy: .public)")
        if let container {
            try? report.write(to: container.appendingPathComponent("spike-report.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Reads the dummy item if present (second launch / rebuilt binary), otherwise creates it.
    private static func keychainRoundTrip() -> [String] {
        let service = "com.nullterminater.spendable.spike"
        let account = "spike"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &item)
        if readStatus == errSecSuccess, let data = item as? Data {
            return ["keychain: read existing dummy item, \(data.count) bytes, status \(readStatus)"]
        }
        query.removeValue(forKey: kSecReturnData as String)
        query[kSecValueData as String] = Data("spike \(Date().timeIntervalSince1970)".utf8)
        query[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        return ["keychain: read status \(readStatus) (expected -25300 on first launch), add status \(addStatus)"]
    }
}
#endif
