// KEF speaker discovery over Bonjour. The LS50 Wireless II advertises
// `_kef-info._tcp` with the instance name "<mac>@<model>" (observed on
// firmware 420.390…); every candidate is then verified by a read-only
// identity fetch, so a lookalike service never becomes a speaker record.
import Foundation
import Network

public struct KEFServiceHit: Equatable, Sendable {
    public let instanceName: String
    public let address: String
    public init(instanceName: String, address: String) {
        self.instanceName = instanceName
        self.address = address
    }
}

public struct KEFDiscoveredSpeaker: Equatable, Identifiable, Sendable {
    public let identity: KEFIdentity
    public let address: String
    public var id: String { identity.deviceID }
}

public protocol KEFServiceBrowsing: Sendable {
    /// Browses for `timeout` seconds; returns every resolved IPv4 hit.
    func browse(timeout: TimeInterval) async -> [KEFServiceHit]
}

public enum KEFDiscovery {
    public static let serviceType = "_kef-info._tcp"
    public static let defaultTimeout: TimeInterval = 4
    public static let timeoutKey = "kefDiscoveryTimeoutSeconds"

    /// "841715152764@LS50WII" → (mac "841715152764", model "LS50WII").
    static func parseInstance(_ name: String) -> (mac: String, model: String)? {
        let parts = name.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let mac = parts[0].lowercased()
        guard mac.count == 12, mac.allSatisfy({ $0.isHexDigit && $0.isASCII }), !parts[1].isEmpty else { return nil }
        return (mac, parts[1])
    }

    public static func timeout(from defaults: UserDefaults = .standard) -> TimeInterval {
        min(max(defaults.object(forKey: timeoutKey) as? Double ?? defaultTimeout, 1), 30)
    }

    /// Supported speakers on the LAN, verified by a read-only identity fetch.
    public static func discover(
        browser: KEFServiceBrowsing = KEFBonjourBrowser(),
        makeClient: @escaping @Sendable (String) throws -> any KEFClientProtocol = { try KEFClient(host: $0) },
        timeout: TimeInterval = timeout()
    ) async -> [KEFDiscoveredSpeaker] {
        let hits = await browser.browse(timeout: timeout).filter { hit in
            KEFClient.isValidIPv4(hit.address) && (parseInstance(hit.instanceName).map { KEFModel.isSupported($0.model) } ?? false)
        }
        var found: [String: KEFDiscoveredSpeaker] = [:]
        await withTaskGroup(of: KEFDiscoveredSpeaker?.self) { group in
            for hit in hits {
                group.addTask {
                    guard let parsed = parseInstance(hit.instanceName),
                          let client = try? makeClient(hit.address),
                          let identity = try? await client.fetchIdentity(),
                          identity.isSupportedModel, identity.macAddress == parsed.mac else { return nil }
                    return KEFDiscoveredSpeaker(identity: identity, address: hit.address)
                }
            }
            for await speaker in group { if let speaker { found[speaker.id] = speaker } }
        }
        return found.values.sorted { $0.id < $1.id }
    }
}

/// NWBrowser-backed browse; each service is resolved to its IPv4 by a short-lived connection.
public final class KEFBonjourBrowser: KEFServiceBrowsing, @unchecked Sendable {
    public init() {}

    public func browse(timeout: TimeInterval) async -> [KEFServiceHit] {
        let queue = DispatchQueue(label: "kef.discovery")
        let results = ResultBox()
        let browser = NWBrowser(for: .bonjour(type: KEFDiscovery.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { found, _ in
            queue.async { results.endpoints = Set(found.map(\.endpoint)) }
        }
        browser.start(queue: queue)
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        browser.cancel()
        let endpoints = queue.sync { Array(results.endpoints) }
        var hits: [KEFServiceHit] = []
        await withTaskGroup(of: KEFServiceHit?.self) { group in
            for endpoint in endpoints {
                group.addTask { await Self.resolve(endpoint, queue: queue) }
            }
            for await hit in group { if let hit { hits.append(hit) } }
        }
        return hits
    }

    private final class ResultBox: @unchecked Sendable { var endpoints: Set<NWEndpoint> = [] }

    private static func resolve(_ endpoint: NWEndpoint, queue: DispatchQueue) async -> KEFServiceHit? {
        guard case let .service(name, _, _, _) = endpoint else { return nil }
        let parameters = NWParameters.tcp
        if let options = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { options.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        return await withCheckedContinuation { continuation in
            let once = Once()
            let finish: @Sendable (KEFServiceHit?) -> Void = { hit in
                guard once.first() else { return }
                connection.cancel()
                continuation.resume(returning: hit)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint, case .ipv4(let address) = host {
                        let text = "\(address)".split(separator: "%").first.map(String.init) ?? ""
                        finish(KEFServiceHit(instanceName: name, address: text))
                    } else { finish(nil) }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
}
