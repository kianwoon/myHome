// Starting YouTube on a Cast speaker. The YouTube receiver app is driven by
// YouTube's own "lounge" web API (the protocol the YouTube phone app speaks),
// NOT by the Cast media channel: launch the receiver, ask it for its screenId
// over the mdx namespace, trade that for a lounge token, bind a session, then
// send a setPlaylist command. Public videos/playlists only; no sign-in.
// UNOFFICIAL: YouTube can change this at any time (reference: casttube).
import Foundation

public struct CastYouTubeRef: Equatable, Hashable, Sendable {
    public var videoID: String?
    public var listID: String?

    public init(videoID: String? = nil, listID: String? = nil) {
        self.videoID = videoID
        self.listID = listID
    }

    static let hosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"]

    /// watch?v=ID[&list=LIST], playlist?list=LIST, youtu.be/ID, music.youtube.com/watch?v=ID.
    public static func parse(_ url: URL) -> CastYouTubeRef? {
        guard let host = url.host?.lowercased(), hosts.contains(host),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { valid($0) } }
        var video = query("v")
        if host == "youtu.be" { video = valid(url.pathComponents.dropFirst().first ?? "") }
        let list = query("list")
        guard video != nil || list != nil else { return nil }
        return CastYouTubeRef(videoID: video, listID: list)
    }

    /// YouTube ids are URL-safe base64-ish tokens; anything else is refused.
    static func valid(_ id: String) -> String? {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } ? id : nil
    }
}

public protocol CastHTTPPosting: Sendable {
    func post(url: URL, query: [String: String], form: [String: String], headers: [String: String]) async throws -> (status: Int, body: String)
}

public struct CastURLSessionHTTP: CastHTTPPosting {
    let timeout: TimeInterval
    public init(timeout: TimeInterval = CastConfig.defaults.requestTimeout) { self.timeout = timeout }

    static func encode(_ pairs: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    public func post(url: URL, query: [String: String], form: [String: String], headers: [String: String]) async throws -> (status: Int, body: String) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CastError.malformedResponse }
        if !query.isEmpty { components.percentEncodedQuery = Self.encode(query) }
        guard let final = components.url else { throw CastError.malformedResponse }
        var request = URLRequest(url: final, timeoutInterval: timeout)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = Data(Self.encode(form).utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        } catch {
            throw CastError.unreachable
        }
    }
}

/// The lounge exchange, with the HTTP transport injected so it is testable offline.
public struct YouTubeLounge: Sendable {
    public static let base = "https://www.youtube.com/"
    public static let mdxNamespace = "urn:x-cast:com.google.youtube.mdx"
    static let tokenPath = "api/lounge/pairing/get_lounge_token_batch"
    static let bindPath = "api/lounge/bc/bind"
    static let loungeHeader = "X-YouTube-LoungeId-Token"
    static let version = "8"
    static let clientVersion = "1"
    /// The lounge rejects a bind whose theme does not match the receiver ("unmatchingTheme").
    /// Nest Mini with YouTube Music as its source answers to "m" (receiver lb-v4); "cl" is the classic fallback.
    static let themes = ["m", "cl"]
    static let refusalMarker = "loungeScreenDisconnected"
    static let deviceName = "MyHome"
    static let appIdentity = "android-phone-13.14.55"

    let http: CastHTTPPosting
    public init(http: CastHTTPPosting = CastURLSessionHTTP()) { self.http = http }

    func url(_ path: String) -> URL { URL(string: Self.base + path)! }

    func loungeToken(screenID: String) async throws -> String {
        let reply = try await http.post(url: url(Self.tokenPath), query: [:], form: ["screen_ids": screenID],
                                        headers: ["Origin": Self.base, "Content-Type": "application/x-www-form-urlencoded"])
        guard reply.status == 200, let data = reply.body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let screens = object["screens"] as? [[String: Any]],
              let token = screens.first?["loungeToken"] as? String, !token.isEmpty else { throw CastError.malformedResponse }
        return token
    }

    /// `"c","<SID>",` and `"S","<gsessionid>"]` in the bind reply.
    static func parseBind(_ body: String) -> (sid: String, gsession: String)? {
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                  let range = Range(match.range(at: 1), in: body) else { return nil }
            return String(body[range])
        }
        guard let sid = capture("\\\"c\\\",\\\"(.*?)\\\","), let session = capture("\\\"S\\\",\\\"(.*?)\\\"\\]") else { return nil }
        return (sid, session)
    }

    /// `{"reason":"…"}` of a loungeScreenDisconnected event, if the bind was refused.
    static func refusalReason(_ body: String) -> String? {
        guard body.contains(refusalMarker) else { return nil }
        guard let regex = try? NSRegularExpression(pattern: "\\\"reason\\\":\\\"(.*?)\\\""),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else { return "refused" }
        return String(body[range])
    }

    func bind(token: String) async throws -> (sid: String, gsession: String, theme: String) {
        var reason = "refused"
        for theme in Self.themes {
            let reply = try await bind(token: token, theme: theme)
            if let refused = Self.refusalReason(reply.body) { reason = refused; continue }
            guard reply.status == 200, let ids = Self.parseBind(reply.body) else { throw CastError.malformedResponse }
            return (ids.sid, ids.gsession, theme)
        }
        throw CastError.youtubeRefused(reason)
    }

    private func bind(token: String, theme: String) async throws -> (status: Int, body: String) {
        let identity = String((0..<26).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        let reply = try await http.post(
            url: url(Self.bindPath), query: ["RID": "0", "VER": Self.version, "CVER": Self.clientVersion, "theme": theme],
            form: ["device": "REMOTE_CONTROL", "id": identity, "name": Self.deviceName, "mdx-version": "3",
                   "pairing_type": "cast", "app": Self.appIdentity],
            headers: ["Origin": Self.base, "Content-Type": "application/x-www-form-urlencoded", Self.loungeHeader: token])
        return reply
    }

    static func setPlaylistForm(_ ref: CastYouTubeRef) -> [String: String] {
        ["req0__sc": "setPlaylist", "req0_videoId": ref.videoID ?? "", "req0_listId": ref.listID ?? "",
         "req0_currentTime": "0", "req0_currentIndex": "-1", "req0_audioOnly": "false", "count": "1"]
    }

    public func play(screenID: String, ref: CastYouTubeRef) async throws {
        let token = try await loungeToken(screenID: screenID)
        let ids = try await bind(token: token)
        let reply = try await http.post(
            url: url(Self.bindPath),
            query: ["SID": ids.sid, "gsessionid": ids.gsession, "RID": "1", "VER": Self.version, "CVER": Self.clientVersion, "theme": ids.theme],
            form: Self.setPlaylistForm(ref),
            headers: ["Origin": Self.base, "Content-Type": "application/x-www-form-urlencoded", Self.loungeHeader: token])
        guard (200..<300).contains(reply.status) else { throw CastError.malformedResponse }
    }
}
