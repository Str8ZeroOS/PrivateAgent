import Foundation
#if canImport(Security)
import Security
#endif

/// Minimal key/value storage for credentials and connection state.
///
/// Bridge bearer tokens go to `KeychainCredentialStore` on Apple platforms.
/// Non-secret state (for example a WebDriverAgent session id) can use
/// `UserDefaultsCredentialStore`. Tests use `InMemoryCredentialStore`.
public protocol CredentialStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String) throws
    func removeValue(forKey key: String)
}

public enum CredentialStoreError: Error, Sendable, Equatable {
    case unexpectedStatus(Int32)
    case encodingFailed
}

/// Thread-safe in-memory store, used by unit tests and as the Linux fallback.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var values: [String: String]
    private let lock = NSLock()

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    public func set(_ value: String, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    public func removeValue(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = nil
    }

    public var allKeys: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(values.keys)
    }
}

/// Non-secret values only (session ids, last-known kinds). Never tokens.
public struct UserDefaultsCredentialStore: CredentialStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "PrivateAgent.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: prefix + key)
    }

    public func set(_ value: String, forKey key: String) throws {
        defaults.set(value, forKey: prefix + key)
    }

    public func removeValue(forKey key: String) {
        defaults.removeObject(forKey: prefix + key)
    }
}

#if canImport(Security)
/// iOS / macOS Keychain storage (generic password items).
///
/// Items are `AfterFirstUnlockThisDeviceOnly`, so they never sync to iCloud
/// or migrate to another device through a backup.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String

    public init(service: String = "PrivateAgent.Credentials") {
        self.service = service
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    public func string(forKey key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else { throw CredentialStoreError.encodingFailed }
        let query = baseQuery(key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(updateStatus)
        }
        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(addStatus)
        }
    }

    public func removeValue(forKey key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }
}
#endif

public enum CredentialStores {
    /// Secure store for bearer tokens: Keychain on Apple platforms, memory elsewhere.
    public static func secure() -> any CredentialStore {
        #if canImport(Security)
        return KeychainCredentialStore()
        #else
        return InMemoryCredentialStore()
        #endif
    }
}

/// Keys used for persisted connection credentials. Scoped by host:port so
/// switching between a PC and a Mac bridge never mixes tokens.
public enum CredentialKeys {
    public static func bridgeToken(host: String, port: Int) -> String {
        "bridgeToken:\(host.lowercased()):\(port)"
    }

    public static func wdaSession(host: String, port: Int) -> String {
        "wdaSession:\(host.lowercased()):\(port)"
    }

    public static func wdaToken(host: String, port: Int) -> String {
        "wdaToken:\(host.lowercased()):\(port)"
    }
}

/// Never print full credentials. Shows only the length and last 4 characters.
public enum SecretRedactor {
    public static func redact(_ secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return "<none>" }
        guard secret.count > 8 else { return "••••(\(secret.count))" }
        return "••••\(secret.suffix(4)) (\(secret.count) chars)"
    }
}
