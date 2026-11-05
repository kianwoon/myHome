// One key-entry flow for every API key in Settings (Jev decider and the cloud
// planner), as an explicit state machine the view only renders:
//   idle -> typing -> saving -> saved(fingerprint, date) -> removed
// Rules: the ONLY value Save writes is the field text at the moment Save is
// pressed; Save and Remove clear the field and all stale state; Test connection
// never saves and reads the key back from the SecretStore at call time; the
// saved-state line comes from the store (refresh), never from the field.
// The fingerprint is the last few characters only, for the UI; never logged.
import Combine
import Foundation

public extension AppSettings {
    /// Characters of a key shown as its fingerprint ("ending …wxyz").
    static let keyFingerprintLength = 4
}

public enum KeyFingerprint {
    /// "…wxyz" (last characters only). UI text; must never be logged.
    public static func ending(_ key: String, count: Int = AppSettings.keyFingerprintLength) -> String {
        "…" + String(key.suffix(max(count, 0)))
    }
}

@MainActor
public final class SecretKeyEntryModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case typing
        case saving
        case saved(fingerprint: String, date: Date?)
        case removed
    }

    public let account: String
    private let secrets: SecretStore
    private let environmentVariable: String?
    private let environment: [String: String]

    @Published public private(set) var phase: Phase = .idle
    /// Text in the key field. Never persisted; cleared after Save and Remove.
    @Published public var fieldText = "" {
        didSet {
            guard fieldText != oldValue, phase != .saving else { return }
            if !fieldText.isEmpty { phase = .typing } else if phase == .typing { phase = storedPhase }
        }
    }
    @Published public var reveal = false
    /// Bumped whenever the field must be rebuilt empty (used as the field's view identity).
    @Published public private(set) var fieldGeneration = 0
    @Published public private(set) var stored: ResolvedSecret
    @Published public private(set) var storedDate: Date?
    @Published public private(set) var message = ""
    @Published public private(set) var testResult = ""
    @Published public private(set) var testing = false
    /// Called after the stored key changed (Save or Remove), e.g. to rebuild planners.
    public var onStoredKeyChange: (() -> Void)?

    public init(account: String, secrets: SecretStore, environmentVariable: String? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.account = account
        self.secrets = secrets
        self.environmentVariable = environmentVariable
        self.environment = environment
        self.stored = ResolvedSecret(value: nil, source: .none, keychainStatus: nil)
        refresh()
    }

    /// True when the store holds an item for this account (valid or not).
    public var hasStoredKey: Bool { stored.source == .keychain }

    /// Re-read the store (on appear, on app/window activation, on Refresh) so the
    /// saved-state line reflects changes made outside the app.
    public func refresh() {
        let envValue = environmentVariable.flatMap { environment[$0] }
        stored = ResolvedSecret.resolve(secrets: secrets, account: account, environmentValue: envValue)
        storedDate = stored.source == .keychain ? secrets.modificationDate(account: account) : nil
        if fieldText.isEmpty, phase != .saving, phase != .removed || hasStoredKey { phase = storedPhase }
    }

    private var storedPhase: Phase {
        if stored.source == .keychain, let value = stored.value {
            return .saved(fingerprint: KeyFingerprint.ending(value), date: storedDate)
        }
        return .idle
    }

    /// Save exactly the field text as it is now.
    public func save() {
        let typed = fieldText
        guard !typed.isEmpty else { message = APIKeySanitizer.saveMessage(for: .empty); return }
        phase = .saving
        let outcome = saveSecretVerifiedOutcome(typed, account: account, in: secrets)
        phase = .typing
        guard outcome.saved else { message = outcome.message; return }   // keep the text so it can be revealed and fixed
        clearField()
        refresh()
        let ending = stored.value.map { " Saved key ending \(KeyFingerprint.ending($0))." } ?? ""
        message = outcome.message + ending
        testResult = ""
        onStoredKeyChange?()
    }

    public func remove() {
        do {
            try secrets.delete(account: account)
            clearField()
            refresh()
            phase = .removed
            message = "Key removed."
            testResult = ""
            onStoredKeyChange?()
        } catch {
            message = error.localizedDescription
        }
    }

    /// Test the SAVED key: `run` must resolve the key from the store itself; this
    /// re-reads the store first so the fingerprint shown is the one being tested.
    public func test(_ run: () async -> String) async {
        guard !testing else { return }
        testing = true
        defer { testing = false }
        refresh()
        var parts: [String] = []
        if let typed = typedFingerprint {
            parts.append("The typed key ending \(typed) is NOT saved (press Save key to use it).")
        }
        if let value = stored.value {
            let from = stored.source == .keychain ? "Keychain" : "environment"
            parts.append("Testing saved key ending \(KeyFingerprint.ending(value)) (from \(from)):")
        }
        parts.append(await run())
        testResult = parts.joined(separator: " ")
    }

    /// Fingerprint of the unsaved field text, as it would be saved (nil when empty).
    public var typedFingerprint: String? {
        let trimmed = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return KeyFingerprint.ending(APIKeySanitizer.sanitize(trimmed).key ?? trimmed)
    }

    /// The line under the key field: what is actually stored right now.
    public func savedLine(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch stored.source {
        case .keychain:
            guard let value = stored.value else { return stored.missingMessage ?? "The saved key cannot be used." }
            var text = "Saved key ending \(KeyFingerprint.ending(value))"
            if let date = storedDate { text += ", saved \(Self.format(date, now: now, calendar: calendar, locale: locale))" }
            return text
        case .environment:
            let name = environmentVariable ?? "environment"
            guard let value = stored.value else { return stored.missingMessage ?? "No key saved" }
            return "No key saved; using \(name) ending \(KeyFingerprint.ending(value))"
        case .none:
            return stored.missingMessage ?? "No key saved"
        }
    }

    static func format(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = calendar.isDate(date, inSameDayAs: now) ? .none : .medium
        return formatter.string(from: date)
    }

    private func clearField() {
        fieldText = ""
        reveal = false
        fieldGeneration += 1
    }
}
