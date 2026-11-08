// Read-only Cast qualification probe: `swift run CastProbe [seconds]`.
// Lists every Cast speaker on the LAN and prints its receiver state. Writes nothing.
import Foundation
import MyHomeCore

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
