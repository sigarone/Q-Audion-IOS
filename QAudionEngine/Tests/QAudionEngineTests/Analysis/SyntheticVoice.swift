import Foundation
@testable import QAudionEngine

/// Synthetic voice for the analysis tests: a glottal pulse train at f0 (the
/// derivative of a Rosenberg flow pulse, evaluated at the exact sample time so
/// the period carries no jitter), through a cascade of three second-order
/// resonators at F1/F2/F3 with bandwidths 80/90/120 Hz, at 48 kHz.
///
/// Because the true f0, formants, SNR and syllable rate are known by
/// construction, a test that feeds this through the engine checks the engine
/// against ground truth.
enum SyntheticVoice {
    static let sampleRate = 48_000.0

    struct Vowel {
        let f1: Double
        let f2: Double
        let f3: Double
    }

    static let a = Vowel(f1: 700, f2: 1220, f3: 2600)
    static let i = Vowel(f1: 270, f2: 2290, f3: 3010)
    static let u = Vowel(f1: 300, f2: 870, f3: 2240)

    static let bandwidths: [Double] = [80, 90, 120]

    /// Deterministic noise (xorshift64* -> uniform -> Box-Muller).
    struct Rng {
        private var state: UInt64
        private var spare: Double?

        init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) { state = seed }

        mutating func uniform() -> Double {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let v = state &* 0x2545_F491_4F6C_DD1D
            return (Double(v >> 11) + 0.5) / 9_007_199_254_740_992.0
        }

        mutating func gaussian() -> Double {
            if let s = spare {
                spare = nil
                return s
            }
            let u1 = uniform()
            let u2 = uniform()
            let r = (-2.0 * log(u1)).squareRoot()
            spare = r * sin(2.0 * Double.pi * u2)
            return r * cos(2.0 * Double.pi * u2)
        }
    }

    private static func glottalDerivative(phase: Double) -> Double {
        let tp = 0.4, tn = 0.16
        if phase < tp { return 0.5 * Double.pi / tp * sin(Double.pi * phase / tp) }
        if phase < tp + tn { return -(Double.pi / 2.0) / tn * sin(Double.pi / 2.0 * (phase - tp) / tn) }
        return 0
    }

    private static func resonate(_ x: [Double], frequency: Double, bandwidth: Double) -> [Double] {
        let c = -exp(-2.0 * Double.pi * bandwidth / sampleRate)
        let b = 2.0 * exp(-Double.pi * bandwidth / sampleRate) * cos(2.0 * Double.pi * frequency / sampleRate)
        let a = 1.0 - b - c
        var y1 = 0.0, y2 = 0.0
        var out = [Double](repeating: 0, count: x.count)
        for n in 0..<x.count {
            let y = a * x[n] + b * y1 + c * y2
            out[n] = y
            y2 = y1
            y1 = y
        }
        return out
    }

    static func rms(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        var sum = 0.0
        for v in x { sum += v * v }
        return (sum / Double(x.count)).squareRoot()
    }

    /// A steady vowel of the given f0, scaled to the given RMS.
    static func vowel(f0: Double, _ vowel: Vowel, seconds: Double, rms target: Double = 0.1) -> [Double] {
        let n = Int((seconds * sampleRate).rounded())
        var y = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let phase = (f0 * Double(k) / sampleRate).truncatingRemainder(dividingBy: 1.0)
            y[k] = glottalDerivative(phase: phase)
        }
        for (formant, bandwidth) in zip([vowel.f1, vowel.f2, vowel.f3], bandwidths) {
            y = resonate(y, frequency: formant, bandwidth: bandwidth)
        }
        let gain = target / rms(y)
        return y.map { $0 * gain }
    }

    /// `x` plus white Gaussian noise at the given SNR (dB, full band).
    static func addNoise(_ x: [Double], snrDb: Double, seed: UInt64 = 1) -> [Double] {
        let noiseRms = rms(x) / pow(10.0, snrDb / 20.0)
        var rng = Rng(seed: seed)
        return x.map { $0 + noiseRms * rng.gaussian() }
    }

    static func whiteNoise(seconds: Double, rms: Double, seed: UInt64 = 7) -> [Double] {
        var rng = Rng(seed: seed)
        return (0..<Int((seconds * sampleRate).rounded())).map { _ in rms * rng.gaussian() }
    }

    /// Amplitude-modulate into WHOLE syllables (a sin^2 hump per syllable, period
    /// 1/rate). Each block holds round((blockSeconds - pause) * rate) whole
    /// syllables followed by `pause` seconds of digital silence, so the true rate
    /// while speaking is exactly `rate`.
    static func syllabic(_ x: [Double], rate: Double, pause: Double = 0.4, blockSeconds: Double = 2.0) -> [Double] {
        let syllables = (blockSeconds - pause) * rate
        let nSyllables = syllables.rounded()
        let syllableLength = 1.0 / rate
        let block = nSyllables * syllableLength + pause
        var out = [Double](repeating: 0, count: x.count)
        for k in 0..<x.count {
            let t = Double(k) / sampleRate
            let tb = t.truncatingRemainder(dividingBy: block)
            if tb >= nSyllables * syllableLength { continue }
            let tl = tb.truncatingRemainder(dividingBy: syllableLength)
            let s = sin(Double.pi * tl * rate)
            out[k] = x[k] * s * s
        }
        return out
    }

    static func sine(frequency: Double, seconds: Double, amplitude: Double = 0.5) -> [Double] {
        (0..<Int((seconds * sampleRate).rounded())).map {
            amplitude * sin(2.0 * Double.pi * frequency * Double($0) / sampleRate)
        }
    }

    /// Little-endian Int16 PCM, as the engine receives it.
    static func pcm(_ x: [Double], from: Int = 0, count: Int? = nil) -> Data {
        let n = count ?? (x.count - from)
        var data = Data(capacity: n * 2)
        for k in from..<(from + n) {
            let q = Int16(max(-32768.0, min(32767.0, (x[k] * 32767.0).rounded())))
            let u = UInt16(bitPattern: q)
            data.append(UInt8(u & 0xFF))
            data.append(UInt8(u >> 8))
        }
        return data
    }

    struct Run {
        var results: [VoiceAnalysisResult] = []
        /// Samples fed when each result was delivered.
        var stamps: [Int] = []
    }

    /// Feed `x` to `engine` in chunks of `chunkMs` and collect every result.
    @discardableResult
    static func run(_ x: [Double], chunkMs: Int, engine: VoiceAnalysisEngine = VoiceAnalysisEngine()) -> Run {
        var run = Run()
        var fed = 0
        engine.onResult = { result in
            run.results.append(result)
            run.stamps.append(fed)
        }
        let chunk = chunkMs * 48
        var offset = 0
        while offset + chunk <= x.count {
            fed = offset + chunk
            engine.processFrame(pcm(x, from: offset, count: chunk))
            offset += chunk
        }
        engine.onResult = nil
        return run
    }

    /// A `VoiceWindow` holding the last 60 ms of `x`, snapshotted (for the
    /// per-measurement unit tests).
    static func window(of x: [Double], endingAt end: Int? = nil) -> VoiceWindow {
        let w = VoiceWindow()
        let stop = end ?? x.count
        let start = max(0, stop - VoiceDsp.windowSamples)
        // Quantise through Int16 exactly like the engine's input.
        var samples = [Double](repeating: 0, count: stop - start)
        for k in start..<stop {
            let q = Int16(max(-32768.0, min(32767.0, (x[k] * 32767.0).rounded())))
            samples[k - start] = Double(q) / 32768.0
        }
        samples.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { w.append(base, count: buffer.count) }
        }
        w.snapshot()
        return w
    }
}
