import Foundation

/// Detects a decoder that regurgitated its hotword prompt (Qwen3-ASR does this
/// with a long device list) or produced text no human could speak in the audio.
public enum HotwordEcho {
    /// True when `transcript` is mostly made of hotword phrases (at least
    /// `AppSettings.speechEchoMinDistinctHotwords` distinct ones covering at
    /// least `AppSettings.speechEchoCoverage` of its characters), or when the
    /// speech rate exceeds `AppSettings.speechMaxCharsPerSecond`.
    public static func isEcho(_ transcript: String, hotwords: [String], audioSeconds: Double,
                              minDistinct: Int = AppSettings.speechEchoMinDistinctHotwords,
                              coverage: Double = AppSettings.speechEchoCoverage,
                              maxCharsPerSecond: Double = AppSettings.speechMaxCharsPerSecond) -> Bool {
        let text = Array(transcript.lowercased())
        guard !text.isEmpty else { return false }
        if audioSeconds > 0, Double(text.count) / audioSeconds > maxCharsPerSecond { return true }
        var covered = [Bool](repeating: false, count: text.count)
        var distinct = Set<String>()
        var seen = Set<String>()
        let phrases = hotwords
            .map { $0.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { $0.count >= AppSettings.speechEchoMinHotwordLength && seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
        for phrase in phrases {
            let needle = Array(phrase)
            guard needle.count <= text.count else { continue }
            var i = 0
            while i + needle.count <= text.count {
                if Array(text[i..<(i + needle.count)]) == needle {
                    distinct.insert(phrase)
                    for k in i..<(i + needle.count) { covered[k] = true }
                    i += needle.count
                } else {
                    i += 1
                }
            }
        }
        guard distinct.count >= minDistinct else { return false }
        return Double(covered.filter { $0 }.count) / Double(text.count) >= coverage
    }
}
