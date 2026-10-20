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
/// The protocol is strictly serial, so replies are correlated with requests by
/// order. Every request has a 6 second timeout; a timeout tears the process
/// down so the next request starts from a clean protocol state.
public final class BridgeClient: @unchecked Sendable {
    public static let shared = BridgeClient()

    private let queue = DispatchQueue(label: "com.myhome.bridge")
    private let fileManager = FileManager.default

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var pending: [Pending] = []

    private final class Pending {
        let continuation: CheckedContinuation<[String: Any], Error>
        var finished = false

        init(_ continuation: CheckedContinuation<[String: Any], Error>) {
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

    // MARK: - Public API

    public func ping() async throws -> Bool {
        let reply = try await request(["cmd": "ping"])
        return reply["ok"] as? Bool == true
    }

    public func request(_ payload: [String: Any], timeout: TimeInterval = 6) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: payload)
        var line = body
        line.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.ensureRunningLocked()
                    let entry = Pending(continuation)
                    self.pending.append(entry)
                    try self.input?.write(contentsOf: line)
                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        guard !entry.finished else { return }
                        self.log("request timed out after \(timeout)s — resetting bridge")
                        self.completeLocked(entry, .failure(BridgeError.timeout))
                        self.resetLocked()
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

        let directory = BridgeClient.bridgeDirectory()
        let script = directory.appendingPathComponent("bridge.py")
        let venvPython = directory.appendingPathComponent(".venv/bin/python")

        guard fileManager.fileExists(atPath: script.path) else {
            throw BridgeError.unavailable("bridge.py not found at \(script.path)")
        }

        let executable: URL
        let arguments: [String]
        if fileManager.isExecutableFile(atPath: venvPython.path) {
            executable = venvPython
            arguments = [script.path]
        } else {
            executable = URL(fileURLWithPath: "/usr/bin/env")
            arguments = ["python3", script.path]
        }

        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.currentDirectoryURL = directory
        task.environment = ProcessInfo.processInfo.environment

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

            guard let entry = pending.first else { continue }
            pending.removeFirst()

            do {
                guard let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    throw BridgeError.badResponse("expected a JSON object")
                }
                completeLocked(entry, .success(object))
            } catch {
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
