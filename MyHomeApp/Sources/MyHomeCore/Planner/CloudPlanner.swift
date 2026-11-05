// Level-2 planner on a cloud LLM (Anthropic Messages API or any OpenAI-
// compatible chat-completions server, including local ones). Same contract as
// the on-device planner: THE MODEL ONLY PROPOSES a plan from a compact device
// catalogue; the coordinator validates every handle, DeviceController applies
// policy, and the user confirms before anything runs.
//
// Privacy: the request carries the command plus device and room NAMES, kinds,
// capabilities and current on/off state + level (no ids, no credentials). The API key lives in
// the Keychain, is sent only to the configured host as a header, and is
// scrubbed from every error string. Plain http is allowed for localhost only.
import Foundation

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)   // never forward the key to a redirect target
    }
}

@MainActor
public final class CloudPlanner: NaturalLanguagePlanner {
    /// Everything one request needs, snapshotted from settings.
    struct Config: Equatable {
        var provider: AppSettings.PlannerProvider
        var baseURL: String
        var model: String
        var apiVersion: String
        var maxTokens: Int
        var timeout: TimeInterval
        var catalogueBudget: Int
        var maxDevices: Int
        var toolOutputBudget: Int
        var instructions: String

        static func fromDefaults(_ defaults: UserDefaults, provider: AppSettings.PlannerProvider) -> Config {
            Config(provider: provider,
                   baseURL: AppSettings.plannerBaseURL(for: provider, from: defaults),
                   model: AppSettings.plannerModel(for: provider, from: defaults),
                   apiVersion: AppSettings.anthropicAPIVersion(from: defaults),
                   maxTokens: AppSettings.plannerMaxTokens(from: defaults),
                   timeout: AppSettings.plannerTimeout(from: defaults),
                   catalogueBudget: AppSettings.cloudCatalogueBudget(from: defaults),
                   maxDevices: AppSettings.cloudMaxDevices(from: defaults),
                   toolOutputBudget: AppSettings.plannerToolOutputBudget(from: defaults),
                   instructions: AppSettings.plannerInstructions(from: defaults, fallback: CloudPlanner.defaultInstructions))
        }
    }

    // allow-hardcode: the model prompt (reviewed guidance; AppSettings.plannerInstructions overrides it).
    public nonisolated static let defaultInstructions = PlannerPersona.housekeeper + """

    Use only device handles (like d3) from the list.
    If the request is ambiguous, impossible, or names nothing in the list, return no actions and ask a short question in clarification.
    Levels are percents 0-100; fan speeds are gear numbers. Do not add actions that were not asked for.
    """

    private let controller: DeviceController
    private let defaults: UserDefaults
    private let secrets: SecretStore
    private let session: URLSession

    public init(controller: DeviceController, defaults: UserDefaults = .standard,
                secrets: SecretStore = KeychainSecretStore(), session: URLSession = CloudPlanner.makeSession()) {
        self.controller = controller
        self.defaults = defaults
        self.secrets = secrets
        self.session = session
    }

    /// Ephemeral (no cookies/cache), no redirects.
    public nonisolated static func makeSession() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// Keychain read with its status kept (never swallowed) for diagnostics.
    private func resolvedKey(for provider: AppSettings.PlannerProvider) -> ResolvedSecret {
        ResolvedSecret.resolve(secrets: secrets, account: AppSettings.plannerSecretAccount(for: provider))
    }

    private var provider: AppSettings.PlannerProvider {
        let chosen = AppSettings.plannerProvider(from: defaults)
        return chosen.isCloud ? chosen : .openAICompatible
    }

    private var config: Config { Config.fromDefaults(defaults, provider: provider) }

    public var isAvailable: Bool { unavailableReason == nil }

    public var unavailableReason: String? {
        let secret = resolvedKey(for: provider)
        if let invalid = secret.missingMessage, secret.invalid != nil { return invalid }
        return Self.problem(with: config, key: secret.value)
    }

    // MARK: - Planning

    public func plan(_ utterance: String, devices: [DeviceSummary]) async throws -> ProposedPlan {
        let config = self.config
        let secret = resolvedKey(for: config.provider)
        let key = secret.value
        if secret.invalid != nil, let message = secret.missingMessage { throw PlannerError.unavailable(message) }
        if let problem = Self.problem(with: config, key: key) { throw PlannerError.unavailable(problem) }
        let catalogue = PlannerCatalogue(devices: devices, utterance: utterance, budget: config.catalogueBudget,
                                         maxDevices: config.maxDevices, toolOutputBudget: config.toolOutputBudget)
        let user = "Devices (\(PlannerCatalogue.columns)):\n\(catalogue.render())\n\nRequest: \(utterance)"
        let text = try await Self.complete(config: config, key: key, system: Self.systemPrompt(config.instructions), user: user, session: session)
        let payload = try Self.decodePlan(text)
        return PlanConverter.convert(payload, resolveDevice: catalogue.id(forHandle:))
    }

    /// One tiny request that proves URL, key and model work together.
    public func testConnection() async -> String {
        let config = self.config
        let secret = resolvedKey(for: config.provider)
        let key = secret.value
        let shape = Self.expectedShape(for: config)
        if secret.invalid != nil, let message = secret.missingMessage {
            AppLog.assistant.info("planner test: invalid key \(secret.logSummary, privacy: .public)")
            return "\(message). \(secret.shapeDescription(expecting: shape))"
        }
        if let problem = Self.problem(with: config, key: key) {
            AppLog.assistant.info("planner test: no key \(secret.logSummary, privacy: .public)")
            return secret.missingMessage ?? problem
        }
        var small = config
        small.maxTokens = AppSettings.plannerMaxTokensRange.lowerBound
        do {
            _ = try await Self.complete(config: small, key: key, system: "Reply with the single word OK.", user: "ping", session: session)
            return "Connected: \(config.model) replied. \(await toolProbeSummary())"
        } catch PlannerError.failed(let text) where text == Self.outOfTokensMessage || text == Self.emptyReplyMessage {
            // The tiny probe budget can be eaten by a reasoning model; the provider and key still worked.
            return "Connected: \(config.model) answered (\(text)). \(await toolProbeSummary())"
        } catch PlannerError.failed(let text) {
            AppLog.assistant.info("planner test failed: \(secret.logSummary, privacy: .public)")
            guard text.contains("rejected the API key") else { return text }
            let message = "\(secret.sentDescription), \(text). \(secret.shapeDescription(expecting: shape))"
            // 401/403 from OpenRouter itself: ask it once what kind of key this is.
            if let key, !key.isEmpty, config.provider != .anthropic, let url = try? Self.endpoint(for: config), OpenRouterKeyInfo.isOpenRouter(url) {
                let probeSession = URLSession(configuration: session.configuration, delegate: JevNoRedirectDelegate(), delegateQueue: nil)
                defer { probeSession.finishTasksAndInvalidate() }
                if let verdict = await OpenRouterKeyInfo.probe(key: key, timeout: config.timeout, transport: URLSessionJevTransport(session: probeSession)) {
                    return OpenRouterKeyInfo.refine(message, verdict: verdict, sent: secret.sentDescription, service: "the provider")
                }
            }
            return message
        } catch {
            return Self.scrub(error.localizedDescription, key: key)
        }
    }

    /// How the housekeeper's tool calls travel through this provider: the
    /// recorded probe, or a fresh one when none was recorded for this model.
    private func toolProbeSummary() async -> String {
        let config = self.config
        if defaults.string(forKey: AppSettings.housekeeperProbedModelKey) == config.model,
           let summary = AppSettings.housekeeperProbeSummary(from: defaults) { return summary + "." }
        return await AgentToolProbe.runAndRecord(defaults: defaults, secrets: secrets, session: session).summary
    }

    // MARK: - Request / response (static so tests can drive them directly)

    /// The key shape a provider/base URL pair expects (diagnostics only).
    static func expectedShape(for config: Config) -> KeyShapeClass {
        if config.provider == .anthropic { return .anthropic }
        return config.baseURL.lowercased().contains("openrouter") ? .openRouter : .openAI   // allow-hardcode: host marker
    }

    static func problem(with config: Config, key: String?) -> String? {
        if config.model.isEmpty { return "choose a model name in Settings → Assistant" }
        guard (try? endpoint(for: config)) != nil else { return "the base URL must be https (http is only allowed for localhost)" }
        let needsKey = config.provider == .anthropic || !isLocal(config.baseURL)
        if needsKey, (key ?? "").isEmpty { return "add an API key in Settings → Assistant" }
        return nil
    }

    private static func isLocal(_ base: String) -> Bool {
        guard let host = URL(string: base)?.host else { return false }
        return AppSettings.plainHTTPHosts.contains(host.lowercased())
    }

    static func endpoint(for config: Config) throws -> URL {
        let path = config.provider == .anthropic ? AppSettings.anthropicMessagesPath : AppSettings.openAIChatPath
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path), let scheme = url.scheme?.lowercased(), let host = url.host else {
            throw PlannerError.unavailable("invalid base URL")
        }
        guard scheme == "https" || (scheme == "http" && AppSettings.plainHTTPHosts.contains(host.lowercased())) else {
            throw PlannerError.unavailable("insecure base URL")
        }
        return url
    }

    static func systemPrompt(_ instructions: String) -> String {
        let actions = PlanConverter.actionNames.joined(separator: "|")
        // allow-hardcode: the wire schema the model must answer with.
        return instructions + """


        Reply with ONLY a JSON object, no prose and no code fences:
        {"actions":[{"device":"<handle>","action":"<\(actions)>","value":<integer or null>,"mode":<string or null>,"color":<string or null>}],"summary":"<one short sentence>","clarification":"<question, or empty>"}
        """
    }

    static func buildRequest(config: Config, key: String?, system: String, user: String) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(for: config), timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any]
        switch config.provider {
        case .anthropic:
            if let key, !key.isEmpty, !APIKeySanitizer.isHeaderSafe(key) { throw PlannerError.unavailable("the API key contains characters that cannot be sent in a header") }
            request.setValue(key ?? "", forHTTPHeaderField: "x-api-key")
            request.setValue(config.apiVersion, forHTTPHeaderField: "anthropic-version")
            body = ["model": config.model, "max_tokens": config.maxTokens, "system": system,
                    "messages": [["role": "user", "content": user]]]
        default:
            if let key, !key.isEmpty {
                guard APIKeySanitizer.isHeaderSafe(key) else { throw PlannerError.unavailable("the API key contains characters that cannot be sent in a header") }
                request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
            }
            body = ["model": config.model, "max_completion_tokens": config.maxTokens,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func complete(config: Config, key: String?, system: String, user: String, session: URLSession) async throws -> String {
        let request = try buildRequest(config: config, key: key, system: system, user: user)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw PlannerError.failed(scrub(networkMessage(for: error), key: key))
        }
        guard let http = response as? HTTPURLResponse else { throw PlannerError.failed("the server sent no HTTP response") }
        // The body is never quoted: providers can echo (part of) the key in errors.
        guard (200..<300).contains(http.statusCode) else { throw PlannerError.failed(statusMessage(http.statusCode)) }
        return try readReply(data, provider: config.provider)
    }

    /// Provider-reported "ran out of tokens" markers (OpenAI / Anthropic).
    static let truncationReasons: Set<String> = ["length", "max_tokens"]
    static let thinkOpen = "<think>"
    static let thinkClose = "</think>"
    static let notJSONMessage = "the provider's reply was not JSON"
    static let emptyReplyMessage = "the model returned an empty reply"
    static let outOfTokensMessage = "the model ran out of tokens before answering; raise Max tokens in Settings → AI Models or pick a non-reasoning model"

    static func extractText(_ data: Data, provider: AppSettings.PlannerProvider) -> String? {
        try? readReply(data, provider: provider)
    }

    /// The reply text, or a key-free `PlannerError.failed` saying why there is none.
    static func readReply(_ data: Data, provider: AppSettings.PlannerProvider) throws -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            AppLog.assistant.info("planner reply was not a JSON object")
            throw PlannerError.failed(notJSONMessage)
        }
        let raw: String
        let finish: String?
        if provider == .anthropic {
            raw = contentText(root["content"])
            finish = root["stop_reason"] as? String
        } else {
            let choice = (root["choices"] as? [[String: Any]])?.first
            let message = choice?["message"] as? [String: Any]
            // Some servers answer in the legacy `text` field of the choice.
            raw = contentText(message?["content"]) .nonEmpty ?? contentText(choice?["text"])
            finish = choice?["finish_reason"] as? String
        }
        let text = stripThinking(raw)
        if !text.isEmpty { return text }
        let completion = ((root["usage"] as? [String: Any])?["completion_tokens"] ?? (root["usage"] as? [String: Any])?["output_tokens"]) as? Int
        AppLog.assistant.info("planner reply had no text: keys=\(root.keys.sorted().joined(separator: ","), privacy: .public) finish=\(finish ?? "none", privacy: .public) completion_tokens=\(completion.map(String.init) ?? "none", privacy: .public)")
        if let finish, truncationReasons.contains(finish) { throw PlannerError.failed(outOfTokensMessage) }
        throw PlannerError.failed(emptyReplyMessage)
    }

    /// `content` as a string, or an array of parts / {type:"text",text} objects joined.
    static func contentText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let parts = content as? [Any] else { return "" }
        return parts.compactMap { part -> String? in
            if let string = part as? String { return string }
            guard let object = part as? [String: Any] else { return nil }
            let type = object["type"] as? String
            return (type == nil || type == "text" || type == "output_text") ? object["text"] as? String : nil
        }.joined()
    }

    /// Drops hidden-reasoning `<think>…</think>` blocks (an unclosed one hides everything after it).
    static func stripThinking(_ text: String) -> String {
        var rest = text
        while let open = rest.range(of: thinkOpen) {
            if let close = rest.range(of: thinkClose, range: open.upperBound..<rest.endIndex) {
                rest.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                rest.removeSubrange(open.lowerBound..<rest.endIndex)
            }
        }
        // A stray closer (the opener was cut by the provider): keep what follows it.
        if let close = rest.range(of: thinkClose, options: .backwards) { rest = String(rest[close.upperBound...]) }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The model sometimes wraps JSON in prose or fences; take the outermost object.
    static func decodePlan(_ text: String) throws -> PlanPayload {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let payload = try? JSONDecoder().decode(PlanPayload.self, from: Data(text[start...end].utf8)) else {
            throw PlannerError.failed("the model's reply was not a valid plan")
        }
        return payload
    }

    static func statusMessage(_ code: Int) -> String {
        switch code {
        case 401, 403: return "the provider rejected the API key (HTTP \(code))"
        case 404: return "the provider does not know that URL or model (HTTP 404)"
        case 429: return "the provider is rate limiting requests (HTTP 429)"
        case 500...599: return "the provider had a server error (HTTP \(code))"
        default: return "the provider returned HTTP \(code)"
        }
    }

    static func networkMessage(for error: URLError) -> String {
        switch error.code {
        case .timedOut: return "the provider did not answer in time"
        case .notConnectedToInternet, .networkConnectionLost: return "no network connection"
        case .cannotFindHost, .cannotConnectToHost: return "could not reach the provider"
        default: return "network error \(error.code.rawValue)"
        }
    }

    static func scrub(_ text: String, key: String?) -> String {
        guard let key, !key.isEmpty else { return text }
        return text.replacingOccurrences(of: key, with: "•••")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
