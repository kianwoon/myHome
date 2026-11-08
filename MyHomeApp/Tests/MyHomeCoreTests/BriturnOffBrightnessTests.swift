import Foundation
import XCTest
@testable import MyHomeCore

private final class NullBridge: BridgeSending, @unchecked Sendable {
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] { ["ok": true] }
}

/// Regression for group "master middle": OFF, the Bluetooth light kept its
/// colour bytes (card 57) while the cloud light's off frame had zeroed
/// channels (card 0). Off lights must show their last ON level everywhere.
@MainActor
final class BriturnOffBrightnessTests: XCTestCase {
    private typealias S = DeviceStore.BriturnState
    private func store() -> DeviceStore {
        DeviceStore(bridge: NullBridge(), defaults: UserDefaults(suiteName: "OffBright-\(UUID())")!)
    }

    func testOnDerivationUnchanged() {
        let colour = S(on: true, rawPower: 0x23, mode: 97, r: 145, g: 20, b: 0, w: 0)
        XCTAssertEqual(colour.channelBrightnessPercent, 145.0 * 100 / 255, accuracy: 0.001)
        let white = S(on: true, rawPower: 0x23, mode: 97, r: 0, g: 0, b: 0, w: 100, cool: 45)
        XCTAssertEqual(white.channelBrightnessPercent, 145.0 * 100 / 255, accuracy: 0.001)
        let s = store()
        s.setBriturnStatus("a", colour)
        XCTAssertEqual(s.briturnDisplayBrightness("a")!, colour.channelBrightnessPercent, accuracy: 0.001)
    }

    func testOffLightsAgreeAcrossTransports() {
        let s = store()
        let on = S(on: true, rawPower: 0x23, mode: 97, r: 145, g: 0, b: 0, w: 0)
        s.setBriturnStatus("ble", on)
        s.setBriturnStatus("cloud", on)
        // Bluetooth power-only update keeps the colour bytes; the cloud off frame zeroes them.
        s.setBriturnStatus("ble", S(on: false, rawPower: 0x24, mode: 97, r: 145, g: 0, b: 0, w: 0))
        s.applyBriturnWireStates(["cloud": S(on: false, rawPower: 0x24, mode: 97, r: 0, g: 0, b: 0, w: 0)])
        let ble = s.briturnDisplayBrightness("ble")!
        let cloud = s.briturnDisplayBrightness("cloud")!
        XCTAssertEqual(ble, cloud, accuracy: 0.001, "off lights must not split 57 vs 0")
        XCTAssertEqual(cloud, on.channelBrightnessPercent, accuracy: 0.001)
    }

    func testOffWithoutHistoryFallsBackToChannels() {
        let s = store()
        s.setBriturnStatus("x", S(on: false, rawPower: 0x24, mode: 97, r: 0, g: 0, b: 0, w: 51))
        XCTAssertEqual(s.briturnDisplayBrightness("x")!, 20, accuracy: 0.001)
        XCTAssertNil(s.briturnDisplayBrightness("missing"))
    }

    func testTurningOnAtNewLevelUpdatesMemory() {
        let s = store()
        s.setBriturnStatus("x", S(on: true, rawPower: 0x23, mode: 97, r: 255, g: 0, b: 0, w: 0))
        s.setBriturnStatus("x", S(on: true, rawPower: 0x23, mode: 97, r: 51, g: 0, b: 0, w: 0))
        s.setBriturnStatus("x", S(on: false, rawPower: 0x24, mode: 97, r: 0, g: 0, b: 0, w: 0))
        XCTAssertEqual(s.briturnDisplayBrightness("x")!, 20, accuracy: 0.001)
    }
}
