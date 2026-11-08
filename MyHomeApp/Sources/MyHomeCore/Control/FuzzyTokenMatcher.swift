// "Fuzzy" device matching: tolerates the small misrecognitions an accent
// causes ("links lamp" for "Ling's lamp"). Used by DeviceResolver only when
// strict matching found nothing, and its hits are always suggestions
// (.ambiguous), never an outright decision.
import Foundation

enum FuzzyTokenMatcher {
    /// True when `heard` is close enough to `target` to be a misrecognition of it.
    static func isClose(_ heard: String, _ target: String,
                        minLength: Int = AppSettings.defaultFuzzyMinTokenLength,
                        maxDistanceRatio: Double = AppSettings.defaultFuzzyMaxDistanceRatio) -> Bool {
        guard heard.count >= minLength, target.count >= minLength else { return false }
        if heard == target { return true }
        let allowed = max(1, Int(Double(max(heard.count, target.count)) * maxDistanceRatio))
        if abs(heard.count - target.count) > allowed { return false }
        if distance(Array(heard), Array(target)) <= allowed { return true }
        // Same consonant skeleton (vowels are what accents shift most).
        let skeleton = consonants(heard)
        return skeleton.count >= minLength - 1 && skeleton == consonants(target)
    }

    static func consonants(_ token: String) -> String {
        String(token.filter { !"aeiou".contains($0) })
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            for (j, cb) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}
