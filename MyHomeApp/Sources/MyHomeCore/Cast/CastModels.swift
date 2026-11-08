// Google Cast speakers (Google Home Mini, Nest Audio, Chromecast Audio, groups)
// controlled natively on the LAN through the Cast V2 protocol (SwiftCast).
// A Cast speaker has no power or input: the honest controls are receiver
// volume, mute, and transport on the running session.
import Foundation

public enum CastProtocol {
    /// `Device.category` of a Cast speaker record in the roster.
    public static let category = "cast"
    public static let idPrefix = "cast:"
    public static let serviceType = "_googlecast._tcp"
    public static let serviceDomain = "local."
    public static let defaultPort = 8009
}

public struct CastSpeakerRecord: Codable, Equatable, Identifiable, Sendable {
    public static let currentVersion = 1
    public var version = CastSpeakerRecord.currentVersion
    /// Stable Cast device id (TXT `id`), never an IP.
    public let deviceID: String
    public var name: String
    public var room: String
    public var model: String
    /// Bonjour instance name: survives DHCP changes. Nil for manually added speakers.
    public var serviceName: String?
    /// Fallback / manual address (IPv4) and port.
    public var address: String?
    public var port: Int

    public var id: String { CastProtocol.idPrefix + deviceID }

    public init(deviceID: String, name: String, room: String = "", model: String = "",
                serviceName: String? = nil, address: String? = nil, port: Int = CastProtocol.defaultPort) {
        self.deviceID = deviceID
        self.name = name
        self.room = room
        self.model = model
        self.serviceName = serviceName
        self.address = address
        self.port = port
    }
}

public enum CastPlayback: String, Equatable, Sendable {
    case idle, playing, paused, buffering, other
}

/// Last confirmed receiver reading.
public struct CastState: Equatable, Sendable {
    /// Receiver volume as a percent (Cast reports 0.0…1.0).
    public var volume: Int?
    public var muted: Bool?
    /// Foreground app display name; nil when the speaker is on its idle screen.
    public var appName: String?
    public var playback: CastPlayback?
    public init(volume: Int? = nil, muted: Bool? = nil, appName: String? = nil, playback: CastPlayback? = nil) {
        self.volume = volume
        self.muted = muted
        self.appName = appName
        self.playback = playback
    }
}

public enum CastAction: Equatable, Hashable, Sendable {
    case volume(Int)
    case mute(Bool)
    case play
    case pause
    /// Loads and starts a stream/URL/file on the default media receiver.
    case playMedia(CastMediaSource)
    /// Stops the running app (the closest honest equivalent of "off").
    case stop

    public var control: CastPendingControl {
        switch self {
        case .volume: return .volume
        case .mute: return .mute
        case .play, .pause, .stop, .playMedia: return .transport
        }
    }

    /// True when `state` shows the action's effect; nil when the state cannot say.
    public func matches(_ state: CastState) -> Bool? {
        switch self {
        case .volume(let value): return state.volume.map { abs($0 - value) <= 1 }
        case .mute(let value): return state.muted.map { $0 == value }
        case .play, .playMedia: return state.playback.map { $0 == .playing || $0 == .buffering }
        case .pause: return state.playback.map { $0 == .paused }
        case .stop: return state.appName == nil || state.playback == .idle
        }
    }
}

public enum CastPendingControl: String, Hashable, Sendable { case volume, mute, transport }

public enum CastError: Error, Equatable, Sendable {
    case unreachable
    case timeout
    case invalidAddress
    case noActiveSession
    case unplayableSource
    /// YouTube answered the lounge bind with loungeScreenDisconnected (reason attached).
    case youtubeRefused(String)
    case volumeOutOfRange(ClosedRange<Int>)
    case malformedResponse

    public var message: String {
        switch self {
        case .unreachable: return "the speaker is not reachable on the network"
        case .timeout: return "the speaker did not answer in time"
        case .invalidAddress: return "that is not a valid IPv4 address"
        case .noActiveSession: return "nothing is playing on the speaker"
        case .youtubeRefused(let reason): return "YouTube refused the session (\(reason))"
        case .unplayableSource: return "that is not a playable http(s) audio address"
        case .volumeOutOfRange(let range): return "volume must be \(range.lowerBound)–\(range.upperBound)"
        case .malformedResponse: return "the speaker sent an unexpected reply"
        }
    }
}

public struct CastConfig: Equatable, Sendable {
    public var requestTimeout: TimeInterval
    public var visibleRefreshInterval: TimeInterval
    public var backgroundRefreshInterval: TimeInterval
    public var backoffSchedule: [TimeInterval]
    public var backoffCap: TimeInterval
    public var volumeStep: Int
    public var volumeRange: ClosedRange<Int>
    public var readbackDelay: TimeInterval
    public var discoveryTimeout: TimeInterval
    /// Keyboard/accessibility volume changes commit after this quiet period.
    public var commitDebounce: TimeInterval
    /// A started stream takes a few seconds to buffer: readback polls this long.
    public var playSettleTimeout: TimeInterval
    /// Launching the media receiver and loading a stream takes far longer than a state read.
    public var playTimeout: TimeInterval
    /// Playback state is read through a second channel; bounded separately from the volume read.
    public var mediaStatusTimeout: TimeInterval
    public var playSettleInterval: TimeInterval

    public static let defaults = CastConfig(
        requestTimeout: 6, visibleRefreshInterval: 20, backgroundRefreshInterval: 120,
        backoffSchedule: [30, 60, 120], backoffCap: 300, volumeStep: 5,
        volumeRange: 0...100, readbackDelay: 0.5, discoveryTimeout: 4, commitDebounce: 0.4,
        playSettleTimeout: 10, playTimeout: 30, mediaStatusTimeout: 3, playSettleInterval: 1)

    public static let requestTimeoutKey = "castRequestTimeoutSeconds"
    public static let visibleRefreshKey = "castVisibleRefreshSeconds"
    public static let backgroundRefreshKey = "castBackgroundRefreshSeconds"
    public static let volumeStepKey = "castVolumeStep"
    public static let discoveryTimeoutKey = "castDiscoveryTimeoutSeconds"

    public static func fromDefaults(_ store: UserDefaults = .standard) -> CastConfig {
        var config = defaults
        func seconds(_ key: String, _ fallback: TimeInterval, _ range: ClosedRange<TimeInterval>) -> TimeInterval {
            min(max(store.object(forKey: key) as? Double ?? fallback, range.lowerBound), range.upperBound)
        }
        config.requestTimeout = seconds(requestTimeoutKey, defaults.requestTimeout, 2...30)
        config.visibleRefreshInterval = seconds(visibleRefreshKey, defaults.visibleRefreshInterval, 10...300)
        config.backgroundRefreshInterval = max(seconds(backgroundRefreshKey, defaults.backgroundRefreshInterval, 30...900),
                                               defaults.visibleRefreshInterval)
        config.discoveryTimeout = seconds(discoveryTimeoutKey, defaults.discoveryTimeout, 1...30)
        config.volumeStep = min(max(store.object(forKey: volumeStepKey) as? Int ?? defaults.volumeStep, 1), 20)
        return config
    }

    /// Back-off delay after `failures` consecutive failures (0 → none).
    public func backoff(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let index = min(failures - 1, backoffSchedule.count - 1)
        return min(backoffSchedule.isEmpty ? backoffCap : backoffSchedule[index], backoffCap)
    }
}
