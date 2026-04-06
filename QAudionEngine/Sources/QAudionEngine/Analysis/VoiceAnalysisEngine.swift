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

    public init() {}

    public func processFrame(_ pcmFrame: Data) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        frameCount += 1
        guard frameCount % Int64(analysisRate) == 0 else { lock.unlock(); return }
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
