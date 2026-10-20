// baseline-guard:allow rewrite of existing test executable to cover status decoding
import Foundation
import MyHomeCore

@main
struct BridgePingTest {
    static func main() async {
        let arguments = CommandLine.arguments
        let mode = arguments.count > 1 ? arguments[1] : "ping"

        if mode == "shapes" {
            proveLooseDecoding()
            return
        }

        if mode == "listdecode" {
            proveListDecoding()
            return
        }

        if mode == "fanspeed" {
            proveFanSpeed()
            return
        }

        if mode == "setreply" {
            await proveSetReply()
            return
        }

        if mode == "fanrange" {
            proveFanRange()
            return
        }

        if mode == "curtain" {
            proveCurtainKeys()
            return
        }

        if mode == "specs" {
            proveSpecControls()
            return
        }

        if mode == "status" {
            let id = arguments.count > 2 ? arguments[2] : "bf3cf132f77b8ca85dapgm"
            await fetchStatus(id: id)
            return
        }

        do {
            let reply = try await BridgeClient.shared.request(["cmd": "ping"])
            let data = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
            let text = String(data: data, encoding: .utf8) ?? "<unreadable>"
            print("PING_REPLY \(text)")
            if reply["ok"] as? Bool == true {
                print("PING_OK")
                exit(0)
            }
            print("PING_FAIL")
            exit(1)
        } catch {
            print("PING_ERROR \(error.localizedDescription)")
            exit(2)
        }
    }

    private static func fetchStatus(id: String) async {
        do {
            let reply = try await BridgeClient.shared.request(["cmd": "status", "id": id])
            guard reply["ok"] as? Bool == true else {
                print("STATUS_ERROR \(reply["error"] ?? "unknown")")
                exit(1)
            }
            guard let raw = reply["dps"] else {
                print("STATUS_ERROR missing dps")
                exit(1)
            }
            let data = try JSONSerialization.data(withJSONObject: raw)
            let decoded = try JSONDecoder().decode([String: DPSValue].self, from: data)
            let state = DeviceState(dps: decoded)
            print("STATUS_DECODED_KEYS \(decoded.keys.sorted())")
            print("POWER \(state.power.map(String.init) ?? "nil") · WATTS \(state.wattsText ?? "nil")")
            print("STATUS_DECODE_OK")
            exit(0)
        } catch {
            print("STATUS_DECODE_ERROR \(error.localizedDescription)")
            exit(2)
        }
    }

    /// Unexpected DPS shapes must decode into the loose enum, never trap.
    /// Decodes the REAL bridge list reply (path in argv[2]) exactly as
    /// DeviceStore.refresh does — proves or disproves roster decoding.
    private static func proveListDecoding() {
        let path = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/reply_line.json"
        do {
            let raw = try String(contentsOfFile: path, encoding: .utf8)
            guard let data = raw.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["ok"] as? Bool == true,
                  let rawDevices = obj["devices"] else {
                print("LIST_BAD_REPLY"); exit(1)
            }
            let listData = try JSONSerialization.data(withJSONObject: rawDevices)
            let decoded = try JSONDecoder().decode([Device].self, from: listData)
            let byCategory = Dictionary(grouping: decoded, by: { $0.category }).mapValues(\.count)
            print("LIST_DECODED \(decoded.count) \(byCategory)")
            exit(0)
        } catch {
            print("LIST_DECODE_FAILED \(error)")
            exit(1)
        }
    }

    private static func proveLooseDecoding() {        let payload: [String: Any] = [
            "1": true,
            "2": [1, 2, 3],
            "3": ["nested": "value"],
            "4": NSNull(),
            "5": "small",
            "6": 17.5
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let decoded = try JSONDecoder().decode([String: DPSValue].self, from: data)
            print("SHAPES_DECODED \(decoded.keys.sorted())")
            print("SHAPES_OK")
            exit(0)
        } catch {
            print("SHAPES_ERROR \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Fan speed must come from a numeric dps; strings are mode fields and are
    /// only used when no numeric key exists.
    private static func proveFanSpeed() {
        let cases: [(String, [String: Any])] = [
            ("study_fan", ["1": true, "2": "custom", "3": 1]),
            ("numeric_dp2", ["2": 3]),
            ("strings_only", ["2": "large"])
        ]
        do {
            for (name, payload) in cases {
                let data = try JSONSerialization.data(withJSONObject: payload)
                let decoded = try JSONDecoder().decode([String: DPSValue].self, from: data)
                let state = DeviceState(dps: decoded)
                print("\(name) key=\(state.fanSpeedKey ?? "nil") speed=\(state.fanSpeed)")
            }
            print("FANSPEED_OK")
            exit(0)
        } catch {
            print("FANSPEED_ERROR \(error.localizedDescription)")
            exit(1)
        }
    }

    /// setDps must apply the reply's confirmed dps immediately. The fake bridge
    /// returns a different speed than the optimistic value to prove the
    /// DEVICE wins.
    @MainActor
    private static func proveSetReply() async {
        let fake = FakeBridge(reply: [
            "ok": true,
            "dps": ["1": true, "2": "custom", "3": 4]
        ])
        let device = Device(
            id: "bfaded7e0f0815c59eto2l",
            name: "Study Fan",
            ip: "192.168.4.33",
            version: "3.4",
            category: "fs",
            online: true
        )
        let store = DeviceStore(bridge: fake)
        let ok = await store.setDps(device, ["3": 4], optimistic: ["3": .number(2)])
        let state = store.state(for: device)
        let power = store.power(for: device)

        print("SET_REPLY ok=\(ok) power=\(power.map(String.init) ?? "nil") speed=\(state.fanSpeed) key=\(state.fanSpeedKey ?? "nil") dps3=\(state.dps["3"]?.description ?? "nil")")
        print("SET_REQUESTS \(fake.requestCount) CONFIRMED_WINS=\(state.fanSpeed == 4)")
        print("SET_REPLY_APPLIED")
        exit(ok && state.fanSpeed == 4 && state.fanSpeedKey == "3" ? 0 : 1)
    }

    /// Speed capability: numeric-gear fans allow 1-6; string-mode fans 1-3.
    private static func proveFanRange() {
        let cases: [(String, [String: Any])] = [
            ("study_fan", ["2": "custom", "3": 4]),
            ("numeric_dp2", ["2": 3]),
            ("strings_only", ["2": "large"])
        ]
        do {
            for (name, payload) in cases {
                let data = try JSONSerialization.data(withJSONObject: payload)
                let decoded = try JSONDecoder().decode([String: DPSValue].self, from: data)
                let state = DeviceState(dps: decoded)
                print("\(name) speed=\(state.fanSpeed) max=\(state.fanSpeedMax) key=\(state.fanSpeedKey ?? "nil")")
            }
            print("FANRANGE_OK")
            exit(0)
        } catch {
            print("FANRANGE_ERROR \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Curtain keys are selected by value type: string dp = action,
    /// numeric dp = position.
    private static func proveCurtainKeys() {
        let cases: [(String, [String: Any])] = [
            ("closed_curtain", ["1": "close", "3": 100]),
            ("alt_layout", ["1": "open", "2": 50]),
            ("numeric_only", ["2": 60])
        ]
        do {
            for (name, payload) in cases {
                let data = try JSONSerialization.data(withJSONObject: payload)
                let decoded = try JSONDecoder().decode([String: DPSValue].self, from: data)
                let state = DeviceState(dps: decoded)
                print("\(name) action=\(state.curtainActionKey ?? "nil") position=\(state.curtainPositionKey ?? "nil") actionValue=\(state.curtainAction ?? "nil")")
            }
            print("CURTAIN_KEYS_OK")
            exit(0)
        } catch {
            print("CURTAIN_KEYS_ERROR \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Real Study Fan spec fixture: declared dp15 light Boolean must yield a
    /// card control, while numeric gear dp3 stays undeclared (fallback path).
    private static func proveSpecControls() {
        let fixture = """
        {"id":"bfaded7e0f0815c59eto2l","name":"Study Fan","ip":"192.168.4.33",
         "version":"3.4","category":"fs","online":true,
         "spec":{
           "1":{"code":"switch","type":"Boolean","values":{}},
           "2":{"code":"mode","type":"Enum","values":{"range":["nature","sleep","fresh","smart"]}},
           "8":{"code":"fan_direction","type":"Enum","values":{"range":["forward","reverse"]}},
           "15":{"code":"light","type":"Boolean","values":{}}
         }}
        """
        do {
            let device = try JSONDecoder().decode(Device.self, from: Data(fixture.utf8))
            let state = DeviceState(dps: ["1": .bool(true)], capabilities: device.capabilities)
            let caps = state.capabilities
                .map { "\($0.dpId):\($0.code):\($0.type)" }
                .joined(separator: " ")
            let controls = state.controlCapabilities
                .map { "\($0.dpId):\($0.code):\($0.type)" }
                .joined(separator: " ")
            let hasLight = state.capabilities.contains { capability in
                if case .boolean = capability.kind {
                    return capability.dpId == "15" && capability.code == "light"
                }
                return false
            }
            print("CAPS \(caps)")
            print("CONTROLS \(controls)")
            print("DP15_BOOLEAN_LIGHT \(hasLight)")
            print("DP3_UNDECLARED \(!state.isDeclared("3"))")
            print("SPEC_CONTROLS_OK")
            exit(hasLight ? 0 : 1)
        } catch {
            print("SPEC_CONTROLS_ERROR \(error)")
            exit(1)
        }
    }
}

private final class FakeBridge: BridgeSending, @unchecked Sendable {
    private let lock = NSLock()
    private let reply: [String: Any]
    private var requests: [[String: Any]] = []

    init(reply: [String: Any]) {
        self.reply = reply
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func request(_ payload: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        lock.lock()
        requests.append(payload)
        lock.unlock()
        return reply
    }
}
