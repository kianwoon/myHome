// "play jazz music" with no saved station: search YouTube and take the first
// regular video. UNOFFICIAL — reads the public results page (no API key, no
// account), so it can break whenever YouTube changes that page. Live streams
// are skipped (they have no duration): the speaker refuses them.
import Foundation

public protocol CastYouTubeSearching: Sendable {
    func firstVideo(for query: String) async throws -> CastMediaSource?
}

public struct YouTubeSearch: CastYouTubeSearching {
    public static let resultsURL = "https://www.youtube.com/results"
    /// Result filter "Videos" (excludes channels, playlists, shorts shelves).
    static let videoFilter = "EgIQAQ%3D%3D"
    static let dataMarker = "var ytInitialData = "
    static let dataTerminator = ";</script>"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    static let maxQueryLength = 120

    let fetch: @Sendable (URL) async throws -> String

    public init(timeout: TimeInterval = CastConfig.defaults.requestTimeout) {
        fetch = { url in
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.setValue(YouTubeSearch.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                return String(decoding: data, as: UTF8.self)
            } catch { throw CastError.unreachable }
        }
    }

    init(fetch: @escaping @Sendable (URL) async throws -> String) { self.fetch = fetch }

    public func firstVideo(for query: String) async throws -> CastMediaSource? {
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxQueryLength))
        guard !trimmed.isEmpty, var components = URLComponents(string: Self.resultsURL) else { return nil }
        components.queryItems = [URLQueryItem(name: "search_query", value: trimmed)]
        // `sp` is already percent-encoded; set it without double-encoding.
        let base = components.percentEncodedQuery ?? ""
        components.percentEncodedQuery = base + "&sp=" + Self.videoFilter
        guard let url = components.url else { return nil }
        guard let hit = Self.firstPlayable(inHTML: try await fetch(url)) else { return nil }
        guard let link = URL(string: "https://www.youtube.com/watch?v=\(hit.id)") else { return nil }
        return CastMediaSource.from(url: link, title: hit.title)
    }

    /// First videoRenderer that has a duration (i.e. not a live stream).
    static func firstPlayable(inHTML html: String) -> (id: String, title: String)? {
        guard let start = html.range(of: dataMarker), let end = html.range(of: dataTerminator, range: start.upperBound..<html.endIndex),
              let data = String(html[start.upperBound..<end.lowerBound]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var found: (String, String)?
        func walk(_ node: Any) {
            guard found == nil else { return }
            if let object = node as? [String: Any] {
                if let video = object["videoRenderer"] as? [String: Any],
                   let id = video["videoId"] as? String, CastYouTubeRef.valid(id) != nil,
                   (video["lengthText"] as? [String: Any])?["simpleText"] is String {
                    let runs = (video["title"] as? [String: Any])?["runs"] as? [[String: Any]]
                    found = (id, (runs?.first?["text"] as? String) ?? "YouTube")
                    return
                }
                for value in object.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(root)
        return found
    }
}
