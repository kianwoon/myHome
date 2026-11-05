// Engine-agnostic core of the offline speech layer, ported from the Pop app
// (SpeechEngine.swift ring chain, SenseVoiceEngine.swift VADProfile /
// PreRollBuffer / PreRollClamp, the transcriber drain loop). Everything here is
// pure or protocol-driven so it is unit-tested without a model: the Silero VAD
// and sherpa-onnx decoders plug in through `SpeechSegmenting` /
// `OfflineSpeechDecoder` (SherpaSpeechEngines.swift).
import Foundation

// MARK: - VAD profile and endpoint policy

/// Pop's DICTATION VAD profile (single threshold, no hysteresis, 500 ms
/// pre-roll). Values come from AppSettings.speechVADProfile.
public struct VADProfile: Sendable, Equatable {
    public var threshold: Float
    public var minSilenceSeconds: Float
    public var minSpeechSeconds: Float
    public var maxSpeechSeconds: Float
    public var preRollSeconds: Float

    public init(threshold: Float, minSilenceSeconds: Float, minSpeechSeconds: Float,
                maxSpeechSeconds: Float, preRollSeconds: Float) {
        self.threshold = threshold
        self.minSilenceSeconds = minSilenceSeconds
        self.minSpeechSeconds = minSpeechSeconds
        self.maxSpeechSeconds = maxSpeechSeconds
        self.preRollSeconds = preRollSeconds
    }
}

/// When a push-to-talk session ends on its own (MyHome-specific: Pop keeps
/// listening until the user stops; a command bar wants one utterance).
public struct EndpointPolicy: Sendable, Equatable {
    /// Quiet time after the last transcribed segment before the utterance ends.
    public var hangover: TimeInterval
    /// End a session in which nothing was transcribed for this long.
    public var noSpeechTimeout: TimeInterval
    /// Hard cap on one session.
    public var maxUtterance: TimeInterval

    public init(hangover: TimeInterval, noSpeechTimeout: TimeInterval, maxUtterance: TimeInterval) {
        self.hangover = hangover
        self.noSpeechTimeout = noSpeechTimeout
        self.maxUtterance = maxUtterance
    }
}

/// Pure endpointing state machine driven by VAD activity and decoded
/// segments. Times are seconds on any monotonic clock.
public struct UtteranceEndpointer: Sendable {
    public enum Decision: Equatable, Sendable {
        case keepListening
        /// Speech was transcribed and the hangover elapsed: deliver it.
        case endpoint
        /// Nothing transcribed within the no-speech window.
        case noSpeech
        /// The session cap was reached (deliver whatever was heard).
        case maxDuration
    }

    public let policy: EndpointPolicy
    public private(set) var startedAt: TimeInterval
    public private(set) var speechActive = false
    public private(set) var lastSpeechEnd: TimeInterval?
    public private(set) var lastSegmentAt: TimeInterval?
    public private(set) var hasText = false

    public init(policy: EndpointPolicy, startedAt: TimeInterval) {
        self.policy = policy
        self.startedAt = startedAt
    }

    public mutating func speechActivity(_ active: Bool, at time: TimeInterval) {
        if speechActive && !active { lastSpeechEnd = time }
        speechActive = active
    }

    public mutating func segmentDecoded(text: String, at time: TimeInterval) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        hasText = true
        lastSegmentAt = time
    }

    public func evaluate(at now: TimeInterval) -> Decision {
        if now - startedAt >= policy.maxUtterance { return .maxDuration }
        if speechActive { return .keepListening }
        if hasText {
            let quietSince = max(lastSegmentAt ?? startedAt, lastSpeechEnd ?? startedAt)
            return now - quietSince >= policy.hangover ? .endpoint : .keepListening
        }
        let quietSince = lastSpeechEnd ?? startedAt
        return now - quietSince >= policy.noSpeechTimeout ? .noSpeech : .keepListening
    }
}

// MARK: - Pre-roll (Pop)

/// Last-N-samples ring, snapshotted at the instant speech starts so the
/// segment begins before detection time and an onset is never clipped.
public struct PreRollBuffer: Sendable {
    public let capacity: Int
    public private(set) var samples: [Float] = []

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    public mutating func append(_ chunk: [Float]) {
        guard capacity > 0 else { return }
        samples.append(contentsOf: chunk)
        let overflow = samples.count - capacity
        if overflow > 0 { samples.removeFirst(overflow) }
    }
}

/// Pre-roll may only reach back over silence OBSERVED since the last segment
/// close, so it can never replay the previous utterance's tail.
public enum PreRollClamp {
    public static func clamp(_ snapshot: [Float], observedSilenceSamples: Int, capacity: Int) -> [Float] {
        let allowed = max(0, min(capacity, observedSilenceSamples, snapshot.count))
        guard allowed > 0 else { return [] }
        return Array(snapshot.suffix(allowed))
    }
}

// MARK: - Engine chain + liveness (Pop's ring chain)

/// Process-local engine memory, as in Pop: an engine that proved dead sorts to
/// the end of the chain for the rest of the process; the last engine that
/// produced text leads. Nothing is persisted. An instance (not statics) so
/// tests do not share state.
public final class SpeechEngineChain: @unchecked Sendable {
    private let lock = NSLock()
    private var dead: Set<SpeechEngineKind> = []
    private var lastGood: SpeechEngineKind?

    public init() {}

    public func noteDead(_ kind: SpeechEngineKind) {
        lock.lock(); defer { lock.unlock() }
        dead.insert(kind)
        if lastGood == kind { lastGood = nil }
    }

    public func noteGood(_ kind: SpeechEngineKind) {
        lock.lock(); defer { lock.unlock() }
        lastGood = kind
        dead.remove(kind)
    }

    public func isDead(_ kind: SpeechEngineKind) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return dead.contains(kind)
    }

    /// Best-first engines to try. Membership = enabled AND installed
    /// (`eligible`). Natural order is qwenAsr → senseVoice. A valid,
    /// eligible, alive pin leads; otherwise the last good engine leads; dead
    /// engines go last so a fixed install can self-heal.
    public func order(preferred: String, eligible: (SpeechEngineKind) -> Bool) -> [SpeechEngineKind] {
        lock.lock(); defer { lock.unlock() }
        let natural = SpeechEngineKind.allCases.filter(eligible)
        var alive = natural.filter { !dead.contains($0) }
        let deadTail = natural.filter { dead.contains($0) }
        if let pin = SpeechEngineKind(rawValue: preferred), let index = alive.firstIndex(of: pin) {
            alive.remove(at: index)
            alive.insert(pin, at: 0)
        } else if let good = lastGood, let index = alive.firstIndex(of: good) {
            alive.remove(at: index)
            alive.insert(good, at: 0)
        }
        return alive + deadTail
    }
}

public enum SpeechLiveness {
    /// Pop's dead-engine verdict: no result, no processed window, while at
    /// least `threshold` seconds of audible audio flowed in.
    public static func isDead(hadResult: Bool, processedWindows: Int, audibleSeconds: Double,
                              threshold: Double) -> Bool {
        !hadResult && processedWindows == 0 && audibleSeconds >= threshold
    }
}

// MARK: - Segmenter / decoder seams

/// A voice-activity segmenter over 16 kHz mono samples (Silero in the app).
public protocol SpeechSegmenting: AnyObject {
    func accept(_ samples: [Float])
    var isSpeechDetected: Bool { get }
    /// Next closed speech segment, or nil.
    func popSegment() -> [Float]?
    /// Close any open segment (end of audio).
    func flush()
}

/// An offline (whole-segment) recognizer.
public protocol OfflineSpeechDecoder: AnyObject {
    func decode(_ samples: [Float], sampleRate: Int) -> String
}

/// Pop's transcriber drain loop, engine-agnostic: buffers tap audio, runs the
/// segmenter on ONE serial queue (decoders are not thread-safe), prepends the
/// clamped pre-roll to each segment, suppresses an exact repeat, and emits
/// each decoded segment. Offline models yield finals only (no partials).
public final class SegmentingTranscriber: @unchecked Sendable {
    public typealias SegmentHandler = @Sendable (String) -> Void
    public typealias ActivityHandler = @Sendable (Bool) -> Void

    private let segmenter: SpeechSegmenting
    private let decoder: OfflineSpeechDecoder
    private let sampleRate: Int
    private let queue: DispatchQueue
    private let onSegment: SegmentHandler
    private let onActivity: ActivityHandler

    private let lock = NSLock()
    private var pending: [Float] = []
    private var scheduled = false
    private var finished = false
    private var processedWindows = 0
    // Queue-confined state.
    private var lastDecodedText = ""
    private var preRoll: PreRollBuffer
    private var onsetPreRoll: [Float]?
    private var silenceSinceCloseSamples: Int
    private var reportedActive = false

    public init(segmenter: SpeechSegmenting, decoder: OfflineSpeechDecoder, sampleRate: Int,
                preRollSeconds: Float, queue: DispatchQueue,
                onSegment: @escaping SegmentHandler, onActivity: @escaping ActivityHandler = { _ in }) {
        self.segmenter = segmenter
        self.decoder = decoder
        self.sampleRate = sampleRate
        self.queue = queue
        self.onSegment = onSegment
        self.onActivity = onActivity
        self.preRoll = PreRollBuffer(capacity: Int(Double(preRollSeconds) * Double(sampleRate)))
        self.silenceSinceCloseSamples = preRoll.capacity
    }

    /// Tap thread: coalesce and schedule at most one drain at a time.
    public func append(samples: [Float]) {
        lock.lock()
        if finished { lock.unlock(); return }
        pending.append(contentsOf: samples)
        let shouldSchedule = !scheduled
        if shouldSchedule { scheduled = true }
        lock.unlock()
        if shouldSchedule { queue.async { [weak self] in self?.drain() } }
    }

    /// End of audio: decode whatever is buffered, close the open segment, then
    /// call `completion` (on the transcriber queue).
    public func finish(completion: @escaping @Sendable () -> Void = {}) {
        lock.lock()
        if finished { lock.unlock(); queue.async(execute: completion); return }
        finished = true
        lock.unlock()
        queue.async { [weak self] in
            self?.flush()
            completion()
        }
    }

    /// Liveness evidence: windows delivered to the segmenter.
    public func processedWindowCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return processedWindows
    }

    private func drain() {
        while true {
            lock.lock()
            if finished || pending.isEmpty {
                scheduled = false
                lock.unlock()
                return
            }
            let chunk = pending
            pending.removeAll(keepingCapacity: true)
            lock.unlock()
            ingest(chunk)
            drainSegments()
        }
    }

    private func flush() {
        lock.lock()
        let rest = pending
        pending.removeAll()
        scheduled = false
        lock.unlock()
        if !rest.isEmpty { ingest(rest) }
        segmenter.flush()
        drainSegments()
        reportActivity(false)
    }

    private func ingest(_ chunk: [Float]) {
        let wasSpeech = segmenter.isSpeechDetected
        let snapshot = preRoll.samples
        segmenter.accept(chunk)
        preRoll.append(chunk)
        let isSpeech = segmenter.isSpeechDetected
        if !wasSpeech, isSpeech, onsetPreRoll == nil {
            onsetPreRoll = PreRollClamp.clamp(snapshot, observedSilenceSamples: silenceSinceCloseSamples,
                                              capacity: preRoll.capacity)
        } else if !wasSpeech, !isSpeech {
            silenceSinceCloseSamples = min(preRoll.capacity, silenceSinceCloseSamples + chunk.count)
        }
        lock.lock(); processedWindows += 1; lock.unlock()
        reportActivity(isSpeech)
    }

    private func drainSegments() {
        while let segment = segmenter.popSegment() {
            silenceSinceCloseSamples = 0
            var samples = segment
            if let onset = onsetPreRoll {
                samples = onset + samples
                onsetPreRoll = nil
            }
            let text = decoder.decode(samples, sampleRate: sampleRate)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lock.lock(); processedWindows += 1; lock.unlock()
            guard !text.isEmpty, text != lastDecodedText else { continue }
            lastDecodedText = text
            onSegment(text)
        }
    }

    private func reportActivity(_ active: Bool) {
        guard active != reportedActive else { return }
        reportedActive = active
        onActivity(active)
    }
}

/// Joins segment texts into one utterance (Latin: single space).
public enum SegmentTextJoin {
    public static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
