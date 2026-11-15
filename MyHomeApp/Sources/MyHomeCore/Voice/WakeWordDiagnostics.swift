// Opt-in wake-word diagnostics (`defaults write <bundle> wakeWordDiagnostics
// -bool true`): a periodic heartbeat of how much audio the spotter received
// and how loud it was, plus a bounded WAV of exactly those 16 kHz samples, so
// a "says nothing" report can be replayed through the probe test. Confined to
// the listener's spotter queue.
import AVFoundation
import Foundation

public extension AppSettings {
    static let wakeWordDiagnosticsKey = "wakeWordDiagnostics"
    static let defaultWakeWordDiagnostics = false
    static let wakeWordHeartbeatSeconds: Double = 5
    static let wakeWordDumpMaxSeconds: Double = 180
    static let wakeWordDumpFileName = "kws-debug.wav"

    static func wakeWordDiagnostics(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: wakeWordDiagnosticsKey) as? Bool ?? defaultWakeWordDiagnostics
    }
}

final class WakeWordDiagnostics {
    private let sampleRate = Double(SpeechModelSpec.sampleRate)
    private let heartbeatSamples: Int
    private let dumpCapacity: Int
    private let dumpURL: URL
    private var windowSamples = 0
    private var windowPeak: Float = 0
    private var totalSamples = 0
    private var dump: [Float] = []
    private var dumped = false

    init(heartbeatSeconds: Double = AppSettings.wakeWordHeartbeatSeconds,
         dumpSeconds: Double = AppSettings.wakeWordDumpMaxSeconds,
         dumpURL: URL = WakeWordModelStore.directory.deletingLastPathComponent()
             .appendingPathComponent(AppSettings.wakeWordDumpFileName)) {
        heartbeatSamples = Int(heartbeatSeconds * Double(SpeechModelSpec.sampleRate))
        dumpCapacity = Int(dumpSeconds * Double(SpeechModelSpec.sampleRate))
        self.dumpURL = dumpURL
    }

    func observe(_ samples: [Float], hit: Bool) {
        totalSamples += samples.count
        windowSamples += samples.count
        windowPeak = max(windowPeak, samples.reduce(Float(0)) { max($0, abs($1)) })
        if hit { AppLog.assistant.info("wake diag: HIT at \(Double(self.totalSamples) / self.sampleRate, format: .fixed(precision: 1))s") }
        if windowSamples >= heartbeatSamples {
            AppLog.assistant.info("wake diag: received \(Double(self.windowSamples) / self.sampleRate, format: .fixed(precision: 1))s audio, peak=\(self.windowPeak, format: .fixed(precision: 4))")
            windowSamples = 0
            windowPeak = 0
        }
        guard !dumped else { return }
        dump += samples.prefix(dumpCapacity - dump.count)
        if dump.count >= dumpCapacity { write() }
    }

    /// Also called on disarm, so a short session still leaves a file.
    func flush() { if !dumped, !dump.isEmpty { write() } }

    private func write() {
        dumped = true
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(dump.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        dump.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: dump.count) }
        buffer.frameLength = AVAudioFrameCount(dump.count)
        do {
            try? FileManager.default.removeItem(at: dumpURL)
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                           AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let file = try AVAudioFile(forWriting: dumpURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            AppLog.assistant.info("wake diag: wrote \(Double(self.dump.count) / self.sampleRate, format: .fixed(precision: 1))s to \(self.dumpURL.path, privacy: .public)")
        } catch {
            AppLog.assistant.error("wake diag: dump failed \(error.localizedDescription, privacy: .public)")
        }
        dump = []
    }
}
