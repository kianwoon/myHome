import Foundation
import CoreBluetooth
import XCTest
@testable import MyHomeCore

private final class NullBridge: BridgeSending, @unchecked Sendable {
    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] { ["ok": true] }
}

@MainActor
final class BLEIdentityTests: XCTestCase {
    func testSameMfrPatternDifferentPeripheralsStayDistinct() {
        let ble = BLEManager.shared
        // Identical manufacturer payload (state bytes + fixed product tail).
        let mfr = Data([0x5A, 0x00, 0x64, 0x1D, 0xF0, 0x50, 0x01, 0x61, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x23, 0x61, 0xF0, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let u1 = UUID(), u2 = UUID()
        let a = ble.noteLight(uuid: u1, name: "IOTWF4F1", rssi: -50, mfr: mfr, hasServiceData: false)
        let b = ble.noteLight(uuid: u2, name: "IOTWF0D9", rssi: -60, mfr: mfr, hasServiceData: false)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(a.isNew && b.isNew)
        XCTAssertEqual(a.id, "ble-" + u1.uuidString.lowercased())
        let mine = ble.lights.filter { [a.id, b.id].contains($0.id) }
        XCTAssertEqual(Set(mine.map(\.name)), ["IOTWF4F1", "IOTWF0D9"])
        // Re-advert of the same peripheral is not new.
        XCTAssertFalse(ble.noteLight(uuid: u1, name: "IOTWF4F1", rssi: -50, mfr: mfr, hasServiceData: false).isNew)
    }

    func testMigrationDropsTwelveHexIdsKeepsUUIDs() {
        let uuidID = "ble-cfbf120c-7f3d-b4f1-8827-906f05c07e79"
        let stored = [BLELight(id: "ble-00000f500161", name: "IOTWF0D9", rssi: -1),
                      BLELight(id: "ble-641df0500161", name: "IOTWF4F1", rssi: -1),
                      BLELight(id: uuidID, name: "IOTWF4F1", rssi: -1),
                      BLELight(id: "ble-11111111-2222-3333-4444-555555555555", name: "IOTWF4F1", rssi: -1)]
        let kept = DeviceStore.migrateBLESeen(stored)
        XCTAssertEqual(kept.count, 2, "same-name UUID entries are different bulbs and must not merge")
        XCTAssertTrue(kept.allSatisfy { $0.id.count == "ble-".count + 36 })
    }

    func testNameSuffixMapsIOTWF9E3ToRosterLight() throws {
        let store = DeviceStore(bridge: NullBridge(), defaults: UserDefaults(suiteName: "BLEIdentity-\(UUID())")!)
        let item = try BriturnCloudDevice(json: ["deviceId": 9, "entityType": "TCP_WF", "productId": 95,
                                                 "macAddress": "0865f0ef89e3", "name": "Lamp",
                                                 "entityData": ["online": false]], homeID: 1)
        store.briturnCloudDevices = [item.canonicalID: item]
        store.rebuildBriturnRoster()
        XCTAssertEqual(item.canonicalID, "briturn-0865f0ef89e3")
        let light = BLELight(id: "ble-cfbf120c-7f3d-b4f1-8827-906f05c07e79", name: "IOTWF9E3", rssi: -50)
        store.bleSeen[light.id] = light
        store.reattachBLETransports()
        XCTAssertEqual(store.bleKeysByDeviceID["briturn-0865f0ef89e3"], [light.id])
    }

    func testIsTuyaAdvert() {
        XCTAssertTrue(BLEManager.isTuyaAdvert(name: "TY", mfrCompanyID: nil, serviceUUIDs: []))
        XCTAssertTrue(BLEManager.isTuyaAdvert(name: "TUYA_ab", mfrCompanyID: nil, serviceUUIDs: []))
        XCTAssertTrue(BLEManager.isTuyaAdvert(name: "", mfrCompanyID: 0x07D0, serviceUUIDs: []))
        XCTAssertTrue(BLEManager.isTuyaAdvert(name: "", mfrCompanyID: nil, serviceUUIDs: [CBUUID(string: "A201")]))
        XCTAssertTrue(BLEManager.isTuyaAdvert(name: "", mfrCompanyID: nil, serviceUUIDs: [CBUUID(string: "FD50")]))
        XCTAssertFalse(BLEManager.isTuyaAdvert(name: "IOTWF4F1", mfrCompanyID: 0x5A00, serviceUUIDs: [CBUUID(string: "180F")]))
    }
}
