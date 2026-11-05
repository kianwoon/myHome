import Foundation
import XCTest
@testable import MyHomeCore

/// Spec/status fixtures shared by the control-layer tests.
enum ControlFixtures {
    static func spec(_ json: String) -> [String: DPDeclaration] {
        try! JSONDecoder().decode([String: DPDeclaration].self, from: Data(json.utf8))
    }

    static let fanSpec = spec(#"""
    {"1": {"code": "switch", "type": "Boolean", "values": {}},
     "2": {"code": "mode", "type": "Enum", "values": {"range": ["custom", "nature", "sleep"]}},
     "3": {"code": "fan_speed", "type": "Integer", "values": {"min": 1, "max": 6, "step": 1}},
     "5": {"code": "switch_horizontal", "type": "Boolean", "values": {}}}
    """#)

    static let lightSpec = spec(#"""
    {"1": {"code": "switch_led", "type": "Boolean", "values": {}},
     "2": {"code": "bright_value", "type": "Integer", "values": {"min": 10, "max": 1000, "step": 1}},
     "3": {"code": "temp_value", "type": "Integer", "values": {"min": 0, "max": 1000, "step": 1}},
     "4": {"code": "work_mode", "type": "Enum", "values": {"range": ["white", "colour", "scene"]}}}
    """#)

    static let v2LightSpec = spec(#"""
    {"20": {"code": "switch_led", "type": "Boolean", "values": {}},
     "22": {"code": "bright_value_v2", "type": "Integer", "values": {"min": 10, "max": 1000, "step": 1}}}
    """#)

    static let curtainSpec = spec(#"""
    {"1": {"code": "control", "type": "Enum", "values": {"range": ["open", "stop", "close"]}},
     "2": {"code": "percent_control", "type": "Integer", "values": {"min": 0, "max": 100, "step": 1}}}
    """#)

    static func device(_ id: String, name: String, category: String, room: String = "", group: String? = nil,
                       ip: String = "192.168.1.10", online: Bool = true, spec: [String: DPDeclaration]? = nil) -> Device {
        Device(id: id, name: name, ip: ip, version: "3.3", category: category, group: group, online: online, spec: spec, room: room)
    }

    static func profile(_ device: Device, dps: [String: DPSValue] = [:], briturn: Bool = false) -> DeviceProfile {
        DeviceProfile(device: device, state: DeviceState(dps: dps, capabilities: device.capabilities), isBriturn: briturn)
    }
}

final class CapabilityMapTests: XCTestCase {
    func testNumericFanLevelMapsToGearAndSpeedKeyFollowsStatus() {
        let fan = ControlFixtures.device("fan1", name: "Study Fan", category: "fs", spec: ControlFixtures.fanSpec)
        let profile = ControlFixtures.profile(fan, dps: ["1": .bool(true), "2": .string("custom"), "3": .number(2)])
        XCTAssertEqual(CapabilityMap.supported(for: profile), [.power, .level, .fanSpeed, .mode])
        XCTAssertEqual(CapabilityMap.plan(.level(50), for: profile), .success(.tuya(dpId: "3", value: .number(3))))
        XCTAssertEqual(CapabilityMap.plan(.level(100), for: profile), .success(.tuya(dpId: "3", value: .number(6))))
        XCTAssertEqual(CapabilityMap.plan(.level(0), for: profile), .success(.tuya(dpId: "3", value: .number(1))), "never below the lowest gear")
        XCTAssertEqual(CapabilityMap.plan(.fanSpeed(4), for: profile), .success(.tuya(dpId: "3", value: .number(4))))
        XCTAssertEqual(CapabilityMap.plan(.fanSpeed(9), for: profile), .failure(.outOfRange(.fanSpeed, lower: 1, upper: 6)))
        XCTAssertEqual(CapabilityMap.plan(.mode("sleep"), for: profile), .success(.tuya(dpId: "2", value: .string("sleep"))))
        XCTAssertEqual(CapabilityMap.plan(.mode("turbo"), for: profile), .failure(.unknownMode("turbo", options: ["custom", "nature", "sleep"])))
        XCTAssertEqual(CapabilityMap.levelPercent(profile, briturn: nil), 33)
    }

    func testStringGearFanUsesDeclaredEnumWords() {
        let fan = ControlFixtures.device("fan2", name: "Bedroom Fan", category: "fs")
        let profile = ControlFixtures.profile(fan, dps: ["1": .bool(true), "2": .string("small")])
        XCTAssertEqual(CapabilityMap.plan(.fanSpeed(2), for: profile), .success(.tuya(dpId: "2", value: .string("middle"))))
        XCTAssertEqual(CapabilityMap.plan(.level(100), for: profile), .success(.tuya(dpId: "2", value: .string("large"))))
    }

    func testFanWithoutStatusFallsBackToSpecThenNeedsStatus() {
        let fan = ControlFixtures.device("fan3", name: "Fan", category: "fs", spec: ControlFixtures.fanSpec)
        XCTAssertEqual(CapabilityMap.plan(.fanSpeed(3), for: ControlFixtures.profile(fan)), .success(.tuya(dpId: "3", value: .number(3))))
        let bare = ControlFixtures.device("fan4", name: "Fan", category: "fs")
        XCTAssertEqual(CapabilityMap.plan(.fanSpeed(3), for: ControlFixtures.profile(bare)), .failure(.needsStatus(.fanSpeed)))
    }

    func testLightBrightnessAndTemperatureScaleToDeclaredRanges() {
        let light = ControlFixtures.device("l1", name: "Desk Lamp", category: "dj", spec: ControlFixtures.lightSpec)
        let profile = ControlFixtures.profile(light, dps: ["1": .bool(true), "2": .number(500), "3": .number(100)])
        XCTAssertEqual(CapabilityMap.supported(for: profile), [.power, .level, .colorTemperature, .mode])
        XCTAssertEqual(CapabilityMap.plan(.level(50), for: profile), .success(.tuya(dpId: "2", value: .number(505))))
        XCTAssertEqual(CapabilityMap.plan(.level(0), for: profile), .success(.tuya(dpId: "2", value: .number(10))))
        XCTAssertEqual(CapabilityMap.plan(.colorTemperature(100), for: profile), .success(.tuya(dpId: "3", value: .number(1000))))
        XCTAssertEqual(CapabilityMap.plan(.color(RGB(red: 1, green: 2, blue: 3)), for: profile), .failure(.unsupported(.color)))
        XCTAssertEqual(CapabilityMap.plan(.level(101), for: profile), .failure(.outOfRange(.level, lower: 0, upper: 100)))
        XCTAssertEqual(CapabilityMap.levelPercent(profile, briturn: nil), 49)
    }

    func testV2LightUsesSpecCodesNotFixedDpNumbers() {
        let light = ControlFixtures.device("l2", name: "Strip", category: "dj", spec: ControlFixtures.v2LightSpec)
        let profile = ControlFixtures.profile(light)
        XCTAssertEqual(CapabilityMap.plan(.power(true), for: profile), .success(.tuya(dpId: "20", value: .bool(true))))
        XCTAssertEqual(CapabilityMap.plan(.level(100), for: profile), .success(.tuya(dpId: "22", value: .number(1000))))
    }

    func testCurtainActionAndPositionFollowValueTypes() {
        let curtain = ControlFixtures.device("c1", name: "Study Curtain", category: "cl", spec: ControlFixtures.curtainSpec)
        let profile = ControlFixtures.profile(curtain, dps: ["1": .string("stop"), "2": .number(40)])
        XCTAssertEqual(CapabilityMap.supported(for: profile), [.level, .openClose, .mode])
        XCTAssertEqual(CapabilityMap.plan(.cover(.open), for: profile), .success(.tuya(dpId: "1", value: .string("open"))))
        XCTAssertEqual(CapabilityMap.plan(.level(75), for: profile), .success(.tuya(dpId: "2", value: .number(75))))
        XCTAssertEqual(CapabilityMap.plan(.power(true), for: profile), .failure(.unsupported(.power)), "dp 1 is the action enum, not a switch")
    }

    func testBriturnPlansAndExpectations() {
        let bulb = ControlFixtures.device("briturn-1", name: "Lamp", category: "briturn")
        let profile = ControlFixtures.profile(bulb, briturn: true)
        XCTAssertEqual(CapabilityMap.supported(for: profile), [.power, .level, .color, .colorTemperature])
        let power = CapabilityMap.plan(.power(false), for: profile)
        XCTAssertEqual(power, .success(.briturn(on: false, color: nil, brightness: nil, cct: nil)))
        XCTAssertEqual(CapabilityMap.expectation(for: .briturn(on: false, color: nil, brightness: nil, cct: nil)), .briturnPower(false))
        XCTAssertEqual(CapabilityMap.plan(.level(40), for: profile), .success(.briturn(on: nil, color: nil, brightness: 40, cct: nil)))
        XCTAssertEqual(CapabilityMap.expectation(for: .briturn(on: nil, color: nil, brightness: 40, cct: nil)), .accepted)
        XCTAssertEqual(CapabilityMap.plan(.colorTemperature(100), for: profile), .success(.briturn(on: nil, color: nil, brightness: nil, cct: 100)))
        XCTAssertEqual(CapabilityMap.plan(.fanSpeed(1), for: profile), .failure(.unsupported(.fanSpeed)))
    }

    func testPercentScaling() {
        XCTAssertEqual(Percent.scaled(50, to: 10, 1000), 505)
        XCTAssertEqual(Percent.scaled(50, to: 0, 100, step: 10), 50)
        XCTAssertEqual(Percent.scaled(33, to: 0, 100, step: 10), 30)
        XCTAssertEqual(Percent.unscaled(505, from: 10, 1000), 50)
        XCTAssertEqual(Percent.clamp(140), 100)
    }
}
