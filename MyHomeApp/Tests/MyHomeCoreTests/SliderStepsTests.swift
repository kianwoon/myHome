import XCTest
@testable import MyHomeCore

final class SliderStepsTests: XCTestCase {
    func testDiscreteThreshold() {
        XCTAssertTrue(SliderSteps.isDiscrete(range: 0...20, step: 1))
        XCTAssertFalse(SliderSteps.isDiscrete(range: 0...21, step: 1))
        XCTAssertFalse(SliderSteps.isDiscrete(range: 10...1000, step: 1))
        XCTAssertTrue(SliderSteps.isDiscrete(range: 0...1000, step: 100))
        XCTAssertTrue(SliderSteps.isDiscrete(range: 0...10, step: nil))
        XCTAssertFalse(SliderSteps.isDiscrete(range: 0...86400, step: 0))
    }

    func testSnapRoundsToStepFromLowerBound() {
        XCTAssertEqual(SliderSteps.snap(value: 12.4, range: 10...1000, step: 1), 12)
        XCTAssertEqual(SliderSteps.snap(value: 12.6, range: 10...1000, step: 1), 13)
        XCTAssertEqual(SliderSteps.snap(value: 47, range: 10...1000, step: 10), 50)
        XCTAssertEqual(SliderSteps.snap(value: 44, range: 10...1000, step: 10), 40)
    }

    func testSnapClamps() {
        XCTAssertEqual(SliderSteps.snap(value: -5, range: 0...100, step: 5), 0)
        XCTAssertEqual(SliderSteps.snap(value: 999, range: 0...100, step: 5), 100)
        XCTAssertEqual(SliderSteps.snap(value: 99, range: 0...98, step: 10), 98)
    }
}
