// KEF LS50 Wireless II — LAN client over the speaker's local HTTP API
// (GET /api/getData, POST /api/setData). Wire shapes are from open-source
// reference clients, PENDING confirmation on hardware (docs/KEF.md). The
// transport is injected so everything is testable offline.
import Foundation

public protocol KEFClientProtocol: Sendable {
    func fetchIdentity() async throws -> KEFIdentity
    func fetchState() async throws -> KEFState
    func setPower(_ on: Bool) async throws
    func setVolume(_ percent: Int) async throws
    func setMuted(_ muted: Bool) async throws
    func setInput(_ input: KEFInput) async throws
}

/// One HTTP exchange. Returns the status code and body; throws only on transport failure.
public protocol KEFTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

/// Resource paths and typed-value keys (protocol constants, not settings).
public enum KEFProtocol {
    public static let getDataPath = "/api/getData"
    public static let setDataPath = "/api/setData"
    public static let valueRole = "value"
    /// Device.category for KEF speakers.
    public static let category = "kef"
    public static let idPrefix = "kef:"

    public static let releaseText = "settings:/releasetext"      // "<MODEL>_<firmware>"
    public static let modelName = "settings:/kef/host/modelName"
    public static let firmwareVersion = "settings:/kef/host/firmwareVersion"
    public static let primaryMac = "settings:/system/primaryMacAddress"
    public static let speakerStatus = "settings:/kef/host/speakerStatus"
    public static let volume = "player:volume"
    public static let mute = "settings:/mediaPlayer/mute"
    public static let physicalSource = "settings:/kef/play/physicalSource"
    public static let maximumVolume = "settings:/kef/host/maximumVolume"

    public static let typeInt = "i32_"
    public static let typeBool = "bool_"
    public static let typeString = "string_"
    public static let typeSource = "kefPhysicalSource"
    public static let typeStatus = "kefSpeakerStatus"
    /// Waking and sleeping are source writes on this API.
    public static let sourcePowerOn = "powerOn"
    public static let sourceStandby = "standby"
    /// Observed on LS50W2 firmware 420.390…: "powerOn" (reference clients document "poweredOn").
    public static let statusActive = "powerOn"
    public static let statusActiveAlternates: Set<String> = ["poweredOn"]
    public static let statusStandby = "standby"
}

public struct KEFClient: KEFClientProtocol {
    public let host: String
    private let transport: KEFTransport
    private let config: KEFConfig

    public init(host: String, transport: KEFTransport = KEFURLSessionTransport(), config: KEFConfig = .fromDefaults()) throws {
        guard Self.isValidIPv4(host) else { throw KEFError.invalidAddress }
        self.host = host
        self.transport = transport
        self.config = config
    }

    public static func isValidIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy { $0.isASCII && $0.isNumber }
                && (Int(part).map { $0 <= 255 } ?? false) && (part == "0" || !part.hasPrefix("0"))
        }
    }

    // MARK: Reads

    public func fetchIdentity() async throws -> KEFIdentity {
        let release = try? await readString(KEFProtocol.releaseText)
        // releasetext carries the product name ("LS50WII_V41192"); modelName is a hardware code ("SP4025").
        var model: String?
        var firmware = try? await readString(KEFProtocol.firmwareVersion)
        if let release, let split = release.firstIndex(of: "_") {
            model = String(release[..<split])
            if firmware == nil { firmware = String(release[release.index(after: split)...]) }
        }
        if model == nil { model = try? await readString(KEFProtocol.modelName) }
        let rawMac = try await readString(KEFProtocol.primaryMac)
        let mac = rawMac.lowercased().filter { $0.isHexDigit && $0.isASCII }
        guard mac.count == 12, let model, !model.isEmpty else { throw KEFError.malformedResponse }
        return KEFIdentity(model: model, firmware: firmware ?? "", macAddress: mac)
    }

    /// Reads every field independently: one missing value never fails the rest,
    /// but a fully unreadable speaker throws the transport error.
    public func fetchState() async throws -> KEFState {
        var state = KEFState()
        var firstError: KEFError?
        var successes = 0
        func note(_ error: Error) {
            let mapped = (error as? KEFError) ?? .malformedResponse
            if firstError == nil || mapped == .authenticationRequired { firstError = mapped }
        }

        do {
            let status = try await readTyped(KEFProtocol.speakerStatus, key: KEFProtocol.typeStatus)
            state.power = Self.power(fromStatus: status); successes += 1
        } catch { note(error) }
        do { state.volume = try await readInt(KEFProtocol.volume); successes += 1 } catch { note(error) }
        do { state.muted = try await readBool(KEFProtocol.mute); successes += 1 } catch { note(error) }
        do {
            let source = try await readTyped(KEFProtocol.physicalSource, key: KEFProtocol.typeSource); successes += 1
            if source == KEFProtocol.sourceStandby {
                // Observed: speakerStatus lags a standby write by several seconds, the source flips at once.
                state.power = .standby
                state.input = nil
            } else if source == KEFProtocol.sourcePowerOn {
                state.input = nil   // a wake marker, not a selectable input
            } else {
                state.input = KEFInput(wireValue: source)
            }
        } catch { note(error) }
        state.maxVolume = try? await readInt(KEFProtocol.maximumVolume)
        if successes == 0, let firstError { throw firstError }
        return state
    }

    static func power(fromStatus raw: String) -> KEFPower {
        switch raw {
        case KEFProtocol.statusActive, _ where KEFProtocol.statusActiveAlternates.contains(raw): return .active
        case KEFProtocol.statusStandby: return .standby
        default: return .unknown(raw)
        }
    }

    // MARK: Writes

    public func setPower(_ on: Bool) async throws {
        try await write(KEFProtocol.physicalSource, type: KEFProtocol.typeSource,
                        value: on ? KEFProtocol.sourcePowerOn : KEFProtocol.sourceStandby)
    }

    public func setVolume(_ percent: Int) async throws {
        guard config.volumeRange.contains(percent) else { throw KEFError.volumeOutOfRange(config.volumeRange) }
        try await write(KEFProtocol.volume, type: KEFProtocol.typeInt, value: percent)
    }

    public func setMuted(_ muted: Bool) async throws {
        try await write(KEFProtocol.mute, type: KEFProtocol.typeBool, value: muted)
    }

    public func setInput(_ input: KEFInput) async throws {
        guard KEFInput.selectable.contains(input) else { throw KEFError.unsupportedInput(input.wireValue) }
        try await write(KEFProtocol.physicalSource, type: KEFProtocol.typeSource, value: input.wireValue)
    }

    // MARK: Plumbing

    func readURL(_ path: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = config.port
        components.path = KEFProtocol.getDataPath
        components.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "roles", value: KEFProtocol.valueRole)]
        guard let url = components.url else { throw KEFError.invalidAddress }
        return url
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = config.requestTimeout
        let result: (status: Int, body: Data)
        do { result = try await transport.send(request) }
        catch let error as KEFError { throw error }
        catch let error as URLError where error.code == .timedOut { throw KEFError.timeout }
        catch { throw KEFError.unreachable }
        switch result.status {
        case 200..<300: return result.body
        case 401, 403: throw KEFError.authenticationRequired
        default: throw KEFError.rejected(result.status)
        }
    }

    private func readValue(_ path: String) async throws -> [String: Any] {
        let body = try await perform(URLRequest(url: try readURL(path)))
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [Any],
              let first = json.first as? [String: Any] else { throw KEFError.malformedResponse }
        return first
    }

    private func readTyped(_ path: String, key: String) async throws -> String {
        guard let value = try await readValue(path)[key] as? String else { throw KEFError.malformedResponse }
        return value
    }

    private func readString(_ path: String) async throws -> String {
        try await readTyped(path, key: KEFProtocol.typeString)
    }

    private func readInt(_ path: String) async throws -> Int {
        guard let number = try await readValue(path)[KEFProtocol.typeInt] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { throw KEFError.malformedResponse }
        return number.intValue
    }

    private func readBool(_ path: String) async throws -> Bool {
        guard let number = try await readValue(path)[KEFProtocol.typeBool] as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { throw KEFError.malformedResponse }
        return number.boolValue
    }

    func writeRequest(path: String, type: String, value: Any) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = config.port
        components.path = KEFProtocol.setDataPath
        guard let url = components.url else { throw KEFError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["path": path, "roles": KEFProtocol.valueRole, "value": ["type": type, type: value]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private func write(_ path: String, type: String, value: Any) async throws {
        _ = try await perform(try writeRequest(path: path, type: type, value: value))
    }
}

/// URLSession transport that never follows redirects (no hop to another host).
public final class KEFURLSessionTransport: NSObject, KEFTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KEFError.malformedResponse }
        return (http.statusCode, data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
