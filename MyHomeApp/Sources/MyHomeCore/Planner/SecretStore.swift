// API-key storage behind a protocol: the Keychain in the app, an in-memory
// double in tests. Keys never touch UserDefaults, logs or error text.
import Foundation
import Security

public protocol SecretStore: AnyObject {
    func read(account: String) throws -> String?
    func write(_ secret: String, account: String) throws
    func delete(account: String) throws
    /// When the stored item was last written (nil when unknown or missing). Never reads the secret.
    func modificationDate(account: String) -> Date?
}

public extension SecretStore {
    func modificationDate(account: String) -> Date? { nil }
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
        guard let text = String(data: data, encoding: .utf8) else { throw SecretStoreError.keychain(errSecDecode) }
        return text
    }

    /// Legacy (file-based) login keychain on purpose: the data-protection keychain
    /// needs a keychain-access-groups entitlement backed by a provisioning profile,
    /// which an ad-hoc signed build lacks (it fails with -34018). The cost is that
    /// an item's ACL is tied to the creating code signature, so after a rebuild with
    /// a new ad-hoc cdhash the old item can be unreadable: write() therefore replaces
    /// an item it cannot update, and read errors are surfaced, never swallowed.
    /// Sign with MYHOME_SIGN_IDENTITY (stable designated requirement) to avoid it.
    public func write(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            // Stale ACL from an earlier build or any other update failure: replace the item.
            let removed = SecItemDelete(query(account) as CFDictionary)
            guard removed == errSecSuccess || removed == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
        }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecretStoreError.keychain(added) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }

    /// Attributes only (no kSecReturnData), so this never touches the secret or prompts for it.
    public func modificationDate(account: String) -> Date? {
        var request = query(account)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }
}

/// Test double; also a safe default when no Keychain is wanted.
public final class InMemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    private var dates: [String: Date] = [:]
    private let clock: () -> Date
    public init(clock: @escaping () -> Date = Date.init) { self.clock = clock }
    public func read(account: String) throws -> String? { values[account] }
    public func write(_ secret: String, account: String) throws { values[account] = secret; dates[account] = clock() }
    public func delete(account: String) throws { values[account] = nil; dates[account] = nil }
    public func modificationDate(account: String) -> Date? { dates[account] }
}

/// A secret as the app actually resolves it, with everything a diagnostic may say
/// about it that is not the secret: where it came from, how long it is, and the
/// Keychain status if reading failed. `value` must never be logged or shown.
public struct ResolvedSecret: Equatable, Sendable {
    public enum Source: String, Sendable { case keychain, environment, none }

    /// The sanitized key, ready to send; nil when missing or invalid.
    public let value: String?
    public let source: Source
    /// OSStatus of a failed Keychain read (nil when the read worked or found nothing).
    public let keychainStatus: Int32?
    /// Why a stored/environment value was found but must not be sent (value is nil then).
    public let invalid: APIKeySanitizer.Invalid?
    /// Size of the stored value (trimmed) and its whitespace-separated pieces; only meaningful when invalid.
    public let rawLength: Int
    public let tokenCount: Int

    public init(value: String?, source: Source, keychainStatus: Int32?,
                invalid: APIKeySanitizer.Invalid? = nil, rawLength: Int = 0, tokenCount: Int = 0) {
        self.value = value
        self.source = source
        self.keychainStatus = keychainStatus
        self.invalid = invalid
        self.rawLength = rawLength
        self.tokenCount = tokenCount
    }

    public var length: Int { value?.count ?? rawLength }

    /// Keychain first, then the optional environment value. A Keychain read error is
    /// recorded (not swallowed) and the environment value is used if there is one.
    /// A value that is present but malformed (spaces, line breaks, control characters)
    /// is reported through `invalid` and never offered as `value`.
    public static func resolve(secrets: SecretStore, account: String, environmentValue: String? = nil) -> ResolvedSecret {
        var status: Int32?
        do {
            if let stored = try secrets.read(account: account) {
                let outcome = APIKeySanitizer.sanitize(stored)
                if let key = outcome.key { return ResolvedSecret(value: key, source: .keychain, keychainStatus: nil) }
                if let reason = outcome.invalid, reason != .empty {
                    return ResolvedSecret(value: nil, source: .keychain, keychainStatus: nil, invalid: reason,
                                          rawLength: outcome.rawLength, tokenCount: outcome.tokenCount)
                }
            }
        } catch SecretStoreError.keychain(let code) {
            status = code
        } catch {
            status = errSecInternalError
        }
        if let environmentValue {
            let outcome = APIKeySanitizer.sanitize(environmentValue)
            if let key = outcome.key { return ResolvedSecret(value: key, source: .environment, keychainStatus: status) }
            if let reason = outcome.invalid, reason != .empty {
                return ResolvedSecret(value: nil, source: .environment, keychainStatus: status, invalid: reason,
                                      rawLength: outcome.rawLength, tokenCount: outcome.tokenCount)
            }
        }
        return ResolvedSecret(value: nil, source: .none, keychainStatus: status)
    }

    /// Paste mistakes visible without revealing anything (nil when the key looks sane).
    public var shapeWarning: String? {
        guard let value else { return nil }
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || value.unicodeScalars.contains(where: { $0.value < 0x20 }) {
            return "contains whitespace or control characters"
        }
        if value.unicodeScalars.contains(where: { $0.value > 0x7E }) { return "contains non-ASCII characters" }
        if value.lowercased().hasPrefix("bearer") { return "starts with \"Bearer\" (paste only the key)" }
        if value.contains("=") || value.hasPrefix("\"") || value.hasPrefix("'") { return "looks like an export line or quoted text" }
        return nil
    }

    /// Log-safe summary: no key, no prefix.
    public var logSummary: String {
        let status = keychainStatus.map { String($0) } ?? "none"
        return "resolved=\(value == nil ? "no" : "yes") invalid=\(invalid?.rawValue ?? "none") tokens=\(tokenCount) source=\(source.rawValue) length=\(length) keychainStatus=\(status) shapeWarning=\(shapeWarning ?? "none")"
    }

    /// Why nothing could be sent, in user words (nil when a value exists).
    public var missingMessage: String? {
        guard value == nil else { return nil }
        if let invalid {
            return APIKeySanitizer.savedMessage(for: invalid, length: rawLength, tokens: tokenCount,
                                                subject: source == .environment ? "The API key from the environment" : "The saved API key")
        }
        if let keychainStatus { return "No API key could be read from the Keychain (status \(keychainStatus))" }
        return "No API key is saved (paste one and press Save key)"
    }

    /// Key shape in non-secret terms: size, pieces and whether it looks like the expected provider's key.
    public func shapeDescription(expecting shape: KeyShapeClass) -> String {
        let pieces = value == nil ? tokenCount : 1
        let looks = value.map { shape.matches($0) } ?? false
        return "Key shape: \(length) characters, \(pieces) token\(pieces == 1 ? "" : "s"), looks like \(shape.phrase): \(looks ? "yes" : "no")."
    }

    /// What was sent, in user words.
    public var sentDescription: String {
        var text = "Key sent (from \(source == .keychain ? "Keychain" : "environment"), \(length) characters"
        if let value { text += ", ending \(KeyFingerprint.ending(value))" }
        if let shapeWarning { text += ", \(shapeWarning)" }
        return text + ")"
    }
}

/// Save with read-back so a write the app cannot read again is reported at once.
/// The pasted value is sanitized first; a malformed one (several tokens, line breaks,
/// control characters) is refused and never written. The message never contains the key.
public func saveSecretVerified(_ secret: String, account: String, in secrets: SecretStore) -> String {
    saveSecretVerifiedOutcome(secret, account: account, in: secrets).message
}

/// Same as saveSecretVerified, with an explicit success flag (true only when the
/// value read back from the store equals the sanitized key just written).
public func saveSecretVerifiedOutcome(_ secret: String, account: String, in secrets: SecretStore) -> (saved: Bool, message: String) {
    let outcome = APIKeySanitizer.sanitize(secret)
    guard let key = outcome.key else {
        return (false, APIKeySanitizer.saveMessage(for: outcome.invalid ?? .empty))
    }
    let note = APIKeySanitizer.editNote(for: outcome).map { " " + $0 } ?? ""
    do {
        try secrets.write(key, account: account)
        let back = ResolvedSecret.resolve(secrets: secrets, account: account)
        if back.value == key { return (true, "Key saved in Keychain (\(key.count) characters)." + note) }
        if let status = back.keychainStatus { return (false, "Key written but could not be read back from the Keychain (status \(status)).") }
        return (false, "Key written but the Keychain returned a different value.")
    } catch {
        return (false, error.localizedDescription)
    }
}

public extension AppSettings {
    /// Keychain account for a cloud provider's key.
    static func plannerSecretAccount(for provider: PlannerProvider) -> String {
        "planner-\(provider.rawValue)"
    }
}
