import CoreBluetooth
import XCTest
@testable import MyHomeCore

final class BLEWireTests: XCTestCase {
    func testWriteTypePrefersWithResponse() {
        XCTAssertEqual(BLEWire.writeType(for: [.write, .writeWithoutResponse]), .withResponse)
        XCTAssertEqual(BLEWire.writeType(for: [.writeWithoutResponse, .notify]), .withoutResponse)
        XCTAssertNil(BLEWire.writeType(for: [.read, .notify]))
    }

    func testDescribeProperties() {
        XCTAssertEqual(BLEWire.describe([.write, .notify]), "write|notify")
        XCTAssertEqual(BLEWire.describe([]), "none")
    }

    func testHexPrefixIsCappedAtFourBytes() {
        XCTAssertEqual(BLEWire.hexPrefix([0x3B, 0x23, 0x00, 0x00, 0x32, 0xFF]), "3b 23 00 00")
        XCTAssertEqual(BLEWire.hexPrefix([0x3B]), "3b")
    }
}
