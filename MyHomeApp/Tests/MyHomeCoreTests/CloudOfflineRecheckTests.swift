import Foundation
import XCTest
@testable import MyHomeCore

final class CloudOfflineRecheckTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let interval = DeviceStore.cloudOfflineRecheckInterval

    private func check(_ online: [String: Bool], briturn: Set<String> = [], last: Date?) -> Bool {
        DeviceStore.needsOfflineRecheck(cloudOnline: online, briturnIDs: briturn,
                                        lastRefresh: last, now: now, interval: interval)
    }

    func testNoFalseMeansNoRecheck() {
        XCTAssertFalse(check(["a": true, "b": true], last: now.addingTimeInterval(-interval * 10)))
        XCTAssertFalse(check([:], last: nil))
    }

    func testTuyaFalseWithIntervalElapsedRechecks() {
        XCTAssertTrue(check(["a": true, "b": false], last: now.addingTimeInterval(-interval)))
    }

    func testTuyaFalseBeforeIntervalDoesNotRecheck() {
        XCTAssertFalse(check(["a": false], last: now.addingTimeInterval(-interval + 1)))
    }

    func testOnlyBriturnFalseDoesNotRecheck() {
        XCTAssertFalse(check(["bt": false, "a": true], briturn: ["bt"], last: nil))
    }

    func testNilLastRefreshWithFalseRechecks() {
        XCTAssertTrue(check(["a": false], last: nil))
    }
}
