import Foundation
import XCTest
@testable import MyHomeCore

private final class EchoBridge: BridgeSending, @unchecked Sendable {
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        ["ok": true, "dps": payload["dps"] as Any]
    }
}

/// Scripted decisions endpoint: records every request, answers from a closure.
private final class FakeJev: @unchecked Sendable {
    typealias Handler = @Sendable (_ body: [String: Any], _ attempt: Int) async throws -> (Int, Data)
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _handler: Handler = { _, _ in (500, Data()) }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var handler: Handler {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    var transport: JevTransport {
        ClosureJevTransport { [self] request in
            let (attempt, handler) = record(request)
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
            let (status, data) = try await handler(body, attempt)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }

    private func record(_ request: URLRequest) -> (Int, Handler) {
        lock.lock()
        defer { lock.unlock() }
        _requests.append(request)
        return (_requests.count, _handler)
    }

    static func envelope(_ id: String, choice: String, _ probabilities: [String: Double], model: String? = "jev-1.13.0") -> Data {
        var root: [String: Any] = ["answers": [id: ["type": "choice", "choice": choice, "probabilities": probabilities]]]
        if let model { root["model"] = model }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    /// The question id and the label whose description starts with `name`.
    static func label(in body: [String: Any], startingWith name: String) -> (id: String, label: String)? {
        guard let questions = body["questions"] as? [String: Any] else { return nil }
        for (id, value) in questions {
            let criteria = ((value as? [String: Any])?["criteria"] as? [String: String]) ?? [:]
            if let match = criteria.first(where: { $0.value.hasPrefix(name) || $0.key == name }) { return (id, match.key) }
        }
        return nil
    }

    static func questionID(_ body: [String: Any]) -> String {
        (body["questions"] as? [String: Any])?.keys.first ?? ""
    }
}

private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Jev"))
    return try Data(contentsOf: url)
}

// MARK: - Wire contract

final class JevClientTests: XCTestCase {
    private let secretKey = "sk-or-v1-abcdefghijklmnop123456"
    private let labels = ["d1", "d2", "d3"]

    private func client(_ fake: FakeJev, threshold: Double = AppSettings.defaultJevThreshold, timeout: TimeInterval = AppSettings.defaultJevTimeout,
                        endpoint: String = AppSettings.defaultJevEndpoint, key: String? = nil) -> JevClient {
        JevClient(config: JevClient.Config(endpoint: endpoint, model: "openrouter/test/decider-0", threshold: threshold, timeout: timeout,
                                           backoffs: [0, 0]),
                  key: key ?? secretKey, transport: fake.transport)
    }

    private let question = JevQuestion(instructions: "pick", criteria: ["d1": "Study Fan", "d2": "Desk Lamp", "d3": "Floor Lamp"])

    private func verdict(_ name: String, threshold: Double = AppSettings.defaultJevThreshold) throws -> JevVerdict {
        guard case .success(let answers) = JevClient.parseEnvelope(try fixture(name)) else { return .unmeasured("envelope rejected") }
        return JevClient.fold(answers.rows["device"], labels: labels, threshold: threshold)
    }

    func testAcceptedFixture() throws {
        XCTAssertEqual(try verdict("accepted"), .accepted(label: "d1", strength: 0.91))
    }

    func testBelowGateFixtureRanksWhatJevLeanedTo() throws {
        XCTAssertEqual(try verdict("below-gate"), .belowGate(label: "d2", strength: 0.45, ranked: ["d2", "d3", "d1"]))
    }

    func testMissingProbabilityIsUnmeasuredAndConfidenceNeverGates() throws {
        // confidence 0.99 but probabilities lacks the chosen label: never a fabricated 1 (or 0).
        guard case .unmeasured = try verdict("unmeasured-missing-probability") else { return XCTFail("must be unmeasured") }
    }

    func testUnknownLabelIsUnmeasuredNotBelowGate() throws {
        guard case .unmeasured = try verdict("unmeasured-unknown-label") else { return XCTFail("must be unmeasured") }
    }

    func testMalformedRows() throws {
        guard case .unmeasured = try verdict("malformed-row") else { return XCTFail("mixed choice+noul row is malformed") }
        XCTAssertEqual(JevClient.parseRow(["type": "choice", "choice": 42, "probabilities": ["42": 0.9]]), .unavailable(.malformed))
        XCTAssertEqual(JevClient.parseRow(["type": "choice", "choice": "d1", "probabilities": ["d1": true]]), .unavailable(.malformed),
                       "a JSON boolean never stands in for a probability")
        XCTAssertEqual(JevClient.parseRow(["type": "score", "score": 1]), .unavailable(.malformed))
        XCTAssertEqual(JevClient.parseRow(nil), .unavailable(.missing))
        XCTAssertEqual(JevClient.parseRow(["type": "noul", "noul": 0.8]), .noul(0.8))
        XCTAssertEqual(JevClient.fold(.noul(0.99), labels: labels, threshold: 0.7), .unmeasured("answer was not a choice"))
    }

    func testMissingOrEmptyModelFailsOpen() throws {
        guard case .failure(.notDecision) = JevClient.parseEnvelope(try fixture("missing-model")) else { return XCTFail("no model echo must fail open") }
        let empty = FakeJev.envelope("device", choice: "d1", ["d1": 0.99], model: "")
        guard case .failure(.notDecision) = JevClient.parseEnvelope(empty) else { return XCTFail("empty model echo must fail open") }
    }

    func testRowsAreReadFromDecisionsOrResultsToo() {
        let data = try! JSONSerialization.data(withJSONObject: ["model": "m", "decisions": ["device": ["type": "choice", "choice": "d1", "probabilities": ["d1": 0.9]]]])
        guard case .success(let answers) = JevClient.parseEnvelope(data) else { return XCTFail() }
        XCTAssertEqual(answers.model, "m")
        XCTAssertEqual(JevClient.fold(answers.rows["device"], labels: labels, threshold: 0.7), .accepted(label: "d1", strength: 0.9))
    }

    func testThresholdIsClampedAtTheFloor() {
        let defaults = UserDefaults(suiteName: "JevClientTests-\(UUID())")!
        defaults.set(0.1, forKey: AppSettings.jevThresholdKey)
        XCTAssertEqual(AppSettings.jevThreshold(from: defaults), AppSettings.jevConfidenceFloor)
        defaults.set(5.0, forKey: AppSettings.jevThresholdKey)
        XCTAssertEqual(AppSettings.jevThreshold(from: defaults), 1.0)
        XCTAssertEqual(AppSettings.jevThreshold(from: UserDefaults(suiteName: "JevClientTests-\(UUID())")!), 0.7)
        // The fold applies the floor too, whatever threshold a caller passes.
        let row = JevRow.choice(choice: "d1", probability: 0.25, probabilities: ["d1": 0.25], confidence: nil)
        guard case .belowGate = JevClient.fold(row, labels: labels, threshold: 0.1) else { return XCTFail("0.25 is under the 0.3 floor") }
        let strong = JevRow.choice(choice: "d1", probability: 0.35, probabilities: ["d1": 0.35], confidence: nil)
        XCTAssertEqual(JevClient.fold(strong, labels: labels, threshold: 0.1), .accepted(label: "d1", strength: 0.35))
        XCTAssertEqual(JevClient.Config(model: "m", threshold: 0.0).gate, AppSettings.jevConfidenceFloor)
    }

    func testRequestShapeHeadersAndModelPrefix() async throws {
        let fake = FakeJev()
        fake.handler = { _, _ in (200, FakeJev.envelope("device", choice: "d1", ["d1": 0.9])) }
        let result = await client(fake).ask(state: "turn it on", questions: ["device": question])
        guard case .success = result else { return XCTFail("expected success") }
        let sent = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, AppSettings.defaultJevEndpoint)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "authorization"), "Bearer \(secretKey)")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "test/decider-0", "the transport prefix is stripped")
        XCTAssertEqual(body["state"] as? String, "turn it on")
        let row = try XCTUnwrap((body["questions"] as? [String: Any])?["device"] as? [String: Any])
        XCTAssertEqual(row["type"] as? String, "choice")
        XCTAssertEqual(row["criteria"] as? [String: String], question.criteria)
        XCTAssertFalse(String(decoding: sent.httpBody ?? Data(), as: UTF8.self).contains(secretKey), "the key is a header, never the body")
    }

    func testRetries429ThenSucceeds() async {
        let fake = FakeJev()
        fake.handler = { _, attempt in attempt == 1 ? (429, Data()) : (200, FakeJev.envelope("device", choice: "d1", ["d1": 0.9])) }
        guard case .success = await client(fake).ask(state: "s", questions: ["device": question]) else { return XCTFail("retry should succeed") }
        XCTAssertEqual(fake.requests.count, 2)
    }

    func testServerErrorsRetryTwiceThenFailOpen() async {
        let fake = FakeJev()
        fake.handler = { _, _ in (503, Data()) }
        let result = await client(fake).ask(state: "s", questions: ["device": question])
        XCTAssertEqual(fake.requests.count, AppSettings.jevMaxAttempts)
        guard case .failure(.http(503)) = result else { return XCTFail("expected fail-open 503") }
    }

    func testClientErrorIsNotRetriedAndNeverQuotesBodyOrKey() async {
        let fake = FakeJev()
        let key = secretKey
        fake.handler = { _, _ in (401, Data("Invalid key provided: \(key) (raw upstream body)".utf8)) }
        let result = await client(fake).ask(state: "s", questions: ["device": question])
        XCTAssertEqual(fake.requests.count, 1)
        guard case .failure(let failure) = result else { return XCTFail() }
        XCTAssertFalse(failure.message.contains(secretKey))
        XCTAssertFalse(failure.message.contains("raw upstream body"))
        XCTAssertFalse(String(describing: failure).contains(secretKey))
    }

    func testNetworkErrorsRetryAndNeverCarryTheKey() async {
        let fake = FakeJev()
        let key = secretKey
        fake.handler = { _, _ in throw URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "failed for \(key)"]) }
        let result = await client(fake).ask(state: "s", questions: ["device": question])
        XCTAssertEqual(fake.requests.count, AppSettings.jevMaxAttempts)
        guard case .failure(let failure) = result else { return XCTFail() }
        XCTAssertFalse(failure.message.contains(secretKey))
        XCTAssertFalse(String(describing: failure).contains(secretKey))
    }

    func testHangingEndpointTimesOutPerAttemptAndFailsOpen() async {
        let fake = FakeJev()
        fake.handler = { _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return (200, Data())
        }
        let start = Date()
        let result = await client(fake, timeout: 0.1).ask(state: "s", questions: ["device": question])
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(fake.requests.count, AppSettings.jevMaxAttempts, "a timeout is transient: retried")
        guard case .failure(.network) = result else { return XCTFail("expected a timeout failure") }
    }

    func testConfigurationProblems() {
        let fake = FakeJev()
        XCTAssertNotNil(JevClient.problem(with: .init(model: ""), key: secretKey))
        XCTAssertNotNil(JevClient.problem(with: .init(endpoint: "http://openrouter.ai/x", model: "m"), key: secretKey), "plain http is localhost-only")
        XCTAssertNotNil(JevClient.problem(with: .init(model: "m"), key: nil), "a remote endpoint needs a key")
        XCTAssertNil(JevClient.problem(with: .init(endpoint: "http://localhost:8080/decisions", model: "m"), key: nil))
        XCTAssertNil(JevClient.problem(with: .init(model: "m"), key: secretKey))
        _ = fake
    }

    func testKeyComesFromKeychainThenEnvironment() throws {
        let secrets = InMemorySecretStore()
        let env = [AppSettings.jevKeyEnvironmentVariable: "env-key-0123456789abcdef"]
        XCTAssertEqual(JevClient.resolveKey(secrets: secrets, environment: env), "env-key-0123456789abcdef")
        try secrets.write(secretKey, account: AppSettings.jevSecretAccount)
        XCTAssertEqual(JevClient.resolveKey(secrets: secrets, environment: env), secretKey)
        XCTAssertNil(JevClient.resolveKey(secrets: InMemorySecretStore(), environment: [:]))
    }

    func testTestConnectionSendsATwoOptionChoice() async throws {
        let fake = FakeJev()
        fake.handler = { body, _ in (200, FakeJev.envelope(FakeJev.questionID(body), choice: "yes", ["yes": 0.97, "no": 0.03])) }
        let text = await client(fake).testConnection()
        XCTAssertEqual(text, "Connected: jev-1.13.0 answered.")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: fake.requests[0].httpBody ?? Data()) as? [String: Any])
        let row = try XCTUnwrap((body["questions"] as? [String: Any])?.values.first as? [String: Any])
        XCTAssertGreaterThanOrEqual((row["criteria"] as? [String: String])?.count ?? 0, AppSettings.jevChoiceOptionsRange.lowerBound)
    }
}

// MARK: - Through the coordinator

@MainActor
final class JevCoordinatorTests: XCTestCase {
    private var store: DeviceStore!
    private var controller: DeviceController!
    private var assistant: AssistantCoordinator!
    private var defaults: UserDefaults!
    private var secrets: InMemorySecretStore!
    private var fake: FakeJev!

    private let fan = ControlFixtures.device("fan-study", name: "Study Fan", category: "fs", room: "Study", spec: ControlFixtures.fanSpec)
    private let lamp = ControlFixtures.device("lamp-desk", name: "Desk Lamp", category: "dj", room: "Study", spec: ControlFixtures.lightSpec)
    private let lamp2 = ControlFixtures.device("lamp-floor", name: "Floor Lamp", category: "dj", room: "Study", spec: ControlFixtures.lightSpec)

    override func setUp() {
        super.setUp()
        store = DeviceStore(bridge: EchoBridge(), defaults: UserDefaults(suiteName: "JevCoordinatorTests-store-\(UUID())")!)
        store.setRosterForTest([fan, lamp, lamp2])
        store.applyStatus(fan.id, decoded: ["1": .bool(false), "3": .number(2)])
        store.applyStatus(lamp.id, decoded: ["1": .bool(false), "2": .number(300)])
        store.applyStatus(lamp2.id, decoded: ["1": .bool(false), "2": .number(300)])
        controller = DeviceController(store: store, config: ControlConfig(verifyTimeout: 0.2, confirmationDeviceThreshold: 2))
        defaults = UserDefaults(suiteName: "JevCoordinatorTests-\(UUID())")!
        defaults.set(AppSettings.PlannerProvider.jev.rawValue, forKey: AppSettings.plannerProviderKey)
        defaults.set("test/decider-0", forKey: AppSettings.jevModelKey)
        secrets = InMemorySecretStore()
        try? secrets.write("sk-or-v1-abcdefghijklmnop123456", account: AppSettings.jevSecretAccount)
        fake = FakeJev()
        assistant = AssistantCoordinator(controller: controller)
        assistant.jevDecider = PlannerFactory.makeJevDecider(defaults: defaults, secrets: secrets, transport: fake.transport)
    }

    /// Answers each stage by naming the option whose description/label matches.
    private func answer(device: String, _ deviceP: Double, action: String? = nil, _ actionP: Double = 0.9) {
        fake.handler = { body, _ in
            let id = FakeJev.questionID(body)
            if id == JevCommandDecider.deviceQuestionID, let match = FakeJev.label(in: body, startingWith: device) {
                return (200, FakeJev.envelope(id, choice: match.label, [match.label: deviceP]))
            }
            if id == JevCommandDecider.actionQuestionID, let action {
                return (200, FakeJev.envelope(id, choice: action, [action: actionP]))
            }
            return (400, Data())
        }
    }

    func testFactoryMakesTheDeciderOnlyForJev() {
        XCTAssertNotNil(assistant.jevDecider)
        XCTAssertNil(PlannerFactory.makePlanner(controller: controller, defaults: defaults, secrets: secrets))
        let other = UserDefaults(suiteName: "JevCoordinatorTests-\(UUID())")!
        XCTAssertNil(PlannerFactory.makeJevDecider(defaults: other, secrets: secrets, transport: fake.transport))
    }

    func testRuleParserFirstPlainCommandNeverCallsJev() async {
        let reply = await assistant.handle("turn off the study fan", origin: .voice)
        XCTAssertEqual(reply.kind, .executed)
        XCTAssertEqual(reply.source, AssistantCoordinator.grammarSource)
        XCTAssertTrue(fake.requests.isEmpty, "plain commands never leave the Mac")
    }

    func testUnknownRequestStageAThenStageBNeedsConfirmation() async {
        XCTAssertEqual(VoiceCommandParser().parse("it is way too stuffy in the study"), .unknown("it is way too stuffy in the study"))
        answer(device: "Study Fan", 0.92, action: JevCommandDecider.Action.powerOn.rawValue, 0.85)
        let ask = await assistant.handle("it is way too stuffy in the study", origin: .voice)
        XCTAssertEqual(fake.requests.count, 2, "Stage A then Stage B")
        XCTAssertEqual(ask.kind, .needsConfirmation)
        XCTAssertEqual(ask.source, AssistantCoordinator.jevSource)
        XCTAssertTrue(ask.text.hasPrefix("I heard \u{201C}it is way too stuffy in the study\u{201D}"), ask.text)
        XCTAssertTrue(ask.text.contains("Turn on Study Fan"), ask.text)
        XCTAssertEqual(store.power(for: fan), false, "nothing runs before the user agrees")
        // Stage B only offered actions the fan supports.
        let stageB = (try? JSONSerialization.jsonObject(with: fake.requests[1].httpBody ?? Data())) as? [String: Any]
        let criteria = ((stageB?["questions"] as? [String: Any])?["action"] as? [String: Any])?["criteria"] as? [String: String]
        XCTAssertEqual(Set(criteria?.keys ?? [:].keys), ["power-on", "power-off", "set-level", "set-speed"])
        let done = await assistant.handle("yes", origin: .voice)
        XCTAssertEqual(done.kind, .executed)
        XCTAssertEqual(store.power(for: fan), true)
    }

    func testKnownCommandUnknownDeviceRunsStageAOnly() async {
        answer(device: "Desk Lamp", 0.88)
        let ask = await assistant.handle("turn on the reading light thing", origin: .text)
        XCTAssertEqual(fake.requests.count, 1, "the parser already knows the action")
        XCTAssertEqual(ask.kind, .needsConfirmation)
        XCTAssertTrue(ask.text.contains("Turn on Desk Lamp"), ask.text)
        XCTAssertEqual(store.power(for: lamp), false)
        XCTAssertTrue(assistant.hasPendingConfirmation)
    }

    func testAmbiguousDeviceAsksJevAmongTheCandidatesOnly() async throws {
        answer(device: "Floor Lamp", 0.9)
        let ask = await assistant.handle("turn on the lamp", origin: .voice)
        XCTAssertEqual(ask.kind, .needsConfirmation)
        XCTAssertTrue(ask.text.contains("Turn on Floor Lamp"), ask.text)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: fake.requests[0].httpBody ?? Data()) as? [String: Any])
        let criteria = ((body["questions"] as? [String: Any])?["device"] as? [String: Any])?["criteria"] as? [String: String]
        XCTAssertEqual(criteria?.count, 2, "only the two lamps are offered")
        XCTAssertFalse(criteria?.values.contains { $0.hasPrefix("Study Fan") } ?? true)
        XCTAssertEqual(store.power(for: lamp2), false)
    }

    func testBelowGateAsksTheUserAndRunsNothing() async {
        answer(device: "Desk Lamp", 0.45)
        let reply = await assistant.handle("it is way too stuffy in the study", origin: .voice)
        XCTAssertEqual(reply.kind, .ambiguous)
        XCTAssertTrue(reply.text.contains("\(AssistantCoordinator.jevUnsureLead)"), reply.text)
        XCTAssertTrue(reply.text.contains("did you mean Desk Lamp"), reply.text)
        XCTAssertFalse(assistant.hasPendingConfirmation)
        XCTAssertEqual(fake.requests.count, 1, "no Stage B after an unsure Stage A")
        XCTAssertEqual(store.power(for: lamp), false)
        XCTAssertEqual(store.power(for: fan), false)
    }

    func testBelowGateOnAnAmbiguousCommandOffersTheCandidatesAndTheUserPicks() async {
        answer(device: "Desk Lamp", 0.4)
        let reply = await assistant.handle("turn on the lamp", origin: .voice)
        XCTAssertEqual(reply.kind, .needsConfirmation, "one suggestion is a proposal that still waits for yes")
        XCTAssertTrue(reply.text.contains("did you mean: Turn on Desk Lamp"), reply.text)
        XCTAssertEqual(store.power(for: lamp), false)
        _ = await assistant.handle("yes", origin: .voice)
        XCTAssertEqual(store.power(for: lamp), true)
        XCTAssertEqual(store.power(for: lamp2), false)
    }

    func testUnmeasuredAnswerFallsBackToTheParserChoice() async {
        fake.handler = { body, _ in
            let id = FakeJev.questionID(body)
            let data = try! JSONSerialization.data(withJSONObject: ["model": "jev-1.13.0", "answers": [id: ["type": "choice", "choice": "d1", "confidence": 0.99]]])
            return (200, data)
        }
        let reply = await assistant.handle("turn on the lamp", origin: .voice)
        XCTAssertEqual(reply.kind, .ambiguous)
        XCTAssertTrue(reply.text.contains("did you mean Desk Lamp or Floor Lamp"), reply.text)
        XCTAssertNotNil(assistant.pendingChoice, "the user can answer by name")
        XCTAssertFalse(assistant.hasPendingConfirmation)
        XCTAssertEqual(store.power(for: lamp), false)
    }

    func testFailureFailsOpenToTheNotUnderstoodReply() async {
        fake.handler = { _, _ in (503, Data("upstream secret body".utf8)) }
        let reply = await assistant.handle("it is way too stuffy in the study", origin: .voice)
        XCTAssertEqual(reply.kind, .error)
        XCTAssertTrue(reply.text.contains("I heard \u{201C}it is way too stuffy in the study\u{201D}"), reply.text)
        XCTAssertTrue(reply.text.contains(AssistantCoordinator.jevUnsureLead), reply.text)
        XCTAssertFalse(reply.text.contains("upstream secret body"))
        XCTAssertFalse(reply.text.contains("sk-or-v1"))
        XCTAssertFalse(assistant.hasPendingConfirmation, "a failed jev call never authorizes anything")
        XCTAssertEqual(store.power(for: fan), false)
    }

    func testMissingModelEchoFailsOpen() async {
        fake.handler = { body, _ in
            let id = FakeJev.questionID(body)
            let label = FakeJev.label(in: body, startingWith: "Study Fan")?.label ?? "d1"
            return (200, FakeJev.envelope(id, choice: label, [label: 0.99], model: nil))
        }
        let reply = await assistant.handle("it is way too stuffy in the study", origin: .voice)
        XCTAssertNotEqual(reply.kind, .needsConfirmation)
        XCTAssertFalse(assistant.hasPendingConfirmation)
    }

    func testActionWithoutAValueAsksInsteadOfGuessing() async {
        answer(device: "Study Fan", 0.9, action: JevCommandDecider.Action.setSpeed.rawValue, 0.9)
        let reply = await assistant.handle("the study fan should go faster", origin: .voice)
        XCTAssertEqual(reply.kind, .ambiguous)
        XCTAssertTrue(reply.text.contains("say the value"), reply.text)
        XCTAssertFalse(assistant.hasPendingConfirmation)
    }

    func testNumericRequestKeepsTheParserValueAndRunsStageAOnly() async {
        // The grammar reads any trailing number as a level, so Jev only picks the device.
        let utterance = "I want the study breeze going at forty five"
        guard case .command(_, .level(45)) = VoiceCommandParser().parse(utterance) else { return XCTFail("parser must supply the value") }
        answer(device: "Study Fan", 0.9)
        let reply = await assistant.handle(utterance, origin: .voice)
        XCTAssertEqual(fake.requests.count, 1, "the action and value came from the parser")
        XCTAssertEqual(reply.kind, .needsConfirmation, reply.text)
        XCTAssertTrue(reply.text.contains("Set Study Fan to 45%"), reply.text)
        XCTAssertEqual(store.dps(for: fan)["3"], .number(2), "nothing runs before yes")
    }

    func testValueHelperReadsTheNumberTheParserWouldRead() {
        let parser = VoiceCommandParser()
        XCTAssertEqual(parser.value(in: "speed to2 please"), 2)
        XCTAssertEqual(parser.value(in: "lamp 2 at fifty percent"), 50, "the number after a value particle wins")
        XCTAssertEqual(parser.value(in: "twenty five"), 25)
        XCTAssertNil(parser.value(in: "make it cosy"))
    }

    func testUnconfiguredJevSaysWhyAndCallsNothing() async {
        try? secrets.delete(account: AppSettings.jevSecretAccount)
        assistant.jevDecider = JevCommandDecider(defaults: defaults, secrets: secrets, transport: fake.transport, environment: [:])
        let reply = await assistant.handle("it is way too stuffy in the study", origin: .voice)
        XCTAssertEqual(reply.kind, .error)
        XCTAssertTrue(reply.text.contains("add a Jev API key"), reply.text)
        XCTAssertTrue(fake.requests.isEmpty)
    }
}
