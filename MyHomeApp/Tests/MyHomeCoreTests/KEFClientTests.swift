import XCTest
@testable import MyHomeCore

/// Scripted transport: path (from the query or the POST body) → (status, JSON).
final class FakeKEFTransport: KEFTransport, @unchecked Sendable {
    var replies: [String: (Int, String)] = [:]
    var failure: Error?
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        requests.append(request)
        if let failure { throw failure }
        var key = ""
        if let url = request.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let path = items.first(where: { $0.name == "path" })?.value { key = path }
        if let body = request.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            key = "set:" + (json["path"] as? String ?? "")
        }
        let reply = replies[key] ?? (404, "")
        return (reply.0, Data(reply.1.utf8))
    }
}

final class KEFClientTests: XCTestCase {
    private let host = "192.0.2.10"

    private func makeClient(_ transport: FakeKEFTransport) throws -> KEFClient {
        try KEFClient(host: host, transport: transport, config: .defaults)
    }

    func testRejectsInvalidAddresses() {
        for bad in ["", "kef.local", "http://1.2.3.4", "1.2.3", "256.1.1.1", "01.2.3.4", "1.2.3.4/x", "1.2.3.4:80"] {
            XCTAssertThrowsError(try KEFClient(host: bad), bad)
        }
        XCTAssertNoThrow(try KEFClient(host: "10.0.0.5"))
    }

    func testFetchStateDecodesAllFields() async throws {
        let t = FakeKEFTransport()
        t.replies[KEFProtocol.speakerStatus] = (200, #"[{"type":"kefSpeakerStatus","kefSpeakerStatus":"poweredOn"}]"#)
        t.replies[KEFProtocol.volume] = (200, #"[{"type":"i32_","i32_":35}]"#)
        t.replies[KEFProtocol.mute] = (200, #"[{"type":"bool_","bool_":true}]"#)
        t.replies[KEFProtocol.physicalSource] = (200, #"[{"type":"kefPhysicalSource","kefPhysicalSource":"optic"}]"#)
        let state = try await makeClient(t).fetchState()
        XCTAssertEqual(state, KEFState(power: .active, volume: 35, muted: true, input: .optical, maxVolume: nil))
    }

    func testMissingFieldsStayNilAndUnknownEnumsSurvive() async throws {
        let t = FakeKEFTransport()
        t.replies[KEFProtocol.speakerStatus] = (200, #"[{"type":"kefSpeakerStatus","kefSpeakerStatus":"bogus"}]"#)
        t.replies[KEFProtocol.physicalSource] = (200, #"[{"type":"kefPhysicalSource","kefPhysicalSource":"newThing"}]"#)
        let state = try await makeClient(t).fetchState()
        XCTAssertEqual(state.power, .unknown("bogus"))
        XCTAssertEqual(state.input, .unknown("newThing"))
        XCTAssertNil(state.volume)
        XCTAssertNil(state.muted)
    }

    func testFetchStateThrowsWhenNothingReadable() async {
        let t = FakeKEFTransport()
        t.failure = URLError(.timedOut)
        do { _ = try await makeClient(t).fetchState(); XCTFail() } catch { XCTAssertEqual(error as? KEFError, .timeout) }
    }

    func testErrorMapping() async {
        let t = FakeKEFTransport()
        t.replies[KEFProtocol.volume] = (403, "")
        do { _ = try await makeClient(t).fetchState(); XCTFail() } catch { XCTAssertEqual(error as? KEFError, .authenticationRequired) }
        t.replies[KEFProtocol.volume] = (500, "")
        t.replies[KEFProtocol.speakerStatus] = (200, "not json")
        do { _ = try await makeClient(t).fetchState(); XCTFail() } catch { XCTAssertNotNil(error as? KEFError) }
        t.failure = URLError(.cannotConnectToHost)
        do { _ = try await makeClient(t).fetchState(); XCTFail() } catch { XCTAssertEqual(error as? KEFError, .unreachable) }
    }

    func testIdentityParsesMacAndReleaseText() async throws {
        let t = FakeKEFTransport()
        t.replies[KEFProtocol.releaseText] = (200, #"[{"type":"string_","string_":"LS50WII_V1.2.3"}]"#)
        t.replies[KEFProtocol.primaryMac] = (200, #"[{"type":"string_","string_":"AA:BB:CC:00:11:22"}]"#)
        let identity = try await makeClient(t).fetchIdentity()
        XCTAssertEqual(identity.macAddress, "aabbcc001122")
        XCTAssertEqual(identity.model, "LS50WII")
        XCTAssertEqual(identity.firmware, "V1.2.3")
        XCTAssertEqual(identity.deviceID, "kef:aabbcc001122")
        XCTAssertTrue(identity.isSupportedModel)
        XCTAssertFalse(KEFIdentity(model: "LSXII", firmware: "", macAddress: "aabbcc001122").isSupportedModel)
    }

    /// Shapes captured from a real LS50 Wireless II (placeholder MAC).
    func testRealDeviceShapes() async throws {
        let t = FakeKEFTransport()
        t.replies[KEFProtocol.releaseText] = (200, #"[{"string_":"LS50WII_V41192","type":"string_"}]"#)
        t.replies[KEFProtocol.modelName] = (200, #"[{"string_":"SP4025","type":"string_"}]"#)
        t.replies[KEFProtocol.firmwareVersion] = (200, #"[{"string_":"420.390.390.070.0000","type":"string_"}]"#)
        t.replies[KEFProtocol.primaryMac] = (200, #"[{"string_":"00:11:22:33:44:55","type":"string_"}]"#)
        t.replies[KEFProtocol.speakerStatus] = (200, #"[{"kefSpeakerStatus":"powerOn","type":"kefSpeakerStatus"}]"#)
        t.replies[KEFProtocol.volume] = (200, #"[{"type":"i32_","i32_":95}]"#)
        t.replies[KEFProtocol.mute] = (200, #"[{"type":"bool_","bool_":false}]"#)
        t.replies[KEFProtocol.physicalSource] = (200, #"[{"type":"kefPhysicalSource","kefPhysicalSource":"analog"}]"#)
        t.replies[KEFProtocol.maximumVolume] = (200, #"[{"type":"i32_","i32_":95}]"#)
        let client = try makeClient(t)
        let identity = try await client.fetchIdentity()
        XCTAssertEqual(identity.model, "LS50WII")
        XCTAssertEqual(identity.firmware, "420.390.390.070.0000")
        XCTAssertTrue(identity.isSupportedModel)
        XCTAssertTrue(KEFIdentity(model: "SP4025", firmware: "", macAddress: "001122334455").isSupportedModel)
        let state = try await client.fetchState()
        XCTAssertEqual(state, KEFState(power: .active, volume: 95, muted: false, input: .analog, maxVolume: 95))
    }

    func testStandbySourceOverridesLaggingStatusAndIsNotAnInput() async throws {
        let t = FakeKEFTransport()
        t.replies[KEFProtocol.speakerStatus] = (200, #"[{"kefSpeakerStatus":"powerOn","type":"kefSpeakerStatus"}]"#)
        t.replies[KEFProtocol.physicalSource] = (200, #"[{"type":"kefPhysicalSource","kefPhysicalSource":"standby"}]"#)
        var state = try await makeClient(t).fetchState()
        XCTAssertEqual(state.power, .standby)
        XCTAssertNil(state.input)
        t.replies[KEFProtocol.physicalSource] = (200, #"[{"type":"kefPhysicalSource","kefPhysicalSource":"powerOn"}]"#)
        state = try await makeClient(t).fetchState()
        XCTAssertEqual(state.power, .active)
        XCTAssertNil(state.input)
    }

    func testIdentityMalformedMacRejected() async {
        let t = FakeKEFTransport()
        t.replies[KEFProtocol.releaseText] = (200, #"[{"type":"string_","string_":"LS50WII_V1"}]"#)
        t.replies[KEFProtocol.primaryMac] = (200, #"[{"type":"string_","string_":"zz"}]"#)
        do { _ = try await makeClient(t).fetchIdentity(); XCTFail() } catch { XCTAssertEqual(error as? KEFError, .malformedResponse) }
    }

    func testWriteEncodingTypedBodies() throws {
        let client = try makeClient(FakeKEFTransport())
        func body(_ request: URLRequest) -> String { String(data: request.httpBody!, encoding: .utf8)! }
        let volume = try client.writeRequest(path: KEFProtocol.volume, type: KEFProtocol.typeInt, value: 30)
        XCTAssertEqual(volume.httpMethod, "POST")
        XCTAssertEqual(volume.url?.absoluteString, "http://192.0.2.10:80/api/setData")
        XCTAssertEqual(body(volume), #"{"path":"player:volume","roles":"value","value":{"i32_":30,"type":"i32_"}}"#)
        let mute = try client.writeRequest(path: KEFProtocol.mute, type: KEFProtocol.typeBool, value: true)
        XCTAssertTrue(body(mute).contains(#""bool_":true"#))
    }

    func testWritesSendOnceAndGuardInputs() async throws {
        let t = FakeKEFTransport()
        t.replies["set:" + KEFProtocol.volume] = (200, "[]")
        t.replies["set:" + KEFProtocol.physicalSource] = (200, "[]")
        let client = try makeClient(t)
        try await client.setVolume(30)
        try await client.setPower(true)
        XCTAssertTrue(String(data: t.requests.last!.httpBody!, encoding: .utf8)!.contains("powerOn"))
        try await client.setPower(false)
        XCTAssertTrue(String(data: t.requests.last!.httpBody!, encoding: .utf8)!.contains("standby"))
        XCTAssertEqual(t.requests.count, 3)
        do { try await client.setVolume(101); XCTFail() } catch { XCTAssertEqual(error as? KEFError, .volumeOutOfRange(0...100)) }
        do { try await client.setInput(.unknown("x")); XCTFail() } catch { XCTAssertEqual(error as? KEFError, .unsupportedInput("x")) }
        XCTAssertEqual(t.requests.count, 3, "rejected inputs never reach the wire")
        t.replies["set:" + KEFProtocol.volume] = (500, "")
        do { try await client.setVolume(10); XCTFail() } catch { XCTAssertEqual(error as? KEFError, .rejected(500)) }
    }

    func testBackoffSchedule() {
        let c = KEFConfig.defaults
        XCTAssertEqual([0, 1, 2, 3, 4, 9].map(c.backoff(afterFailures:)), [0, 30, 60, 120, 300, 300])
    }
}
