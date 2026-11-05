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

    func testOpenRouterProvisioningKeyIsNamedOnTestConnection() async {
        configure(.openAICompatible, key: secretKey, baseURL: "https://openrouter.ai/api/v1")
        MockURLProtocol.handler = { request, _ in
            if request.httpMethod == "GET" { return (200, Data(#"{"data":{"is_provisioning_key":true,"usage":0}}"#.utf8)) }
            return (401, Data(#"{"error":{"message":"User not found.","code":401}}"#.utf8))
        }
        let text = await planner().testConnection()
        XCTAssertTrue(text.contains("PROVISIONING key"), text)
        XCTAssertFalse(text.contains(secretKey))
        let gets = MockURLProtocol.seen.filter { $0.request.httpMethod == "GET" }
        XCTAssertEqual(gets.count, 1)
        XCTAssertEqual(gets.first?.request.url?.absoluteString, AppSettings.jevKeyInfoURL)
    }

    func testNonOpenRouterBaseURLMakesNoKeyInfoRequest() async {
        configure(.openAICompatible, key: secretKey, baseURL: "https://llm.example.test/v1")
        MockURLProtocol.handler = { _, _ in (401, Data()) }
        let text = await planner().testConnection()
        XCTAssertTrue(text.contains("rejected the API key"), text)
        XCTAssertEqual(MockURLProtocol.seen.count, 1)
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

    func testPromptCarriesCurrentStateAndTheConditionGuidance() async throws {
        configure(.anthropic, key: secretKey)
        MockURLProtocol.handler = { _, _ in (200, self.anthropicBody(self.planJSON)) }
        _ = try await planner().plan("the study is stuffy", devices: controller.summaries())
        let body = try XCTUnwrap(MockURLProtocol.seen.last?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let user = (((json["messages"] as? [[String: Any]])?.first)?["content"] as? String) ?? ""
        XCTAssertTrue(user.contains("(\(PlannerCatalogue.columns))"), user)
        XCTAssertTrue(user.contains("|fan|off|"), "the fan's current state is in the catalogue line: \(user)")
        let system = "\(json["system"] ?? "")"
        XCTAssertTrue(system.lowercased().contains("for a condition pick sensible values"), system)
        XCTAssertTrue(CloudPlanner.defaultInstructions.contains("current state"))
    }

    func testCatalogueStateColumn() {
        func summary(_ on: Bool?, level: Int? = nil, reach: DeviceSummary.ReachabilitySummary = .wifi) -> DeviceSummary {
            DeviceSummary(id: "x", name: "X", room: "", group: nil, kind: .light, capabilities: [.power], reachability: reach,
                          isControllable: true, isOn: on, levelPercent: level)
        }
        XCTAssertEqual(PlannerCatalogue.state(of: summary(true, level: 40)), "on 40%")
        XCTAssertEqual(PlannerCatalogue.state(of: summary(true)), "on")
        XCTAssertEqual(PlannerCatalogue.state(of: summary(false, level: 40)), "off")
        XCTAssertEqual(PlannerCatalogue.state(of: summary(nil)), "?")
        XCTAssertEqual(PlannerCatalogue.state(of: summary(true, reach: .offline)), "offline")
    }

    func testScrubRemovesKey() {
        XCTAssertEqual(CloudPlanner.scrub("bad \(secretKey) here", key: secretKey), "bad ••• here")
    }
}

/// Reply-shape tolerance for OpenAI-compatible reasoning models.
@MainActor
final class CloudPlannerReplyTests: XCTestCase {
    private func body(_ content: Any?, finish: String? = "stop", extra: [String: Any] = [:]) -> Data {
        var message: [String: Any] = ["role": "assistant"]
        if let content { message["content"] = content }
        var choice: [String: Any] = ["message": message]
        if let finish { choice["finish_reason"] = finish }
        var root: [String: Any] = ["choices": [choice]]
        root.merge(extra) { $1 }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private func failure(_ data: Data) -> String? {
        do { _ = try CloudPlanner.readReply(data, provider: .openAICompatible); return nil }
        catch PlannerError.failed(let text) { return text }
        catch { return "other" }
    }

    func testStringContent() throws {
        XCTAssertEqual(try CloudPlanner.readReply(body("{\"a\":1}"), provider: .openAICompatible), "{\"a\":1}")
    }

    func testPartsArrayContentIsJoined() throws {
        let parts: [[String: Any]] = [["type": "text", "text": "{\"a\":"], ["type": "text", "text": "1}"]]
        XCTAssertEqual(try CloudPlanner.readReply(body(parts), provider: .openAICompatible), "{\"a\":1}")
    }

    func testLeadingThinkBlockIsStripped() throws {
        let text = "<think>hmm {\"x\":0} </think>\n{\"a\":1}"
        XCTAssertEqual(try CloudPlanner.readReply(body(text), provider: .openAICompatible), "{\"a\":1}")
        XCTAssertEqual(CloudPlanner.stripThinking("reasoning</think>{\"a\":1}"), "{\"a\":1}")
        XCTAssertEqual(CloudPlanner.stripThinking("<think>never closed {\"a\":1}"), "")
    }

    func testLengthWithEmptyContentSaysOutOfTokens() {
        XCTAssertEqual(failure(body("", finish: "length", extra: ["usage": ["completion_tokens": 64]])), CloudPlanner.outOfTokensMessage)
        XCTAssertEqual(failure(body(nil, finish: "length")), CloudPlanner.outOfTokensMessage)
    }

    func testEmptyContentOtherwiseSaysEmptyReply() {
        XCTAssertEqual(failure(body("", finish: "stop")), CloudPlanner.emptyReplyMessage)
        XCTAssertEqual(failure(body("<think>only thoughts</think>", finish: "stop")), CloudPlanner.emptyReplyMessage)
    }

    func testNonJSONBody() {
        XCTAssertEqual(failure(Data("<html>oops</html>".utf8)), CloudPlanner.notJSONMessage)
        XCTAssertNil(CloudPlanner.extractText(Data("nope".utf8), provider: .openAICompatible))
    }

    func testAnthropicBlocksAndMaxTokens() throws {
        let ok = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "hi"]], "stop_reason": "end_turn"])
        XCTAssertEqual(try CloudPlanner.readReply(ok, provider: .anthropic), "hi")
        let cut = try JSONSerialization.data(withJSONObject: ["content": [], "stop_reason": "max_tokens"])
        XCTAssertThrowsError(try CloudPlanner.readReply(cut, provider: .anthropic)) {
            XCTAssertEqual($0 as? PlannerError, .failed(CloudPlanner.outOfTokensMessage))
        }
    }

    func testDefaultTokenBudgetIsRoomyForReasoningModels() {
        XCTAssertTrue(AppSettings.plannerMaxTokensRange.contains(AppSettings.defaultPlannerMaxTokens))
        XCTAssertGreaterThanOrEqual(AppSettings.defaultPlannerMaxTokens, 4096)
    }
}
