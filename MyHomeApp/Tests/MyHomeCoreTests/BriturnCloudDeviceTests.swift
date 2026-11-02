import Foundation
import XCTest
@testable import MyHomeCore

final class BriturnCloudDeviceTests: XCTestCase {
    private let stateHex = "815f24611050000000380a000f16"
    private func item(id: Int = 1, mac: String = "AABBCCDDEEFF", online: Bool = true) -> [String: Any] {
        ["deviceId": id, "entityType": "TCP_WF", "productId": 95, "macAddress": mac,
         "name": "Cloud Fixture", "entityData": ["online": online],
         "functionList": ["POWER", "RGB", "CCT"].map { ["function": $0] }]
    }
    private func storage() -> MemorySessions {
        let storage = MemorySessions()
        storage.session = BriturnCloudSession(account: BriturnCloudAccount(maskedEmail: "t…@example.invalid", region: .us, signedInAt: Date()),
                                              token: "TEST_OLD", apiURL: URL(string: "https://app-us.briturn.net")!)
        return storage
    }
    private var config: (Int, [String: Any]) { (200, ["code": 0, "data": ["time": 1700000000]]) }
    private func reply(_ data: Any) -> (Int, [String: Any]) { (200, ["code": 0, "data": data]) }

    func testMACMergeKeepsLocalTransportAndGroupsWithoutDuplicates() throws {
        let cloud = try BriturnCloudDevice(json: item(), homeID: 7)
        let local = Device(id: "briturn-aabbccddeeff", name: "Old", ip: "192.0.2.10", version: "1", category: "briturn", group: "Study", online: true)
        let unrelated = Device(id: "tuya-test", name: "Tuya", ip: "192.0.2.11", version: "3.3", category: "cz", online: true)
        let merged = BriturnCloudDevice.merge(local: [local, unrelated], cloud: [cloud])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].name, "Cloud Fixture")
        XCTAssertEqual(merged[0].ip, local.ip)
        XCTAssertEqual(merged[0].group, "Study")
        XCTAssertEqual(merged[1], unrelated)
        let cloudOnly = BriturnCloudDevice.merge(local: [], cloud: [cloud])
        XCTAssertEqual(cloudOnly[0].id, local.id)
        XCTAssertEqual(cloudOnly[0].ip, "")
    }

    func testStatusParserChecksLengthPowerAndChecksum() {
        let state = BriturnCloudPackets.parseState(stateHex)
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.on, false)
        XCTAssertEqual(state?.firmware, 10)
        XCTAssertEqual(state?.w, 56)
        XCTAssertNil(BriturnCloudPackets.parseState(String(stateHex.dropLast()) + "0"))
        XCTAssertNil(BriturnCloudPackets.parseState("ea8102005f0a246101500f000000001600000000"))
        XCTAssertNil(BriturnCloudPackets.parseState("not-hex"))
    }

    func testVerifiedPowerHSVAndCCTPackets() throws {
        let state = try XCTUnwrap(BriturnCloudPackets.parseState(stateHex))
        let functions: Set<String> = ["POWER", "RGB", "CCT"]
        let packets = try BriturnCloudPackets.commands(state: state, functions: functions, on: true,
                                                      color: (255, 0, 0), brightness: 50, white: false, cct: nil)
        XCTAssertEqual(BriturnCloudPackets.hex(packets[0]), "3B23000000000000000000005E")
        XCTAssertEqual(Array(packets[1].prefix(5)), [0x3B, 0xA1, 0, 100, 50])
        for packet in packets { XCTAssertEqual(packet.count, 13); XCTAssertEqual(packet.dropLast().reduce(0) { $0 + Int($1) } & 255, Int(packet.last!)) }
        let cct = try BriturnCloudPackets.commands(state: state, functions: functions, on: nil,
                                                  color: nil, brightness: 75, white: true, cct: 40)
        XCTAssertEqual(Array(cct[0].prefix(7)), [0x3B, 0xB1, 0, 0, 0, 40, 75])
        XCTAssertThrowsError(try BriturnCloudPackets.commands(state: state, functions: ["POWER"], on: nil, color: (255, 0, 0), brightness: nil, white: false, cct: nil))
    }

    func testSyncRotatesTokenBeforeNextRequestAndLoadsHomes() async throws {
        let storage = storage()
        let transport = MockTransport([config, (200, ["code": 0, "token": "TEST_NEW", "data": [["homeId": 7]]]), reply([item()])])
        let client = BriturnCloudClient(transport: transport, storage: storage)
        let devices = try await client.syncDevices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].homeID, 7)
        let requests = await transport.captured()
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "token"), "TEST_OLD")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "token"), "TEST_NEW")
        XCTAssertEqual(storage.session?.token, "TEST_NEW")
        let body = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as! [String: Int]
        XCTAssertEqual(body, ["homeId": 7])
    }

    func testGroupControlQueriesThenSendsBatchThenReadsActualState() async throws {
        let storage = storage()
        let a = try BriturnCloudDevice(json: item(), homeID: 7)
        let b = try BriturnCloudDevice(json: item(id: 2, mac: "112233445566"), homeID: 7)
        let states: [[String: Any]] = [["id": 1, "state": stateHex], ["id": 2, "state": stateHex]]
        let transport = MockTransport([config, reply(states), reply([]), reply(states)])
        let client = BriturnCloudClient(transport: transport, storage: storage)
        let result = try await client.control(devices: [a, b], on: false)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[a.canonicalID]?.on, false)
        let requests = await transport.captured()
        let bodies = try requests.dropFirst().map { try JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: Any] }
        XCTAssertEqual(bodies.compactMap { $0["type"] as? String }, ["device.quest", "device.hex", "device.quest"])
        let commands = bodies[1]["body"] as! [[String: Any]]
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.allSatisfy { $0["value"] as? String == "3B24000000000000000000005F" })
    }

    func testOfflineMemberDoesNotBlockReachableGroupMember() async throws {
        let a = try BriturnCloudDevice(json: item(), homeID: 7)
        let b = try BriturnCloudDevice(json: item(id: 2, mac: "112233445566"), homeID: 7)
        let transport = MockTransport([config, reply([["id": 1, "state": stateHex]]), reply([]), reply([["id": 1, "state": stateHex]])])
        let client = BriturnCloudClient(transport: transport, storage: storage())
        let result = try await client.control(devices: [a, b], on: false)
        XCTAssertEqual(Set(result.keys), [a.canonicalID])
        let requests = await transport.captured()
        let body = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as! [String: Any]
        XCTAssertEqual((body["body"] as! [[String: Any]]).count, 1)
    }

    func testAcknowledgementWithoutRequestedPowerChangeIsNotSuccess() async throws {
        let device = try BriturnCloudDevice(json: item(), homeID: 7)
        let states: [[String: Any]] = [["id": 1, "state": stateHex]]
        let client = BriturnCloudClient(transport: MockTransport([config, reply(states), reply([]), reply(states)]), storage: storage())
        do {
            _ = try await client.control(devices: [device], on: true)
            XCTFail("An HTTP acknowledgement with unchanged power must not count as success")
        } catch BriturnCloudError.commandUnconfirmed { }
    }

    func testUnauthorizedClearsSessionAndSignedOutSyncReturnsNoDevices() async throws {
        let storage = storage()
        let transport = MockTransport([config, (401, [:])])
        let client = BriturnCloudClient(transport: transport, storage: storage)
        do { _ = try await client.syncDevices(); XCTFail("Expected expiry") }
        catch BriturnCloudError.unauthorized { }
        XCTAssertNil(storage.session)
        let devices = try await client.syncDevices()
        XCTAssertTrue(devices.isEmpty)
    }
}
