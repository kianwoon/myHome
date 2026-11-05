// Tool calling over plain text, for providers or proxies that do not pass
// native function calls through. The tool list is rendered into the system
// prompt; the model emits one JSON object per line ({"tool":…,"arguments":…});
// results go back as a user message. Both transports use this when native
// tool calls are unavailable, and also to recover tool-call lines a model
// wrote into its text while native mode was on.
import Foundation

public enum TextToolProtocol {
    /// Marker a tool-result message starts with (the model learns it from the prompt).
    public static let resultLead = "TOOL RESULT"
    static let toolKeys = ["tool", "name", "function"]
    static let argumentKeys = ["arguments", "args", "input", "parameters"]
    static let callIDPrefix = "text-call-"

    // allow-hardcode: model prompt text (the text-protocol contract, reviewed guidance).
    /// The prompt block that teaches the protocol and lists the tools.
    public static func render(_ tools: [AgentToolDefinition]) -> String {
        var lines = [
            "TOOLS. You can call the tools below. To call one, write a line that contains ONLY a JSON object of the form",
            "{\"tool\":\"<name>\",\"arguments\":{…}} — one object per line, several lines allowed, nothing else on those lines.",
            "After writing tool calls, STOP and wait: each result comes back in a message starting with \"\(resultLead)\".",
            "When no tool is needed, answer in plain text (no JSON). Never invent tool results.",
            "",
        ]
        for tool in tools {
            lines.append("- \(tool.name): \(tool.description)")
            lines.append("  arguments schema: \(tool.parameters.jsonText)")
        }
        return lines.joined(separator: "\n")
    }

    /// Tool calls found in `text` (one JSON object per line, fences allowed)
    /// and the prose that remains without them.
    public static func parse(_ text: String) -> (calls: [AgentToolCall], remainder: String) {
        var calls: [AgentToolCall] = []
        var kept: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { continue }   // fence markers never carry content
            if let call = call(fromLine: line, index: calls.count + 1) {
                calls.append(call)
            } else {
                kept.append(rawLine)
            }
        }
        if calls.isEmpty, let call = call(fromLine: text.trimmingCharacters(in: .whitespacesAndNewlines), index: 1) {
            // The whole reply is one (pretty-printed) object.
            return ([call], "")
        }
        return (calls, kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func call(fromLine line: String, index: Int) -> AgentToolCall? {
        guard line.hasPrefix("{"), line.hasSuffix("}"), let value = JSONValue.parse(line), let object = value.objectValue else { return nil }
        guard let name = toolKeys.lazy.compactMap({ object[$0]?.stringValue }).first, !name.isEmpty else { return nil }
        var arguments: [String: JSONValue] = [:]
        if let found = argumentKeys.lazy.compactMap({ object[$0] }).first {
            if let nested = found.objectValue { arguments = nested }
            else if let text = found.stringValue, let nested = JSONValue.parse(text)?.objectValue { arguments = nested }
        }
        let id = object["id"]?.stringValue ?? "\(callIDPrefix)\(index)"
        return AgentToolCall(id: id, name: name, arguments: arguments)
    }

    /// The line form of a call, for re-rendering history in text mode.
    public static func line(for call: AgentToolCall) -> String {
        JSONValue.object(["tool": .string(call.name), "arguments": .object(call.arguments)]).jsonText
    }

    /// The text of a tool result as the model receives it in text mode.
    public static func resultText(name: String, callID: String, content: String) -> String {
        "\(resultLead) \(name) (\(callID)):\n\(content)"
    }
}
