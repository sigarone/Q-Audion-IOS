import Foundation

public final class GuardianMode: @unchecked Sendable {
    public var onAlert: ((ConfidenceIndex.Level, Float) -> Void)?

    /// Drives `ConfidenceIndex` off a single AASIST-raw spoof score from
    /// `VoiceprintAnalyzer`, sampled every `analysisRate`-th frame on the
    /// synchronous audio-processing thread (no per-frame Task/dispatch —
    /// see the never-block note at the `processFrame` call site in
    /// `QAudionCallIntegration`).
    ///
    /// Unlike the Desktop Guardian (`GuardianScorer.ts`, `0.7 * ml + 0.3 *
    /// lfcc`), this does NOT fuse an ML score with a real LFCC/voiceprint
    /// mismatch score. `DeepfakeClassifier` (a second, `async` AASIST path)
    /// and `SpeakerVerifier`/`LfccExtractor` (the actual LFCC leg, requires
    /// speaker enrollment) exist in this module but aren't wired in here —
    /// same Sprint-22-pending status as the third `LcnnDetector` leg.

    private let analyzer = VoiceprintAnalyzer()
    private let confidence = ConfidenceIndex()
    private let lock = NSLock()
    private var enabled = true
    private var frameCount: Int64 = 0
    private var analysisRate: Int = 5  // analyze every Nth frame

    /// How often the analyser should actually run, in MILLISECONDS.
    ///
    /// 2026-08-12 — `analysisRate` counts FRAMES, and a frame stopped being a
    /// fixed amount of time when the 60 ms profile shipped. Every 5th frame is
    /// every 100 ms at 20 ms and every 300 ms at 60 ms, so the confidence
    /// history advanced at a third of its rate while `AppState`'s sampler kept
    /// reading it at 5 Hz. On a device that reads as a meter that has stopped —
    /// reported as "il confidence meter sembra fermo o non funzionare", on a
    /// call that was otherwise fine.
    ///
    /// 100 ms is not a new number: it is what `analysisRate = 5` has always
    /// meant at the shipping cadence. Stating it as a duration keeps that
    /// behaviour identical at 20 ms and restores it at every other frame size.
    private static let analysisIntervalMs: Int = 100

    /// Milliseconds of audio seen since the last analysis. Accumulated from the
    /// FRAMES THEMSELVES rather than from a clock: this runs on the receive
    /// path, where the meaningful rate is audio time, and a wall clock would
    /// keep advancing through a gap in which no audio arrived at all.
    private var pendingMs: Int = 0
    private var redThreshold: Float = ConfidenceIndex.redThreshold
    private var sustainedRedStartMs: Int64?
    // 5 s of sustained red required before alarm — effectively impossible for genuine voice.
    // With 2.63% EER model a single misfiring inference doesn't cause an alert.
    private let sustainedRedDurationMs: Int64 = 5000
    private let alertCooldownMs: Int64 = 30000  // 30 s cooldown between alerts
    private var lastAlertMs: Int64 = 0

    public init() {}

    public func processFrame(_ pcmFrame: Data) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        frameCount += 1
        // Frame duration derived from the buffer in hand — 48 kHz mono Int16 is
        // 96 bytes per millisecond — so this holds for any cadence a peer sends,
        // negotiated or not, without the receive path having to be told.
        // Falls back to the counter when the length is not a whole number of
        // milliseconds, which means it is not the PCM this expects.
        let frameMs = pcmFrame.count / 96
        let due: Bool
        if frameMs > 0 {
            pendingMs += frameMs
            due = pendingMs >= Self.analysisIntervalMs
            if due { pendingMs = 0 }
        } else {
            due = frameCount % Int64(analysisRate) == 0
        }
        guard due else { lock.unlock(); return }
        lock.unlock()

        let score = analyzer.analyze(pcmFrame: pcmFrame)
        let level = confidence.update(score)

        lock.lock()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if level == .red {
            if sustainedRedStartMs == nil { sustainedRedStartMs = now }
            if let start = sustainedRedStartMs,
               (now - start) >= sustainedRedDurationMs,
               (now - lastAlertMs) >= alertCooldownMs {
                lastAlertMs = now
                let callback = onAlert
                lock.unlock()
                callback?(.red, score)
                return
            }
        } else {
            sustainedRedStartMs = nil
        }
        lock.unlock()
    }

    public func setEnabled(_ enabled: Bool) { lock.lock(); self.enabled = enabled; lock.unlock() }
    public func setAnalysisRate(_ rate: Int) { lock.lock(); analysisRate = max(1, rate); lock.unlock() }
    public func setSensitivity(redThreshold: Float, yellowThreshold: Float) {
        lock.lock(); self.redThreshold = redThreshold; lock.unlock()
    }
    public func getConfidenceIndex() -> ConfidenceIndex { confidence }
    public var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
}
