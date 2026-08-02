import Foundation

public final class VoiceHealthMonitor {
    public init() {}

    public func analyze(pitch: VoiceAnalysisResult.Pitch, pcmFrame: Data) -> VoiceAnalysisResult.VoiceHealth {
        guard pitch.voiced else { return VoiceAnalysisResult.VoiceHealth(hnr: 0, breathiness: 1.0) }
        let hnr = estimateHNR(pcmFrame)
        // Clamped at BOTH ends (2026-08-02). It was `max(0, …)` only, so the
        // floor was enforced and the ceiling was not: HNR is a ratio in dB and
        // goes NEGATIVE whenever noise dominates the harmonic part, which
        // makes `1 - hnr/20` exceed 1. Measured 1.5292995 on a random-noise
        // frame — the exact value `testNoiseInputHealth` reported before this
        // class was excluded from CI on 2026-06-19.
        //
        // [0, 1] is the contract everywhere else in this file and its tests:
        // the unvoiced early-return above hands back exactly 1.0, and
        // `testShortFrameWithVoicedPitch` pins 1.0 for a zero-HNR frame. The
        // value is rendered directly in the in-call diagnostics
        // (`InCallScreen`, `LiveInCallScreen`), so out-of-range readings
        // reached the UI on any noisy frame.
        let breathiness = min(1.0, max(0, 1.0 - hnr / 20.0))
        return VoiceAnalysisResult.VoiceHealth(hnr: hnr, breathiness: breathiness)
    }

    private func estimateHNR(_ data: Data) -> Float {
        let samples = pcmToFloat(data)
        guard samples.count > 100 else { return 0 }
        let energy = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        // Simplified HNR: ratio of periodic to noise energy
        var periodicEnergy: Float = 0
        for i in 1..<samples.count { periodicEnergy += samples[i] * samples[i-1] }
        periodicEnergy /= Float(samples.count - 1)
        let noiseEnergy = max(0.0001, energy - abs(periodicEnergy))
        return 10 * log10(max(0.0001, abs(periodicEnergy)) / noiseEnergy)
    }

    private func pcmToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        var floats = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<count { floats[i] = Float(ptr[i]) / 32768.0 }
        }
        return floats
    }
}
