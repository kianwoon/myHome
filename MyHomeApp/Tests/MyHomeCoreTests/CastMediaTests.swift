import XCTest
@testable import MyHomeCore

@MainActor
final class CastMediaTests: XCTestCase {
    let presets = CastRadioPreset.seed + [CastRadioPreset(id: "j", name: "Smooth Jazz", url: "https://example.com/jazz.mp3")]

    func testResolveByNameGenericAndLastPlayed() {
        XCTAssertEqual(CastRadioPreset.resolve("jazz", in: presets)?.id, "j")
        XCTAssertEqual(CastRadioPreset.resolve("kexp", in: presets)?.id, "seed-kexp")
        XCTAssertEqual(CastRadioPreset.resolve("radio paradise mellow", in: presets)?.id, "seed-rp-mellow")
        XCTAssertEqual(CastRadioPreset.resolve("music", in: presets)?.id, presets[0].id)
        XCTAssertEqual(CastRadioPreset.resolve("some music", in: presets, lastPlayed: "j")?.id, "j")
        XCTAssertNil(CastRadioPreset.resolve("polka", in: presets))
    }

    func testOnlyHTTPSourcesArePlayable() {
        XCTAssertTrue(CastMediaSource(title: "x", url: URL(string: "https://a.example/s.mp3")!).isPlayable)
        XCTAssertFalse(CastMediaSource(title: "x", url: URL(string: "file:///etc/passwd")!).isPlayable)
        XCTAssertFalse(CastMediaSource(title: "x", url: URL(string: "javascript:alert(1)")!).isPlayable)
        XCTAssertNil(CastRadioPreset(name: "bad", url: "ftp://a/b").source)
    }

    func testPresetStoreSeedsOnceThenRespectsEmptyList() {
        let defaults = UserDefaults(suiteName: "CastRadio-\(UUID())")!
        let store = CastRadioStore(defaults: defaults)
        XCTAssertEqual(store.load(), CastRadioPreset.seed)
        store.save([])
        XCTAssertEqual(store.load(), [])
    }

    func testVoiceGrammar() {
        let parser = VoiceCommandParser()
        func parse(_ text: String) -> (String?, DeviceCommand)? {
            if case .command(let query, let command) = parser.parse(text) { return (query.text, command) }
            return nil
        }
        XCTAssertEqual(parse("play jazz on the study room speaker")?.1, .play("jazz"))
        XCTAssertEqual(parse("play jazz on the study room speaker")?.0, "study room speaker")
        XCTAssertEqual(parse("play music")?.1, .play("music"))
        XCTAssertEqual(parse("pause the living room speaker")?.1, .playback(.pause))
        XCTAssertEqual(parse("resume music in the study")?.1, .playback(.resume))
        XCTAssertEqual(parse("stop the music on the living room speaker")?.1, .playback(.stop))
        XCTAssertEqual(parse("stop the study room speaker")?.1, .playback(.stop))
        XCTAssertEqual(parse("stop the study room speaker")?.0, "study room speaker")
        XCTAssertNotEqual(parse("put the fan on")?.1.capability, .media)
        // Bare "stop" must remain a cover command.
        XCTAssertEqual(parse("stop the curtain")?.1, .cover(.stop))
    }

    func testPlanResolvesStationOrRejects() {
        let device = Device(id: "cast:x", name: "Mini", ip: "", version: nil, category: CastProtocol.category, online: true)
        let profile = DeviceProfile(device: device, state: DeviceState(dps: [:]), isBriturn: false, isCast: true, castPresets: presets)
        let result = CapabilityMap.plan(.play("jazz"), for: profile)
        guard case .success(.cast(.playMedia(let source))) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(source.title, "Smooth Jazz")
        // No saved station: a real phrase becomes a YouTube search; a generic one with no presets is rejected.
        guard case .success(.cast(.playSearch("polka music"))) = CapabilityMap.plan(.play("polka music"), for: profile) else { return XCTFail() }
        let empty = DeviceProfile(device: device, state: DeviceState(dps: [:]), isBriturn: false, isCast: true)
        guard case .failure = CapabilityMap.plan(.play("music"), for: empty) else { return XCTFail("nothing to play must be rejected") }
        guard case .success(.cast(.pause)) = CapabilityMap.plan(.playback(.pause), for: profile) else { return XCTFail() }
        let light = DeviceProfile(device: device, state: DeviceState(dps: [:]), isBriturn: true)
        guard case .failure = CapabilityMap.plan(.play("jazz"), for: light) else { return XCTFail("lights cannot play music") }
    }

    func testFileServerRequestParsing() {
        let request = CastFileServer.parse("GET /cast/abc/song.mp3 HTTP/1.1\r\nHost: x\r\nRange: bytes=100-199\r\n\r\n")
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/cast/abc/song.mp3")
        XCTAssertEqual(request?.range?.start, 100)
        XCTAssertEqual(request?.range?.end, 199)
        XCTAssertNil(CastFileServer.parse("POST /cast/a HTTP/1.1\r\n\r\n"), "only GET/HEAD are served")
    }

    func testFileServerRefusesUnregisteredAndUnreadable() async {
        let server = CastFileServer()
        do { _ = try await server.register(URL(fileURLWithPath: "/nonexistent/file.mp3")); XCTFail() } catch { XCTAssertEqual(error as? CastError, .unplayableSource) }
    }
}

@MainActor
final class CastPlayStoreTests: XCTestCase {
    func testPlayPresetStartsPlaybackAndRemembersIt() async {
        let defaults = UserDefaults(suiteName: "CastPlay-\(UUID())")!
        let store = DeviceStore(bridge: NullKEFBridge(), defaults: defaults)
        let speaker = FakeCastSpeaker(state: CastState(volume: 30, muted: false))
        var config = CastConfig.defaults
        config.readbackDelay = 0.01
        config.playSettleInterval = 0.01
        store.setCastConfigForTest(config)
        store.setCastPersistenceForTest(CastConfigurationStore(defaults: defaults))
        store.setCastClientFactoryForTest { _ in speaker }
        store.addCastSpeaker(CastSpeakerRecord(deviceID: "m", name: "Mini", serviceName: "m"))
        let device = store.castSpeakerDevices[0]
        await store.refreshCast(device.id)
        let preset = store.castPresets[1]
        guard case .confirmed(let state) = await store.castPlay(device, preset: preset) else { return XCTFail() }
        XCTAssertEqual(state.playback, .playing)
        XCTAssertEqual(store.castLastPlayed, preset.id)
        XCTAssertTrue(speaker.calls.contains("play:\(preset.name)"))
    }
}

final class CastYouTubeTests: XCTestCase {
    func testLinkParsing() {
        func ref(_ text: String) -> CastYouTubeRef? { CastYouTubeRef.parse(URL(string: text)!) }
        XCTAssertEqual(ref("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), CastYouTubeRef(videoID: "dQw4w9WgXcQ"))
        XCTAssertEqual(ref("https://youtu.be/dQw4w9WgXcQ"), CastYouTubeRef(videoID: "dQw4w9WgXcQ"))
        XCTAssertEqual(ref("https://music.youtube.com/watch?v=abc_123-x&list=PLx1"), CastYouTubeRef(videoID: "abc_123-x", listID: "PLx1"))
        XCTAssertEqual(ref("https://www.youtube.com/playlist?list=PLx1"), CastYouTubeRef(listID: "PLx1"))
        XCTAssertNil(ref("https://example.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(ref("https://www.youtube.com/watch?v=bad%20id;rm"))
        XCTAssertNil(ref("ftp://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    func testYouTubeSourceIsDetectedAndPlayable() {
        let source = CastMediaSource.from(url: URL(string: "https://youtu.be/dQw4w9WgXcQ")!, title: "x")
        XCTAssertEqual(source.youtube?.videoID, "dQw4w9WgXcQ")
        XCTAssertTrue(source.isPlayable)
        XCTAssertEqual(CastRadioPreset(name: "rick", url: "https://youtu.be/dQw4w9WgXcQ").source?.youtube?.videoID, "dQw4w9WgXcQ")
    }

    func testBindReplies() {
        let accepted = "1395\n[[0,[\"c\",\"SID123\",\"\",8]]\n,[1,[\"S\",\"GSESSION456\"]]\n,[2,[\"loungeStatus\",{\"devices\":\"[]\"}]]\n]\n"
        let refused = "157\n[[0,[\"c\",\"SID123\",\"\",8]]\n,[1,[\"S\",\"GSESSION456\"]]\n,[2,[\"loungeScreenDisconnected\",{\"reason\":\"unmatchingTheme\"}]]\n]\n"
        XCTAssertEqual(YouTubeLounge.parseBind(accepted)?.sid, "SID123")
        XCTAssertEqual(YouTubeLounge.parseBind(accepted)?.gsession, "GSESSION456")
        XCTAssertNil(YouTubeLounge.refusalReason(accepted))
        XCTAssertEqual(YouTubeLounge.refusalReason(refused), "unmatchingTheme")
    }

    struct FakeHTTP: CastHTTPPosting {
        let refuseThemes: Set<String>
        func post(url: URL, query: [String: String], form: [String: String], headers: [String: String]) async throws -> (status: Int, body: String) {
            if url.path.hasSuffix("get_lounge_token_batch") { return (200, "{\"screens\":[{\"loungeToken\":\"TOKEN\"}]}") }
            if query["RID"] == "0" {
                let refused = refuseThemes.contains(query["theme"] ?? "")
                let tail = refused ? "[\"loungeScreenDisconnected\",{\"reason\":\"unmatchingTheme\"}]" : "[\"loungeStatus\",{}]"
                return (200, "9\n[[0,[\"c\",\"SID\",\"\",8]]\n,[1,[\"S\",\"GS\"]]\n,[2,\(tail)]\n]\n")
            }
            return (200, "8\n[0,-1,0]")
        }
    }

    func testLoungeFallsBackToNextThemeThenRefuses() async throws {
        let bound = try await YouTubeLounge(http: FakeHTTP(refuseThemes: ["m"])).bind(token: "TOKEN")
        XCTAssertEqual(bound.theme, "cl")
        try await YouTubeLounge(http: FakeHTTP(refuseThemes: [])).play(screenID: "S", ref: CastYouTubeRef(videoID: "dQw4w9WgXcQ"))
        do {
            _ = try await YouTubeLounge(http: FakeHTTP(refuseThemes: ["m", "cl"])).bind(token: "TOKEN")
            XCTFail("expected refusal")
        } catch { XCTAssertEqual(error as? CastError, .youtubeRefused("unmatchingTheme")) }
    }

    func testSetPlaylistFormCarriesIds() {
        let form = YouTubeLounge.setPlaylistForm(CastYouTubeRef(videoID: "v", listID: "l"))
        XCTAssertEqual(form["req0__sc"], "setPlaylist")
        XCTAssertEqual(form["req0_videoId"], "v")
        XCTAssertEqual(form["req0_listId"], "l")
    }
}

final class CastYouTubeSearchTests: XCTestCase {
    static func page(_ renderers: String) -> String {
        "<html><script>var ytInitialData = {\"contents\":[\(renderers)]};</script></html>"
    }
    static let live = "{\"videoRenderer\":{\"videoId\":\"LIVEid00001\",\"title\":{\"runs\":[{\"text\":\"Jazz 24/7\"}]}}}"
    static let vod = "{\"videoRenderer\":{\"videoId\":\"VODid000002\",\"title\":{\"runs\":[{\"text\":\"Smooth Jazz\"}]},\"lengthText\":{\"simpleText\":\"1:10:37\"}}}"

    func testSkipsLiveStreamsAndTakesFirstDuration() {
        let hit = YouTubeSearch.firstPlayable(inHTML: Self.page(Self.live + "," + Self.vod))
        XCTAssertEqual(hit?.id, "VODid000002")
        XCTAssertEqual(hit?.title, "Smooth Jazz")
        XCTAssertNil(YouTubeSearch.firstPlayable(inHTML: Self.page(Self.live)))
        XCTAssertNil(YouTubeSearch.firstPlayable(inHTML: "<html>consent wall</html>"))
    }

    func testBuildsSourceAndEncodesQuery() async throws {
        let seen = SeenURL()
        let search = YouTubeSearch(fetch: { url in await seen.set(url); return Self.page(Self.vod) })
        let source = try await search.firstVideo(for: "jazz & blues music")
        XCTAssertEqual(source?.youtube?.videoID, "VODid000002")
        let url = await seen.value?.absoluteString ?? ""
        XCTAssertTrue(url.contains("search_query=jazz%20%26%20blues%20music"), url)
        XCTAssertTrue(url.hasSuffix("&sp=EgIQAQ%3D%3D"), url)
    }

    actor SeenURL { var value: URL?; func set(_ url: URL) { value = url } }
}

@MainActor
final class CastSearchStoreTests: XCTestCase {
    struct StubSearch: CastYouTubeSearching {
        let source: CastMediaSource?
        func firstVideo(for query: String) async throws -> CastMediaSource? { source }
    }

    func makeStore(search: CastMediaSource?) async -> (DeviceStore, FakeCastSpeaker, Device) {
        let defaults = UserDefaults(suiteName: "CastSearch-\(UUID())")!
        let store = DeviceStore(bridge: NullKEFBridge(), defaults: defaults)
        let speaker = FakeCastSpeaker(state: CastState(volume: 30, muted: false))
        var config = CastConfig.defaults
        config.readbackDelay = 0.01
        config.playSettleInterval = 0.01
        store.setCastConfigForTest(config)
        store.setCastPersistenceForTest(CastConfigurationStore(defaults: defaults))
        store.setCastClientFactoryForTest { _ in speaker }
        store.setCastSearchForTest(StubSearch(source: search))
        store.addCastSpeaker(CastSpeakerRecord(deviceID: "m", name: "Mini", serviceName: "m"))
        let device = store.castSpeakerDevices[0]
        await store.refreshCast(device.id)
        return (store, speaker, device)
    }

    func testSearchPlaysFirstResult() async {
        let hit = CastMediaSource.from(url: URL(string: "https://www.youtube.com/watch?v=VODid000002")!, title: "Smooth Jazz")
        let (store, speaker, device) = await makeStore(search: hit)
        guard case .confirmed = await store.castWrite(device, .playSearch("jazz music")) else { return XCTFail() }
        XCTAssertTrue(speaker.calls.contains("play:Smooth Jazz"))
    }

    func testNoResultsFailsWithoutTouchingTheSpeaker() async {
        let (store, speaker, device) = await makeStore(search: nil)
        let before = speaker.calls.count
        guard case .failed(.searchFailed("polka")) = await store.castWrite(device, .playSearch("polka")) else { return XCTFail() }
        XCTAssertEqual(speaker.calls.count, before)
    }
}
