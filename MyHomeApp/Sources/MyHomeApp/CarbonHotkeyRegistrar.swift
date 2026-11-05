// Carbon RegisterEventHotKey implementation of HotkeyRegistering — the same
// mechanism as Pop's HotkeyCenter (~/Downloads/pop/Sources/Pop/HotkeyCenter.swift).
// Chosen over NSEvent global monitors / CGEventTap because it works while the
// app is in the background, needs no Accessibility or Input Monitoring
// permission, and delivers BOTH key-down (kEventHotKeyPressed) and key-up
// (kEventHotKeyReleased), which hold-to-talk needs. Pop only handled "pressed".
import Carbon.HIToolbox
import MyHomeCore

@MainActor
final class CarbonHotkeyRegistrar: HotkeyRegistering {
    /// 'MYHK'
    nonisolated static let signature: OSType = 0x4D59_484B
    private static let hotKeyIDValue: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate var handler: ((HotkeyEvent) -> Void)?

    func register(_ binding: HotkeyBinding, handler: @escaping (HotkeyEvent) -> Void) throws {
        unregister()
        try installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: Self.hotKeyIDValue),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            throw status == OSStatus(eventHotKeyExistsErr) ? HotkeyRegistrationError.conflict
                                                            : HotkeyRegistrationError.failed(status)
        }
        hotKeyRef = ref
        self.handler = handler
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        handler = nil
    }

    private func installEventHandlerIfNeeded() throws {
        guard handlerRef == nil else { return }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), carbonHotkeyHandler, types.count, &types,
                                         Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard status == noErr else { throw HotkeyRegistrationError.failed(status) }
    }

    /// Carbon delivers hot-key events on the main thread.
    fileprivate nonisolated func deliver(_ event: HotkeyEvent) {
        MainActor.assumeIsolated { handler?(event) }
    }
}

private let carbonHotkeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == CarbonHotkeyRegistrar.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    switch GetEventKind(event) {
    case UInt32(kEventHotKeyPressed): registrar.deliver(.pressed)
    case UInt32(kEventHotKeyReleased): registrar.deliver(.released)
    default: return OSStatus(eventNotHandledErr)
    }
    return OSStatus(noErr)
}
