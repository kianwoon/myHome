import XCTest
@testable import MyHomeCore

@MainActor
private final class FakeRegistrar: HotkeyRegistering {
    var registered: [HotkeyBinding] = []
    var unregisterCount = 0
    var failWith: HotkeyRegistrationError?
    var handler: ((HotkeyEvent) -> Void)?

    func register(_ binding: HotkeyBinding, handler: @escaping (HotkeyEvent) -> Void) throws {
        if let failWith { throw failWith }
        registered.append(binding)
        self.handler = handler
    }

    func unregister() {
        unregisterCount += 1
        handler = nil
    }
}

final class HotkeyBindingTests: XCTestCase {
    private let optionSpace = HotkeyBinding(keyCode: 49, modifiers: HotkeyBinding.optionMask)

    private func isolatedDefaults() -> UserDefaults { UserDefaults(suiteName: "HotkeyTests-\(UUID())")! }

    func testBareKeyRejected() {
        XCTAssertEqual(HotkeyBinding(keyCode: 49, modifiers: 0).validate().isAcceptable, false)
    }

    func testModifierOnlyKeyRejected() {
        XCTAssertFalse(HotkeyBinding(keyCode: 58, modifiers: HotkeyBinding.optionMask).validate().isAcceptable)
    }

    func testOptionSpaceIsOk() {
        XCTAssertEqual(optionSpace.validate(), .ok)
    }

    func testReservedCombosWarnButStayAcceptable() {
        for binding in [HotkeyBinding(keyCode: 49, modifiers: HotkeyBinding.commandMask),
                        HotkeyBinding(keyCode: 48, modifiers: HotkeyBinding.commandMask)] {
            let verdict = binding.validate()
            guard case .warning = verdict else { return XCTFail("expected warning for \(binding.displayString)") }
            XCTAssertTrue(verdict.isAcceptable)
        }
    }

    func testShiftOnlyWarns() {
        guard case .warning = HotkeyBinding(keyCode: 0, modifiers: HotkeyBinding.shiftMask).validate() else { return XCTFail() }
    }

    func testForeignModifierBitsDropped() {
        XCTAssertEqual(HotkeyBinding(keyCode: 49, modifiers: HotkeyBinding.optionMask | 0x10000).modifiers, HotkeyBinding.optionMask)
    }

    func testDisplayString() {
        XCTAssertEqual(optionSpace.displayString, "⌥Space")
        let all = HotkeyBinding(keyCode: 40, modifiers: HotkeyBinding.allModifiers)
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘K")
        XCTAssertEqual(HotkeyBinding(keyCode: 122, modifiers: HotkeyBinding.controlMask).displayString, "⌃F1")
    }

    func testDefaultIsUnset() {
        XCTAssertNil(AppSettings.defaultHotkeyBinding)
        XCTAssertNil(HotkeyBinding.load(from: isolatedDefaults()))
    }

    func testPersistenceRoundTripAndClear() {
        let defaults = isolatedDefaults()
        HotkeyBinding.save(optionSpace, to: defaults)
        XCTAssertEqual(HotkeyBinding.load(from: defaults), optionSpace)
        HotkeyBinding.save(nil, to: defaults)
        XCTAssertNil(HotkeyBinding.load(from: defaults))
    }

    func testCorruptStoredValueFallsBackToDefault() {
        let defaults = isolatedDefaults()
        defaults.set(Data("nope".utf8), forKey: AppSettings.hotkeyBindingKey)
        XCTAssertNil(HotkeyBinding.load(from: defaults))
        // A stored bare key (hand-edited defaults) is not trusted either.
        HotkeyBinding.save(HotkeyBinding(keyCode: 49, modifiers: 0), to: defaults)
        XCTAssertNil(HotkeyBinding.load(from: defaults))
    }

    func testHUDDelaysClamped() {
        let defaults = isolatedDefaults()
        XCTAssertEqual(AppSettings.hotkeyHUDDismiss(from: defaults), AppSettings.defaultHotkeyHUDDismiss)
        defaults.set(9999.0, forKey: AppSettings.hotkeyHUDDismissKey)
        XCTAssertEqual(AppSettings.hotkeyHUDDismiss(from: defaults), AppSettings.hotkeyHUDDismissRange.upperBound)
    }
}

@MainActor
final class HotkeyControllerTests: XCTestCase {
    private let optionSpace = HotkeyBinding(keyCode: 49, modifiers: HotkeyBinding.optionMask)
    private var registrar = FakeRegistrar()
    private var defaults = UserDefaults(suiteName: "HotkeyControllerTests-\(UUID())")!
    private var presses = 0, releases = 0

    private func makeController() -> HotkeyController {
        registrar = FakeRegistrar()
        defaults = UserDefaults(suiteName: "HotkeyControllerTests-\(UUID())")!
        presses = 0; releases = 0
        let controller = HotkeyController(registrar: registrar, defaults: defaults)
        controller.onPress = { [unowned self] in presses += 1 }
        controller.onRelease = { [unowned self] in releases += 1 }
        return controller
    }

    func testUnsetBindingRegistersNothing() {
        let controller = makeController()
        controller.start()
        XCTAssertNil(controller.binding)
        XCTAssertTrue(registrar.registered.isEmpty)
    }

    func testStartRegistersStoredBinding() {
        let controller = makeController()
        HotkeyBinding.save(optionSpace, to: defaults)
        controller.start()
        XCTAssertEqual(registrar.registered, [optionSpace])
    }

    func testPressReleaseCycle() {
        let controller = makeController()
        controller.setBinding(optionSpace)
        registrar.handler?(.pressed)
        XCTAssertTrue(controller.isHeld)
        registrar.handler?(.released)
        XCTAssertFalse(controller.isHeld)
        XCTAssertEqual([presses, releases], [1, 1])
    }

    func testKeyRepeatIgnored() {
        let controller = makeController()
        controller.setBinding(optionSpace)
        for _ in 0..<5 { registrar.handler?(.pressed) }
        XCTAssertEqual(presses, 1)
        registrar.handler?(.released)
        XCTAssertEqual(releases, 1)
    }

    func testReleaseWithoutPressIgnored() {
        let controller = makeController()
        controller.setBinding(optionSpace)
        registrar.handler?(.released)
        XCTAssertEqual([presses, releases], [0, 0])
    }

    func testRebindWhileHeldReleasesFirstThenReRegisters() {
        let controller = makeController()
        controller.setBinding(optionSpace)
        registrar.handler?(.pressed)
        let other = HotkeyBinding(keyCode: 40, modifiers: HotkeyBinding.controlMask)
        controller.setBinding(other)
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(controller.isHeld)
        XCTAssertEqual(registrar.registered.last, other)
        XCTAssertEqual(HotkeyBinding.load(from: defaults), other)
    }

    func testRejectedBindingChangesNothing() {
        let controller = makeController()
        controller.setBinding(optionSpace)
        let verdict = controller.setBinding(HotkeyBinding(keyCode: 49, modifiers: 0))
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertEqual(controller.binding, optionSpace)
        XCTAssertEqual(HotkeyBinding.load(from: defaults), optionSpace)
    }

    func testClearUnregistersAndPersists() {
        let controller = makeController()
        controller.setBinding(optionSpace)
        controller.setBinding(nil)
        XCTAssertNil(controller.binding)
        XCTAssertNil(registrar.handler)
        XCTAssertNil(HotkeyBinding.load(from: defaults))
    }

    func testConflictSurfacesErrorAndClearsOnSuccess() {
        let controller = makeController()
        registrar.failWith = .conflict
        controller.setBinding(optionSpace)
        XCTAssertNotNil(controller.registrationError)
        XCTAssertTrue(controller.registrationError?.contains("already in use") == true)
        registrar.failWith = nil
        controller.setBinding(HotkeyBinding(keyCode: 40, modifiers: HotkeyBinding.controlMask))
        XCTAssertNil(controller.registrationError)
    }

    func testSuspendDuringRecordingAndResume() {
        let controller = makeController()
        controller.setBinding(optionSpace)
        controller.suspend()
        XCTAssertNil(registrar.handler)
        controller.resume()
        XCTAssertNotNil(registrar.handler)
    }

    func testCancelHeldActsAsRelease() {
        let controller = makeController()
        controller.setBinding(optionSpace)
        registrar.handler?(.pressed)
        controller.cancelHeld()
        XCTAssertEqual(releases, 1)
        registrar.handler?(.released)   // late real key-up is ignored
        XCTAssertEqual(releases, 1)
    }
}
