// Pasted-key hygiene: one sanitizer for the Jev and cloud-planner keys. Fake keys only.
import XCTest
@testable import MyHomeCore

private final class CountingTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var transport: JevTransport {
        ClosureJevTransport { [self] request in
            lock.lock(); _requests.append(request); lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"error":{"message":"Missing Authentication header"}}"#.utf8), response)
        }
    }
}

@MainActor
final class APIKeySanitizerTests: XCTestCase {
    /// Obviously fake, 73 characters, OpenRouter-shaped.
    private let fake: String = {
        let base = "sk-or-v1-abcdefghijklmnop123456"
        return base + String(repeating: "x", count: 73 - base.count)
    }()

    func testFakeIsSeventyThreeCharactersAndValid() {
        XCTAssertEqual(fake.count, 73)
        let outcome = APIKeySanitizer.sanitize(fake)
        XCTAssertEqual(outcome.key, fake)
        XCTAssertNil(outcome.invalid)
        XCTAssertFalse(outcome.wasEdited)
    }

    func testTrimsAndStripsBearerAndQuotes() {
        XCTAssertEqual(APIKeySanitizer.sanitize("Bearer xyz").key, "xyz")
        XCTAssertTrue(APIKeySanitizer.sanitize("Bearer xyz").removedBearerPrefix)
        XCTAssertEqual(APIKeySanitizer.sanitize("  bEaReR   xyz \n").key, "xyz")
        XCTAssertEqual(APIKeySanitizer.sanitize("Authorization: Bearer xyz").key, "xyz")
        XCTAssertEqual(APIKeySanitizer.sanitize("\"\(fake)\"").key, fake)
        XCTAssertTrue(APIKeySanitizer.sanitize("'\(fake)'").removedQuotes)
        XCTAssertEqual(APIKeySanitizer.sanitize("\"Bearer \(fake)\"").key, fake)
        XCTAssertEqual(APIKeySanitizer.sanitize("\(fake)\n").key, fake, "trailing newline is trimmed")
        XCTAssertFalse(APIKeySanitizer.sanitize("\(fake)\n").wasEdited)
        XCTAssertEqual(APIKeySanitizer.sanitize("bearerkey").key, "bearerkey", "no space: not a prefix")
    }

    func testInvalidShapesAreClassifiedNotRepaired() {
        let multi = APIKeySanitizer.sanitize("abc\ndef")
        XCTAssertEqual(multi.invalid, .multiLine); XCTAssertNil(multi.key); XCTAssertEqual(multi.tokenCount, 2)
        let spaces = APIKeySanitizer.sanitize("abc def ghi")
        XCTAssertEqual(spaces.invalid, .internalWhitespace); XCTAssertNil(spaces.key); XCTAssertEqual(spaces.tokenCount, 3)
        XCTAssertEqual(APIKeySanitizer.sanitize("abc\u{0007}def").invalid, .controlCharacters)
        XCTAssertEqual(APIKeySanitizer.sanitize("abc\u{200B}def").invalid, .controlCharacters)
        XCTAssertEqual(APIKeySanitizer.sanitize("abc\u{00E9}").invalid, .nonASCII)
        XCTAssertEqual(APIKeySanitizer.sanitize("").invalid, .empty)
        XCTAssertEqual(APIKeySanitizer.sanitize(" \n\t ").invalid, .empty)
        XCTAssertEqual(APIKeySanitizer.sanitize("Bearer ").invalid, .empty)
        XCTAssertEqual(APIKeySanitizer.sanitize("{\"key\": \"abc\"}").invalid, .internalWhitespace)
    }

    func testSaveRefusesInvalidAndNeverEchoesTheKey() throws {
        let store = InMemorySecretStore()
        let pasted = "\(fake)\n\(fake)"
        let message = saveSecretVerified(pasted, account: "a", in: store)
        XCTAssertEqual(message, "That doesn't look like a single API key: it contains line breaks. Paste only the key itself.")
        XCTAssertNil(try store.read(account: "a"), "nothing written")
        XCTAssertFalse(message.contains("sk-or"))
        XCTAssertTrue(saveSecretVerified("a b", account: "a", in: store).contains("spaces"))
        XCTAssertEqual(saveSecretVerified("  ", account: "a", in: store), "Nothing to save: the key field is empty.")
    }

    func testSaveStripsBearerAndSaysSo() throws {
        let store = InMemorySecretStore()
        let message = saveSecretVerified("Bearer \(fake)", account: "a", in: store)
        XCTAssertEqual(message, "Key saved in Keychain (73 characters). Removed a leading \"Bearer \" from the pasted value.")
        XCTAssertEqual(try store.read(account: "a"), fake)
    }

    func testResolveFlagsASavedInvalidKeyWithoutRevealingIt() throws {
        let store = InMemorySecretStore()
        let bad = String(repeating: "abcdefgh", count: 4) + " " + String(repeating: "ijklmnop", count: 5) // 73 chars, 2 tokens
        try store.write(bad, account: "a")
        let secret = ResolvedSecret.resolve(secrets: store, account: "a")
        XCTAssertNil(secret.value)
        XCTAssertEqual(secret.invalid, .internalWhitespace)
        let message = try XCTUnwrap(secret.missingMessage)
        XCTAssertEqual(message, "The saved API key contains spaces or line breaks (73 characters, 2 tokens) — paste only the key and press Save key")
        XCTAssertFalse(secret.logSummary.contains("abcdefgh"))
        XCTAssertEqual(secret.shapeDescription(expecting: .openRouter), "Key shape: 73 characters, 2 tokens, looks like an OpenRouter key: no.")
        XCTAssertNil(ResolvedSecret.resolve(secrets: store, account: "none").invalid)
    }

    func testShapeDescriptionForAValidKey() {
        let secret = ResolvedSecret(value: fake, source: .keychain, keychainStatus: nil)
        XCTAssertEqual(secret.shapeDescription(expecting: .openRouter), "Key shape: 73 characters, 1 token, looks like an OpenRouter key: yes.")
        XCTAssertEqual(secret.shapeDescription(expecting: .anthropic), "Key shape: 73 characters, 1 token, looks like an Anthropic key: no.")
    }

    func testSavedInvalidKeySendsNoRequestAndReportsThePrecisePaste() async throws {
        let store = InMemorySecretStore()
        try store.write("sk-or-v1-aaa\nsk-or-v1-bbb  ccc", account: AppSettings.jevSecretAccount)
        let counter = CountingTransport()
        let defaults = UserDefaults(suiteName: "keysan-\(UUID().uuidString)")!
        let decider = JevCommandDecider(defaults: defaults, secrets: store, transport: counter.transport, environment: [:])
        let result = await decider.testConnection()
        XCTAssertTrue(result.hasPrefix("The saved API key contains spaces or line breaks (30 characters, 3 tokens) — paste only the key and press Save key"), result)
        XCTAssertTrue(result.contains("looks like an OpenRouter key: no"), result)
        XCTAssertFalse(result.contains("sk-or"))
        XCTAssertEqual(counter.requests.count, 0, "no HTTP request for a malformed key")
        // The real decision path is also blocked.
        let answer = await decider.client.ask(state: "s", questions: ["q": JevQuestion(instructions: "i", criteria: ["a": "x", "b": "y"])])
        if case .failure(.notConfigured(let text)) = answer { XCTAssertTrue(text.contains("saved API key contains")) } else { XCTFail("expected notConfigured") }
        XCTAssertEqual(counter.requests.count, 0)
    }

    func testValidKeyIsSentAndHeadersRefuseControlCharacters() async throws {
        let counter = CountingTransport()
        let defaults = UserDefaults(suiteName: "keysan-\(UUID().uuidString)")!
        defaults.set("https://openrouter.test/api", forKey: AppSettings.jevEndpointKey)
        defaults.set("some/model", forKey: AppSettings.jevModelKey)
        let config = JevClient.Config.fromDefaults(defaults)
        let good = JevClient(config: config, key: fake, transport: counter.transport)
        _ = try good.buildRequest(state: "s", questions: [:])
        let bad = JevClient(config: config, key: "abc\r\nX-Evil: 1", transport: counter.transport)
        XCTAssertThrowsError(try bad.buildRequest(state: "s", questions: [:]))
        XCTAssertThrowsError(try CloudPlanner.buildRequest(config: .fromDefaults(defaults, provider: .anthropic), key: "k\n2", system: "s", user: "u"))
        XCTAssertThrowsError(try CloudPlanner.buildRequest(config: .fromDefaults(defaults, provider: .openAICompatible), key: "k\u{7}", system: "s", user: "u"))
        let failure = await bad.ask(state: "s", questions: [:])
        if case .failure(.notConfigured) = failure {} else { XCTFail("expected notConfigured") }
        XCTAssertEqual(counter.requests.count, 0)
    }
}
