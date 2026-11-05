// OpenRouter "provisioning" (management) keys pass a generic validity check but
// cannot make API calls: the decisions endpoint answers HTTP 401 "User not found".
// When a request to the OpenRouter host is rejected with 401/403, Test connection
// makes ONE follow-up GET to the key-info endpoint with the same key and says
// which kind of key it is. The key goes only to the OpenRouter host it was already
// being sent to (https, redirects refused, no retries); no body is ever logged
// or quoted, and any failure here leaves the original message unchanged.
import Foundation

enum OpenRouterKeyInfo {
    enum Verdict: Equatable, Sendable {
        case provisioning
        /// A normal API key; `usage` is OpenRouter's `data.usage` when it sent a number.
        case normal(usage: Double?)
        /// The key-info call itself answered 401.
        case invalid
    }

    /// https and exactly the configured OpenRouter host.
    static func isOpenRouter(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == AppSettings.openRouterHost
    }

    /// nil = unknown (timeout, network error, other status, malformed reply): keep the original message.
    static func probe(key: String, timeout: TimeInterval, transport: JevTransport) async -> Verdict? {
        guard APIKeySanitizer.isHeaderSafe(key), let url = URL(string: AppSettings.jevKeyInfoURL), isOpenRouter(url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let outcome = await Deadline.run(seconds: timeout) { () -> Verdict? in
            guard let (data, response) = try? await transport.send(request), let http = response as? HTTPURLResponse else { return nil }
            return verdict(status: http.statusCode, data: data)
        }
        let result = outcome ?? nil
        AppLog.assistant.info("openrouter key-info: \(describe(result), privacy: .public)")
        return result
    }

    static func verdict(status: Int, data: Data) -> Verdict? {
        if status == 401 { return .invalid }
        guard status == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let info = root["data"] as? [String: Any],
              let flag = info["is_provisioning_key"] as? NSNumber, CFGetTypeID(flag as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        if flag.boolValue { return .provisioning }
        return .normal(usage: JevClient.number(info["usage"]))
    }

    /// Replace (provisioning, invalid) or extend (normal) the original failure text.
    static func refine(_ original: String, verdict: Verdict, sent: String?, service: String) -> String {
        let prefix = sent.map { "\($0). " } ?? ""
        switch verdict {
        case .provisioning:
            return prefix + "This is an OpenRouter PROVISIONING key (it only manages other keys and cannot make requests). Create a normal API key (Create API Key, not provisioning) and save that one."
        case .invalid:
            return prefix + "OpenRouter says this key is invalid or deleted."
        case .normal(let usage):
            var text = original + " The key is a normal API key but \(service) does not accept it for this model/account."
            if let usage { text += " (OpenRouter usage for this key: \(usage).)" }
            return text
        }
    }

    private static func describe(_ verdict: Verdict?) -> String {
        switch verdict {
        case .provisioning?: return "provisioning=true"
        case .normal?: return "provisioning=false"
        case .invalid?: return "invalid"
        case nil: return "unknown"
        }
    }
}
