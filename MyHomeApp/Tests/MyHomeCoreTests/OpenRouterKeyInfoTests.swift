import Foundation
import XCTest
@testable import MyHomeCore

/// Offline: a mock transport answers the decisions POST and the key-info GET separately.
private final class KeyInfoFake: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var decisions: (Int, Data) = (401, Data(#"{"error":{"message":"User not found.","code":401}}"#.utf8))
    var keyInfo: @Sendable () async throws -> (Int, Data) = { (200, Data()) }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var keyInfoRequests: [URLRequest] { requests.filter { $0.httpMethod == "GET" } }

    var transport: JevTransport {
        ClosureJevTransport { [self] request in
            lock.lock(); _requests.append(request); lock.unlock()
            let (status, data) = request.httpMethod == "GET" ? try await keyInfo() : decisions
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    static func info(provisioning: Any, usage: Any? = 15.26) -> (Int, Data) {
        var data: [String: Any] = ["label": "sk-or-v1-0a2...d4d", "is_provisioning_key": provisioning]
        if let usage { data["usage"] = usage }
        return (200, try! JSONSerialization.data(withJSONObject: ["data": data]))
    }
}

final class OpenRouterKeyInfoTests: XCTestCase {
    private let key = "sk-or-v1-FAKEFAKEFAKEFAKEFAKE0123456789"

    private func client(_ fake: KeyInfoFake, endpoint: String = AppSettings.defaultJevEndpoint, key: String? = nil,
                        timeout: TimeInterval = 1, resolved: ResolvedSecret? = nil) -> JevClient {
        JevClient(config: .init(endpoint: endpoint, model: "m", timeout: timeout, maxAttempts: 1, backoffs: []),
                  key: key ?? self.key, transport: fake.transport, resolved: resolved)
    }

    func testProvisioningKeyIsNamedAtOnce() async {
        let fake = KeyInfoFake()
        fake.keyInfo = { KeyInfoFake.info(provisioning: true) }
        let text = await client(fake).testConnection()
        XCTAssertTrue(text.contains("PROVISIONING key"), text)
        XCTAssertTrue(text.contains("Create a normal API key"), text)
        XCTAssertFalse(text.contains(key))
        XCTAssertEqual(fake.keyInfoRequests.count, 1)
        let request = fake.keyInfoRequests[0]
        XCTAssertEqual(request.url?.absoluteString, AppSettings.jevKeyInfoURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(request.url?.host, AppSettings.openRouterHost)
    }

    func testProvisioningMessageKeepsTheKeyEndingText() async {
        let secrets = InMemorySecretStore()
        try? secrets.write(key, account: AppSettings.jevSecretAccount)
        let resolved = ResolvedSecret.resolve(secrets: secrets, account: AppSettings.jevSecretAccount)
        let fake = KeyInfoFake()
        fake.keyInfo = { KeyInfoFake.info(provisioning: true) }
        let text = await client(fake, resolved: resolved).testConnection()
        XCTAssertTrue(text.hasPrefix("Key sent"), text)
        XCTAssertTrue(text.contains("ending"), text)
        XCTAssertTrue(text.contains("PROVISIONING"), text)
        XCTAssertFalse(text.contains(key))
    }

    func testNormalKeyKeepsThe401TextAndAddsTheNote() async {
        let fake = KeyInfoFake()
        fake.keyInfo = { KeyInfoFake.info(provisioning: false) }
        let text = await client(fake).testConnection()
        XCTAssertTrue(text.contains("HTTP 401"), text)
        XCTAssertTrue(text.contains("The key is a normal API key but the Jev service does not accept it for this model/account."), text)
        XCTAssertFalse(text.contains("PROVISIONING"))
        XCTAssertFalse(text.contains(key))
        XCTAssertEqual(fake.keyInfoRequests.count, 1)
    }

    func testKeyInfo401MeansInvalidOrDeleted() async {
        let fake = KeyInfoFake()
        fake.keyInfo = { (401, Data(#"{"error":{"message":"No auth credentials found","code":401}}"#.utf8)) }
        let text = await client(fake).testConnection()
        XCTAssertTrue(text.contains("OpenRouter says this key is invalid or deleted."), text)
        XCTAssertFalse(text.contains(key))
    }

    func testKeyInfoTimeoutLeavesTheOriginalMessage() async {
        let baseline = KeyInfoFake()
        baseline.keyInfo = { (500, Data()) }
        let original = await client(baseline).testConnection()
        let fake = KeyInfoFake()
        fake.keyInfo = { try await Task.sleep(nanoseconds: 3_000_000_000); return KeyInfoFake.info(provisioning: true) }
        let text = await client(fake, timeout: 0.3).testConnection()
        XCTAssertEqual(text, original)
        XCTAssertTrue(text.contains("HTTP 401"), text)
        XCTAssertEqual(fake.keyInfoRequests.count, 1, "no retries")
    }

    func testMalformedOrNonStrictBoolLeavesTheOriginalMessage() async {
        let baseline = KeyInfoFake()
        baseline.keyInfo = { (500, Data()) }
        let original = await client(baseline).testConnection()
        let replies: [(Int, Data)] = [
            (200, Data("not json".utf8)),
            (200, Data(#"{"data":{}}"#.utf8)),
            KeyInfoFake.info(provisioning: "true"),
            KeyInfoFake.info(provisioning: 1),
            (403, Data()),
        ]
        for reply in replies {
            let fake = KeyInfoFake()
            fake.keyInfo = { reply }
            let text = await client(fake).testConnection()
            XCTAssertEqual(text, original, "reply \(reply.0)")
        }
    }

    func testNonOpenRouterHostMakesNoFollowUpRequest() async {
        let fake = KeyInfoFake()
        fake.keyInfo = { KeyInfoFake.info(provisioning: true) }
        let text = await client(fake, endpoint: "https://jev.example.test/decisions").testConnection()
        XCTAssertFalse(text.contains("PROVISIONING"), text)
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(fake.keyInfoRequests.count, 0)
    }

    func testLookalikeHostAndPlainHTTPAreNotOpenRouter() {
        XCTAssertTrue(JevClient.isOpenRouterEndpoint("https://openrouter.ai/api/alpha/decisions"))
        XCTAssertFalse(JevClient.isOpenRouterEndpoint("https://openrouter.ai.evil.test/x"))
        XCTAssertFalse(JevClient.isOpenRouterEndpoint("https://evil.test/openrouter.ai"))
        XCTAssertFalse(JevClient.isOpenRouterEndpoint("http://openrouter.ai/x"))
    }

    func testSuccessAndNon401FailuresMakeNoFollowUp() async {
        for decisions in [(500, Data()), (404, Data()), (429, Data())] {
            let fake = KeyInfoFake()
            fake.decisions = decisions
            _ = await client(fake).testConnection()
            XCTAssertEqual(fake.keyInfoRequests.count, 0, "status \(decisions.0)")
        }
        let ok = KeyInfoFake()
        ok.decisions = (200, try! JSONSerialization.data(withJSONObject: [
            "model": "jev-1", "answers": ["ping": ["type": "choice", "choice": "yes", "probabilities": ["yes": 0.9, "no": 0.1]]]]))
        let text = await client(ok).testConnection()
        XCTAssertTrue(text.hasPrefix("Connected"), text)
        XCTAssertEqual(ok.keyInfoRequests.count, 0)
    }

    func test403AlsoTriggersTheProbe() async {
        let fake = KeyInfoFake()
        fake.decisions = (403, Data())
        fake.keyInfo = { KeyInfoFake.info(provisioning: true) }
        let text = await client(fake).testConnection()
        XCTAssertTrue(text.contains("PROVISIONING"), text)
    }

    func testVerdictParsing() {
        XCTAssertEqual(OpenRouterKeyInfo.verdict(status: 200, data: KeyInfoFake.info(provisioning: false).1), .normal(usage: 15.26))
        XCTAssertEqual(OpenRouterKeyInfo.verdict(status: 200, data: KeyInfoFake.info(provisioning: false, usage: nil).1), .normal(usage: nil))
        XCTAssertEqual(OpenRouterKeyInfo.verdict(status: 200, data: KeyInfoFake.info(provisioning: true).1), .provisioning)
        XCTAssertEqual(OpenRouterKeyInfo.verdict(status: 401, data: Data()), .invalid)
        XCTAssertNil(OpenRouterKeyInfo.verdict(status: 500, data: Data()))
    }
}
