import XCTest
@testable import MyHomeCore

final class MlxQwenStoreTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mlxgate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testEmptyDirectoryFailsGate() throws {
        XCTAssertFalse(MlxQwenStore.isInstalled(at: try tempDir()))
    }

    func testTruncatedAssetsFailGate() throws {
        let dir = try tempDir()
        for file in ["model.safetensors", "vocab.json", "merges.txt"] {
            try Data("<html>error</html>".utf8).write(to: dir.appendingPathComponent(file))
        }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        XCTAssertFalse(MlxQwenStore.isInstalled(at: dir))
    }

    func testBackendSettingDefaultsToMlxAndRejectsJunk() {
        let defaults = UserDefaults(suiteName: "mlx-\(UUID().uuidString)")!
        XCTAssertEqual(AppSettings.speechQwenBackend(from: defaults), AppSettings.speechBackendMlx)
        defaults.set("bogus", forKey: AppSettings.speechQwenBackendKey)
        XCTAssertEqual(AppSettings.speechQwenBackend(from: defaults), AppSettings.speechBackendMlx)
        defaults.set(AppSettings.speechBackendOnnx, forKey: AppSettings.speechQwenBackendKey)
        XCTAssertEqual(AppSettings.speechQwenBackend(from: defaults), AppSettings.speechBackendOnnx)
    }
}

/// Real-model check, skipped when no MLX model is installed.
final class MlxQwenInferenceTests: XCTestCase {
    func testTranscribesSaidCommand() throws {
        guard let dir = MlxQwenStore.locate(usePop: true) else { throw XCTSkip("MLX Qwen3-ASR model not installed") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-say-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", tmp.path, "--data-format=LEI16@16000", "turn on the living room light"]
        try say.run(); say.waitUntilExit()
        let data = try Data(contentsOf: tmp).dropFirst(44)
        let samples: [Float] = data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
        }
        let loadStart = Date()
        let decoder = try XCTUnwrap(MlxQwenDecoder(directory: dir, hotwords: []))
        let loadSeconds = Date().timeIntervalSince(loadStart)
        let start = Date()
        let text = decoder.decode(samples, sampleRate: 16000)
        print("MLX_PROBE load=\(loadSeconds)s decode=\(Date().timeIntervalSince(start))s audio=\(Double(samples.count) / 16000)s text=\(text)")
        XCTAssertTrue(text.lowercased().contains("living room"), text)
    }
}
