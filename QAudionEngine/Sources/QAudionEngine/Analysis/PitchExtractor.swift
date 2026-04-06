import Foundation

public final class PitchExtractor {
    private let sampleRate: Float = 48000
    private let minF0: Float = 50
    private let maxF0: Float = 600

    public init() {}

    public func extract(pcmFrame: Data) -> VoiceAnalysisResult.Pitch {
        let samples = pcmToFloat(pcmFrame)
        guard samples.count >= 480 else { return VoiceAnalysisResult.Pitch(f0Hz: 0, voiced: false, rms: 0) }
        let rms = computeRms(samples)
        guard rms > 0.01 else { return VoiceAnalysisResult.Pitch(f0Hz: 0, voiced: false, rms: rms) }

        // Autocorrelation-based pitch detection
        let minLag = Int(sampleRate / maxF0)
        let maxLag = Int(sampleRate / minF0)
        var bestLag = 0; var bestCorr: Float = 0
        let n = samples.count

        for lag in minLag..<min(maxLag, n / 2) {
            var corr: Float = 0
            for i in 0..<(n - lag) { corr += samples[i] * samples[i + lag] }
            corr /= Float(n - lag)
            if corr > bestCorr { bestCorr = corr; bestLag = lag }
        }

        let f0 = bestLag > 0 ? sampleRate / Float(bestLag) : 0
        let voiced = bestCorr > 0.3 && f0 >= minF0 && f0 <= maxF0
        return VoiceAnalysisResult.Pitch(f0Hz: voiced ? f0 : 0, voiced: voiced, rms: rms)
    }

    private func computeRms(_ samples: [Float]) -> Float {
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sum / Float(samples.count))
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
