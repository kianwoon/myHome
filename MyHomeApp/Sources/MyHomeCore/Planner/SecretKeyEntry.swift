// One key-entry flow for every API key in Settings (Jev decider and the cloud
// planner), as an explicit state machine the view only renders:
//   idle -> typing -> saving -> saved(fingerprint, date) -> removed
// Two ways in, no SwiftUI SecureField anywhere (macOS infers a password field for
// an NSSecureTextField even with contentType nil, so AutoFill can target it):
//   - clipboard: "Paste key from clipboard" reads the pasteboard ONCE, holds the
//     sanitized key in memory and shows a preview (length + ending); Save writes
//     exactly that held value, Cancel drops it. Nothing reads the pasteboard again.
//   - typed: Save writes exactly the plain field's text at the moment Save is pressed.
// Save and Remove clear the field and all stale state; Test connection never saves
// and reads the key back from the SecretStore at call time; the saved-state line
// comes from the store (refresh), never from the field.
// Every save leaves a NON-SECRET audit record (source, length, last-4 fingerprint,
// time, Keychain outcome) in os.Logger and UserDefaults, so a wrong-key report can be
// told apart at once: app fault vs. a clipboard that already held the other key.
// The fingerprint is the last few characters only; the key itself is never logged.
import Combine
import Foundation
import os

/// Source of clipboard text for the key-entry flow (NSPasteboard in the app, a fake in tests).
public protocol KeyPasteboard: AnyObject {
    /// The current plain-text contents, or nil when there is none or access was denied.
    func string() -> String?
}

/// Where a saved key came from.
public enum KeySaveSource: String, Codable, Sendable {
    case clipboard
    case typed
}

/// Non-secret record of one save: never contains the key.
public struct KeySaveAudit: Codable, Equatable, Sendable {
    public let source: KeySaveSource
    public let length: Int
    public let fingerprint: String
    public let date: Date
    public let saved: Bool
    /// Short outcome text from the save (the store's message; never the key).
    public let status: String

    public init(source: KeySaveSource, length: Int, fingerprint: String, date: Date, saved: Bool, status: String) {
        self.source = source; self.length = length; self.fingerprint = fingerprint
        self.date = date; self.saved = saved; self.status = status
    }
}

public extension AppSettings {
    /// Characters of a key shown as its fingerprint ("ending …wxyz").
    static let keyFingerprintLength = 4
    /// UserDefaults key of the last save audit for a secret account (non-secret JSON).
    static func keySaveAuditKey(account: String) -> String { "keySaveAudit.\(account)" }
}

enum KeyEntryLog {
    static let logger = Logger(subsystem: AppLog.subsystem, category: "keyentry")
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

    /// What the clipboard held when "Paste key from clipboard" was pressed (no key text).
    public struct ClipboardPreview: Equatable {
        public let length: Int
        public let fingerprint: String
    }

    public let account: String
    private let secrets: SecretStore
    private let defaults: UserDefaults
    private let clock: () -> Date
    /// The sanitized clipboard key awaiting Save/Cancel. Memory only, never published or logged.
    private var heldClipboardKey: String?
    /// Fingerprint of the key that Remove just deleted; cleared by the next save.
    private var removedFingerprint: String?
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
    @Published public private(set) var clipboardPreview: ClipboardPreview?
    /// Non-blocking warning shown after a save (e.g. same key as the one just removed).
    @Published public private(set) var warning = ""
    @Published public private(set) var lastAudit: KeySaveAudit?
    /// Called after the stored key changed (Save or Remove), e.g. to rebuild planners.
    public var onStoredKeyChange: (() -> Void)?

    public init(account: String, secrets: SecretStore, environmentVariable: String? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init) {
        self.account = account
        self.secrets = secrets
        self.environmentVariable = environmentVariable
        self.environment = environment
        self.defaults = defaults
        self.clock = clock
        self.stored = ResolvedSecret(value: nil, source: .none, keychainStatus: nil)
        if let data = defaults.data(forKey: AppSettings.keySaveAuditKey(account: account)) {
            lastAudit = try? JSONDecoder().decode(KeySaveAudit.self, from: data)
        }
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

    /// Typed path: save exactly the field text as it is now.
    public func save() {
        let typed = fieldText
        guard !typed.isEmpty else { message = APIKeySanitizer.saveMessage(for: .empty); return }
        commit(typed, source: .typed)
    }

    /// Clipboard path, step 1: read the pasteboard once and show a preview. Nothing is saved.
    public func loadFromClipboard(_ pasteboard: KeyPasteboard) {
        heldClipboardKey = nil
        clipboardPreview = nil
        warning = ""
        guard let raw = pasteboard.string(), !raw.isEmpty else {
            message = "The clipboard has no text (if macOS asked to allow pasting, allow it, or check System Settings > Privacy & Security > Paste from Other Apps)."
            return
        }
        let outcome = APIKeySanitizer.sanitize(raw)
        guard let key = outcome.key else {
            message = "Clipboard: " + APIKeySanitizer.saveMessage(for: outcome.invalid ?? .empty)
            return
        }
        heldClipboardKey = key
        clipboardPreview = ClipboardPreview(length: key.count, fingerprint: KeyFingerprint.ending(key))
        message = ""
    }

    /// Preview text: "Clipboard holds a key: 73 characters, ending …wxyz — Save this key?"
    public var clipboardPreviewLine: String? {
        clipboardPreview.map { "Clipboard holds a key: \($0.length) characters, ending \($0.fingerprint) — Save this key?" }
    }

    /// Clipboard path, step 2: save the value read in step 1 (never re-reads the pasteboard).
    public func confirmClipboardSave() {
        guard let key = heldClipboardKey else { return }
        heldClipboardKey = nil
        clipboardPreview = nil
        commit(key, source: .clipboard)
    }

    public func cancelClipboard() {
        heldClipboardKey = nil
        clipboardPreview = nil
    }

    /// The one write path for both sources: verified save, audit, same-key warning.
    private func commit(_ text: String, source: KeySaveSource) {
        phase = .saving
        let outcome = saveSecretVerifiedOutcome(text, account: account, in: secrets)
        phase = .typing
        let candidate = APIKeySanitizer.sanitize(text).key ?? text
        let fingerprint = KeyFingerprint.ending(candidate)
        recordAudit(KeySaveAudit(source: source, length: candidate.count, fingerprint: fingerprint, date: clock(),
                                 saved: outcome.saved, status: outcome.message))
        guard outcome.saved else {   // keep typed text so it can be revealed and fixed
            if fieldText.isEmpty { phase = storedPhase }
            message = outcome.message
            return
        }
        warning = removedFingerprint == fingerprint
            ? "This is the same key as before (ending \(fingerprint)) — if you meant a different key, copy it again." : ""
        removedFingerprint = nil
        clearField()
        refresh()
        let ending = stored.value.map { " Saved key ending \(KeyFingerprint.ending($0))." } ?? ""
        message = outcome.message + ending
        testResult = ""
        onStoredKeyChange?()
    }

    private func recordAudit(_ audit: KeySaveAudit) {
        lastAudit = audit
        if let data = try? JSONEncoder().encode(audit) {
            defaults.set(data, forKey: AppSettings.keySaveAuditKey(account: account))
        }
        // Non-secret fields only, public so `log show` prints them.
        KeyEntryLog.logger.info("""
            key save account=\(self.account, privacy: .public) source=\(audit.source.rawValue, privacy: .public) \
            length=\(audit.length, privacy: .public) ending=\(audit.fingerprint, privacy: .public) \
            saved=\(audit.saved, privacy: .public) status=\(audit.status, privacy: .public)
            """)
    }

    public func remove() {
        do {
            let previous = stored.source == .keychain ? stored.value.map { KeyFingerprint.ending($0) } : nil
            try secrets.delete(account: account)
            removedFingerprint = previous
            cancelClipboard()
            warning = ""
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

    /// "Last saved from clipboard at 21:33 (73 chars, ending …wxyz)" (nil before any save).
    public func auditLine(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let audit = lastAudit else { return nil }
        let when = Self.format(audit.date, now: now, calendar: calendar, locale: locale)
        let result = audit.saved ? "" : " — NOT saved: \(audit.status)"
        let how = audit.source == .clipboard ? "from clipboard" : "by typing"
        return "Last saved \(how) at \(when) (\(audit.length) chars, ending \(audit.fingerprint))\(result)"
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
