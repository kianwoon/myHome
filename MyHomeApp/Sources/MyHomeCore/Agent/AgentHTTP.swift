// The one HTTP exchange both cloud transports share: build the request from a
// CloudPlanner.Config (same endpoint rules, same header hygiene, same key
// resolution through SecretStore), send it, and turn failures into key-free
// AgentTransportError messages. Bodies are never quoted (a provider can echo
// the key in an error).
import Foundation

@MainActor
enum AgentHTTP {
    /// A cloud request's settings and key, resolved at call time (settings
    /// can change between turns; the key is never cached).
    @MainActor
    struct Context {
        let config: CloudPlanner.Config
        let key: String?
        let secret: ResolvedSecret

        static func resolve(defaults: UserDefaults, secrets: SecretStore) -> Context {
            let chosen = AppSettings.plannerProvider(from: defaults)
            let provider = chosen.isCloud ? chosen : .openAICompatible
            let secret = ResolvedSecret.resolve(secrets: secrets, account: AppSettings.plannerSecretAccount(for: provider))
            return Context(config: CloudPlanner.Config.fromDefaults(defaults, provider: provider), key: secret.value, secret: secret)
        }

        /// Why no request can be sent (missing/invalid key, bad URL, no model).
        var problem: String? {
            if secret.invalid != nil, let message = secret.missingMessage { return message }
            return CloudPlanner.problem(with: config, key: key)
        }
    }

    static func request(context: Context, body: [String: Any], timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: try CloudPlanner.endpoint(for: context.config), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let key = context.key
        if context.config.provider == .anthropic {
            if let key, !key.isEmpty, !APIKeySanitizer.isHeaderSafe(key) { throw AgentTransportError.unavailable("the API key contains characters that cannot be sent in a header") }
            request.setValue(key ?? "", forHTTPHeaderField: "x-api-key")
            request.setValue(context.config.apiVersion, forHTTPHeaderField: "anthropic-version")
        } else if let key, !key.isEmpty {
            guard APIKeySanitizer.isHeaderSafe(key) else { throw AgentTransportError.unavailable("the API key contains characters that cannot be sent in a header") }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Sends and returns the body of a 2xx reply as a JSON object.
    static func send(_ request: URLRequest, session: URLSession, key: String?) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw AgentTransportError.cancelled
        } catch let error as URLError {
            throw AgentTransportError.failed(CloudPlanner.scrub(CloudPlanner.networkMessage(for: error), key: key))
        } catch {
            if Task.isCancelled { throw AgentTransportError.cancelled }
            throw AgentTransportError.failed(CloudPlanner.scrub(error.localizedDescription, key: key))
        }
        guard let http = response as? HTTPURLResponse else { throw AgentTransportError.failed("the server sent no HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw Status(code: http.statusCode) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AgentTransportError.failed(CloudPlanner.notJSONMessage)
        }
        return root
    }

    /// A non-2xx reply (the body is deliberately not kept).
    @MainActor
    struct Status: Error {
        let code: Int
        var message: String { CloudPlanner.statusMessage(code) }
        /// Client errors are what a provider answers when it rejects `tools`.
        var mayBeToolRejection: Bool { (400..<500).contains(code) && code != 401 && code != 403 && code != 429 }
    }

    /// Token usage from either provider family.
    static func usage(from root: [String: Any]) -> AgentUsage? {
        guard let usage = root["usage"] as? [String: Any] else { return nil }
        let prompt = (usage["prompt_tokens"] ?? usage["input_tokens"]) as? Int
        let completion = (usage["completion_tokens"] ?? usage["output_tokens"]) as? Int
        return AgentUsage(promptTokens: prompt, completionTokens: completion)
    }
}
