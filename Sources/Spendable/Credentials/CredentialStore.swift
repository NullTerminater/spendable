import Foundation
import Security
import Synchronization

/// The SimpleFIN access URL, split into its parts. It is never printed, never logged, and never
/// encoded anywhere except inside `KeychainCredentialStore`.
struct SimpleFINCredential: Sendable, Equatable {
    /// The server root without credentials, e.g. `https://beta-bridge.simplefin.org/simplefin`.
    let baseURL: URL
    let username: String
    let password: String

    /// Fails unless the base URL is https, has a host, carries no credentials, and both parts are non-empty.
    init?(baseURL: URL, username: String, password: String) {
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.host() != nil,
              baseURL.user() == nil, baseURL.password() == nil,
              !username.isEmpty, !password.isEmpty
        else { return nil }
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }
}

extension SimpleFINCredential: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "<SimpleFINCredential redacted>" }
    var debugDescription: String { description }
}

enum CredentialStoreError: Error, Equatable {
    /// The item was written but reading it back did not return the same credential.
    case verificationFailed
    case keychain(OSStatus)
    case encoding
}

/// Where the SimpleFIN credential lives. The app has exactly one real implementation (Keychain)
/// and one in-memory implementation for tests and previews.
protocol CredentialStore: Sendable {
    func load() throws -> SimpleFINCredential?
    /// Writes the credential, then reads it back and compares before returning. Throws if the
    /// read-back differs, so a caller never believes a credential is stored when it is not.
    func save(_ credential: SimpleFINCredential) throws
    func delete() throws
}

final class InMemoryCredentialStore: CredentialStore {
    private let state = Mutex<SimpleFINCredential?>(nil)

    init() {}

    func load() throws -> SimpleFINCredential? {
        state.withLock { $0 }
    }

    func save(_ credential: SimpleFINCredential) throws {
        state.withLock { $0 = credential }
    }

    func delete() throws {
        state.withLock { $0 = nil }
    }
}

/// One generic-password item in the login keychain. The service is reserved for this item; the
/// account name is fixed. The encrypted payload is a small JSON object holding all three parts,
/// so the base URL and the user part never sit in unencrypted keychain metadata.
///
/// The data-protection keychain is deliberately not used: under a free Personal Team its access
/// group would depend on a provisioning profile that expires every seven days.
final class KeychainCredentialStore: CredentialStore {
    private let service: String
    private let account = "access"

    init(service: String = StorePaths.keychainService) {
        self.service = service
    }

    private struct Payload: Codable {
        var base: String
        var user: String
        var password: String
    }

    func load() throws -> SimpleFINCredential? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw CredentialStoreError.encoding }
            return try Self.decode(data)
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychain(status)
        }
    }

    func save(_ credential: SimpleFINCredential) throws {
        let data = try Self.encode(credential)
        let query = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrSynchronizable as String] = false
            add[kSecAttrLabel as String] = "Spendable — SimpleFIN access"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }

        guard let readBack = try load(), readBack == credential else {
            throw CredentialStoreError.verificationFailed
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func encode(_ credential: SimpleFINCredential) throws -> Data {
        let payload = Payload(
            base: credential.baseURL.absoluteString,
            user: credential.username,
            password: credential.password)
        do {
            return try JSONEncoder().encode(payload)
        } catch {
            throw CredentialStoreError.encoding
        }
    }

    private static func decode(_ data: Data) throws -> SimpleFINCredential {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let url = URL(string: payload.base),
              let credential = SimpleFINCredential(baseURL: url, username: payload.user, password: payload.password)
        else { throw CredentialStoreError.encoding }
        return credential
    }
}
