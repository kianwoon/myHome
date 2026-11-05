import Foundation
import XCTest
@testable import MyHomeCore

final class DeviceResolverTests: XCTestCase {
    private let devices: [Device] = [
        ControlFixtures.device("fan-study", name: "Study Fan", category: "fs", room: "Study Room"),
        ControlFixtures.device("fan-bed", name: "Bedroom Fan", category: "fs", room: "Master Bedroom"),
        ControlFixtures.device("light-bed", name: "Ceiling Light", category: "dj", room: "Master Bedroom"),
        ControlFixtures.device("light-bed2", name: "Bedside Lamp", category: "dj", room: "Master Bedroom"),
        ControlFixtures.device("plug-kitchen", name: "Kettle Plug", category: "cz", room: "Kitchen"),
        ControlFixtures.device("briturn-1", name: "Lamp A", category: "briturn", group: "Study"),
        ControlFixtures.device("briturn-2", name: "Lamp B", category: "briturn", group: "Study"),
        ControlFixtures.device("briturn-3", name: "Lamp C", category: "briturn", group: "Living"),
    ]

    private func resolve(_ text: String, wantsSet: Bool = false, kind: DeviceKind? = nil, room: String? = nil) -> Resolution {
        DeviceResolver(devices: devices).resolve(DeviceQuery(text: text, room: room, kind: kind, wantsSet: wantsSet))
    }

    func testExactNameResolvesSingle() {
        XCTAssertEqual(resolve("study fan"), .single(devices[0]))
        XCTAssertEqual(resolve("the Study  Fan, please"), .single(devices[0]))
    }

    func testKindOnlyQueryWithSeveralMatchesIsAmbiguousNotGuessed() {
        guard case .ambiguous(let candidates) = resolve("the fan") else { return XCTFail("expected ambiguity") }
        XCTAssertEqual(Set(candidates.map(\.id)), ["fan-study", "fan-bed"])
    }

    func testRoomNarrowsAKindQuery() {
        XCTAssertEqual(resolve("bedroom fan"), .single(devices[1]))
        XCTAssertEqual(resolve("fan", room: "bedroom"), .single(devices[1]))
    }

    func testPluralMeansEveryMatchingDevice() {
        guard case .set(let found, let scope) = resolve("bedroom lights") else { return XCTFail("expected set") }
        XCTAssertEqual(Set(found.map(\.id)), ["light-bed", "light-bed2"])
        XCTAssertEqual(scope, .room("Master Bedroom"))
        guard case .set(let fans, let fanScope) = resolve("all the fans") else { return XCTFail("expected set") }
        XCTAssertEqual(fans.count, 2)
        XCTAssertEqual(fanScope, .kind(.fan))
    }

    func testSingularRoomLightWithTwoLightsIsAmbiguous() {
        XCTAssertTrue(resolve("bedroom light").isAmbiguous)
    }

    func testBriturnGroupResolvesToGroupWrite() {
        XCTAssertEqual(resolve("study lights"), .briturnGroup("Study", members: [devices[5], devices[6]]))
        XCTAssertEqual(resolve("living lights"), .single(devices[7]), "a one-member group is just that light")
    }

    func testNoMatchAndPartialMatch() {
        XCTAssertEqual(resolve("garage door"), .none)
        guard case .ambiguous(let partial) = resolve("kettle socket thing") else { return XCTFail("expected suggestions") }
        XCTAssertEqual(partial.map(\.id), ["plug-kitchen"], "partial coverage is surfaced as a suggestion, never executed")
    }

    func testExplicitIdsAndCapabilityFilter() {
        let resolver = DeviceResolver(devices: devices, supports: { device, _ in device.kind == .fan })
        XCTAssertEqual(resolver.resolve(DeviceQuery(ids: ["light-bed"])), .single(devices[2]))
        XCTAssertEqual(resolver.resolve(DeviceQuery(text: "ceiling light", requiredCapability: .fanSpeed)), .none)
        XCTAssertEqual(resolver.resolve(DeviceQuery(text: "study fan", requiredCapability: .fanSpeed)), .single(devices[0]))
    }

    func testEmptyQueryWithKindFilter() {
        guard case .set(let found, let scope) = resolve("", wantsSet: true, kind: .light) else { return XCTFail("expected set") }
        XCTAssertEqual(found.count, 5)
        XCTAssertEqual(scope, .kind(.light))
    }

    func testNormalizer() {
        XCTAssertEqual(TextNormalizer.tokens("The Bedroom Lights!"), ["the", "bedroom", "light"])
        XCTAssertEqual(TextNormalizer.singular("glass"), "glass")
        XCTAssertEqual(TextNormalizer.canonical("Café  Lamp"), "cafe lamp")
    }
}

final class DeviceEntityMatchingTests: XCTestCase {
    private let lamp = ControlFixtures.device("lamp-desk", name: "Desk Lamp", category: "dj", room: "Study")
    private let fan = ControlFixtures.device("fan-desk", name: "Desk Fan", category: "fs", room: "Study")

    func testOnlyClearResolutionsAnswerOutright() {
        XCTAssertEqual(DeviceEntityMatching.clearMatches(in: .single(lamp)).map(\.id), [lamp.id])
        XCTAssertEqual(DeviceEntityMatching.clearMatches(in: .set([lamp, fan], scope: .all)).count, 2)
        XCTAssertTrue(DeviceEntityMatching.clearMatches(in: .none).isEmpty)
        XCTAssertTrue(DeviceEntityMatching.clearMatches(in: .ambiguous([lamp])).isEmpty, "a lone partial match must not be returned as the answer")
    }

    func testPartialQueryResolvesAmbiguousSoItIsNotClear() {
        let resolver = DeviceResolver(devices: [lamp, fan], config: ResolverConfig(), vocabulary: .standard)
        let resolution = resolver.resolve(DeviceQuery(text: "kitchen lamp"))
        XCTAssertTrue(DeviceEntityMatching.clearMatches(in: resolution).isEmpty)
    }
}
