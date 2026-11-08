// Per-speaker Cast client. Each exchange opens a short-lived TLS session
// (connect → one operation → disconnect): Home Minis allow few concurrent
// senders and the app polls rarely, so no long-lived socket is held.
import Foundation
import Network
import SwiftCast

public protocol CastClientProtocol: Sendable {
    func fetchState() async throws -> CastState
    func setVolume(_ percent: Int) async throws
    func setMuted(_ muted: Bool) async throws
    /// `.play`, `.pause`, `.stop` on the running session.
    func transport(_ action: CastAction) async throws
    /// Loads `source` on the default media receiver and starts it.
    func play(_ source: CastMediaSource) async throws
}

public struct CastSwiftClient: CastClientProtocol {
    let device: CastDevice
    let timeout: TimeInterval
    let playTimeout: TimeInterval
    let mediaStatusTimeout: TimeInterval
    private var deviceID: String { device.id }

    public init(record: CastSpeakerRecord, timeout: TimeInterval = CastConfig.defaults.requestTimeout,
                playTimeout: TimeInterval = CastConfig.defaults.playTimeout,
                mediaStatusTimeout: TimeInterval = CastConfig.defaults.mediaStatusTimeout) throws {
        self.timeout = timeout
        self.mediaStatusTimeout = mediaStatusTimeout
        self.playTimeout = playTimeout
        if let service = record.serviceName, !service.isEmpty {
            device = CastDevice(id: record.deviceID, name: record.name, endpoint:
                .service(name: service, type: CastProtocol.serviceType, domain: CastProtocol.serviceDomain, interface: nil))
        } else if let address = record.address, Self.isValidIPv4(address), (1...65535).contains(record.port) {
            device = CastDevice(host: address, port: UInt16(record.port), name: record.name)
        } else {
            throw CastError.invalidAddress
        }
    }

    public init(address: String, port: Int = CastProtocol.defaultPort, timeout: TimeInterval = CastConfig.defaults.requestTimeout) throws {
        guard Self.isValidIPv4(address), (1...65535).contains(port) else { throw CastError.invalidAddress }
        self.timeout = timeout
        self.playTimeout = CastConfig.defaults.playTimeout
        self.mediaStatusTimeout = CastConfig.defaults.mediaStatusTimeout
        device = CastDevice(host: address, port: UInt16(port))
    }

    public static func isValidIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && Int(part).map { (0...255).contains($0) } == true
        }
    }

    // MARK: - Operations

    public func fetchState() async throws -> CastState {
        let limit = mediaStatusTimeout
        return try await session { client in
            let status = try await client.receiver.getStatus()
            var state = Self.state(from: status)
            // Playback is best-effort and bounded on its own: a slow media channel must not fail the volume read.
            if let app = status.foregroundApplication, !(app.isIdleScreen ?? false), app.supports(.media) {
                state.playback = await Self.bounded(seconds: limit) {
                    guard let media = try? await client.mediaController(for: app) else { return nil }
                    defer { Task { await media.detach() } }
                    return (try? await media.refreshStatus()).map { Self.playback($0.playerState) }
                } ?? nil
            }
            if state.appName == nil { await CastSessionHolder.shared.release(deviceID) }
            return state
        }
    }

    public func setVolume(_ percent: Int) async throws {
        let level = Double(Percent.clamp(percent)) / 100
        try await session { client in _ = try await client.receiver.setVolume(level) }
    }

    public func setMuted(_ muted: Bool) async throws {
        try await session { client in _ = try await client.receiver.setMuted(muted) }
    }

    public func transport(_ action: CastAction) async throws {
        try await session { client in
            let status = try await client.receiver.getStatus()
            guard let app = status.foregroundApplication, !(app.isIdleScreen ?? false) else { throw CastError.noActiveSession }
            if action == .stop {
                try await client.receiver.stop(app)
                await CastSessionHolder.shared.release(deviceID)
                return
            }
            guard app.supports(.media) else { throw CastError.noActiveSession }
            let media = try await client.mediaController(for: app)
            switch action {
            case .play: _ = try await media.play()
            case .pause: _ = try await media.pause()
            default: break
            }
            await media.detach()
        }
    }

    /// Starts `source`, then KEEPS the connection open: the Default Media Receiver
    /// quits as soon as its last sender disconnects (observed on Nest Mini), so a
    /// short-lived session would stop the music it just started.
    public func play(_ source: CastMediaSource) async throws {
        guard source.isPlayable else { throw CastError.unplayableSource }
        let client = CastClient(device: device)
        let limit = playTimeout
        do {
            try await Self.boundedThrowing(seconds: limit) {
                try await client.connect()
                let media = try await client.launchMediaReceiver()
                let info = MediaInformation(
                    contentId: source.url.absoluteString, contentURL: source.url,
                    streamType: source.isLive ? .live : .buffered, contentType: source.contentType,
                    metadata: .generic(title: source.title))
                _ = try await media.load(info)
            }
        } catch {
            await client.disconnect()
            throw Self.map(error)
        }
        await CastSessionHolder.shared.hold(device.id, client)
    }

    // MARK: - Plumbing

    private func session<T: Sendable>(timeout override: TimeInterval? = nil, _ work: @escaping @Sendable (CastClient) async throws -> T) async throws -> T {
        let client = CastClient(device: device)
        let limit = override ?? timeout
        do {
            let result: T = try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask {
                    try await client.connect()
                    return try await work(client)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                    throw CastError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            await client.disconnect()
            return result
        } catch {
            await client.disconnect()
            throw Self.map(error)
        }
    }

    static func boundedThrowing(seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CastError.timeout
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    /// Runs `work`, returning nil if it has not finished within `seconds`.
    static func bounded<T: Sendable>(seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    static func map(_ error: Error) -> CastError {
        if let cast = error as? CastError { return cast }
        if error is CancellationError { return .timeout }
        return .unreachable
    }

    static func state(from status: ReceiverStatus) -> CastState {
        var state = CastState()
        state.volume = status.volume?.level.map { Int(($0 * 100).rounded()) }
        state.muted = status.volume?.muted
        if let app = status.foregroundApplication, !(app.isIdleScreen ?? false) { state.appName = app.displayName ?? app.appId.rawValue }
        return state
    }

    static func playback(_ player: PlayerState) -> CastPlayback {
        switch player {
        case .idle: return .idle
        case .playing: return .playing
        case .paused: return .paused
        case .buffering, .loading: return .buffering
        case .unknown: return .other
        }
    }
}

/// Keeps one open Cast connection per playing speaker (see `CastSwiftClient.play`).
/// Released when playback is stopped, a new stream replaces it, or the speaker goes idle.
public actor CastSessionHolder {
    public static let shared = CastSessionHolder()
    private var held: [String: CastClient] = [:]

    public func hold(_ id: String, _ client: CastClient) async {
        let previous = held[id]
        held[id] = client
        await previous?.disconnect()
    }

    public func release(_ id: String) async {
        guard let client = held.removeValue(forKey: id) else { return }
        await client.disconnect()
    }

    public func releaseAll() async {
        let all = held
        held.removeAll()
        for client in all.values { await client.disconnect() }
    }
}
