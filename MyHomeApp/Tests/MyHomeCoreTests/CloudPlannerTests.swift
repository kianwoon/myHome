import Foundation
import XCTest
@testable import MyHomeCore

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> (Int, Data))?
    nonisolated(unsafe) static var seen: [(request: URLRequest, body: Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.seen.append((request, body))
        do {
            let (status, data) = try Self.handler?(request, body) ?? (500, Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class EchoBridge: BridgeSending, @unchecked Sendable {
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] { ["ok": true, "dps": payload["dps"] as Any] }
}

@MainActor
final class CloudPlannerTests: XCTestCase {
    private let secretKey = "sk-test-SECRET-0123456789"
    private var defaults: UserDefaults!
    private var secrets: InMemorySecretStore!
    private var session: URLSession!
    private var store: DeviceStore!
    private var controller: DeviceController!
    private let fan = ControlFixtures.device("fan-study", name: "Study Fan", category: "fs", room: "Study", spec: ControlFixtures.fanSpec)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "CloudPlannerTests-\(UUID())")!
        secrets = InMemorySecretStore()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        MockURLProtocol.seen = []
        MockURLProtocol.handler = nil
        store = DeviceStore(bridge: EchoBridge(), defaults: UserDefaults(suiteName: "CloudPlannerStore-\(UUID())")!)
        store.setRosterForTest([fan])
        store.applyStatus(fan.id, decoded: ["1": .bool(false), "3": .number(1)])
        controller = DeviceController(store: store, config: ControlConfig(verifyTimeout: 0.2, confirmationDeviceThreshold: 2))
    }

    private func configure(_ provider: AppSettings.PlannerProvider, model: String = "test-model", key: String? = nil, baseURL: String? = nil) {
        defaults.set(provider.rawValue, forKey: AppSettings.plannerProviderKey)
        defaults.set(model, forKey: provider == .anthropic ? AppSettings.anthropicModelKey : AppSettings.openAIModelKey)
        if let baseURL { defaults.set(baseURL, forKey: provider == .anthropic ? AppSettings.anthropicBaseURLKey : AppSettings.openAIBaseURLKey) }
        if let key { try? secrets.write(key, account: AppSettings.plannerSecretAccount(for: provider)) }
    }

    private func planner() -> CloudPlanner {
        CloudPlanner(controller: controller, defaults: defaults, secrets: secrets, session: session)
    }

    private let planJSON = #"{"actions":[{"device":"d1","action":"setFanSpeed","value":2}],"summary":"Fan to 2.","clarification":""}"#

    private func anthropicBody(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]]])
    }

    private func openAIBody(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": text]]]])
    }

    func testAnthropicSuccessMapsHandlesBackAndSendsHeaders() async throws {
        configure(.anthropic, key: secretKey)
        MockURLProtocol.handler = { _, _ in (200, self.anthropicBody("Sure:\n```json\n\(self.planJSON)\n```")) }
        let plan = try await planner().plan("fan to two", devices: controller.summaries())
        XCTAssertEqual(plan.steps, [ProposedStep(deviceIDs: [fan.id], command: .fanSpeed(2))])
        let sent = try XCTUnwrap(MockURLProtocol.seen.first)
        XCTAssertEqual(sent.request.url?.absoluteString, AppSettings.defaultAnthropicBaseURL + AppSettings.anthropicMessagesPath)
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "x-api-key"), secretKey)
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "anthropic-version"), AppSettings.defaultAnthropicAPIVersion)
        let body = String(decoding: sent.body, as: UTF8.self)
        XCTAssertFalse(body.contains(secretKey), "the key travels in a header only")
        XCTAssertFalse(body.contains(fan.id), "ids are replaced by short handles")
        XCTAssertTrue(body.contains("Study Fan"))
    }

    func testOpenAICompatibleSuccessUsesBearerAndCustomBaseURL() async throws {
        configure(.openAICompatible, key: secretKey, baseURL: "https://llm.example.test/v1/")
        MockURLProtocol.handler = { _, _ in (200, self.openAIBody(self.planJSON)) }
        let plan = try await planner().plan("fan to two", devices: controller.summaries())
        XCTAssertEqual(plan.steps.first?.command, .fanSpeed(2))
        let sent = try XCTUnwrap(MockURLProtocol.seen.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://llm.example.test/v1/chat/completions")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "authorization"), "Bearer \(secretKey)")
    }

    func testHTTPErrorNeverQuotesTheBodyOrKey() async {
        configure(.openAICompatible, key: secretKey)
        MockURLProtocol.handler = { _, _ in (401, Data("Incorrect API key provided: \(self.secretKey)".utf8)) }
        do {
            _ = try await planner().plan("x", devices: controller.summaries())
            XCTFail("expected an error")
        } catch let error as PlannerError {
            guard case .failed(let text) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(text.contains("rejected"), text)
            XCTAssertFalse(text.contains(secretKey))
            XCTAssertFalse("\(error)".contains(secretKey))
        } catch { XCTFail("\(error)") }
    }

    func testMalformedReplyIsAClearError() async {
        configure(.anthropic, key: secretKey)
        for data in [Data("not json".utf8), anthropicBody("I cannot help with that."), anthropicBody("{broken")] {
            MockURLProtocol.handler = { _, _ in (200, data) }
            do {
                _ = try await planner().plan("x", devices: controller.summaries())
                XCTFail("expected an error")
            } catch PlannerError.failed(let text) {
                XCTAssertFalse(text.isEmpty)
            } catch { XCTFail("\(error)") }
        }
    }

    func testNetworkTimeoutIsReportedWithoutTheKey() async {
        configure(.anthropic, key: secretKey)
        MockURLProtocol.handler = { _, _ in throw URLError(.timedOut) }
        do {
            _ = try await planner().plan("x", devices: controller.summaries())
            XCTFail("expected an error")
        } catch PlannerError.failed(let text) {
            XCTAssertTrue(text.contains("in time"), text)
            XCTAssertFalse(text.contains(secretKey))
        } catch { XCTFail("\(error)") }
    }

    func testAvailabilityRules() {
        configure(.anthropic, model: "")
        XCTAssertNotNil(planner().unavailableReason, "needs a model")
        configure(.anthropic, model: "m")
        XCTAssertEqual(planner().unavailableReason, "add an API key in Settings → Assistant")
        configure(.anthropic, key: secretKey, baseURL: "http://evil.example.test")
        XCTAssertNotNil(planner().unavailableReason, "plain http is for localhost only")
        configure(.openAICompatible, baseURL: "http://localhost:11434/v1")
        XCTAssertNil(planner().unavailableReason, "a local server needs no key")
        configure(.openAICompatible, baseURL: "https://api.openai.com/v1")
        XCTAssertNotNil(planner().unavailableReason, "a remote server needs a key")
    }

    func testTestConnectionReportsSuccessAndFailure() async {
        configure(.anthropic, key: secretKey)
        MockURLProtocol.handler = { _, _ in (200, self.anthropicBody("OK")) }
        let ok = await planner().testConnection()
        XCTAssertTrue(ok.hasPrefix("Connected"), ok)
        MockURLProtocol.handler = { _, _ in (404, Data()) }
        let bad = await planner().testConnection()
        XCTAssertTrue(bad.contains("404"), bad)
        XCTAssertFalse(bad.contains(secretKey))
    }

    func testFactorySelectsByProvider() {
        func made() -> NaturalLanguagePlanner? { PlannerFactory.makePlanner(controller: controller, defaults: defaults, secrets: secrets, session: session) }
        XCTAssertNil(made(), "default provider is none")
        configure(.anthropic)
        XCTAssertTrue(made() is CloudPlanner)
        configure(.openAICompatible)
        XCTAssertTrue(made() is CloudPlanner)
        defaults.set(AppSettings.PlannerProvider.none.rawValue, forKey: AppSettings.plannerProviderKey)
        XCTAssertNil(made())
    }

    func testCloudPlansAlwaysNeedConfirmation() async {
        configure(.anthropic, key: secretKey)
        MockURLProtocol.handler = { _, _ in (200, self.anthropicBody(self.planJSON)) }
        let assistant = AssistantCoordinator(controller: controller, planner: planner())
        let reply = await assistant.handle("make the study fan nice and breezy", origin: .text)
        XCTAssertEqual(reply.kind, .needsConfirmation)
        XCTAssertEqual(reply.source, AssistantCoordinator.modelSource)
        XCTAssertEqual(store.power(for: fan), false, "nothing runs before the yes")
    }

    func testSecretStoreRoundTripAndKeyNeverInDefaults() throws {
        let account = AppSettings.plannerSecretAccount(for: .anthropic)
        XCTAssertNil(try secrets.read(account: account))
        try secrets.write(secretKey, account: account)
        XCTAssertEqual(try secrets.read(account: account), secretKey)
        try secrets.delete(account: account)
        XCTAssertNil(try secrets.read(account: account))
        configure(.anthropic, key: secretKey)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { "\($0)".contains(secretKey) })
    }

    func testScrubRemovesKey() {
        XCTAssertEqual(CloudPlanner.scrub("bad \(secretKey) here", key: secretKey), "bad ••• here")
    }
}
