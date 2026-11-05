// baseline-guard:allow new native flux transport, no prior baseline
// Native TCP transport for Zengge WiFi lights (port 5577), replacing bridge
// round-trips for briturn devices. General rule: briturn traffic never touches
// the serial bridge — one slow bulb must never delay Tuya devices, cloud
// calls, or schedules.
//
// Wire protocol (validated live against AK001-ZJ214 firmware, same packets
// the bridge uses):
//   Query state : 81 8a 8b -> 14-byte frame, anchor on 81 5f preamble:
//                 [2]=power (0x23 on / 0x24 off), [3]=mode,
//                 [9]=warm white level ([5] is a fixed 0x50 on this
//                 firmware, not the level), [6..8]=r g b
//   Power       : 71 23 (on) / 71 24 (off)
//   Colour      : 31 r g b warm 0xF0 0xAA  (0xF0 applies the warm byte)

import Foundation

public enum FluxClient {
    private static let port: UInt16 = 5577
    // Concurrent: one wedged bulb must not head-of-line-block other bulbs.
    // Callers already chunk per-device work, so this needs no call-site change.
    private static let queue = DispatchQueue(
        label: "myhome.fluxclient", qos: .utility, attributes: .concurrent
    )

    // MARK: - Public API

    /// The test host must never reach a real light (fixtures carry real-looking IPs).
    static let isUnderXCTest = NSClassFromString("XCTestCase") != nil

    public static func query(ip: String) async -> DeviceStore.BriturnState? {
        if isUnderXCTest { return nil }
        return await run(ip: ip) { sock in
            guard sendAll(sock, [0x81, 0x8A, 0x8B]) else { return nil }
            var buffer = [UInt8](repeating: 0, count: 64)
            let n = recv(sock, &buffer, buffer.count, 0)
            guard n >= 14 else { return nil }
            return parseFrame(Array(buffer[0..<n]))
        }
    }

    public static func setPower(ip: String, on: Bool) async -> Bool {
        await write(ip: ip, [0x71, on ? 0x23 : 0x24])
    }

    /// Pure colour: drives the warm byte explicitly (0 = white off), matching
    /// the bridge's white-off rule so picker colours render true.
    public static func setColor(ip: String, red: Int, green: Int, blue: Int, warm: Int = 0) async -> Bool {
        await write(ip: ip, [0x31, clamp(red), clamp(green), clamp(blue), clamp(warm), 0xF0, 0xAA])
    }

    /// Warm-white level (white mode). level 0-255.
    public static func setWhiteLevel(ip: String, level: Int) async -> Bool {
        await write(ip: ip, [0x31, 0, 0, 0, clamp(level), 0xF0, 0xAA])
    }

    // MARK: - Internals

    private func dummy() {}

    private static func clamp(_ v: Int) -> UInt8 { UInt8(min(max(v, 0), 255)) }

    private static func parseFrame(_ reply: [UInt8]) -> DeviceStore.BriturnState? {
        // Anchor on the 81 5f preamble — ack streams may precede the frame.
        guard let offset = reply.lastRange(of: [0x81, 0x5F])?.lowerBound,
              reply.count - offset >= 14 else { return nil }
        let f = Array(reply[offset...])
        let on = f[2] == 0x23
        let rgbZero = f[6] == 0 && f[7] == 0 && f[8] == 0
        return DeviceStore.BriturnState(
            on: on,
            rawPower: Int(f[2]),
            mode: Int(f[3]),
            r: rgbZero ? 0 : Int(f[6]),
            g: rgbZero ? 0 : Int(f[7]),
            b: rgbZero ? 0 : Int(f[8]),
            w: Int(f[9]),
            cool: Int(f[11]),
            firmware: Int(f[10])
        )
    }

    private static func write(ip: String, _ packet: [UInt8]) async -> Bool {
        let ok: Bool? = await run(ip: ip) { sock in
            sendAll(sock, packet) ? true : nil
        }
        return ok == true
    }

    /// Runs one socket exchange off the main thread. Two attempts, short
    /// timeouts — these are flaky consumer firmwares, never loop hard.
    private static func run<T>(ip: String, _ body: @escaping (Int32) -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            queue.async {
                for _ in 0..<2 {
                    // Close the attempt socket on EVERY path: a body that
                    // returns nil must not leak an ESTABLISHED session, or
                    // the bulb's single session slot wedges until restart.
                    guard let sock = connect(ip: ip) else { continue }
                    let result = body(sock)
                    close(sock)
                    if let result = result {
                        continuation.resume(returning: result)
                        return
                    }
                    connect(ip: ip).map { close($0) }
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private static func connect(ip: String) -> Int32? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        let timeout = timeval(tv_sec: 3, tv_usec: 0)
        var tv = timeout
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let flags = fcntl(sock, F_GETFL, 0)
        guard flags >= 0, fcntl(sock, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            close(sock)
            return nil
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // SO_RCVTIMEO/SO_SNDTIMEO do NOT bound connect(): a dropped SYN would
        // block for the OS default (~75s). Connect non-blocking and poll.
        if result != 0 {
            guard errno == EINPROGRESS else {
                close(sock)
                return nil
            }
            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, 2000) > 0 else {
                close(sock)
                return nil
            }
            var err: Int32 = 0
            var errLen = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &errLen) == 0,
                  err == 0 else {
                close(sock)
                return nil
            }
        }
        // Blocking again for recv/send, which ARE bounded by the socket timeouts.
        _ = fcntl(sock, F_SETFL, flags)
        return sock
    }

    private static func sendAll(_ sock: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        let total = bytes.count
        return bytes.withUnsafeBufferPointer { buf in
            var ptr = buf.baseAddress!
            while sent < total {
                let n = Darwin.send(sock, ptr, total - sent, 0)
                if n <= 0 { return false }
                sent += n
                ptr += n
            }
            return true
        }
    }
}
