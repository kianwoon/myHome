import Foundation
import XCTest
@testable import MyHomeCore

final class DeviceQueryAnswererTests: XCTestCase {
    private func device(_ name: String, _ kind: DeviceKind, on: Bool?, room: String = "",
                        reach: DeviceSummary.ReachabilitySummary = .wifi) -> DeviceSummary {
        DeviceSummary(id: name.lowercased(), name: name, room: room, group: nil, kind: kind, capabilities: [.power],
                      reachability: reach, isControllable: reach != .offline, isOn: on, levelPercent: nil)
    }

    private lazy var home: [DeviceSummary] = [
        device("Desk Lamp", .light, on: true, room: "Study"),
        device("Bedside", .light, on: true, room: "Bedroom"),
        device("Floor Lamp", .light, on: false, room: "Study"),
        device("Study Fan", .fan, on: false, room: "Study"),
    ]

    private func answer(_ kind: DeviceKind?, _ state: StateQuery.State, _ aggregation: StateQuery.Aggregation,
                        name: String? = nil, devices: [DeviceSummary]? = nil, listMax: Int = 5) -> String {
        DeviceQueryAnswerer.answer(StateQuery(kind: kind, state: state, aggregation: aggregation, name: name),
                                   devices: devices ?? home, listMax: listMax)
    }

    func testCountIsComputedFromTheRegistry() {
        XCTAssertEqual(answer(.light, .on, .count), "2 of 3 lights are on: Desk Lamp and Bedside.")
        XCTAssertEqual(answer(.light, .off, .count), "1 of 3 lights is off: Floor Lamp.")
        XCTAssertEqual(answer(nil, .on, .count), "2 of 4 devices are on: Desk Lamp and Bedside.")
    }

    func testZeroAndSingular() {
        XCTAssertEqual(answer(.fan, .on, .count), "No fans are on.")
        XCTAssertEqual(answer(.fan, .off, .count), "1 of 1 fan is off: Study Fan.")
        XCTAssertEqual(answer(.fan, .on, .is), "No, no fans are on.")
        XCTAssertEqual(answer(.curtain, .on, .count), "No curtains found.")
        XCTAssertEqual(answer(.climate, .on, .count), "No climate devices found.")
    }

    func testListAndYesNo() {
        XCTAssertEqual(answer(.light, .on, .list), "2 lights are on: Desk Lamp and Bedside.")
        XCTAssertEqual(answer(.light, .off, .is), "Yes, 1 light is off: Floor Lamp.")
        XCTAssertEqual(answer(.light, .any, .count), "3 lights: Desk Lamp, Bedside, and Floor Lamp.")
    }

    func testNameScopesTheDevices() {
        XCTAssertEqual(answer(.light, .on, .count, name: "study"), "1 of 2 lights matching \u{201C}study\u{201D} is on: Desk Lamp.")
    }

    func testOfflineAndUnknownAreNotCountedButMentioned() {
        let devices = home + [device("Porch", .light, on: true, reach: .offline), device("Hall", .light, on: nil)]
        XCTAssertEqual(answer(.light, .on, .count, devices: devices),
                       "2 of 3 lights are on: Desk Lamp and Bedside. 1 light is offline. 1 light has no state reading yet.")
        let allOffline = [device("Porch", .light, on: true, reach: .offline), device("Gate", .light, on: false, reach: .offline)]
        XCTAssertEqual(answer(.light, .on, .count, devices: allOffline), "No lights are on. 2 lights are offline.")
    }

    func testLongListsAreTruncated() {
        let many = (1...7).map { device("Lamp \($0)", .light, on: true) }
        XCTAssertEqual(answer(.light, .on, .list, devices: many, listMax: 3), "7 lights are on: Lamp 1, Lamp 2, Lamp 3, and 4 more.")
        XCTAssertTrue(answer(.light, .on, .count, devices: many, listMax: 3).hasPrefix("7 of 7 lights are on:"))
        XCTAssertEqual(AppSettings.stateQueryListMax(from: UserDefaults(suiteName: "answerer-\(UUID())")!), AppSettings.defaultStateQueryListMax)
    }
}

final class StateQueryParserTests: XCTestCase {
    private let parser = VoiceCommandParser()

    func testCountListAndYesNoQuestions() {
        XCTAssertEqual(parser.parse("how many lights are on?"), .stateQuery(StateQuery(kind: .light, state: .on, aggregation: .count)))
        XCTAssertEqual(parser.parse("Which fans are off"), .stateQuery(StateQuery(kind: .fan, state: .off, aggregation: .list)))
        XCTAssertEqual(parser.parse("are any lamps on in the study"),
                       .stateQuery(StateQuery(kind: .light, state: .on, aggregation: .is, name: "study")))
        XCTAssertEqual(parser.parse("are there any fans running"), .stateQuery(StateQuery(kind: .fan, state: .on, aggregation: .is)))
        XCTAssertEqual(parser.parse("how many devices are on"), .stateQuery(StateQuery(kind: nil, state: .on, aggregation: .count)))
        XCTAssertEqual(parser.parse("how many fans are there"), .stateQuery(StateQuery(kind: .fan, state: .any, aggregation: .count)))
        XCTAssertEqual(parser.parse("what lights are on"), .stateQuery(StateQuery(kind: .light, state: .on, aggregation: .list)))
    }

    func testSingleDeviceStatusIsUnchanged() {
        XCTAssertEqual(parser.parse("is the study fan on"), .status(DeviceQuery(text: "study fan")))
        XCTAssertEqual(parser.parse("is the study fan running"), .status(DeviceQuery(text: "study fan")))
        XCTAssertEqual(parser.parse("status of the study fan"), .status(DeviceQuery(text: "study fan")))
        if case .stateQuery = parser.parse("what is the study fan speed") { XCTFail("no on/off word: not a state question") }
        if case .stateQuery = parser.parse("which one") { XCTFail("no kind noun: not a state question") }
    }

    func testFanNounsResolveToTheFanKind() {
        XCTAssertEqual(ResolverVocabulary.standard.kind(for: "fan"), .fan)
        XCTAssertEqual(ResolverVocabulary.standard.kind(for: "fans"), .fan)
        XCTAssertEqual(ResolverVocabulary.standard.kind(for: "lamps"), .light)
    }
}
