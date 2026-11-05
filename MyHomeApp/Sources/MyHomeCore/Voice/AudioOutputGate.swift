// Silences the default audio output while the microphone is open (so music or
// a video never leaks into the recogniser) and puts it back EXACTLY as it was.
// Mirrors Pop's AudioOutputMute (CoreAudio, default device, borrow-not-change)
// and adds ducking, a volume fallback for outputs with no mute property,
// reference counting, and a persisted record so a crash cannot leave the Mac
// silent. The hardware sits behind AudioOutputControlling so it is testable.
import Foundation

/// The user-visible state of one output device.
public struct AudioOutputSnapshot: Equatable, Codable, Sendable {
    public var deviceUID: String
    /// nil = the device has no (settable) mute property.
    public var muted: Bool?
    /// Main volume (one entry) or per-channel volumes; empty = no volume control.
    public var volumes: [Float]

    public init(deviceUID: String, muted: Bool?, volumes: [Float]) {
        self.deviceUID = deviceUID
        self.muted = muted
        self.volumes = volumes
    }
}

public protocol AudioOutputControlling: AnyObject {
    func defaultOutputDeviceUID() -> String?
    /// nil when the device is gone.
    func snapshot(deviceUID: String) -> AudioOutputSnapshot?
    func setMuted(_ muted: Bool, deviceUID: String) -> Bool
    func setVolumes(_ volumes: [Float], deviceUID: String) -> Bool
}

/// What we changed and what it was before; persisted for crash recovery.
public struct PendingOutputRestore: Codable, Equatable, Sendable {
    public var original: AudioOutputSnapshot
    public var applied: AudioOutputSnapshot
}

@MainActor
public final class ListeningOutputGate: ObservableObject {
    public enum Engagement: Equatable, Sendable {
        case off, muted, ducked, alreadySilent
        case unsupported(String)
    }

    public enum Capability: Equatable, Sendable {
        case mute, volumeOnly, none, noDevice
    }

    public static let cannotMuteMessage = "Cannot mute this output (no mute or volume control); music may still be heard while listening."
    public static let noDeviceMessage = "No audio output device found."
    public static let changeFailedMessage = "Could not change the output volume; music may still be heard while listening."

    @Published public private(set) var lastEngagement: Engagement = .off

    private let controller: AudioOutputControlling
    private let defaults: UserDefaults
    private var holders = 0
    private var engaged: PendingOutputRestore?

    public init(controller: AudioOutputControlling, defaults: UserDefaults = .standard) {
        self.controller = controller
        self.defaults = defaults
    }

    public var holderCount: Int { holders }
    public var isEngaged: Bool { engaged != nil }

    // MARK: Hold lifecycle

    /// A listening session started. Nested sessions share one mute.
    public func begin() {
        holders += 1
        if holders == 1 { engage() }
    }

    /// A listening session ended. Extra calls are ignored.
    public func end() {
        guard holders > 0 else { return }
        holders -= 1
        if holders == 0 { restore() }
    }

    /// Unconditional restore (quit, sleep, cancel-all).
    public func restoreNow() {
        holders = 0
        restore()
    }

    /// Restores unless a session is still holding the output; called before
    /// a reply is spoken so it is always audible.
    public func settle() {
        if holders == 0 { restore() }
    }

    /// Launch-time recovery after a crash / force-quit.
    public func recoverPending() {
        guard engaged == nil, let record = loadRecord() else { return }
        clearRecord()
        revert(record)
    }

    /// What this Mac's current default output supports (no audio change).
    public func probe() -> Capability {
        guard let uid = controller.defaultOutputDeviceUID(), let snap = controller.snapshot(deviceUID: uid) else { return .noDevice }
        if snap.muted != nil { return .mute }
        return snap.volumes.isEmpty ? .none : .volumeOnly
    }

    // MARK: Engage / restore

    private func engage() {
        let mode = AppSettings.listenOutputMode(from: defaults)
        guard mode != .off else { lastEngagement = .off; return }
        guard let uid = controller.defaultOutputDeviceUID(), let original = controller.snapshot(deviceUID: uid) else {
            lastEngagement = .unsupported(Self.noDeviceMessage)
            return
        }
        let level = Float(AppSettings.listenDuckLevel(from: defaults))
        let plan = Self.plan(mode: mode, original: original, level: level)
        let applied: AudioOutputSnapshot
        let result: Engagement
        switch plan {
        case .silent:
            lastEngagement = .alreadySilent
            return
        case .unsupported:
            lastEngagement = .unsupported(Self.cannotMuteMessage)
            return
        case .apply(let snap, let engagement):
            applied = snap
            result = engagement
        }
        let record = PendingOutputRestore(original: original, applied: applied)
        saveRecord(record)   // before touching hardware: a crash mid-change is recoverable
        if apply(applied, over: original) {
            engaged = record
            lastEngagement = result
        } else {
            _ = apply(original, over: applied)
            clearRecord()
            lastEngagement = .unsupported(Self.changeFailedMessage)
        }
    }

    private func restore() {
        guard let record = engaged else { return }
        engaged = nil
        clearRecord()
        revert(record)
        lastEngagement = .off
    }

    /// Writes only the parts of `target` that differ from `current`.
    private func apply(_ target: AudioOutputSnapshot, over current: AudioOutputSnapshot) -> Bool {
        var ok = true
        if let m = target.muted, m != current.muted {
            ok = controller.setMuted(m, deviceUID: target.deviceUID) && ok
        }
        if !target.volumes.isEmpty, target.volumes != current.volumes {
            ok = controller.setVolumes(target.volumes, deviceUID: target.deviceUID) && ok
        }
        return ok
    }

    /// Restores the ORIGINAL device only (never the new default), and only the
    /// parts still at the value we set — a change the user made meanwhile wins.
    private func revert(_ record: PendingOutputRestore) {
        let uid = record.original.deviceUID
        guard let current = controller.snapshot(deviceUID: uid) else { return }
        if let appliedMute = record.applied.muted, appliedMute != record.original.muted, current.muted == appliedMute,
           let originalMute = record.original.muted {
            _ = controller.setMuted(originalMute, deviceUID: uid)
        }
        if record.applied.volumes != record.original.volumes,
           Self.matches(current.volumes, record.applied.volumes) {
            _ = controller.setVolumes(record.original.volumes, deviceUID: uid)
        }
    }

    // MARK: Planning

    enum Plan: Equatable {
        case silent
        case unsupported
        case apply(AudioOutputSnapshot, Engagement)
    }

    static func plan(mode: AppSettings.ListenOutputMode, original: AudioOutputSnapshot, level: Float) -> Plan {
        let tolerance = AppSettings.outputVolumeTolerance
        let volumeSilent = !original.volumes.isEmpty && original.volumes.allSatisfy { $0 <= tolerance }
        if original.muted == true || volumeSilent { return .silent }
        var applied = original
        let canMute = original.muted != nil
        let hasVolume = !original.volumes.isEmpty
        switch mode {
        case .off:
            return .silent
        case .mute:
            if canMute { applied.muted = true; return .apply(applied, .muted) }
            if hasVolume { applied.volumes = original.volumes.map { _ in 0 }; return .apply(applied, .muted) }
        case .duck:
            if hasVolume { applied.volumes = original.volumes.map { $0 * level }; return .apply(applied, .ducked) }
            if canMute { applied.muted = true; return .apply(applied, .muted) }
        }
        return .unsupported
    }

    private static func matches(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= AppSettings.outputVolumeTolerance }
    }

    // MARK: Persistence

    private func saveRecord(_ record: PendingOutputRestore) {
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: AppSettings.listenOutputPendingKey) }
    }

    private func loadRecord() -> PendingOutputRestore? {
        guard let data = defaults.data(forKey: AppSettings.listenOutputPendingKey) else { return nil }
        return try? JSONDecoder().decode(PendingOutputRestore.self, from: data)
    }

    private func clearRecord() {
        defaults.removeObject(forKey: AppSettings.listenOutputPendingKey)
    }
}
