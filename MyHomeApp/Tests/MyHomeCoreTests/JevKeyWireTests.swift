// Proves, on a real socket, that the key stored through the real SecretStore code
// path reaches the wire as `Authorization: Bearer <exact key>`, and covers the
// key-resolution diagnostics. Uses a throwaway Keychain account only.
import Network
import XCTest
@testable import MyHomeCore

/// Minimal HTTP/1.1 capture server on 127.0.0.1 (ephemeral port).
private final class CaptureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "capture")
    private let lock = NSLock()
    private var _headers: [[String: String]] = []
    var status = 401
    var body = #"{"error":{"message":"User not found.","code":401}}"#

    var headers: [[String: String]] { lock.lock(); defer { lock.unlock() }; return _headers }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: cont.resume(returning: listener.port?.rawValue ?? 0); listener.stateUpdateHandler = nil
                case .failed(let error): cont.resume(throwing: error); listener.stateUpdateHandler = nil
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
                if let data { buffer.append(data) }
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                    var parsed: [String: String] = [:]
                    for line in head.components(separatedBy: "\r\n").dropFirst() {
                        if let colon = line.firstIndex(of: ":") {
                            parsed[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        }
                    }
                    let length = Int(parsed["content-length"] ?? "") ?? 0
                    if buffer.count - range.upperBound >= length {
                        lock.lock(); _headers.append(parsed); lock.unlock()
                        let payload = Data(body.utf8)
                        let reply = "HTTP/1.1 \(status) X\r\ncontent-type: application/json\r\ncontent-length: \(payload.count)\r\nconnection: close\r\n\r\n"
                        conn.send(content: Data(reply.utf8) + payload, completion: .contentProcessed { _ in conn.cancel() })
                        return
                    }
                }
                if done || error != nil { conn.cancel() } else { receive() }
            }
        }
        receive()
    }
}

@MainActor
final class JevKeyWireTests: XCTestCase {
    // Built at runtime so no key-shaped literal sits in the repo (push protection scans literals).
    private let fakeKey = "sk-or-v1-" + String(repeating: "x", count: 64)

    private func decider(port: UInt16, secrets: SecretStore, env: [String: String] = [:]) -> (JevCommandDecider, UserDefaults) {
        let suite = "jevwire-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("http://127.0.0.1:\(port)/api/alpha/decisions", forKey: AppSettings.jevEndpointKey)
        defaults.set("perplexity/pplx-decider-flash-v1.2", forKey: AppSettings.jevModelKey)
        let transport = URLSessionJevTransport()
        return (JevCommandDecider(defaults: defaults, secrets: secrets, transport: transport, environment: env), defaults)
    }

    func testStoredKeyReachesTheWireExactlyThroughTheRealKeychainPath() async throws {
        let account = "test-jevwire-\(UUID().uuidString)"
        let keychain = KeychainSecretStore()
        defer { try? keychain.delete(account: account) }
        // Same code path as the Save key button, but on a throwaway account.
        XCTAssertEqual(saveSecretVerified("  \(fakeKey)\n", account: account, in: keychain), "Key saved in Keychain (\(fakeKey.count) characters).")
        let secret = ResolvedSecret.resolve(secrets: keychain, account: account)
        XCTAssertEqual(secret.value, fakeKey)
        XCTAssertEqual(secret.source, .keychain)

        let server = try CaptureServer()
        let port = try await server.start()
        defer { server.stop() }
        let defaults = UserDefaults(suiteName: "jevwire-\(UUID().uuidString)")!
        defaults.set("http://127.0.0.1:\(port)/api/alpha/decisions", forKey: AppSettings.jevEndpointKey)
        defaults.set("perplexity/pplx-decider-flash-v1.2", forKey: AppSettings.jevModelKey)
        let client = JevClient(config: .fromDefaults(defaults), secret: secret, transport: URLSessionJevTransport())
        let message = await client.testConnection()

        let sent = try XCTUnwrap(server.headers.first, "no request reached the capture server")
        XCTAssertEqual(sent["authorization"], "Bearer \(fakeKey)")
        XCTAssertEqual(sent["http-referer"], AppSettings.jevReferer)
        XCTAssertEqual(sent["x-title"], AppSettings.jevAppTitle)
        XCTAssertEqual(sent["content-type"], "application/json")
        XCTAssertEqual(server.headers.count, 1, "401 is not retried")
        XCTAssertTrue(message.hasPrefix("Key sent (from Keychain, \(fakeKey.count) characters), service rejected it"), message)
        XCTAssertTrue(message.contains("(HTTP 401): User not found."), message)
        XCTAssertFalse(message.contains(fakeKey))
        XCTAssertFalse(message.contains(String(fakeKey.prefix(8))))
    }

    func testDeciderUsesTheKeyStoredAfterItWasBuilt() async throws {
        let server = try CaptureServer()
        let port = try await server.start()
        defer { server.stop() }
        let secrets = InMemorySecretStore()
        let (decider, _) = decider(port: port, secrets: secrets)
        _ = await decider.testConnection()                       // no key yet
        XCTAssertNil(server.headers.first?["authorization"], "no key yet: no Authorization header")
        try secrets.write(fakeKey, account: AppSettings.jevSecretAccount)
        _ = await decider.testConnection()                       // same decider, key saved afterwards
        XCTAssertEqual(server.headers.last?["authorization"], "Bearer \(fakeKey)")
    }

    func testNoKeyMessagesNameTheKeychainStatus() async {
        func fresh() -> UserDefaults { UserDefaults(suiteName: "jevwire-\(UUID().uuidString)")! }
        let failing = JevCommandDecider(defaults: fresh(), secrets: FailingSecretStore(status: -34018), environment: [:])
        let denied = await failing.testConnection()
        XCTAssertEqual(denied, "No API key could be read from the Keychain (status -34018)")
        let empty = JevCommandDecider(defaults: fresh(), secrets: InMemorySecretStore(), environment: [:])
        let none = await empty.testConnection()
        XCTAssertEqual(none, "No API key is saved (paste one and press Save key)")
    }

    func testKeychainErrorFallsBackToEnvironmentButIsRecorded() {
        let secret = ResolvedSecret.resolve(secrets: FailingSecretStore(status: -25293), account: "a", environmentValue: " env-key \n")
        XCTAssertEqual(secret.value, "env-key")
        XCTAssertEqual(secret.source, .environment)
        XCTAssertEqual(secret.keychainStatus, -25293)
        XCTAssertTrue(secret.logSummary.contains("source=environment"))
        XCTAssertTrue(secret.logSummary.contains("length=7"))
        XCTAssertFalse(secret.logSummary.contains("env-key"))
    }

    func testShapeWarningsNeverRevealTheKey() {
        func warn(_ text: String) -> String? {
            ResolvedSecret(value: text, source: .keychain, keychainStatus: nil).shapeWarning
        }
        XCTAssertNil(warn(fakeKey))
        XCTAssertNotNil(warn("sk-or-v1-abc def"))
        XCTAssertNotNil(warn("Bearer sk-or-v1-abc"))
        XCTAssertNotNil(warn("OPENROUTER_API_KEY=sk-or-v1-abc"))
        XCTAssertNotNil(warn("\"sk-or-v1-abc\""))
        XCTAssertNotNil(warn("sk-or-v1-abc\u{200B}"))
    }

    func testRealKeychainRoundTripReplaceAndDelete() throws {
        let account = "test-roundtrip-\(UUID().uuidString)"
        let keychain = KeychainSecretStore()
        defer { try? keychain.delete(account: account) }
        XCTAssertNil(try keychain.read(account: account))
        try keychain.write("one", account: account)
        try keychain.write("two", account: account)
        XCTAssertEqual(try keychain.read(account: account), "two")
        try keychain.delete(account: account)
        XCTAssertNil(try keychain.read(account: account))
    }
}

private final class FailingSecretStore: SecretStore {
    let status: Int32
    init(status: Int32) { self.status = status }
    func read(account: String) throws -> String? { throw SecretStoreError.keychain(status) }
    func write(_ secret: String, account: String) throws { throw SecretStoreError.keychain(status) }
    func delete(account: String) throws { throw SecretStoreError.keychain(status) }
}
