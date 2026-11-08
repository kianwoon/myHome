// Persistence for Cast speaker records (non-secret metadata only) plus the
// registry value the DeviceStore publishes. Versioned JSON in UserDefaults.
import Foundation

public struct CastConfigurationStore {
    public static let storageKey = "cast.speakers.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> [CastSpeakerRecord] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let records = try? JSONDecoder().decode([CastSpeakerRecord].self, from: data) else { return [] }
        return records.filter { $0.version <= CastSpeakerRecord.currentVersion }
    }

    public func save(_ records: [CastSpeakerRecord]) {
        guard let data = try? JSONEncoder().encode(records.sorted { $0.id < $1.id }) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

public struct CastReading: Equatable {
    public var state = CastState()
    public var lastSuccess: Date?
    public var lastError: CastError?
    public var failures = 0
    public var nextAttempt: Date?
    public var lastAttempt: Date?
    /// Bumped by every write; a read that started before a newer write is dropped.
    public var generation = 0
    public var pending: Set<CastPendingControl> = []
    public init() {}
}

public struct CastRegistry {
    public var records: [String: CastSpeakerRecord] = [:]
    public var readings: [String: CastReading] = [:]
    var makeClient: (CastSpeakerRecord) throws -> any CastClientProtocol = { record in
        try CastSwiftClient(record: record, timeout: CastConfig.fromDefaults().requestTimeout)
    }
    var gates: [String: KEFSerialGate] = [:]
    var volumeTokens: [String: Int] = [:]
    var visible: Set<String> = []
    var config: CastConfig = .fromDefaults()
    var persistence = CastConfigurationStore()
    var radio = CastRadioStore()
    public var presets: [CastRadioPreset] = CastRadioStore().load()

    /// Roster-shaped devices. `ip` stays EMPTY so no Tuya/Briturn path adopts them.
    public var devices: [Device] {
        records.values.sorted { $0.id < $1.id }.map { record in
            let reading = readings[record.id]
            let online = reading?.lastSuccess != nil && (reading?.failures ?? 0) == 0
            return Device(id: record.id, name: record.name, ip: "", version: nil,
                          category: CastProtocol.category, group: nil, online: online, room: record.room)
        }
    }
}
