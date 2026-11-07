import XCTest
@testable import MyHomeCore

private struct StubBrowser: KEFServiceBrowsing {
    let hits: [KEFServiceHit]
    func browse(timeout: TimeInterval) async -> [KEFServiceHit] { hits }
}

final class KEFDiscoveryTests: XCTestCase {
    private func client(mac: String = "aabbcc001122", model: String = "LS50WII") -> @Sendable (String) throws -> any KEFClientProtocol {
        { _ in FixedIdentityClient(identity: KEFIdentity(model: model, firmware: "V1", macAddress: mac)) }
    }

    func testParsesInstanceNames() {
        XCTAssertEqual(KEFDiscovery.parseInstance("AABBCC001122@LS50WII")?.mac, "aabbcc001122")
        XCTAssertEqual(KEFDiscovery.parseInstance("aabbcc001122@LS50WII")?.model, "LS50WII")
        for bad in ["LS50WII", "zz@LS50WII", "aabbcc001122@", "aabbcc00112@LS50WII"] { XCTAssertNil(KEFDiscovery.parseInstance(bad), bad) }
    }

    func testVerifiedSpeakerIsFoundAndDeduplicated() async {
        let hits = [KEFServiceHit(instanceName: "aabbcc001122@LS50WII", address: "192.0.2.10"),
                    KEFServiceHit(instanceName: "aabbcc001122@LS50WII", address: "192.0.2.10")]
        let found = await KEFDiscovery.discover(browser: StubBrowser(hits: hits), makeClient: client(), timeout: 0)
        XCTAssertEqual(found.map(\.id), ["kef:aabbcc001122"])
        XCTAssertEqual(found.first?.address, "192.0.2.10")
    }

    func testRejectsUnsupportedModelBadAddressAndIdentityMismatch() async {
        let hits = [KEFServiceHit(instanceName: "aabbcc001122@LSXII", address: "192.0.2.11"),
                    KEFServiceHit(instanceName: "aabbcc001122@LS50WII", address: "not-an-ip"),
                    KEFServiceHit(instanceName: "aabbcc001122@LS50WII", address: "192.0.2.12")]
        // The device behind .12 reports a different MAC than its advertisement: not trusted.
        let found = await KEFDiscovery.discover(browser: StubBrowser(hits: hits), makeClient: client(mac: "ffffffffffff"), timeout: 0)
        XCTAssertTrue(found.isEmpty)
    }

    func testUnverifiableCandidateIsDropped() async {
        struct Failing: KEFClientProtocol {
            func fetchIdentity() async throws -> KEFIdentity { throw KEFError.unreachable }
            func fetchState() async throws -> KEFState { KEFState() }
            func setPower(_ on: Bool) async throws {}
            func setVolume(_ percent: Int) async throws {}
            func setMuted(_ muted: Bool) async throws {}
            func setInput(_ input: KEFInput) async throws {}
        }
        let hits = [KEFServiceHit(instanceName: "aabbcc001122@LS50WII", address: "192.0.2.10")]
        let found = await KEFDiscovery.discover(browser: StubBrowser(hits: hits), makeClient: { _ in Failing() }, timeout: 0)
        XCTAssertTrue(found.isEmpty)
    }
}

private struct FixedIdentityClient: KEFClientProtocol {
    let identity: KEFIdentity
    func fetchIdentity() async throws -> KEFIdentity { identity }
    func fetchState() async throws -> KEFState { KEFState() }
    func setPower(_ on: Bool) async throws {}
    func setVolume(_ percent: Int) async throws {}
    func setMuted(_ muted: Bool) async throws {}
    func setInput(_ input: KEFInput) async throws {}
}
