// Read-only Cast qualification probe: `swift run CastProbe [seconds]`.
// Lists every Cast speaker on the LAN and prints its receiver state. Writes nothing.
import Foundation
import MyHomeCore
setvbuf(stdout, nil, _IOLBF, 0)

let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? CastConfig.defaults.discoveryTimeout
let found = await CastSpeakerDiscovery.discover(timeout: seconds)
print("found \(found.count) Cast speaker(s) in \(seconds)s")
for speaker in found {
    print("- \(speaker.name) [\(speaker.model)] id=\(speaker.deviceID) group=\(speaker.isGroup)")
    do {
        let client = try CastSwiftClient(record: speaker.record())
        print("    state: \(try await client.fetchState())")
    } catch {
        print("    read failed: \((error as? CastError)?.message ?? "\(error)")")
    }
}

// Opt-in write qualification: CAST_QUALIFY_WRITE=<deviceID> nudges that speaker's
// volume by one step and restores it, verifying each by readback.
if let target = ProcessInfo.processInfo.environment["CAST_QUALIFY_WRITE"], let speaker = found.first(where: { $0.deviceID == target }) {
    let client = try CastSwiftClient(record: speaker.record())
    let original = try await client.fetchState().volume ?? 0
    let nudged = original > 0 ? original - 1 : 1
    try await client.setVolume(nudged)
    try await Task.sleep(nanoseconds: UInt64(CastConfig.defaults.readbackDelay * 1_000_000_000))
    let seen = try await client.fetchState().volume
    try await client.setVolume(original)
    try await Task.sleep(nanoseconds: UInt64(CastConfig.defaults.readbackDelay * 1_000_000_000))
    let restored = try await client.fetchState().volume
    print("qualify \(speaker.name): \(original) → \(nudged) read \(String(describing: seen)) → restored \(String(describing: restored))")
}

// Opt-in playback qualification: CAST_QUALIFY_PLAY=<deviceID> [CAST_QUALIFY_FILE=<audio file>]
// plays the first radio preset (or the file, served from this Mac) until the
// speaker reports playing, then stops it. Audible on that speaker.
if let target = ProcessInfo.processInfo.environment["CAST_QUALIFY_PLAY"], let speaker = found.first(where: { $0.deviceID == target }) {
    let client = try CastSwiftClient(record: speaker.record())
    var source: CastMediaSource
    if let phrase = ProcessInfo.processInfo.environment["CAST_QUALIFY_SEARCH"] {
        guard let hit = try await YouTubeSearch().firstVideo(for: phrase) else { fatalError("no search result") }
        source = hit
        print("search \(phrase) -> \(hit.title) \(hit.url)")
    } else if let link = ProcessInfo.processInfo.environment["CAST_QUALIFY_YOUTUBE"], let url = URL(string: link) {
        source = CastMediaSource.from(url: url, title: "YouTube")
        print("youtube ref: \(String(describing: source.youtube))")
    } else if let path = ProcessInfo.processInfo.environment["CAST_QUALIFY_FILE"] {
        let file = URL(fileURLWithPath: path)
        source = CastMediaSource(title: file.lastPathComponent, url: try await CastFileServer.shared.register(file), contentType: CastFileServer.contentType(for: file))
        print("serving \(source.url)")
    } else {
        source = CastRadioPreset.seed[0].source!
    }
    try await client.play(source)
    let deadline = Date().addingTimeInterval(CastConfig.defaults.playSettleTimeout)
    var state = try await client.fetchState()
    while state.playback != .playing, Date() < deadline {
        try await Task.sleep(nanoseconds: UInt64(CastConfig.defaults.playSettleInterval * 1_000_000_000))
        state = try await client.fetchState()
    }
    print("play \(source.title): \(state)")
    try await Task.sleep(nanoseconds: UInt64(ProcessInfo.processInfo.environment["CAST_QUALIFY_HOLD"].flatMap(Double.init) ?? CastConfig.defaults.playSettleInterval * 2) * 1_000_000_000)
    try await client.transport(.stop)
    try await Task.sleep(nanoseconds: UInt64(CastConfig.defaults.readbackDelay * 1_000_000_000))
    print("after stop: \(try await client.fetchState())")
}
