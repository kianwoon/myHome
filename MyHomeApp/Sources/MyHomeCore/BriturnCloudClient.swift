import CryptoKit
import Foundation
import Security

public enum BriturnCloudRegion: String, CaseIterable, Codable, Identifiable {
    case us, eu, cn
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .us: return "United States"
        case .eu: return "Europe"
        case .cn: return "China"
        }
    }
    var host: String { "app-\(rawValue).briturn.net" }
}

public struct BriturnCloudAccount: Codable, Equatable {
    public let maskedEmail: String
    public let region: BriturnCloudRegion
    public let signedInAt: Date
}

struct BriturnCloudSession: Codable {
    let account: BriturnCloudAccount
    let token: String
    let apiURL: URL
}

public enum BriturnCloudError: LocalizedError {
    case invalidInput, invalidResponse, unauthorized, server(Int), storage, network, unsafeServer, unsupportedDevice, deviceOffline, commandUnconfirmed
    public var errorDescription: String? {
        switch self {
        case .commandUnconfirmed: return "The light did not confirm the requested change. Please try again."
        case .unsupportedDevice: return "This Briturn model does not support this cloud lighting control."
        case .deviceOffline: return "Briturn did not return a current device status. The light may be offline."
        case .invalidInput: return "Enter your Briturn email and password."
        case .invalidResponse: return "Briturn returned an unexpected response. Please try again."
        case .unauthorized: return "Your Briturn session has expired or was rejected. Sign in again in Settings → Cloud."
        case .server(let code): return "Briturn could not complete the request (code \(code)). Please try again."
        case .storage: return "The Briturn session could not be saved in Keychain. Please try again."
        case .network: return "Could not reach Briturn. Check your connection and try again."
        case .unsafeServer: return "Briturn returned an unsupported server address. The session was not saved."
        }
    }
}

protocol BriturnSessionStorage {
    func load() throws -> BriturnCloudSession?
    func save(_ session: BriturnCloudSession) throws
    func delete() throws
}

struct BriturnKeychainStorage: BriturnSessionStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.myhome.app.briturn-cloud",
         kSecAttrAccount as String: "session"]
    }

    func load() throws -> BriturnCloudSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let session = try? JSONDecoder().decode(BriturnCloudSession.self, from: data) else {
            throw BriturnCloudError.storage
        }
        return session
    }

    func save(_ session: BriturnCloudSession) throws {
        let data = try JSONEncoder().encode(session)
        let status = SecItemUpdate(query as CFDictionary,
                                  [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw BriturnCloudError.storage
            }
        } else if status != errSecSuccess {
            throw BriturnCloudError.storage
        }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BriturnCloudError.storage
        }
    }
}

protocol BriturnHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class BriturnRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Login bodies must never be forwarded to a redirect destination.
        completionHandler(nil)
    }
}

private struct BriturnURLTransport: BriturnHTTPTransport {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: BriturnRedirectPolicy(), delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BriturnCloudError.invalidResponse }
        return (data, http)
    }
}

/// Briturn 1.0.23's Flutter email protocol. Passwords never enter persisted state.
public actor BriturnCloudClient {
    public static let shared = BriturnCloudClient()
    private let transport: any BriturnHTTPTransport
    private let storage: any BriturnSessionStorage
    private let now: () -> Date
    private var operationInProgress = false
    private var sessionWaiters: [CheckedContinuation<Void, Never>] = []
    private var serverClockOffset = 0
    private var lastClockSync: Date?

    public init() {
        transport = BriturnURLTransport()
        storage = BriturnKeychainStorage()
        now = Date.init
    }

    init(transport: any BriturnHTTPTransport, storage: any BriturnSessionStorage,
         now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.storage = storage
        self.now = now
    }

    public func savedAccount() throws -> BriturnCloudAccount? {
        try storage.load()?.account
    }

    public func signOut() async throws {
        await acquireSessionOperation()
        defer { releaseSessionOperation() }
        try storage.delete()
    }

    public func signIn(email: String, password: String, region: BriturnCloudRegion) async throws -> BriturnCloudAccount {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !email.contains(where: { $0.isWhitespace }), !password.isEmpty else {
            throw BriturnCloudError.invalidInput
        }
        guard !operationInProgress else { throw BriturnCloudError.invalidResponse }
        operationInProgress = true
        defer { releaseSessionOperation() }
        do {
            // Ask the same configuration endpoint as the official app to align request time.
            let config = try await post(path: "/app/sys/config", body: [:], region: region, timestamp: Int(now().timeIntervalSince1970))
            guard let configData = config["data"] as? [String: Any],
                  let serverTime = configData["time"] as? NSNumber,
                  CFGetTypeID(serverTime) != CFBooleanGetTypeID(), serverTime.doubleValue > 0 else {
                throw BriturnCloudError.invalidResponse
            }
            let offset = Int(now().timeIntervalSince1970) - serverTime.intValue
            serverClockOffset = offset
            lastClockSync = now()
            let response = try await post(path: "/app/user/login",
                                          body: ["codeType": "EMAIL", "username": email,
                                                 "password": Self.md5(password).uppercased()],
                                          region: region, timestamp: Int(now().timeIntervalSince1970) - offset)
            guard let token = response["token"] as? String, !token.isEmpty,
                  let data = response["data"] as? [String: Any] else {
                throw BriturnCloudError.invalidResponse
            }
            let apiURL: URL
            if let raw = data["webApi"] as? String, !raw.isEmpty {
                guard let url = URL(string: raw), Self.isAllowedServer(url) else {
                    throw BriturnCloudError.unsafeServer
                }
                apiURL = url
            } else {
                apiURL = URL(string: "https://\(region.host)")!
            }
            let accountRegion = BriturnCloudRegion.allCases.first { $0.host == apiURL.host } ?? region
            let masked = "\(parts[0].prefix(1))…@\(parts[1])"
            let account = BriturnCloudAccount(maskedEmail: masked, region: accountRegion, signedInAt: now())
            try Task.checkCancellation()
            try storage.save(BriturnCloudSession(account: account, token: token, apiURL: apiURL))
            return account
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BriturnCloudError {
            throw error
        } catch {
            // Never surface a server body, URL, request, password digest or token in errors.
            throw BriturnCloudError.network
        }
    }

    private func acquireSessionOperation() async {
        if operationInProgress {
            await withCheckedContinuation { sessionWaiters.append($0) }
        } else { operationInProgress = true }
    }

    private func releaseSessionOperation() {
        if sessionWaiters.isEmpty { operationInProgress = false }
        else { sessionWaiters.removeFirst().resume() }
    }

    private func authenticatedPost(path: String, body: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard let saved = try storage.load() else { throw BriturnCloudError.unauthorized }
        guard Self.isAllowedServer(saved.apiURL),
              let region = BriturnCloudRegion.allCases.first(where: { $0.host == saved.apiURL.host }) else {
            throw BriturnCloudError.unsafeServer
        }
        do {
            if lastClockSync == nil || now().timeIntervalSince(lastClockSync!) > 300 {
                let config = try await post(path: "/app/sys/config", body: [:], region: region,
                                            timestamp: Int(now().timeIntervalSince1970))
                guard let data = config["data"] as? [String: Any], let time = data["time"] as? NSNumber,
                      CFGetTypeID(time) != CFBooleanGetTypeID(), time.doubleValue > 0 else {
                    throw BriturnCloudError.invalidResponse
                }
                serverClockOffset = Int(now().timeIntervalSince1970) - time.intValue
                lastClockSync = now()
            }
            let response = try await post(path: path, body: body, region: region,
                                           timestamp: Int(now().timeIntervalSince1970) - serverClockOffset,
                                           token: saved.token)
            if let token = response["token"] as? String, !token.isEmpty, token != saved.token {
                try storage.save(BriturnCloudSession(account: saved.account, token: token, apiURL: saved.apiURL))
            }
            return response
        } catch BriturnCloudError.unauthorized {
            try storage.delete()
            throw BriturnCloudError.unauthorized
        } catch let error as BriturnCloudError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw BriturnCloudError.network }
    }

    public func syncDevices() async throws -> [BriturnCloudDevice] {
        await acquireSessionOperation()
        defer { releaseSessionOperation() }
        guard try storage.load() != nil else { return [] }
        let response = try await authenticatedPost(path: "/app/home/list", body: [:])
        guard let homes = response["data"] as? [[String: Any]] else { throw BriturnCloudError.invalidResponse }
        var devices: [String: BriturnCloudDevice] = [:]
        for home in homes {
            guard let homeID = BriturnCloudDevice.integer(home["homeId"]) else { throw BriturnCloudError.invalidResponse }
            let response = try await authenticatedPost(path: "/app/device/list", body: ["homeId": homeID])
            guard let items = response["data"] as? [[String: Any]] else { throw BriturnCloudError.invalidResponse }
            for item in items {
                let device = try BriturnCloudDevice(json: item, homeID: homeID)
                devices[device.canonicalID] = device
            }
        }
        return devices.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Read-only discovery of how Briturn models groups/rooms: raw replies of the
    /// group and home endpoints plus one full device entry, keyed by endpoint.
    public func probeGroups() async throws -> [String: Any] {
        await acquireSessionOperation()
        defer { releaseSessionOperation() }
        guard try storage.load() != nil else { return [:] }
        let homes = try await authenticatedPost(path: "/app/home/list", body: [:])
        guard let list = homes["data"] as? [[String: Any]],
              let homeID = list.lazy.compactMap({ BriturnCloudDevice.integer($0["homeId"]) }).first else {
            throw BriturnCloudError.invalidResponse
        }
        var result: [String: Any] = [:]
        for path in ["/app/device/group/list", "/app/home/get"] {
            result[path] = try await authenticatedPost(path: path, body: ["homeId": homeID])
        }
        let devices = try await authenticatedPost(path: "/app/device/list", body: ["homeId": homeID])
        if let first = (devices["data"] as? [[String: Any]])?.first { result["/app/device/list (first entry)"] = first }
        return result
    }

    public func queryStates(devices: [BriturnCloudDevice]) async throws -> [String: DeviceStore.BriturnState] {
        await acquireSessionOperation()
        defer { releaseSessionOperation() }
        return try await queryUnlocked(devices: devices)
    }

    private func queryUnlocked(devices: [BriturnCloudDevice]) async throws -> [String: DeviceStore.BriturnState] {
        var states: [String: DeviceStore.BriturnState] = [:]
        let supported = devices.filter(\.supportsLighting)
        for group in Dictionary(grouping: supported, by: \.entityType).values {
            // Bound cloud requests; never send a whole large installation in one call.
            for start in stride(from: 0, to: group.count, by: 32) {
                let chunk = Array(group[start..<min(start + 32, group.count)])
                let response = try await authenticatedPost(path: "/app/command/custom", body: [
                    "entityType": chunk[0].entityType, "type": "device.quest",
                    "body": chunk.map { ["id": $0.deviceID, "value": "818A8B96"] as [String: Any] }])
                guard let items = response["data"] as? [[String: Any]] else { throw BriturnCloudError.invalidResponse }
                for item in items {
                    guard let id = BriturnCloudDevice.integer(item["id"]),
                          let device = chunk.first(where: { $0.deviceID == id }),
                          let hex = item["state"] as? String,
                          let state = BriturnCloudPackets.parseState(hex) else { continue }
                    states[device.canonicalID] = state
                }
            }
        }
        return states
    }

    public func control(devices: [BriturnCloudDevice], on: Bool? = nil,
                        color: (red: Int, green: Int, blue: Int)? = nil,
                        brightness: Int? = nil, white: Bool = false, cct: Int? = nil) async throws -> [String: DeviceStore.BriturnState] {
        guard !devices.isEmpty else { return [:] }
        guard devices.allSatisfy(\.supportsLighting) else { throw BriturnCloudError.unsupportedDevice }
        await acquireSessionOperation()
        defer { releaseSessionOperation() }
        // Determine firmware and current white balance from the device, never guess.
        let before = try await queryUnlocked(devices: devices)
        let reachable = devices.filter { before[$0.canonicalID] != nil }
        guard !reachable.isEmpty else { throw BriturnCloudError.deviceOffline }
        var packets: [String: [[UInt8]]] = [:]
        for device in reachable {
            packets[device.canonicalID] = try BriturnCloudPackets.commands(
                state: before[device.canonicalID]!, functions: device.functions,
                on: on, color: color, brightness: brightness, white: white, cct: cct)
        }
        let stageCount = packets.values.map(\.count).max() ?? 0
        for stage in 0..<stageCount {
            for group in Dictionary(grouping: reachable, by: \.entityType).values {
                let stageDevices = group.filter { (packets[$0.canonicalID]?.count ?? 0) > stage }
                for start in stride(from: 0, to: stageDevices.count, by: 32) {
                    let chunk = Array(stageDevices[start..<min(start + 32, stageDevices.count)])
                    _ = try await authenticatedPost(path: "/app/command/custom", body: [
                        "entityType": chunk[0].entityType, "type": "device.hex",
                        "body": chunk.map { ["id": $0.deviceID, "value": BriturnCloudPackets.hex(packets[$0.canonicalID]![stage])] as [String: Any] }])
                }
            }
        }
        // An accepted command is not proof of state. Re-query rather than optimistic success.
        let after = try await queryUnlocked(devices: reachable)
        guard !after.isEmpty else { throw BriturnCloudError.deviceOffline }
        let confirmed = after.filter { on == nil || $0.value.on == on }
        guard !confirmed.isEmpty else { throw BriturnCloudError.commandUnconfirmed }
        return confirmed
    }

    static func isAllowedServer(_ url: URL) -> Bool {
        url.scheme == "https" && BriturnCloudRegion.allCases.contains { $0.host == url.host }
            && url.user == nil && url.password == nil && url.port == nil
            && (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
    }

    static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func signature(parameters: [String: String], appSecure: String) -> String {
        let order = ["appBVer", "appKey", "appVer", "lang", "os", "osSystem", "platform",
                     "sdkVersion", "time", "timeZoneId", "v"]
        return md5(order.map { parameters[$0] ?? "" }.joined() + "appSecure=" + appSecure)
    }

    func post(path: String, body: [String: Any], region: BriturnCloudRegion,
                      timestamp: Int, token: String? = nil) async throws -> [String: Any] {
        // Compatibility metadata from the Android app whose protocol was inspected.
        var parameters = ["appBVer": "67", "appKey": "BR001", "appVer": "1.0.23",
                          "lang": Locale.preferredLanguages.first ?? "en-US", "os": "Android",
                          "osSystem": "36", "platform": "MyHome-macOS", "sdkVersion": "1.0",
                          "time": String(timestamp), "timeZoneId": TimeZone.current.identifier, "v": "1"]
        parameters["sign"] = Self.signature(parameters: parameters, appSecure: Self.appSecure)
        var components = URLComponents()
        components.scheme = "https"
        components.host = region.host
        components.path = path
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw BriturnCloudError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(parameters["lang"], forHTTPHeaderField: "accept-language")
        if let token { request.setValue(token, forHTTPHeaderField: "token") }
        let (data, response) = try await transport.send(request)
        guard response.statusCode != 401 && response.statusCode != 403 else { throw BriturnCloudError.unauthorized }
        guard response.statusCode == 200, data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? NSNumber,
              CFGetTypeID(code) != CFBooleanGetTypeID(),
              code.doubleValue == Double(code.intValue) else { throw BriturnCloudError.invalidResponse }
        guard code.intValue == 0 else { throw BriturnCloudError.server(code.intValue) }
        return object
    }

    // App-wide protocol constant recovered from Briturn's distributed Android app.
    // This is not an account credential; never replace it with a user's password.
    private static let appSecure = "18n2SS2j"
}
