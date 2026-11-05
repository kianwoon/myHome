// Jev decisions client — a Swift port of opencode's jev client (jev.md §2;
// packages/core/src/jev/client.ts). Jev is a CHOICE CLASSIFIER: it answers
// named choice questions with a label and per-label probabilities. It never
// plans and never authorizes anything; every failure path fails OPEN (the
// caller keeps the rule parser's answer and asks the user).
//
//   POST <endpoint>  Authorization: Bearer <key>
//   {"model": "<id>", "state": "<text>", "questions": {<id>: {type, instructions, criteria}}}
//   -> {"model": "<id echo>", "answers": {<id>: {type, choice, probabilities, confidence}}, "usage": {…}}
//
// Contract rules kept here: an envelope without a non-empty `model` string is
// not a decision response (fail open); rows are read from `answers`, then
// `decisions`, then `results`; the gate is probabilities[choice] (never
// `confidence`), at max(threshold, 0.3 floor); a choice row whose probability
// map lacks the chosen label is UNMEASURED, never a fabricated 1 or 0.
// Retries: network error / timeout / 429 / 5xx only, 3 attempts, 200 ms then
// 600 ms. The key is sent only as a header to the configured host, redirects
// are refused, plain http is allowed for localhost only, and no error string
// ever quotes a response body or the key.
import CoreFoundation
import Foundation

// MARK: - Transport

/// One HTTP exchange. The app uses URLSession; tests inject a closure.
public protocol JevTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

private final class JevNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)   // never forward the key to a redirect target
    }
}

public struct URLSessionJevTransport: JevTransport, @unchecked Sendable {
    private let session: URLSession

    /// Ephemeral (no cookies/cache), no redirects.
    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: JevNoRedirectDelegate(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Test/stub transport driven by a closure.
public struct ClosureJevTransport: JevTransport {
    private let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public init(_ handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.handler = handler
    }
    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) { try await handler(request) }
}

// MARK: - Wire types

public struct JevQuestion: Equatable, Sendable {
    public var instructions: String
    /// label → description (choice questions take a record, never an array).
    public var criteria: [String: String]

    public init(instructions: String, criteria: [String: String]) {
        self.instructions = instructions
        self.criteria = criteria
    }

    var json: [String: Any] { ["type": "choice", "instructions": instructions, "criteria": criteria] }
}

/// Why a row cannot be used (TS `JevUnavailableReason`).
public enum JevUnavailableReason: String, Equatable, Sendable {
    case missing, malformed, unmeasured
}

/// One parsed answer row (TS `parseJevAnswer`, choice and noul rows).
public enum JevRow: Equatable, Sendable {
    case choice(choice: String, probability: Double, probabilities: [String: Double], confidence: Double?)
    case noul(Double)
    case unavailable(JevUnavailableReason)
}

/// The three-outcome fold (TS `foldController` vocabulary).
public enum JevVerdict: Equatable, Sendable {
    case accepted(label: String, strength: Double)
    /// Measured but weak: the labels the model leaned to, strongest first.
    case belowGate(label: String, strength: Double, ranked: [String])
    case unmeasured(String)
}

/// A call that produced no usable envelope. Messages never quote a body or the key.
public enum JevFailure: Error, Equatable, Sendable {
    case notConfigured(String)
    case network(String)
    case http(Int)
    /// 401/403: the server's own short `error.message` (key-scrubbed, capped), if it sent one.
    case rejected(Int, String?)
    case notDecision
    case unreadable
    case cancelled

    public var message: String {
        switch self {
        case .notConfigured(let text): return text
        case .network(let text): return text
        case .http(let code): return JevClient.statusMessage(code)
        case .rejected(let code, let server):
            guard let server, !server.isEmpty else { return JevClient.statusMessage(code) }
            return JevClient.statusMessage(code) + ": \(server)"
        case .notDecision: return "the reply was not a decision response (no model echo)"
        case .unreadable: return "the decision reply could not be read"
        case .cancelled: return "cancelled"
        }
    }
}

public struct JevAnswers: Sendable {
    /// The envelope's `model` echo (the transport marker).
    public let model: String
    public let rows: [String: JevRow]
}

// MARK: - Client

public struct JevClient: Sendable {
    public struct Config: Equatable, Sendable {
        public var endpoint: String
        public var model: String
        public var threshold: Double
        public var timeout: TimeInterval
        public var maxAttempts: Int
        public var backoffs: [TimeInterval]

        public init(endpoint: String = AppSettings.defaultJevEndpoint, model: String, threshold: Double = AppSettings.defaultJevThreshold,
                    timeout: TimeInterval = AppSettings.defaultJevTimeout, maxAttempts: Int = AppSettings.jevMaxAttempts,
                    backoffs: [TimeInterval] = AppSettings.jevRetryBackoffs) {
            self.endpoint = endpoint
            self.model = AppSettings.jevWireModel(model)
            self.threshold = AppSettings.clampedJevThreshold(threshold)
            self.timeout = timeout
            self.maxAttempts = max(1, maxAttempts)
            self.backoffs = backoffs
        }

        public static func fromDefaults(_ defaults: UserDefaults) -> Config {
            Config(endpoint: AppSettings.jevEndpoint(from: defaults), model: AppSettings.jevModel(from: defaults),
                   threshold: AppSettings.jevThreshold(from: defaults), timeout: AppSettings.jevTimeout(from: defaults))
        }

        /// The accept bar: the threshold, never below the confidence floor.
        public var gate: Double { max(threshold, AppSettings.jevConfidenceFloor) }
    }

    public let config: Config
    private let key: String?
    private let transport: JevTransport
    /// How the key was resolved (diagnostics only; nil when the caller passed a bare key).
    private let resolved: ResolvedSecret?

    public init(config: Config, key: String?, transport: JevTransport, resolved: ResolvedSecret? = nil) {
        self.config = config
        self.key = key
        self.transport = transport
        self.resolved = resolved
    }

    public init(config: Config, secret: ResolvedSecret, transport: JevTransport) {
        self.init(config: config, key: secret.value, transport: transport, resolved: secret)
    }

    /// Keychain first, then the environment fallback (never another app's files).
    public static func resolveKey(secrets: SecretStore, environment: [String: String]) -> String? {
        resolveSecret(secrets: secrets, environment: environment).value
    }

    /// Same resolution, keeping source/length/Keychain status for diagnostics.
    public static func resolveSecret(secrets: SecretStore, environment: [String: String]) -> ResolvedSecret {
        ResolvedSecret.resolve(secrets: secrets, account: AppSettings.jevSecretAccount,
                               environmentValue: environment[AppSettings.jevKeyEnvironmentVariable])
    }

    /// Why no call can be made (nil when ready).
    public static func problem(with config: Config, key: String?) -> String? {
        if config.model.isEmpty { return "choose a Jev model in Settings → Assistant" }
        guard let url = endpointURL(config.endpoint) else { return "the Jev endpoint must be https (http is only allowed for localhost)" }
        let local = AppSettings.plainHTTPHosts.contains(url.host?.lowercased() ?? "")
        if !local, (key ?? "").isEmpty { return "add a Jev API key in Settings → Assistant" }
        return nil
    }

    static func endpointURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        guard scheme == "https" || (scheme == "http" && AppSettings.plainHTTPHosts.contains(host)) else { return nil }
        return url
    }

    func buildRequest(state: String, questions: [String: JevQuestion]) throws -> URLRequest {
        guard let url = Self.endpointURL(config.endpoint) else { throw JevFailure.notConfigured("invalid Jev endpoint") }
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(AppSettings.jevReferer, forHTTPHeaderField: "http-referer")
        request.setValue(AppSettings.jevAppTitle, forHTTPHeaderField: "x-title")
        if let key, !key.isEmpty {
            // CR/LF or control characters in a header make the service see no Authorization at all.
            guard APIKeySanitizer.isHeaderSafe(key) else { throw JevFailure.notConfigured("the API key contains characters that cannot be sent in a header") }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        }
        let body: [String: Any] = ["model": config.model, "state": state, "questions": questions.mapValues(\.json)]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    // MARK: Call

    private enum Attempt: @unchecked Sendable {
        case response(Data, Int)
        case network(URLError?)
        case notHTTP
    }

    /// One decisions call with bounded retry. Fails open: `.failure` never authorizes anything.
    public func ask(state: String, questions: [String: JevQuestion]) async -> Result<JevAnswers, JevFailure> {
        // A saved-but-malformed key is reported precisely and nothing is sent.
        if resolved?.invalid != nil, let message = resolved?.missingMessage { return .failure(.notConfigured(message)) }
        if let problem = Self.problem(with: config, key: key) { return .failure(.notConfigured(problem)) }
        let request: URLRequest
        do { request = try buildRequest(state: state, questions: questions) }
        catch let failure as JevFailure { return .failure(failure) }
        catch { return .failure(.notConfigured("the Jev request could not be built")) }
        var last: JevFailure = .network("the Jev service did not answer")
        let transport = self.transport
        for attempt in 0..<config.maxAttempts {
            if attempt > 0, !config.backoffs.isEmpty {
                let delay = config.backoffs[min(attempt - 1, config.backoffs.count - 1)]
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            }
            if Task.isCancelled { return .failure(.cancelled) }
            // Per-attempt TOTAL bound (URLRequest.timeoutInterval is an idle timeout).
            let outcome = await Deadline.run(seconds: config.timeout) { () -> Attempt in
                do {
                    let (data, response) = try await transport.send(request)
                    guard let http = response as? HTTPURLResponse else { return .notHTTP }
                    return .response(data, http.statusCode)
                } catch {
                    return .network(error as? URLError)
                }
            }
            if Task.isCancelled { return .failure(.cancelled) }
            switch outcome {
            case nil:
                last = .network("the Jev service did not answer in time")
                AppLog.assistant.info("jev attempt \(attempt + 1, privacy: .public) timed out")
            case .network(let error)?:
                last = .network(error.map(Self.networkMessage(for:)) ?? "network error")
                AppLog.assistant.info("jev attempt \(attempt + 1, privacy: .public) network error")
            case .notHTTP?:
                return .failure(.unreadable)
            case .response(let data, let status)?:
                if status == 429 || status >= 500 {
                    last = .http(status)
                    AppLog.assistant.info("jev attempt \(attempt + 1, privacy: .public) HTTP \(status, privacy: .public)")
                    continue
                }
                // Any other status is the endpoint's real answer: no retry, body never quoted.
                if status == 401 || status == 403 {
                    let server = Self.serverMessage(in: data, scrubbing: key)
                    AppLog.assistant.info("jev rejected: HTTP \(status, privacy: .public) \(self.resolved?.logSummary ?? "key=unknown", privacy: .public)")
                    return .failure(.rejected(status, server))
                }
                guard (200..<300).contains(status) else { return .failure(.http(status)) }
                return Self.parseEnvelope(data)
            }
        }
        return .failure(last)
    }

    /// The server's short `{"error":{"message":…}}` text, with the key scrubbed. Anything else is not quoted.
    static func serverMessage(in data: Data, scrubbing key: String?) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = root["error"] as? [String: Any], var text = error["message"] as? String else { return nil }
        text = String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
        if let key, !key.isEmpty { text = text.replacingOccurrences(of: key, with: "[key]") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(AppSettings.jevServerMessageMax))
    }

    /// Proves endpoint, key and model together with a minimal two-option choice.
    public func testConnection() async -> String {
        if let resolved, let missing = resolved.missingMessage, resolved.invalid != nil || !Self.isLocalEndpoint(config.endpoint) {
            AppLog.assistant.info("jev test: no key \(resolved.logSummary, privacy: .public)")
            return resolved.invalid == nil ? missing : "\(missing). \(resolved.shapeDescription(expecting: .openRouter))"
        }
        let question = JevQuestion(instructions: Self.pingInstructions, criteria: Self.pingCriteria)
        switch await ask(state: Self.pingState, questions: [Self.pingID: question]) {
        case .success(let answers):
            switch answers.rows[Self.pingID] {
            case .choice?: return "Connected: \(answers.model) answered."
            default: return "Connected to \(answers.model), but its answer had no measured choice."
            }
        case .failure(let failure):
            if let resolved { AppLog.assistant.info("jev test failed: \(resolved.logSummary, privacy: .public)") }
            if case .rejected = failure, let resolved, resolved.value != nil {
                return "\(resolved.sentDescription), service rejected it: \(failure.message). \(resolved.shapeDescription(expecting: .openRouter))"
            }
            return failure.message
        }
    }

    static func isLocalEndpoint(_ text: String) -> Bool {
        guard let url = endpointURL(text) else { return false }
        return AppSettings.plainHTTPHosts.contains(url.host?.lowercased() ?? "")
    }

    // allow-hardcode: the connectivity probe question (two options = the contract minimum).
    static let pingID = "ping"
    static let pingState = "Connectivity check from the MyHome app."
    static let pingInstructions = "Is this message a connectivity check?"
    static let pingCriteria = ["yes": "The message is a connectivity check.", "no": "The message is something else."]

    static func statusMessage(_ code: Int) -> String {
        switch code {
        case 401, 403: return "the Jev service rejected the API key (HTTP \(code))"
        case 404: return "the Jev service does not know that URL or model (HTTP 404)"
        case 429: return "the Jev service is rate limiting requests (HTTP 429)"
        case 500...599: return "the Jev service had a server error (HTTP \(code))"
        default: return "the Jev service returned HTTP \(code)"
        }
    }

    static func networkMessage(for error: URLError) -> String {
        switch error.code {
        case .timedOut: return "the Jev service did not answer in time"
        case .notConnectedToInternet, .networkConnectionLost: return "no network connection"
        case .cannotFindHost, .cannotConnectToHost: return "could not reach the Jev service"
        default: return "network error \(error.code.rawValue)"
        }
    }

    // MARK: Parsing (static so tests drive them directly)

    /// Envelope rule: non-empty `model` first, then rows under answers → decisions → results.
    public static func parseEnvelope(_ data: Data) -> Result<JevAnswers, JevFailure> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.unreadable) }
        guard let model = root["model"] as? String, !model.isEmpty else { return .failure(.notDecision) }
        guard let raw = (root["answers"] as? [String: Any]) ?? (root["decisions"] as? [String: Any]) ?? (root["results"] as? [String: Any]) else {
            return .failure(.unreadable)
        }
        return .success(JevAnswers(model: model, rows: raw.mapValues(parseRow)))
    }

    /// TS `parseJevAnswer` for choice/noul rows; an explicit unknown or mixed type is never guessed.
    public static func parseRow(_ value: Any?) -> JevRow {
        guard let value, !(value is NSNull) else { return .unavailable(.missing) }
        guard let row = value as? [String: Any] else { return .unavailable(.malformed) }
        let legacyKeys = ["choice", "answer", "value", "label", "decision"]
        if let type = row["type"] {
            switch type as? String {
            case "choice":
                if row["score"] != nil || row["noul"] != nil { return .unavailable(.malformed) }
                return parseChoice(row, row["choice"])
            case "noul":
                if row["score"] != nil || legacyKeys.contains(where: { row[$0] != nil }) { return .unavailable(.malformed) }
                return parseNoul(row)
            default:
                return .unavailable(.malformed)   // score rows are not asked here; unknown types are never guessed
            }
        }
        if let legacy = row["choice"] ?? row["answer"] ?? row["value"] ?? row["label"] ?? row["decision"] {
            return parseChoice(row, legacy)
        }
        if row["noul"] != nil { return parseNoul(row) }
        return .unavailable(.malformed)
    }

    private static func parseChoice(_ row: [String: Any], _ rawChoice: Any?) -> JevRow {
        guard let choice = rawChoice as? String, !choice.trimmingCharacters(in: .whitespaces).isEmpty else { return .unavailable(.malformed) }
        guard let raw = row["probabilities"] as? [String: Any], raw.keys.contains(choice) else { return .unavailable(.unmeasured) }
        guard let selected = number(raw[choice]) else { return .unavailable(.malformed) }
        var probabilities: [String: Double] = [:]
        for (label, value) in raw { if let n = number(value) { probabilities[label] = n } }
        return .choice(choice: choice, probability: selected, probabilities: probabilities, confidence: number(row["confidence"]))
    }

    private static func parseNoul(_ row: [String: Any]) -> JevRow {
        guard let noul = number(row["noul"]), (0...1).contains(noul) else { return .unavailable(.malformed) }
        return .noul(noul)
    }

    /// A finite JSON number; a JSON boolean never stands in for 1/0.
    static func number(_ value: Any?) -> Double? {
        guard let value, let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// Gate one row against the labels that were offered. An unknown label is
    /// UNMEASURED (never below-gate, never accepted); `confidence` is ignored.
    public static func fold(_ row: JevRow?, labels: [String], threshold: Double) -> JevVerdict {
        let gate = max(AppSettings.clampedJevThreshold(threshold), AppSettings.jevConfidenceFloor)
        guard let row else { return .unmeasured("no answer for the question") }
        switch row {
        case .unavailable(let reason):
            return .unmeasured("answer \(reason.rawValue)")
        case .noul:
            return .unmeasured("answer was not a choice")
        case .choice(let choice, let probability, let probabilities, _):
            guard labels.contains(choice) else { return .unmeasured("answer named an option that was not offered") }
            guard probability >= gate else {
                let ranked = labels.filter { probabilities[$0] != nil }
                    .sorted { (probabilities[$0] ?? 0) > (probabilities[$1] ?? 0) }
                return .belowGate(label: choice, strength: probability, ranked: ranked.isEmpty ? [choice] : ranked)
            }
            return .accepted(label: choice, strength: probability)
        }
    }
}
