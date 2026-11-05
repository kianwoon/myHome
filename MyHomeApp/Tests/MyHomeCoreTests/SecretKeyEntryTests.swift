// The shared Settings key-entry flow (Jev decider + cloud planner), driven the way
// the buttons drive it, against a stateful fake store and a capturing transport.
// Fake keys only, built at runtime.
import XCTest
@testable import MyHomeCore

/// Stateful store that also records every write/delete in order.
private final class RecordingSecretStore: SecretStore {
    let inner: InMemorySecretStore
    private(set) var log: [String] = []
    init(clock: @escaping () -> Date = Date.init) { inner = InMemorySecretStore(clock: clock) }
    func read(account: String) throws -> String? { try inner.read(account: account) }
    func write(_ secret: String, account: String) throws { log.append("write \(account) …\(secret.suffix(4))"); try inner.write(secret, account: account) }
    func delete(account: String) throws { log.append("delete \(account)"); try inner.delete(account: account) }
    func modificationDate(account: String) -> Date? { inner.modificationDate(account: account) }
}

private final class AuthCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _auth: [String] = []
    var auth: [String] { lock.lock(); defer { lock.unlock() }; return _auth }
    var transport: JevTransport {
        ClosureJevTransport { [self] request in
            lock.lock(); _auth.append(request.value(forHTTPHeaderField: "Authorization") ?? ""); lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"error":{"message":"User not found.","code":401}}"#.utf8), response)
        }
    }
}

@MainActor
final class SecretKeyEntryTests: XCTestCase {
    private func fake(_ tail: String) -> String {
        let base = "sk-or-v1-abcdefghijklmnop123456"
        return base + String(repeating: "x", count: 73 - base.count - tail.count) + tail
    }
    private lazy var keyA = fake("AAAA")
    private lazy var keyB = fake("BBBB")
    private let account = AppSettings.jevSecretAccount

    private func makeModel(_ store: SecretStore) -> SecretKeyEntryModel {
        SecretKeyEntryModel(account: account, secrets: store, environmentVariable: AppSettings.jevKeyEnvironmentVariable, environment: [:])
    }

    private func decider(_ store: SecretStore, _ capture: AuthCapture) -> JevCommandDecider {
        let defaults = UserDefaults(suiteName: "keyentry-\(UUID().uuidString)")!
        defaults.set("https://decisions.invalid/api/alpha/decisions", forKey: AppSettings.jevEndpointKey)
        defaults.set("perplexity/pplx-decider-flash-v1.2", forKey: AppSettings.jevModelKey)
        return JevCommandDecider(defaults: defaults, secrets: store, transport: capture.transport, environment: [:])
    }

    /// The user's sequence: save A, Remove key, paste B, Save key, Test connection.
    func testSaveARemoveSaveBThenTestSendsBOnTheWire() async {
        let store = RecordingSecretStore()
        let capture = AuthCapture()
        let model = makeModel(store)
        model.fieldText = keyA
        model.save()
        XCTAssertEqual(try store.read(account: account), keyA)
        model.remove()
        XCTAssertNil(try store.read(account: account))
        XCTAssertEqual(model.fieldText, "")
        XCTAssertEqual(model.phase, .removed)
        model.fieldText = keyB
        model.save()
        XCTAssertEqual(try store.read(account: account), keyB, "store holds exactly the field text")
        let jev = decider(store, capture)
        await model.test { await jev.testConnection() }
        XCTAssertEqual(capture.auth, ["Bearer \(keyB)"], "Test connection sent key B")
        XCTAssertTrue(model.testResult.contains("Testing saved key ending …BBBB"), model.testResult)
        XCTAssertTrue(model.testResult.contains("ending …BBBB), service rejected it"), model.testResult)
        XCTAssertFalse(model.testResult.contains(keyB))
        XCTAssertEqual(store.log, ["write \(account) …AAAA", "delete \(account)", "write \(account) …BBBB"])
    }

    /// Same sequence with the view (and its model) re-created between every step.
    func testSequenceSurvivesViewRecreation() async {
        let store = RecordingSecretStore()
        let capture = AuthCapture()
        var model = makeModel(store)
        model.fieldText = keyA
        model.save()
        model = makeModel(store)
        XCTAssertEqual(model.fieldText, "")
        XCTAssertEqual(model.savedLine().hasPrefix("Saved key ending …AAAA"), true, model.savedLine())
        model.remove()
        model = makeModel(store)
        XCTAssertEqual(model.savedLine(), "No API key is saved (paste one and press Save key)")
        model.fieldText = keyB
        model.save()
        model = makeModel(store)
        let jev = decider(store, capture)
        await model.test { await jev.testConnection() }
        XCTAssertEqual(capture.auth, ["Bearer \(keyB)"])
    }

    func testSaveWritesExactlyTheFieldTextAndClearsState() {
        let store = RecordingSecretStore()
        let model = makeModel(store)
        model.fieldText = keyA
        model.save()
        model.fieldText = "  \(keyB)\n"
        model.reveal = true
        XCTAssertEqual(model.phase, .typing)
        let generation = model.fieldGeneration
        model.save()
        XCTAssertEqual(try store.read(account: account), keyB)
        XCTAssertEqual(model.fieldText, "")
        XCTAssertFalse(model.reveal)
        XCTAssertEqual(model.fieldGeneration, generation + 1, "field identity is rebuilt empty")
        XCTAssertEqual(model.message, "Key saved in Keychain (73 characters). Saved key ending …BBBB.")
        guard case .saved(let fingerprint, let date) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(fingerprint, "…BBBB")
        XCTAssertNotNil(date)
    }

    func testRemoveClearsTypedTextAndStaleState() {
        let store = RecordingSecretStore()
        let model = makeModel(store)
        model.fieldText = keyA
        model.save()
        model.fieldText = keyB   // typed, never saved
        model.reveal = true
        model.remove()
        XCTAssertEqual(model.fieldText, "")
        XCTAssertFalse(model.reveal)
        XCTAssertEqual(model.testResult, "")
        XCTAssertFalse(model.hasStoredKey)
        // Nothing typed after Remove: Save writes nothing.
        model.save()
        XCTAssertEqual(store.log, ["write \(account) …AAAA", "delete \(account)"])
        XCTAssertNil(try store.read(account: account))
    }

    func testTestConnectionWithUnsavedTextNeverSavesAndSaysSo() async {
        let store = RecordingSecretStore()
        let capture = AuthCapture()
        let model = makeModel(store)
        model.fieldText = keyA
        model.save()
        model.fieldText = keyB
        let jev = decider(store, capture)
        await model.test { await jev.testConnection() }
        XCTAssertEqual(capture.auth, ["Bearer \(keyA)"], "the SAVED key is tested")
        XCTAssertEqual(try store.read(account: account), keyA, "Test connection does not save")
        XCTAssertTrue(model.testResult.hasPrefix("The typed key ending …BBBB is NOT saved"), model.testResult)
        XCTAssertTrue(model.testResult.contains("Testing saved key ending …AAAA"), model.testResult)
        XCTAssertEqual(model.fieldText, keyB, "typed text is kept for Save")
    }

    func testRefusedSaveKeepsStoredKeyAndTypedText() {
        let store = RecordingSecretStore()
        let model = makeModel(store)
        model.fieldText = keyA
        model.save()
        model.fieldText = "\(keyB) \(keyA)"
        model.save()
        XCTAssertEqual(try store.read(account: account), keyA)
        XCTAssertEqual(model.fieldText, "\(keyB) \(keyA)")
        XCTAssertTrue(model.message.contains("contains spaces"), model.message)
        XCTAssertEqual(model.phase, .typing)
    }

    func testRefreshReflectsChangesMadeOutsideTheApp() throws {
        let store = RecordingSecretStore()
        let model = makeModel(store)
        XCTAssertEqual(model.phase, .idle)
        try store.write(keyB, account: account)   // e.g. `security add-generic-password -U`
        XCTAssertFalse(model.hasStoredKey, "not re-read yet")
        model.refresh()
        XCTAssertTrue(model.savedLine().hasPrefix("Saved key ending …BBBB, saved "), model.savedLine())
        try store.delete(account: account)
        model.refresh()
        XCTAssertEqual(model.phase, .idle)
    }

    func testSavedLineFormatAndEnvironmentFallback() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let saved = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 21, minute: 17))!
        let store = RecordingSecretStore(clock: { saved })
        try store.write(keyB, account: account)
        let model = makeModel(store)
        let locale = Locale(identifier: "en_GB")
        XCTAssertEqual(model.savedLine(now: saved, calendar: calendar, locale: locale), "Saved key ending …BBBB, saved 21:17")
        XCTAssertFalse(model.savedLine().contains(keyB))
        let env = SecretKeyEntryModel(account: account, secrets: InMemorySecretStore(), environmentVariable: AppSettings.jevKeyEnvironmentVariable,
                                      environment: [AppSettings.jevKeyEnvironmentVariable: keyA])
        XCTAssertEqual(env.savedLine(), "No key saved; using OPENROUTER_API_KEY ending …AAAA")
        XCTAssertFalse(env.hasStoredKey)
    }

    func testFingerprintIsLastCharactersOnly() {
        XCTAssertEqual(KeyFingerprint.ending(keyB), "…BBBB")
        XCTAssertEqual(KeyFingerprint.ending("ab"), "…ab")
        XCTAssertFalse(ResolvedSecret(value: keyB, source: .keychain, keychainStatus: nil).logSummary.contains("BBBB"), "never in logs")
    }

    /// Real Keychain, throwaway account: modification date comes from the item attributes.
    func testKeychainModificationDateOnThrowawayAccount() throws {
        let keychain = KeychainSecretStore()
        let throwaway = "test-keyentry-\(UUID().uuidString)"
        defer { try? keychain.delete(account: throwaway) }
        do { try keychain.write(keyA, account: throwaway) } catch { throw XCTSkip("Keychain unavailable: \(error)") }
        XCTAssertNotNil(keychain.modificationDate(account: throwaway))
        try keychain.delete(account: throwaway)
        XCTAssertNil(keychain.modificationDate(account: throwaway))
    }
}
