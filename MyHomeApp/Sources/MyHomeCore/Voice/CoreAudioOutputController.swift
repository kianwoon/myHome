// CoreAudio implementation of AudioOutputControlling (same calls as Pop's
// AudioOutputMute). Devices are addressed by UID so a record survives the
// numeric AudioDeviceID changing. Prefers kAudioDevicePropertyMute; volume is
// the main scalar when present, else the stereo channels. Bluetooth / AirPlay /
// HDMI outputs often lack one or both — the snapshot then reports nil / empty.
import CoreAudio
import Foundation

public final class CoreAudioOutputController: AudioOutputControlling {
    /// Channels probed when a device has no main volume element.
    private static let channelElements: [AudioObjectPropertyElement] = [1, 2]

    public init() {}

    public func defaultOutputDeviceUID() -> String? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return uid(of: device)
    }

    public func snapshot(deviceUID: String) -> AudioOutputSnapshot? {
        guard let device = device(forUID: deviceUID) else { return nil }
        var muted: Bool?
        if Self.isSettable(device, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain),
           let value: UInt32 = Self.read(device, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain) {
            muted = value != 0
        }
        let volumes = volumeElements(device).compactMap { element -> Float? in
            Self.read(device, kAudioDevicePropertyVolumeScalar, element: element)
        }
        return AudioOutputSnapshot(deviceUID: deviceUID, muted: muted, volumes: volumes)
    }

    public func setMuted(_ muted: Bool, deviceUID: String) -> Bool {
        guard let device = device(forUID: deviceUID),
              Self.isSettable(device, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain) else { return false }
        return Self.write(UInt32(muted ? 1 : 0), device, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain)
    }

    public func setVolumes(_ volumes: [Float], deviceUID: String) -> Bool {
        guard let device = device(forUID: deviceUID) else { return false }
        let elements = volumeElements(device)
        guard elements.count == volumes.count else { return false }
        var ok = true
        for (element, value) in zip(elements, volumes) {
            ok = Self.write(min(max(value, 0), 1), device, kAudioDevicePropertyVolumeScalar, element: element) && ok
        }
        return ok
    }

    // MARK: Helpers

    private func volumeElements(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        if Self.isSettable(device, kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        return Self.channelElements.filter { Self.isSettable(device, kAudioDevicePropertyVolumeScalar, element: $0) }
    }

    private func device(forUID uid: String) -> AudioDeviceID? {
        var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice, scope: kAudioObjectPropertyScopeGlobal)
        var cfUID = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private func uid(of device: AudioDeviceID) -> String? {
        var address = Self.address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func isSettable(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                   element: AudioObjectPropertyElement) -> Bool {
        var address = address(selector, element: element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func read<T>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                element: AudioObjectPropertyElement) -> T? where T: FixedWidthInteger {
        var address = address(selector, element: element)
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func read(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                             element: AudioObjectPropertyElement) -> Float? {
        var address = address(selector, element: element)
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func write<T>(_ value: T, _ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                 element: AudioObjectPropertyElement) -> Bool {
        var address = address(selector, element: element)
        var copy = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &copy) == noErr
    }
}
