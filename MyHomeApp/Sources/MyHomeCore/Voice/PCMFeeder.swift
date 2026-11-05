// Microphone tap → 16 kHz mono Float32, ported from Pop's WhisperStreamFeeder.
// Also measures audible input for the liveness (dead-engine) verdict.
import AVFoundation
import Foundation

final class PCMFeeder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let ratio: Double
    private let sink: SegmentingTranscriber
    private let audiblePeak: Float
    private let lock = NSLock()
    private var stopped = false
    private var conversionFailed = false
    private var audible = 0.0

    var onFailure: (@Sendable (String) -> Void)?

    init?(tapFormat: AVAudioFormat, sink: SegmentingTranscriber,
          audiblePeak: Float = AppSettings.speechAudiblePeakThreshold) {
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: Double(SpeechModelSpec.sampleRate),
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: tapFormat, to: outputFormat),
              tapFormat.sampleRate > 0 else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.converter = converter
        self.outputFormat = outputFormat
        self.ratio = outputFormat.sampleRate / tapFormat.sampleRate
        self.sink = sink
        self.audiblePeak = audiblePeak
    }

    var audibleSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return audible
    }

    /// Audio thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let skip = stopped || conversionFailed
        lock.unlock()
        guard !skip else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            lock.lock(); conversionFailed = true; lock.unlock()
            onFailure?("the microphone audio could not be converted (\(error.localizedDescription))")
            return
        }
        guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
        let frames = Int(output.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channel, count: frames))
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        if peak > audiblePeak {
            lock.lock(); audible += Double(frames) / outputFormat.sampleRate; lock.unlock()
        }
        sink.append(samples: samples)
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }
}
