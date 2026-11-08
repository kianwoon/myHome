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
        guard case .failure = CapabilityMap.plan(.play("polka"), for: profile) else { return XCTFail("unknown station must be rejected") }
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
