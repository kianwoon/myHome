// Read-only KEF qualification probe (docs/KEF.md, work package 1).
//   swift run KEFProbe <speaker-ipv4> [port]
// Issues GET /api/getData for the catalogued resource paths ONLY — never a write —
// and prints status + raw JSON so the real value shapes can be recorded.
import Foundation
import MyHomeCore

let arguments = CommandLine.arguments
guard arguments.count >= 2, KEFClient.isValidIPv4(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: KEFProbe <speaker-ipv4> [port]\n".utf8))
    exit(2)
}
let host = arguments[1]
let port = arguments.count > 2 ? Int(arguments[2]) ?? KEFConfig.defaults.port : KEFConfig.defaults.port
let paths = [KEFProtocol.releaseText, KEFProtocol.modelName, KEFProtocol.firmwareVersion, KEFProtocol.primaryMac,
             KEFProtocol.speakerStatus, KEFProtocol.volume, KEFProtocol.mute, KEFProtocol.physicalSource,
             KEFProtocol.maximumVolume, "settings:/kef/host/volumeLimit", "powermanager:target"]

let session = URLSession(configuration: .ephemeral)
for path in paths {
    var components = URLComponents()
    components.scheme = "http"; components.host = host; components.port = port
    components.path = KEFProtocol.getDataPath
    components.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "roles", value: KEFProtocol.valueRole)]
    var request = URLRequest(url: components.url!)
    request.timeoutInterval = KEFConfig.defaults.requestTimeout
    do {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("\(path)\n  HTTP \(status)  \(String(data: data, encoding: .utf8) ?? "<binary>")")
    } catch {
        print("\(path)\n  ERROR \(error.localizedDescription)")
    }
}

// MARK: - Write qualification (explicit opt-in): `KEFProbe <ip> qualify <low-volume>`
// Exercises the real KEFClient writes at a low volume and prints each readback.
// Restores mute/input/power; leaves the LOW volume (restoring a loud level could blast).
if arguments.count > 3, arguments[2] == "qualify", let lowVolume = Int(arguments[3]) {
    let client = try KEFClient(host: host)
    let settle: UInt64 = 2_000_000_000
    func show(_ step: String, expect: String) async {
        try? await Task.sleep(nanoseconds: settle)
        if let s = try? await client.fetchState() {
            print("\(step): power=\(s.power.map { "\($0)" } ?? "nil") vol=\(s.volume.map(String.init) ?? "nil") muted=\(s.muted.map(String.init) ?? "nil") input=\(s.input?.wireValue ?? "nil")  [expect \(expect)]")
        } else { print("\(step): readback failed") }
    }
    let original = try await client.fetchState()
    print("\n== qualify: start \(original) ==")
    do {
        try await client.setMuted(true);  await show("mute on", expect: "muted=true, vol unchanged")
        try await client.setMuted(false); await show("mute off", expect: "muted=false, vol unchanged")
        try await client.setVolume(lowVolume); await show("volume \(lowVolume)", expect: "vol=\(lowVolume)")
        for input in KEFInput.selectable where input != original.input {
            try await client.setInput(input); await show("input \(input.wireValue)", expect: "input=\(input.wireValue)")
        }
        if let input = original.input { try await client.setInput(input); await show("restore input", expect: "input=\(input.wireValue)") }
        try await client.setPower(false); await show("standby", expect: "power=standby")
        let standbyState = try? await client.fetchState()
        print("state readable in standby: \(standbyState != nil)")
        try await client.setPower(true);  await show("power on", expect: "power=active")
    } catch { print("qualify aborted: \(error)") }
}
