// Household notes the housekeeper remembers across sessions ("the desk lamp
// is the one by the window", "no fans after midnight"): a small JSON file in
// Application Support/MyHome, editable in Settings → AI Models, read into
// every system prompt. Only an explicit "remember …" (or a correction) adds
// one; the agent never writes notes on its own.
import Combine
import Foundation

public struct HouseholdNote: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public var text: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

@MainActor
public final class HouseholdNotes: ObservableObject {
    @Published public private(set) var notes: [HouseholdNote] = []
    /// Last load/save problem, for the Settings UI (nil when fine).
    @Published public private(set) var problem: String?
    public let fileURL: URL?
    private let maxCount: Int
    private let maxLength: Int

    /// `fileURL` nil = in memory only (tests, or no Application Support).
    public init(fileURL: URL? = HouseholdNotes.defaultFileURL(), maxCount: Int = AppSettings.householdNotesMaxCount,
                maxLength: Int = AppSettings.householdNoteMaxLength) {
        self.fileURL = fileURL
        self.maxCount = maxCount
        self.maxLength = maxLength
        load()
    }

    public nonisolated static func defaultFileURL() -> URL? {
        BridgeClient.bundledDataDirectory()?.appendingPathComponent(AppSettings.householdNotesFileName)
    }

    public func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            notes = try decoder.decode([HouseholdNote].self, from: data)
            problem = nil
        } catch {
            problem = "Household notes could not be read: \(error.localizedDescription)"
            AppLog.assistant.error("household notes load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    public func add(_ text: String) -> HouseholdNote? {
        guard let clean = sanitized(text) else { return nil }
        let note = HouseholdNote(text: clean)
        notes.append(note)
        if notes.count > maxCount { notes.removeFirst(notes.count - maxCount) }
        save()
        return note
    }

    @discardableResult
    public func update(id: String, text: String) -> Bool {
        guard let clean = sanitized(text), let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        notes[index].text = clean
        save()
        return true
    }

    @discardableResult
    public func remove(id: String) -> Bool {
        let before = notes.count
        notes.removeAll { $0.id == id }
        guard notes.count != before else { return false }
        save()
        return true
    }

    /// Prompt form: one line per note with its id (so the model can forget it).
    public func rendered() -> String {
        notes.map { "- [\($0.id.prefix(8))] \($0.text)" }.joined(separator: "\n")
    }

    /// A note by its full id or the 8-character prefix the prompt shows.
    public func note(matching id: String) -> HouseholdNote? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return notes.first { $0.id.lowercased() == key || $0.id.lowercased().hasPrefix(key) && key.count >= 4 }
    }

    private func sanitized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }

    private func save() {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(notes)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            problem = nil
        } catch {
            problem = "Household notes could not be saved: \(error.localizedDescription)"
            AppLog.assistant.error("household notes save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
