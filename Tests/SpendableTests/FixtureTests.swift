import Foundation
import Testing
@testable import Spendable

/// Guards the fixtures themselves. The repository must never hold a real balance, account number or
/// credential, and the surest way to keep that true is to check it on every test run.
@Suite("Fixtures hold only public demo data")
struct FixtureTests {
    static func fixtureDirectory(_ name: String) throws -> URL {
        let bundle = Bundle(for: FixtureMarker.self)
        guard let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
                ?? bundle.resourceURL?.appendingPathComponent("Fixtures/\(name)")
        else { throw FixtureError.missing(name) }
        return url
    }

    static func load(_ path: String) throws -> Data {
        let bundle = Bundle(for: FixtureMarker.self)
        guard let root = bundle.resourceURL else { throw FixtureError.missing(path) }
        let url = root.appendingPathComponent("Fixtures/\(path)")
        guard FileManager.default.fileExists(atPath: url.path) else { throw FixtureError.missing(url.path) }
        return try Data(contentsOf: url)
    }

    static func demoFiles() throws -> [URL] {
        let directory = try fixtureDirectory("Demo")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test("the captured responses are present and are the demo server's")
    func demoFixturesAreDemo() throws {
        let files = try Self.demoFiles()
        #expect(files.count >= 5)
        let names = Set(files.map(\.lastPathComponent))
        #expect(names.contains("v2-balances-only.json"))
        #expect(names.contains("v2-window.json"))
        #expect(names.contains("v2-range-capped.json"))
        #expect(names.contains("v2-bad-credentials.json"))

        for file in files where file.pathExtension == "json" {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            let accounts = json["accounts"] as? [[String: Any]] ?? []
            for account in accounts {
                let id = account["id"] as? String ?? ""
                #expect(id.hasPrefix("Demo "), "fixture \(file.lastPathComponent) holds a non-demo account id")
            }
            if let connections = json["connections"] as? [[String: Any]] {
                for connection in connections {
                    let id = connection["conn_id"] as? String ?? ""
                    #expect(id.contains("DEMO") || id.contains("demo"),
                            "fixture \(file.lastPathComponent) holds a non-demo connection")
                }
            }
        }
    }

    @Test("no fixture contains anything shaped like a credential")
    func noCredentialsInFixtures() throws {
        // A URL carrying a username and password, or the base64 of a URL, which is what a setup
        // token is. Written so this file does not match its own patterns.
        let userInfo = try Regex("https?://[^/\\s\"]+:[^/\\s@\"]+@")
        let base64URL = try Regex("aHR0cHM6L" + "y|aHR0cDov" + "L")
        let basicAuth = try Regex("Basic [A-Za-z0-9+/=]{20,}")

        for file in try Self.demoFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.firstMatch(of: userInfo) == nil, "\(file.lastPathComponent) holds a URL with credentials")
            #expect(text.firstMatch(of: base64URL) == nil, "\(file.lastPathComponent) holds a base64 URL")
            #expect(text.firstMatch(of: basicAuth) == nil, "\(file.lastPathComponent) holds a Basic credential")
        }
    }
}

enum FixtureError: Error {
    case missing(String)
}

/// Only here so `Bundle(for:)` can find the test bundle.
final class FixtureMarker {}
