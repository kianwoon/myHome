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
}

public struct CastSwiftClient: CastClientProtocol {
    let device: CastDevice
    let timeout: TimeInterval

    public init(record: CastSpeakerRecord, timeout: TimeInterval = CastConfig.defaults.requestTimeout) throws {
        self.timeout = timeout
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
        try await session { client in
            let status = try await client.receiver.getStatus()
            var state = Self.state(from: status)
            if let app = status.foregroundApplication, !(app.isIdleScreen ?? false),
               app.supports(.media), let media = try? await client.mediaController(for: app) {
                if let current = try? await media.refreshStatus() { state.playback = Self.playback(current.playerState) }
                await media.detach()
            }
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
            if action == .stop { try await client.receiver.stop(app); return }
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

    // MARK: - Plumbing

    private func session<T: Sendable>(_ work: @escaping @Sendable (CastClient) async throws -> T) async throws -> T {
        let client = CastClient(device: device)
        let limit = timeout
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
