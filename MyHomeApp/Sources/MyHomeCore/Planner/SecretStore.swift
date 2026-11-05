// API-key storage behind a protocol: the Keychain in the app, an in-memory
// double in tests. Keys never touch UserDefaults, logs or error text.
import Foundation
import Security

public protocol SecretStore: AnyObject {
    func read(account: String) throws -> String?
    func write(_ secret: String, account: String) throws
    func delete(account: String) throws
}

public enum SecretStoreError: Error, Equatable, LocalizedError {
    case keychain(Int32)
    public var errorDescription: String? {
        switch self {
        case .keychain(let status): return "The API key could not be accessed in Keychain (status \(status))."
        }
    }
}

public final class KeychainSecretStore: SecretStore {
    public static let service = "com.myhome.app.planner"

    public init() {}

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
    }

    public func read(account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw SecretStoreError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw SecretStoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw SecretStoreError.keychain(status)
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }
}

/// Test double; also a safe default when no Keychain is wanted.
public final class InMemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    public init() {}
    public func read(account: String) throws -> String? { values[account] }
    public func write(_ secret: String, account: String) throws { values[account] = secret }
    public func delete(account: String) throws { values[account] = nil }
}

public extension AppSettings {
    /// Keychain account for a cloud provider's key.
    static func plannerSecretAccount(for provider: PlannerProvider) -> String {
        "planner-\(provider.rawValue)"
    }
}
