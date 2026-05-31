import Foundation

public final class GuardianMode: @unchecked Sendable {
    public var onAlert: ((ConfidenceIndex.Level, Float) -> Void)?

    /// Weight for the ML spoof-probability component in the combined score.
    /// Mirrors the Desktop/Android Guardian: `0.7 * ml + 0.3 * lfcc`.
    public static let mlWeight: Float = 0.7
    /// Weight for the LFCC voiceprint-mismatch component.
    public static let lfccWeight: Float = 0.3

    private let analyzer = VoiceprintAnalyzer()
    private let classifier = DeepfakeClassifier.shared
    private let confidence = ConfidenceIndex()
    private let lock = NSLock()
    private var enabled = true
    private var frameCount: Int64 = 0
    private var analysisRate: Int = 5  // analyze every Nth frame
    private var redThreshold: Float = ConfidenceIndex.redThreshold
    private var sustainedRedStartMs: Int64? = nil
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
        guard frameCount % Int64(analysisRate) == 0 else { lock.unlock(); return }
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

    /// Combine the AASIST ML spoof probability with an LFCC voiceprint mismatch
    /// into a single Guardian threat score in `[0, 1]`.
    ///
    /// Score formula (matches Desktop / Android Guardian):
    /// `0.7 * spoofProbability + 0.3 * lfccMismatch`, clamped to `[0, 1]`.
    ///
    /// - Parameters:
    ///   - pcm16kMono: Raw 16 kHz mono Float32 samples (ideally 64600 long;
    ///     padded/truncated as needed by `DeepfakeClassifier`).
    ///   - lfccMismatch: LFCC voiceprint mismatch in `[0, 1]`. A typical
    ///     caller computes `max(0, 1 - cosineSimilarity)` against the enrolled
    ///     voiceprint. Pass `0` when no voiceprint is enrolled — the score
    ///     then collapses to `0.7 * spoofProbability`.
    /// - Returns: `(combinedScore, spoofProbability, mlConfidence)`.
    ///   If the ML runtime is unavailable (simulator / not linked), the
    ///   combined score falls back to `lfccMismatch` and `spoofProbability`
    ///   is reported as `0.5` (neutral).
    public func combinedThreatScore(
        pcm16kMono: [Float],
        lfccMismatch: Float
    ) async -> (combined: Float, spoofProbability: Float, mlConfidence: Float) {
        let lfcc = max(0, min(1, lfccMismatch))
        do {
            let (spoof, conf) = try await classifier.score(pcm16kMono: pcm16kMono)
            let combined = Self.mlWeight * spoof + Self.lfccWeight * lfcc
            return (min(1, max(0, combined)), spoof, conf)
        } catch {
            // ONNX unavailable: keep LFCC path alive, neutral ML component.
            return (lfcc, 0.5, 0.5)
        }
    }
}
