import Foundation

public final class VoiceAnalysisEngine: @unchecked Sendable {
    public var onResult: ((VoiceAnalysisResult) -> Void)?

    private let pitchExtractor = PitchExtractor()
    private let stressDetector = StressDetector()
    private let formantTracker = FormantTracker()
    private let healthMonitor = VoiceHealthMonitor()
    private let speechRateAnalyzer = SpeechRateAnalyzer()
    private let confidenceIndicator = ConfidenceIndicator()

    private let lock = NSLock()
    private var enabled = true
    private var frameCount: Int64 = 0
    private var analysisRate: Int = 5

    /// How often the analyser should actually run, in MILLISECONDS.
    ///
    /// 2026-08-27 — same bug class as `GuardianMode` (fixed 2026-08-12, see
    /// that type's doc comment for the original incident). `analysisRate`
    /// counted FRAMES, and a frame stopped being a fixed amount of time once
    /// the 60 ms profile shipped, and again with the native-SRTP tap's
    /// ~10 ms chunks (`NativeAudioPcmTap` → `QAudionCallIntegration.analyze`).
    /// Every 5th frame is 100 ms at 20 ms, 300 ms at 60 ms, and 50 ms at
    /// 10 ms — pitch/stress/formants/health/speechRate/confidence delivered
    /// via `onResult` arrived at three different real-world rates depending
    /// on which path fed the frame, none of them intentional.
    ///
    /// `QAudionCallIntegration.analyze(_:)` calls `guardianMode.processFrame`
    /// and `voiceAnalysis.processFrame` back-to-back on the exact same
    /// decoded RX `pcm` — same input stream, so the same 100 ms target
    /// GuardianMode was fixed to applies here unchanged.
    private static let analysisIntervalMs: Int = 100

    /// Milliseconds of audio seen since the last analysis. Accumulated from
    /// the FRAMES THEMSELVES rather than from a clock — see `GuardianMode`'s
    /// identical field for why: this runs on the receive path, where the
    /// meaningful rate is audio time, and a wall clock would keep advancing
    /// through a gap in which no audio arrived at all.
    private var pendingMs: Int = 0

    public init() {}

    public func processFrame(_ pcmFrame: Data) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        frameCount += 1
        // Frame duration derived from the buffer in hand — 48 kHz mono Int16
        // is 96 bytes per millisecond — so this holds for any cadence a peer
        // sends, negotiated or not, without this path having to be told.
        // Falls back to the frame-count heuristic when the length is not a
        // whole number of milliseconds, which means it is not the PCM this
        // expects.
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
        let callback = onResult
        lock.unlock()

        let pitch = pitchExtractor.extract(pcmFrame: pcmFrame)
        let stress = stressDetector.analyze(pitch: pitch)
        let formants = formantTracker.extract(pcmFrame: pcmFrame)
        let health = healthMonitor.analyze(pitch: pitch, pcmFrame: pcmFrame)
        let speechRate = speechRateAnalyzer.analyze(pcmFrame: pcmFrame, pitch: pitch)
        let confidence = confidenceIndicator.analyze(pitch: pitch, stress: stress, health: health, speechRate: speechRate)

        let result = VoiceAnalysisResult(pitch: pitch, stress: stress, voiceHealth: health,
            speechRate: speechRate, formants: formants, confidence: confidence)
        callback?(result)
    }

    public func setEnabled(_ enabled: Bool) { lock.lock(); self.enabled = enabled; lock.unlock() }
    public func setAnalysisRate(_ rate: Int) { lock.lock(); analysisRate = max(1, rate); lock.unlock() }
    public var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
}
