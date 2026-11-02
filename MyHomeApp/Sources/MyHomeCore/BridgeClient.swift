// baseline-guard:allow new source file, no prior baseline
import Foundation

public enum BridgeError: LocalizedError {
    case unavailable(String)
    case timeout
    case badResponse(String)
    case bridge(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        case .timeout:
            return "The bridge did not reply in time."
        case .badResponse(let message):
            return "Bad bridge response: \(message)"
        case .bridge(let message):
            return message
        }
    }
}

/// Spawns the Python bridge as a subprocess and speaks its JSON-lines protocol.
///
/// Requests are stamped with an incrementing reqId and replies are matched by
/// that id, so the bridge can answer out of order. Replies without a reqId
/// (a legacy bridge) fall back to FIFO correlation. Every request has a
/// timeout; a timeout tears the process down so the next request starts from
/// a clean protocol state.
public final class BridgeClient: @unchecked Sendable {
    public static let shared = BridgeClient()

    private let queue = DispatchQueue(label: "com.myhome.bridge")
    private let fileManager = FileManager.default

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var pending: [Pending] = []
    private var nextRequestId = 1

    private final class Pending {
        let id: Int
        let continuation: CheckedContinuation<[String: Any], Error>
        var finished = false

        init(id: Int, _ continuation: CheckedContinuation<[String: Any], Error>) {
            self.id = id
            self.continuation = continuation
        }
    }

    private init() {}

    // MARK: - Paths

    /// Directory holding bridge.py. Checks the executable's ancestors first so
    /// the built product can live inside MyHomeApp/ and still find the repo.
    public static func bridgeDirectory() -> URL {
        let manager = FileManager.default
        var candidates: [URL] = []

        if let override = ProcessInfo.processInfo.environment["MYHOME_BRIDGE_DIR"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }

        if let executable = Bundle.main.executableURL {
            var directory = executable.deletingLastPathComponent()
            for _ in 0..<7 {
                candidates.append(directory)
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }

        candidates.append(URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true))
        candidates.append(manager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/myhome", isDirectory: true))

        for candidate in candidates {
            let script = candidate.appendingPathComponent("bridge.py")
            if manager.fileExists(atPath: script.path) {
                return candidate
            }
        }
        return candidates.last ?? URL(fileURLWithPath: manager.currentDirectoryPath)
    }

    /// Resources directory of a bundle that carries an embedded bridge.
    ///
    /// General rule: an embedded bridge wins whenever those resources exist,
    /// regardless of where the .app sits on disk — a copied bundle in /tmp or
    /// a user's Applications folder behaves exactly like the built one. The
    /// running bundle is the default; MYHOME_APP_BUNDLE lets a test harness
    /// point at another bundle (e.g. a copied one) without moving the binary.
    public static func bundledResourcesDirectory() -> URL? {
        let manager = FileManager.default
        let resources: URL?
        if let override = ProcessInfo.processInfo.environment["MYHOME_APP_BUNDLE"], !override.isEmpty {
            let root = URL(fileURLWithPath: override, isDirectory: true)
            let nested = root.appendingPathComponent("Contents/Resources", isDirectory: true)
            let probe = nested.appendingPathComponent("bridge-runtime/bin/python3")
            resources = manager.fileExists(atPath: probe.path) ? nested : root
        } else {
            resources = Bundle.main.resourceURL
        }

        guard let resources = resources else { return nil }
        let python = resources.appendingPathComponent("bridge-runtime/bin/python3")
        let script = resources.appendingPathComponent("bridge/bridge.py")
        guard manager.isExecutableFile(atPath: python.path),
              manager.fileExists(atPath: script.path) else {
            return nil
        }
        return resources
    }

    /// Writable directory the bridge keeps devices.json/tinytuya.json in when
    /// it runs from a bundle. The bundle is read-only and relocatable, so
    /// config belongs in Application Support; an explicit override wins.
    static func bundledDataDirectory() -> URL? {
        let manager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["MYHOME_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = support.appendingPathComponent("MyHome", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Public API

    public func ping() async throws -> Bool {
        let reply = try await request(["cmd": "ping"])
        return reply["ok"] as? Bool == true
    }

    public func request(_ payload: [String: Any], timeout: TimeInterval = 6) async throws -> [String: Any] {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.ensureRunningLocked()
                    let reqId = self.nextRequestId
                    self.nextRequestId = reqId >= Int.max ? 1 : reqId + 1
                    var stamped = payload
                    stamped["reqId"] = reqId
                    var line = try JSONSerialization.data(withJSONObject: stamped)
                    line.append(0x0A)
                    let entry = Pending(id: reqId, continuation)
                    self.pending.append(entry)
                    try self.input?.write(contentsOf: line)
                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        guard !entry.finished else { return }
                        // A hung handler is now isolated to its own request:
                        // the bridge stays responsive for the other in-flight
                        // requests, so never tear the process down here.
                        self.log("request timed out after \(timeout)s — failing that request only")
                        self.completeLocked(entry, .failure(BridgeError.timeout))
                    }
                } catch {
                    continuation.resume(throwing: error)
                    self.resetLocked()
                }
            }
        }
    }

    /// Terminates the bridge process. Used by the app on quit.
    public func stop() {
        queue.sync {
            self.resetLocked()
        }
    }

    // MARK: - Process lifecycle

    private func ensureRunningLocked() throws {
        if let process = process, process.isRunning {
            return
        }
        resetLocked()

        var environment = ProcessInfo.processInfo.environment
        let executable: URL
        let arguments: [String]
        let workingDirectory: URL

        if let resources = BridgeClient.bundledResourcesDirectory() {
            // Embedded runtime first: the bundle is self-contained, so never
            // depend on a repo checkout or a system python.
            executable = resources.appendingPathComponent("bridge-runtime/bin/python3")
            workingDirectory = resources.appendingPathComponent("bridge", isDirectory: true)
            arguments = [workingDirectory.appendingPathComponent("bridge.py").path]
            if let dataDirectory = BridgeClient.bundledDataDirectory() {
                environment["MYHOME_DATA_DIR"] = dataDirectory.path
            }
            // Keep the signed bundle immutable: bytecode caches written beside
            // the bridge script would invalidate its code signature.
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
        } else {
            let directory = BridgeClient.bridgeDirectory()
            let script = directory.appendingPathComponent("bridge.py")
            let venvPython = directory.appendingPathComponent(".venv/bin/python")

            guard fileManager.fileExists(atPath: script.path) else {
                throw BridgeError.unavailable("bridge.py not found at \(script.path)")
            }

            if fileManager.isExecutableFile(atPath: venvPython.path) {
                executable = venvPython
                arguments = [script.path]
            } else {
                executable = URL(fileURLWithPath: "/usr/bin/env")
                arguments = ["python3", script.path]
            }
            workingDirectory = directory
        }

        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.currentDirectoryURL = workingDirectory
        task.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        task.standardInput = stdinPipe
        task.standardOutput = stdoutPipe
        // Bridge stderr used to go to a black hole — every diagnostic was
        // unreadable. Tee it to a capped log file instead.
        let stderrPipe = Pipe()
        task.standardError = stderrPipe
        teeStderr(stderrPipe.fileHandleForReading)

        log("spawned bridge: \(executable.path)")

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self = self else { return }
            self.queue.async {
                self.consumeLocked(data)
            }
        }
        task.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            self.queue.async {
                self.handleTerminationLocked()
            }
        }

        do {
            try task.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            throw BridgeError.unavailable("Could not start bridge: \(error.localizedDescription)")
        }

        process = task
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        buffer.removeAll(keepingCapacity: true)
    }

    // MARK: - Bridge log file
    //
    // General rule: every spawn, kill, timeout and exit is appended to a
    // capped log, and the bridge's stderr is teed into the same file — when
    // something breaks, there must be something to read.

    private let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MyHome-bridge.log")
    }()

    private let logMaxBytes = 512 * 1024

    /// Appends one line to ~/Library/Logs/MyHome-bridge.log, truncating to the
    /// last ~256KB when the cap is exceeded.
    private func log(_ message: String) {
        let line = "\(Date())  \(message)\n"
        let fm = FileManager.default
        // FileHandle(forWritingAtPath:) returns nil for a missing file, so the
        // log never existed. Create it before the cap check opens it.
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: Data())
        }
        if let data = fm.contents(atPath: logURL.path), data.count > logMaxBytes {
            let tail = data.suffix(logMaxBytes / 2)
            try? tail.write(to: logURL)
        }
        if let handle = FileHandle(forWritingAtPath: logURL.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }

    /// Streams bridge stderr into the log file, capped the same way.
    private func teeStderr(_ handle: FileHandle) {
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else {
                fh.readabilityHandler = nil
                return
            }
            let logURL = self.logURL
            let logMaxBytes = self.logMaxBytes
            let fm = FileManager.default
            if !fm.fileExists(atPath: logURL.path) {
                fm.createFile(atPath: logURL.path, contents: Data())
            }
            if let existing = try? Data(contentsOf: logURL), existing.count > logMaxBytes {
                try? existing.suffix(logMaxBytes / 2).write(to: logURL)
            }
            if let out = FileHandle(forWritingAtPath: logURL.path) {
                out.seekToEndOfFile()
                out.write(data)
                try? out.close()
            }
        }
    }

    private func handleTerminationLocked() {
        guard process != nil else { return }
        log("bridge exited unexpectedly — failing pending requests and resetting")
        failAllLocked(BridgeError.unavailable("The bridge process exited."))
        resetLocked()
    }

    private func resetLocked() {
        output?.readabilityHandler = nil
        if let task = process {
            task.terminationHandler = nil
            if task.isRunning {
                task.terminate()
            }
        }
        try? input?.close()
        input = nil
        process = nil
        output = nil
        buffer.removeAll(keepingCapacity: true)
    }

    // MARK: - Response handling

    private func consumeLocked(_ data: Data) {
        if data.isEmpty {
            failAllLocked(BridgeError.unavailable("The bridge closed its output."))
            resetLocked()
            return
        }

        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !lineData.isEmpty else { continue }

            do {
                guard let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    throw BridgeError.badResponse("expected a JSON object")
                }
                // Id-matched completion: replies may land out of order.
                // Legacy bridges omit reqId; those still complete FIFO.
                let entry = (object["reqId"] as? Int).flatMap { reqId in
                    pending.first { $0.id == reqId }
                } ?? (object["reqId"] == nil ? pending.first : nil)
                guard let entry = entry else { continue }
                completeLocked(entry, .success(object))
            } catch {
                guard let entry = pending.first else { continue }
                completeLocked(entry, .failure(BridgeError.badResponse(error.localizedDescription)))
            }
        }
    }

    private func completeLocked(_ entry: Pending, _ result: Result<[String: Any], Error>) {
        guard !entry.finished else { return }
        entry.finished = true
        pending.removeAll { $0 === entry }
        entry.continuation.resume(with: result)
    }

    private func failAllLocked(_ error: Error) {
        let entries = pending
        pending.removeAll()
        for entry in entries where !entry.finished {
            entry.finished = true
            entry.continuation.resume(throwing: error)
        }
    }
}
