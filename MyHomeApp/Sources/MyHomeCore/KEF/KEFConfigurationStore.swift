// Persistence for local KEF speaker records (non-secret metadata only), plus
// the registry value the DeviceStore publishes. Versioned JSON in UserDefaults.
import Foundation

public struct KEFConfigurationStore {
    public static let storageKey = "kef.speakers.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> [KEFSpeakerRecord] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let records = try? JSONDecoder().decode([KEFSpeakerRecord].self, from: data) else { return [] }
        // Unknown future versions are ignored rather than half-read.
        return records.filter { $0.version <= KEFSpeakerRecord.currentVersion }
    }

    public func save(_ records: [KEFSpeakerRecord]) {
        guard let data = try? JSONEncoder().encode(records.sorted { $0.id < $1.id }) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// What the last control/readback attempt of one KEF control produced.
public struct KEFReading: Equatable {
    public var state = KEFState()
    /// Independent of the latest error: the last time ANY read succeeded.
    public var lastSuccess: Date?
    public var lastError: KEFError?
    public var failures = 0
    public var nextAttempt: Date?
    public var lastAttempt: Date?
    /// Bumped by every write; a read that started before a newer write is dropped.
    public var generation = 0
    public var pending: Set<KEFPendingControl> = []
    public init() {}
}

public enum KEFPendingControl: String, Hashable, Sendable { case power, volume, mute, input }

/// Published KEF state (one value so DeviceStore needs a single property).
public struct KEFRegistry {
    public var records: [String: KEFSpeakerRecord] = [:]
    public var readings: [String: KEFReading] = [:]
    var makeClient: (String) throws -> any KEFClientProtocol = { address in
        try KEFClient(host: address)
    }
    /// One serial gate per speaker; volume tokens implement last-intent-wins.
    var gates: [String: KEFSerialGate] = [:]
    var volumeTokens: [String: Int] = [:]
    /// Speakers currently on screen (refresh at the visible cadence).
    var visible: Set<String> = []
    var config: KEFConfig = .fromDefaults()
    var persistence = KEFConfigurationStore()

    /// Roster-shaped devices. `ip` stays EMPTY on purpose: every Tuya/Briturn
    /// path keys off `hasAddress`, and a KEF speaker must never enter them.
    public var devices: [Device] {
        records.values.sorted { $0.id < $1.id }.map { record in
            let reading = readings[record.id]
            let online = reading?.lastSuccess != nil && (reading?.failures ?? 0) == 0
            return Device(id: record.id, name: record.name, ip: "", version: record.identity.firmware,
                          category: KEFProtocol.category, group: nil, online: online, room: record.room)
        }
    }
}

/// One exchange at a time per speaker, FIFO (actors re-enter across awaits,
/// so a plain actor method would interleave).
public actor KEFSerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await work()
    }
}
