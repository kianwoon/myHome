import XCTest
@testable import MyHomeCore

final class BLEReasonTests: XCTestCase {
    private func reason(_ auth: BLEAuthorization = .allowedAlways, _ state: BLEPowerState = .poweredOn,
                        scanning: Bool = true, live: Int = 0, lightLive: Bool = false) -> String {
        BLEReason.message(authorization: auth, state: state, scanning: scanning,
                          liveCount: live, lightLive: lightLive)
    }

    func testDeniedAndRestrictedPointToSystemSettings() {
        XCTAssertEqual(reason(.denied), BLEReason.permissionOff)
        XCTAssertEqual(reason(.restricted), BLEReason.permissionOff)
        XCTAssertEqual(reason(.allowedAlways, .unauthorized), BLEReason.permissionOff)
    }

    func testNotDeterminedWaitsForPrompt() {
        XCTAssertEqual(reason(.notDetermined, .unknown, scanning: false), BLEReason.permissionPending)
    }

    func testPoweredOffOrUnsupportedSaysBluetoothOff() {
        XCTAssertEqual(reason(.allowedAlways, .poweredOff, scanning: false), BLEReason.bluetoothOff)
        XCTAssertEqual(reason(.allowedAlways, .unsupported, scanning: false), BLEReason.bluetoothOff)
    }

    func testScanningWithOtherLightsLiveReportsCount() {
        XCTAssertEqual(reason(live: 3), BLEReason.notSeen + " (3 other lights in range)")
        XCTAssertEqual(reason(live: 1), BLEReason.notSeen + " (1 other light in range)")
    }

    func testScanningWithNoLightsKeepsGenericMessage() {
        XCTAssertEqual(reason(live: 0), BLEReason.notSeen)
        XCTAssertEqual(reason(scanning: false, live: 2), BLEReason.notSeen)
    }
}
