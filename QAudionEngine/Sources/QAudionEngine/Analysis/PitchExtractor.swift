import Foundation

/// Autocorrelation F0 extractor over 16-bit LE mono PCM @ 48 kHz.
///
/// The voicing decision and the period search live in
/// `VoicedDecisionPolicy` — see its doc comment for why the correlation
/// MUST be normalised (the un-normalised version made `voiced` permanently
/// false at real call levels, zeroing every Guardian-ribbon gauge).
public final class PitchExtractor {
    private let sampleRate: Float = 48000
    private let minF0: Float = 50
    private let maxF0: Float = 600

    public init() {}

    public func extract(pcmFrame: Data) -> VoiceAnalysisResult.Pitch {
        let samples = pcmToFloat(pcmFrame)
        guard samples.count >= 480 else {
            return VoiceAnalysisResult.Pitch(f0Hz: 0, voiced: false, rms: 0)
        }

        let rms = VoicedDecisionPolicy.rms(samples)
        guard rms > VoicedDecisionPolicy.minRms else {
            return VoiceAnalysisResult.Pitch(f0Hz: 0, voiced: false, rms: rms)
        }

        // Searchable period range. NOTE the `samples.count / 2` clamp: with a
        // 20 ms frame (960 samples) the longest reachable lag is 480, i.e.
        // F0 >= 100 Hz. Deep male voices below that are reported at the range
        // edge. Android has the identical clamp
        // (`effectiveMaxLag = minOf(maxLag, preEmp.size / 2)`), so this is a
        // shared, known limitation — not a new one.
        let minLag = Int(sampleRate / maxF0)
        let maxLag = min(Int(sampleRate / minF0), samples.count / 2)
        guard maxLag > minLag else {
            return VoiceAnalysisResult.Pitch(f0Hz: 0, voiced: false, rms: rms)
        }

        let estimate = VoicedDecisionPolicy.bestPeriod(samples, minLag: minLag, maxLag: maxLag)
        let f0 = estimate.lag > 0 ? sampleRate / estimate.lag : 0
        let voiced = VoicedDecisionPolicy.isVoiced(correlation: estimate.correlation,
                                                   f0Hz: f0,
                                                   rms: rms,
                                                   minF0: minF0,
                                                   maxF0: maxF0)
        return VoiceAnalysisResult.Pitch(f0Hz: voiced ? f0 : 0, voiced: voiced, rms: rms)
    }

    private func pcmToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        var floats = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<count { floats[i] = Float(ptr[i]) / 32768.0 }
        }
        return floats
    }
}
