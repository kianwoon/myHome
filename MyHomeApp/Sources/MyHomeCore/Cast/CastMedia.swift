// What a Cast speaker can be told to play: an internet-radio preset, any audio
// URL, or a file served from this Mac (see CastFileServer). Presets are user
// data (UserDefaults); the seed list only gives a first run something to play.
import Foundation

public struct CastMediaSource: Equatable, Hashable, Sendable {
    public var title: String
    public var url: URL
    public var contentType: String
    /// Endless streams (radio) are `live`: no duration, no seeking.
    public var isLive: Bool

    public init(title: String, url: URL, contentType: String = CastMediaSource.fallbackContentType, isLive: Bool = false) {
        self.title = title
        self.url = url
        self.contentType = contentType
        self.isLive = isLive
    }

    public static let fallbackContentType = "audio/mpeg"
    static let allowedSchemes: Set<String> = ["http", "https"]

    /// Only http(s) URLs are ever handed to a speaker.
    public var isPlayable: Bool { Self.allowedSchemes.contains(url.scheme?.lowercased() ?? "") && url.host != nil }
}

public struct CastRadioPreset: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    public var contentType: String

    public init(id: String = UUID().uuidString, name: String, url: String, contentType: String = CastMediaSource.fallbackContentType) {
        self.id = id
        self.name = name
        self.url = url
        self.contentType = contentType
    }

    public var source: CastMediaSource? {
        guard let parsed = URL(string: url) else { return nil }
        let source = CastMediaSource(title: name, url: parsed, contentType: contentType, isLive: true)
        return source.isPlayable ? source : nil
    }

    /// First-run stations (public streams, checked reachable 2026-11-08). Editable in the app.
    public static let seed: [CastRadioPreset] = [
        CastRadioPreset(id: "seed-rp-main", name: "Radio Paradise", url: "http://stream.radioparadise.com/mp3-128"),
        CastRadioPreset(id: "seed-rp-mellow", name: "Radio Paradise Mellow", url: "https://stream.radioparadise.com/mellow-128", contentType: "audio/aac"),
        CastRadioPreset(id: "seed-kexp", name: "KEXP", url: "https://kexp.streamguys1.com/kexp128.mp3"),
    ]

    static let genericWords: Set<String> = ["music", "radio", "something", "anything", "songs", "song", "tunes", "a", "some", "the", ""]

    /// Spoken name → preset. Generic requests ("play music") pick `lastPlayed`, then the first preset.
    public static func resolve(_ spoken: String, in presets: [CastRadioPreset], lastPlayed: String? = nil) -> CastRadioPreset? {
        let wanted = spoken.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if wanted.allSatisfy({ genericWords.contains($0) }) {
            return presets.first { $0.id == lastPlayed } ?? presets.first
        }
        func words(_ preset: CastRadioPreset) -> [String] { preset.name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        if let exact = presets.first(where: { words($0) == wanted }) { return exact }
        let meaningful = wanted.filter { !genericWords.contains($0) }
        return presets.first { preset in
            let have = Set(words(preset))
            return !meaningful.isEmpty && meaningful.allSatisfy(have.contains)
        }
    }
}

public struct CastRadioStore {
    public static let storageKey = "cast.radio.v1"
    public static let lastPlayedKey = "cast.radio.lastPlayed"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Seeds only when the user has never saved a list (an emptied list stays empty).
    public func load() -> [CastRadioPreset] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return CastRadioPreset.seed }
        return (try? JSONDecoder().decode([CastRadioPreset].self, from: data)) ?? CastRadioPreset.seed
    }

    public func save(_ presets: [CastRadioPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    public var lastPlayed: String? {
        get { defaults.string(forKey: Self.lastPlayedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.lastPlayedKey) }
    }
}
