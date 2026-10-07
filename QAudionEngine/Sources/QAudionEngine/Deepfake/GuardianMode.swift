import Foundation

public final class GuardianMode: @unchecked Sendable {
    public var onAlert: ((ConfidenceIndex.Level, Float) -> Void)?

    /// Drives `ConfidenceIndex` (Tier 1: the sustained-red alarm and the in-call confidence wave) off a single
    /// AASIST-raw score per window from `VoiceprintAnalyzer`.
    ///
    /// Unlike the Desktop Guardian (`GuardianScorer.ts`, `0.7 * ml + 0.3 * lfcc`), this does NOT fuse an ML
    /// score with a real LFCC/voiceprint mismatch score. `DeepfakeClassifier` (a second, `async` AASIST path)
    /// and `SpeakerVerifier`/`LfccExtractor` (the actual LFCC leg, requires speaker enrollment) live in Tier 2
    /// (`ContactVoiceVerifier`), which is also the only source of the in-call "C=" badge.
    ///
    /// W-GUARDIAN1CONTIG (2026-10-07):
    /// - `processFrame` (on the RX analysis queue) only runs the VAD gate and copies the chunk into
    ///   `GuardianWindowAccumulator`: every voiced chunk, contiguous, at any chunk length. It used to forward
    ///   one chunk per 100 ms of audio, i.e. 10% of the audio on native SRTP.
    /// - Windows (4.04 s) do not overlap, and two inferences are at least `minVoicedMsBetweenInferences` (8 s)
    ///   of voiced audio apart: the first score after one window, then one window in two. The window in between
    ///   is discarded without inference and without queueing. The owner's rule: if it costs, update less often.
    ///   Same rate on every transport (the 60 ms DataChannel path scored every 4.04 s before).
    /// - The inference runs on this class's own serial queue with ONE job in flight. A window that completes
    ///   while the previous one is still being scored is dropped, never queued: no backlog, no stale score,
    ///   and the RX analysis queue (whose ring is 10 chunks, 100 ms at 10 ms chunks) is no longer held for the
    ///   length of an inference.

    /// Scores one 48 kHz window; `nil` = no real score (model not loaded, inference error).
    typealias Scorer = @Sendable ([Float]) -> Float?
    /// Runs one inference job off the caller's thread.
    typealias Executor = @Sendable (@escaping @Sendable () -> Void) -> Void

    /// Read-only counters, for tests and the throttled diagnostic line.
    struct Tier1Stats: Equatable {
        var windowsReady = 0
        /// Discarded because the previous inference was less than `minVoicedMsBetweenInferences` of voice ago.
        var windowsSkipped = 0
        /// Discarded because an inference was still in flight (or a chunk completed several eligible windows).
        var windowsDropped = 0
        var inferences = 0
        var nilScores = 0
        var inferenceInFlight = false
        var pendingSamples = 0
    }

    private let scorer: Scorer
    private let executor: Executor
    private let nowMs: @Sendable () -> Int64
    private let confidence = ConfidenceIndex()
    private let lock = NSLock()
    private var enabled = true
    private var accumulator: GuardianWindowAccumulator
    private var stats = Tier1Stats()

    /// Minimum voiced audio between the windows of two Tier 1 inferences (W-GUARDIAN1CONTIG). With 4.04 s
    /// windows this is one window in two: one inference per 8.075 s of voiced remote speech.
    static let minVoicedMsBetweenInferences = 8_000
    private static let minVoicedSamplesBetweenInferences = minVoicedMsBetweenInferences * 48
    private let windowSamples: Int
    /// Voiced samples taken in up to the end of the last completed window, and up to the end of the last window
    /// handed to the scorer (`nil` before the first).
    private var voicedSamplesAtWindowEnd = 0
    private var lastScoredWindowEnd: Int?

    private var redThreshold: Float = ConfidenceIndex.redThreshold
    private var sustainedRedStartMs: Int64?
    // 5 s of sustained red required before alarm — effectively impossible for genuine voice.
    // With 2.63% EER model a single misfiring inference doesn't cause an alert.
    private let sustainedRedDurationMs: Int64 = 5000
    private let alertCooldownMs: Int64 = 30000  // 30 s cooldown between alerts
    /// `nil` until the first alert: the first alert is never held back by the cooldown, whatever the clock's
    /// origin (it used to be `0` against an epoch clock, which meant the same thing).
    private var lastAlertMs: Int64?

    public convenience init() {
        let analyzer = VoiceprintAnalyzer()
        let queue = DispatchQueue(label: "qaudion.guardian.tier1", qos: .utility)
        self.init(
            scorer: { analyzer.score(window48k: $0) },
            executor: { job in queue.async { job() } },
            nowMs: { Int64(Date().timeIntervalSince1970 * 1000) }
        )
    }

    init(
        scorer: @escaping Scorer,
        executor: @escaping Executor,
        nowMs: @escaping @Sendable () -> Int64,
        windowSamples: Int = GuardianWindowAccumulator.defaultWindowSamples
    ) {
        self.scorer = scorer
        self.executor = executor
        self.nowMs = nowMs
        self.windowSamples = windowSamples
        self.accumulator = GuardianWindowAccumulator(windowSamples: windowSamples)
    }

    /// One decoded RX chunk (little-endian Int16 mono 48 kHz, any length). Cheap: VAD + copy, and at most one
    /// hand-off to the inference queue per `minVoicedMsBetweenInferences` of voiced audio.
    public func processFrame(_ pcmFrame: Data) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        let windows = accumulator.append(int16LE: pcmFrame)
        stats.pendingSamples = accumulator.pendingSamples
        var candidate: (window: [Float], end: Int)?
        for window in windows {
            stats.windowsReady += 1
            voicedSamplesAtWindowEnd += windowSamples
            if let last = lastScoredWindowEnd,
               voicedSamplesAtWindowEnd - last < Self.minVoicedSamplesBetweenInferences {
                stats.windowsSkipped += 1
                continue
            }
            // Only a chunk longer than a whole window can make two eligible: score the newest, drop the rest.
            if candidate != nil { stats.windowsDropped += 1 }
            candidate = (window: window, end: voicedSamplesAtWindowEnd)
        }
        guard let pick = candidate else { lock.unlock(); return }
        guard !stats.inferenceInFlight else {
            stats.windowsDropped += 1
            lock.unlock()
            return
        }
        lastScoredWindowEnd = pick.end
        stats.inferenceInFlight = true
        lock.unlock()

        let newest = pick.window
        executor { [weak self] in self?.runInference(on: newest) }
    }

    private func runInference(on window: [Float]) {
        let startedNs = DispatchTime.now().uptimeNanoseconds
        let scored = scorer(window)
        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000)

        // 2026-08-21 — no real inference (model not loaded, inference error) MUST skip the EMA update rather
        // than feed it a fabricated score: a placeholder 0.5 used to hold genuine voice near 50.
        guard let score = scored else {
            lock.lock()
            stats.nilScores += 1
            stats.inferenceInFlight = false
            lock.unlock()
            return
        }
        let level = confidence.update(score)

        lock.lock()
        stats.inferences += 1
        stats.inferenceInFlight = false
        var fire = false
        let now = nowMs()
        if level == .red {
            if sustainedRedStartMs == nil { sustainedRedStartMs = now }
            if let start = sustainedRedStartMs,
               (now - start) >= sustainedRedDurationMs,
               lastAlertMs.map({ now - $0 >= alertCooldownMs }) ?? true {
                lastAlertMs = now
                fire = true
            }
        } else {
            sustainedRedStartMs = nil
        }
        let callback = fire ? onAlert : nil
        let s = stats
        lock.unlock()

        // Measured cost of the Tier 1 inference, throttled (first, then every 10th): counts and milliseconds
        // only, never audio or scores of individual windows.
        if s.inferences == 1 || s.inferences % 10 == 0 {
            print("[GuardianMode] tier1 inf n=\(s.inferences) ms=\(elapsedMs) windows=\(s.windowsReady) skipped=\(s.windowsSkipped) dropped=\(s.windowsDropped) nil=\(s.nilScores)")
        }
        callback?(.red, score)
    }

    public func setEnabled(_ enabled: Bool) { lock.lock(); self.enabled = enabled; lock.unlock() }
    public func setSensitivity(redThreshold: Float, yellowThreshold: Float) {
        lock.lock(); self.redThreshold = redThreshold; lock.unlock()
    }
    public func getConfidenceIndex() -> ConfidenceIndex { confidence }
    public var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }

    var tier1Stats: Tier1Stats { lock.lock(); defer { lock.unlock() }; return stats }
}
