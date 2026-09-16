import Foundation
import Testing
@testable import Spendable

@Suite("Credential store")
struct CredentialStoreTests {
    static let base = URL(string: "https://beta-bridge.simplefin.org/simplefin")!

    @Test("a credential requires https, a host, no embedded user info, and both parts")
    func validation() {
        #expect(SimpleFINCredential(baseURL: Self.base, username: "u", password: "p") != nil)
        #expect(SimpleFINCredential(baseURL: URL(string: "http://beta-bridge.simplefin.org/simplefin")!, username: "u", password: "p") == nil)
        // Built with URLComponents so no credential-shaped literal exists in the repo.
        var withUserInfo = URLComponents(url: Self.base, resolvingAgainstBaseURL: false)!
        withUserInfo.user = "u"
        withUserInfo.password = "p"
        #expect(SimpleFINCredential(baseURL: withUserInfo.url!, username: "u", password: "p") == nil)
        #expect(SimpleFINCredential(baseURL: Self.base, username: "", password: "p") == nil)
        #expect(SimpleFINCredential(baseURL: Self.base, username: "u", password: "") == nil)
        #expect(SimpleFINCredential(baseURL: URL(string: "https:///simplefin")!, username: "u", password: "p") == nil)
    }

    @Test("printing a credential never reveals its parts")
    func redaction() throws {
        let credential = try #require(SimpleFINCredential(baseURL: Self.base, username: "user-xyz", password: "pass-xyz"))
        for text in [String(describing: credential), String(reflecting: credential), "\(credential)"] {
            #expect(!text.contains("user-xyz"))
            #expect(!text.contains("pass-xyz"))
            #expect(text.contains("redacted"))
        }
    }

    @Test("the in-memory store round-trips and deletes")
    func inMemory() throws {
        let store = InMemoryCredentialStore()
        let credential = try #require(SimpleFINCredential(baseURL: Self.base, username: "u", password: "p"))
        #expect(try store.load() == nil)
        try store.save(credential)
        #expect(try store.load() == credential)
        try store.delete()
        #expect(try store.load() == nil)
    }

    @Test("the keychain store writes, verifies, updates and deletes one item under a throwaway service")
    func keychain() throws {
        // A unique test service; the real service name is never touched by tests.
        let service = "com.nullterminater.spendable.tests.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service)
        defer { try? store.delete() }

        #expect(try store.load() == nil)
        let first = try #require(SimpleFINCredential(baseURL: Self.base, username: "demo", password: "one"))
        try store.save(first)
        #expect(try store.load() == first)

        let second = try #require(SimpleFINCredential(baseURL: Self.base, username: "demo", password: "two"))
        try store.replace(second, expected: first)
        #expect(try store.load() == second)
        // Retry after an already completed promotion is harmless.
        try store.replace(second, expected: first)
        #expect(try store.load() == second)
        // A stale setup screen cannot replace a credential it did not inspect.
        #expect(throws: CredentialStoreError.verificationFailed) {
            try store.replace(first, expected: first)
        }
        #expect(try store.load() == second)

        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()
    }
}
