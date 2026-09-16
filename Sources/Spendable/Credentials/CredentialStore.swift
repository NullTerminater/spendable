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

extension SimpleFINCredential: CustomReflectable {
    /// Both description forms returning "redacted" is not enough on its own: `dump()` and anything
    /// else built on `Mirror` walk the stored properties directly and print the password verbatim.
    /// An empty mirror is what actually closes that door.
    var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

enum CredentialStoreError: Error, Equatable {
    /// Which way the keychain was being used when it refused. The owner-facing sentence has to say
    /// which, because the two ask for different next moves: a failed read means the connection the
    /// app already has could not be opened, and a failed write means the token just pasted was
    /// spent and not kept. Telling the owner to "try again" after a failed *write* sends them back
    /// to a token the server has already burned, and the 403 that follows reads as theft.
    enum Operation: Equatable, Sendable {
        case reading
        case writing
    }

    /// The item was written but reading it back did not return the same credential.
    case verificationFailed
    case keychain(OSStatus, while: Operation)
    case encoding

    /// macOS refused rather than reported nothing there. The difference matters enormously: a
    /// locked keychain must never be mistaken for "the bank rejected your connection", which would
    /// send the owner off to burn a setup token they did not need to burn.
    var isRefusalRatherThanAbsence: Bool {
        guard case .keychain(let status, _) = self else { return false }
        return status == errSecInteractionNotAllowed || status == errSecAuthFailed
            || status == errSecUserCanceled || status == errSecNotAvailable
    }

    var ownerFacingMessage: String {
        if case .keychain(_, let operation) = self, isRefusalRatherThanAbsence {
            switch operation {
            case .reading:
                return "macOS wouldn't let me read your saved connection. Unlock your login keychain and try again."
            case .writing:
                return "macOS wouldn't let me save the connection. Unlock your login keychain and press Try again."
            }
        }
        switch self {
        case .verificationFailed:
            return "macOS said it saved your connection, but reading it back gave something different. Nothing has been kept."
        case .encoding:
            return "Your saved connection couldn't be read. You'll need to connect again."
        case .keychain(_, .reading):
            return "macOS wouldn't let me read your saved connection."
        case .keychain(_, .writing):
            return "macOS wouldn't let me save the connection."
        }
    }
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
    private let account: String

    /// The owner's real connection.
    static let realAccount = "access"
    /// Where a Debug build's "connect to the public demo" action writes. Debug and Release share a
    /// bundle identifier and a login keychain, so without a separate name one demo connection would
    /// overwrite the owner's real access URL — unrecoverable without hand-making a new token.
    static let demoAccount = "access-demo"

    init(service: String = StorePaths.keychainService, account: String = KeychainCredentialStore.realAccount) {
        self.service = service
        self.account = account
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
            throw CredentialStoreError.keychain(status, while: .reading)
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
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status, while: .writing) }

        // The read-back is part of saving, so a keychain that refuses it is reported as a failed
        // save. Otherwise the owner is told to retry a read they never asked for.
        let readBack: SimpleFINCredential?
        do {
            readBack = try load()
        } catch CredentialStoreError.keychain(let status, _) {
            throw CredentialStoreError.keychain(status, while: .writing)
        }
        guard let readBack, readBack == credential else {
            throw CredentialStoreError.verificationFailed
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status, while: .writing)
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
