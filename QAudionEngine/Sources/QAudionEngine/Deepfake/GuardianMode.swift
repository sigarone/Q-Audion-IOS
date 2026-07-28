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
}
