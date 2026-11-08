// Serves audio files picked on this Mac to Cast speakers over the LAN (a
// speaker fetches the URL itself). Only files explicitly registered are
// reachable, each behind an unguessable token; GET/HEAD with byte ranges.
// The listener runs only while at least one file is registered.
import Foundation
import Network
import UniformTypeIdentifiers

public final class CastFileServer: @unchecked Sendable {
    public static let shared = CastFileServer()
    public static let pathPrefix = "/cast/"
    static let maxRequestBytes = 16 * 1024
    static let chunkBytes = 256 * 1024

    private let queue = DispatchQueue(label: "myhome.cast.fileserver")
    private var listener: NWListener?
    private var port: UInt16?
    private var files: [String: URL] = [:]

    public init() {}

    /// Registers `file` and returns the URL a speaker on the same LAN can fetch.
    public func register(_ file: URL) async throws -> URL {
        guard file.isFileURL, FileManager.default.isReadableFile(atPath: file.path) else { throw CastError.unplayableSource }
        let port = try await ensureListening()
        guard let host = Self.lanAddress() else { throw CastError.unreachable }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        queue.sync { files[token] = file }
        let name = file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "audio"
        guard let url = URL(string: "http://\(host):\(port)\(Self.pathPrefix)\(token)/\(name)") else { throw CastError.unplayableSource }
        return url
    }

    public func unregisterAll() {
        queue.sync { files.removeAll(); listener?.cancel(); listener = nil; port = nil }
    }

    public static func contentType(for file: URL) -> String {
        UTType(filenameExtension: file.pathExtension.lowercased())?.preferredMIMEType ?? CastMediaSource.fallbackContentType
    }

    // MARK: - Listener

    private func ensureListening() async throws -> UInt16 {
        if let port = queue.sync(execute: { port }) { return port }
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !finished else { return }
                switch state {
                case .ready:
                    finished = true
                    let value = listener.port?.rawValue ?? 0
                    self?.queue.async { self?.port = value }
                    continuation.resume(returning: value)
                case .failed:
                    finished = true
                    continuation.resume(throwing: CastError.unreachable)
                default: break
                }
            }
            queue.sync { self.listener = listener }
            listener.start(queue: queue)
        }
    }

    // MARK: - HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, let text = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            self.respond(to: text, on: connection)
        }
    }

    struct Request: Equatable {
        var method: String
        var path: String
        var range: (start: Int, end: Int?)?
        static func == (lhs: Request, rhs: Request) -> Bool {
            lhs.method == rhs.method && lhs.path == rhs.path && lhs.range?.start == rhs.range?.start && lhs.range?.end == rhs.range?.end
        }
    }

    static func parse(_ text: String) -> Request? {
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2, ["GET", "HEAD"].contains(parts[0]) else { return nil }
        var request = Request(method: parts[0], path: parts[1], range: nil)
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range: bytes=") {
            let spec = line.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            if spec.count == 2, let start = Int(spec[0]) { request.range = (start, Int(spec[1])) }
        }
        return request
    }

    private func respond(to text: String, on connection: NWConnection) {
        guard let request = Self.parse(text),
              request.path.hasPrefix(Self.pathPrefix),
              let token = request.path.dropFirst(Self.pathPrefix.count).split(separator: "/").first.map(String.init),
              let file = files[token],
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue else {
            return send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", body: nil, on: connection)
        }
        var start = 0
        var end = size - 1
        var status = "200 OK"
        if let range = request.range {
            guard range.start < size else {
                return send("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", body: nil, on: connection)
            }
            start = range.start
            end = min(range.end ?? (size - 1), size - 1)
            status = "206 Partial Content"
        }
        let length = max(end - start + 1, 0)
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(Self.contentType(for: file))\r\nContent-Length: \(length)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
        if status.hasPrefix("206") { head += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        head += "\r\n"
        guard request.method == "GET" else { return send(head, body: nil, on: connection) }
        stream(head: head, file: file, offset: start, remaining: length, on: connection)
    }

    private func send(_ head: String, body: Data?, on connection: NWConnection) {
        connection.send(content: Data(head.utf8) + (body ?? Data()), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func stream(head: String, file: URL, offset: Int, remaining: Int, on connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return connection.cancel() }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { try? handle.close(); return connection.cancel() }
            try? handle.seek(toOffset: UInt64(offset))
            self.pump(handle: handle, remaining: remaining, on: connection)
        })
    }

    private func pump(handle: FileHandle, remaining: Int, on connection: NWConnection) {
        guard remaining > 0, let chunk = try? handle.read(upToCount: min(Self.chunkBytes, remaining)), !chunk.isEmpty else {
            try? handle.close()
            return connection.cancel()
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil { try? handle.close(); return connection.cancel() }
            self?.pump(handle: handle, remaining: remaining - chunk.count, on: connection)
        })
    }

    // MARK: - LAN address

    /// First up, non-loopback IPv4 on an en* interface (Wi-Fi / Ethernet).
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  String(cString: entry.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
