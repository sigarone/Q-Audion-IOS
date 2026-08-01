import Foundation

/// Kaldi-compatible 80-dim log mel-filterbank ("fbank") feature extractor —
/// the exact frontend the CAM++ speaker-embedding model
/// (`campplus_sv_voxceleb_16k.onnx`) was trained and is served with in
/// production (k2-fsa/sherpa-onnx).
///
/// This is a DIFFERENT feature type from this codebase's existing
/// `LfccExtractor` (LFCC, Hamming window, linear-spaced filters, used by the
/// AASIST deepfake model and the legacy classical speaker-embedding path) —
/// do not conflate the two or assume shared parameters.
///
/// 2026-08-01: ported line-for-line from the already-validated Android
/// implementation (`qaudion-engine/.../deepfake/KaldiFbankExtractor.kt`,
/// itself confirmed 2026-07-31 against the LIVE sherpa-onnx source —
/// `sherpa-onnx/csrc/features.h`, `speaker-embedding-extractor-general-impl.h`
/// — and cross-checked against the original 3D-Speaker training code). The
/// FFT here is a manual Cooley-Tukey radix-2 implementation (NOT `vDSP`'s
/// `vDSP_fft_zrip`, unlike `LfccExtractor`) deliberately — this Swift file
/// cannot be compiled or run on the Windows machine that wrote it (no Xcode),
/// so it mirrors the Kotlin reference's own manual FFT bit-for-bit rather
/// than risk a subtly different `vDSP` convention (ordering, normalization,
/// real/imaginary packing) going unverified. Getting any parameter below
/// wrong produces a silently-degraded (not obviously broken) embedding —
/// exactly the failure mode that made the previous classical-DSP speaker
/// verification unable to tell two real speakers apart.
///
///  - sample rate: 16000 Hz — caller must resample first, this class does not
///  - frame length 25ms (400 samples), frame shift 10ms (160 samples)
///  - window: Povey — `(0.5 - 0.5*cos(2*pi*n/(N-1)))^0.85`, NOT Hamming
///  - pre-emphasis coefficient 0.97
///  - dither: 0 (disabled)
///  - DC offset removed per-frame before windowing
///  - FFT size: next power of two >= frame length (512 for 400 samples)
///  - 80 triangular MEL-scale filters (Kaldi mel formula,
///    `mel = 1127 * ln(1 + hz/700)`), NOT the linear-spaced filters
///    `LfccExtractor` uses
///  - log energy, floor = `std::numeric_limits<float>::epsilon()`-equivalent
///  - `snip_edges = false` — Kaldi's non-snip framing: frame count is
///    `round(numSamples / frameShift)`, frames may extend past the signal's
///    edges, filled via Kaldi's `Reflect()` mirroring — NOT the simple
///    truncating/zero-padding framing `LfccExtractor` uses
///  - normalization: CMN only (per-mel-bin mean subtracted across every
///    frame passed into one `extract` call) — no variance normalization,
///    matches sherpa-onnx's "global-mean" `feature_normalize_type`
public final class KaldiFbankExtractor {
    public static let sampleRate = 16_000
    public static let numMelBins = 80
    private static let frameLengthMs = 25
    private static let frameShiftMs = 10
    private static let preEmphCoeff: Float = 0.97
    private static let melLowFreqHz = 20.0
    private static let logFloor: Float = 1.1920929e-7 // std::numeric_limits<float>::epsilon()

    private let sampleRateHz: Int
    private let numMelBinsCount: Int
    private let frameLengthSamples: Int
    private let frameShiftSamples: Int
    private let fftSize: Int
    private let poveyWindow: [Float]
    private let melFilters: [[Float]]

    public init(sampleRate: Int = KaldiFbankExtractor.sampleRate, numMelBins: Int = KaldiFbankExtractor.numMelBins) {
        self.sampleRateHz = sampleRate
        self.numMelBinsCount = numMelBins
        self.frameLengthSamples = sampleRate * Self.frameLengthMs / 1000
        self.frameShiftSamples = sampleRate * Self.frameShiftMs / 1000
        self.fftSize = Self.nextPowerOfTwo(frameLengthSamples)

        let n = frameLengthSamples
        var window = [Float](repeating: 0, count: n)
        let denom = Float(max(n - 1, 1))
        for i in 0..<n {
            let hann = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(denom))
            window[i] = Float(pow(hann, 0.85))
        }
        self.poveyWindow = window

        self.melFilters = Self.buildMelFilterbank(
            sampleRate: sampleRate, numMelBins: numMelBins, fftSize: fftSize, lowFreqHz: Self.melLowFreqHz
        )
    }

    /// Extract log-mel fbank frames from a signal already at `sampleRate`.
    /// Returns `[numFrames][numMelBins]`, CMN-normalized across this WHOLE
    /// call — pass the entire buffer you want normalized together, matching
    /// how sherpa-onnx normalizes over its whole buffered utterance (never
    /// call this per-tiny-chunk and expect consistent normalization across
    /// calls).
    public func extract(_ signal: [Float]) -> [[Float]] {
        let numFrames = numFramesNonSnip(signal.count)
        guard numFrames > 0 else { return [] }

        var frames = [[Float]](repeating: [Float](repeating: 0, count: numMelBinsCount), count: numFrames)
        var real = [Float](repeating: 0, count: fftSize)
        var imag = [Float](repeating: 0, count: fftSize)
        var powerSpec = [Float](repeating: 0, count: fftSize / 2 + 1)

        for f in 0..<numFrames {
            extractWindowNonSnip(signal, frameIndex: f, out: &real)
            if frameLengthSamples < fftSize {
                for i in frameLengthSamples..<fftSize { real[i] = 0 }
            }
            for i in 0..<imag.count { imag[i] = 0 }
            removeDcOffset(&real, length: frameLengthSamples)
            preEmphasize(&real, length: frameLengthSamples)
            applyPoveyWindow(&real)
            fft(real: &real, imag: &imag)
            for k in 0..<powerSpec.count {
                let re = real[k]
                let im = imag[k]
                powerSpec[k] = re * re + im * im
            }
            for m in 0..<numMelBinsCount {
                var e: Float = 0
                let filt = melFilters[m]
                for k in 0..<filt.count { e += filt[k] * powerSpec[k] }
                frames[f][m] = log(max(e, Self.logFloor))
            }
        }
        subtractGlobalMean(&frames)
        return frames
    }

    // MARK: - Kaldi non-snip framing (snip_edges=false)

    private func numFramesNonSnip(_ numSamples: Int) -> Int {
        guard numSamples > 0 else { return 0 }
        // Kaldi: num_frames = round(num_samples / frame_shift), i.e. integer
        // division of (num_samples + frame_shift/2) by frame_shift.
        return (numSamples + frameShiftSamples / 2) / frameShiftSamples
    }

    /// Fills `out`'s first `frameLengthSamples` entries with frame
    /// `frameIndex`'s samples, reflecting at the signal edges (Kaldi's
    /// `Reflect`).
    private func extractWindowNonSnip(_ signal: [Float], frameIndex: Int, out: inout [Float]) {
        let midpoint = frameShiftSamples * frameIndex + frameShiftSamples / 2
        let firstSample = midpoint - frameLengthSamples / 2
        for i in 0..<frameLengthSamples {
            out[i] = signal[Self.reflect(firstSample + i, dim: signal.count)]
        }
    }

    /// Kaldi's `Reflect()` — mirrors an out-of-range sample index back into `[0, dim)`.
    private static func reflect(_ nIn: Int, dim: Int) -> Int {
        guard dim > 0 else { return 0 }
        var n = nIn
        while true {
            if n < 0 {
                n = -n - 1
            } else if n >= dim {
                n = 2 * dim - 1 - n
            } else {
                return n
            }
        }
    }

    private func removeDcOffset(_ frame: inout [Float], length: Int) {
        var sum: Float = 0
        for i in 0..<length { sum += frame[i] }
        let mean = sum / Float(length)
        for i in 0..<length { frame[i] -= mean }
    }

    private func preEmphasize(_ frame: inout [Float], length: Int) {
        var i = length - 1
        while i >= 1 {
            frame[i] -= Self.preEmphCoeff * frame[i - 1]
            i -= 1
        }
        frame[0] -= Self.preEmphCoeff * frame[0]
    }

    private func applyPoveyWindow(_ frame: inout [Float]) {
        for i in 0..<frameLengthSamples { frame[i] *= poveyWindow[i] }
    }

    private func subtractGlobalMean(_ frames: inout [[Float]]) {
        guard !frames.isEmpty else { return }
        let dim = frames[0].count
        var mean = [Float](repeating: 0, count: dim)
        for fr in frames { for d in 0..<dim { mean[d] += fr[d] } }
        for d in 0..<dim { mean[d] /= Float(frames.count) }
        for i in 0..<frames.count {
            for d in 0..<dim { frames[i][d] -= mean[d] }
        }
    }

    /// In-place Cooley-Tukey radix-2 FFT — deliberately a manual port of the
    /// Kotlin reference's own algorithm, not `vDSP`, see class doc.
    private func fft(real: inout [Float], imag: inout [Float]) {
        let n = real.count
        precondition(n & (n - 1) == 0, "FFT size must be power of 2")
        var j = 0
        for i in 0..<(n - 1) {
            if i < j {
                real.swapAt(i, j)
                imag.swapAt(i, j)
            }
            var m = n / 2
            while m > 0 && j >= m {
                j -= m
                m /= 2
            }
            j += m
        }
        var size = 2
        while size <= n {
            let angle = -2.0 * Float.pi / Float(size)
            let sinA = sin(angle)
            let cosA = cos(angle)
            var i = 0
            while i < n {
                var wr: Float = 1.0
                var wi: Float = 0.0
                for k in 0..<(size / 2) {
                    let i1 = i + k
                    let i2 = i + k + size / 2
                    let tr = wr * real[i2] - wi * imag[i2]
                    let ti = wr * imag[i2] + wi * real[i2]
                    real[i2] = real[i1] - tr
                    imag[i2] = imag[i1] - ti
                    real[i1] += tr
                    imag[i1] += ti
                    let wrNew = wr * cosA - wi * sinA
                    wi = wr * sinA + wi * cosA
                    wr = wrNew
                }
                i += size
            }
            size *= 2
        }
    }

    /// Kaldi-standard triangular mel filterbank: `[numMelBins][fftSize/2+1]` weights.
    private static func buildMelFilterbank(sampleRate: Int, numMelBins: Int, fftSize: Int, lowFreqHz: Double) -> [[Float]] {
        let numFftBins = fftSize / 2 + 1
        let nyquist = Double(sampleRate) / 2.0
        let highFreq = nyquist
        func hzToMel(_ hz: Double) -> Double { 1127.0 * log(1.0 + hz / 700.0) }
        func melToHz(_ mel: Double) -> Double { 700.0 * (exp(mel / 1127.0) - 1.0) }
        let melLow = hzToMel(lowFreqHz)
        let melHigh = hzToMel(highFreq)
        // numMelBins+2 boundary points, evenly spaced in mel scale.
        var melPoints = [Double](repeating: 0, count: numMelBins + 2)
        for i in 0..<melPoints.count {
            melPoints[i] = melLow + Double(i) * (melHigh - melLow) / Double(numMelBins + 1)
        }
        let binFreqs = melPoints.map { melToHz($0) }
        var filters = [[Float]](repeating: [Float](repeating: 0, count: numFftBins), count: numMelBins)
        for m in 0..<numMelBins {
            let left = binFreqs[m]
            let center = binFreqs[m + 1]
            let right = binFreqs[m + 2]
            for k in 0..<numFftBins {
                let freq = Double(k) * Double(sampleRate) / Double(fftSize)
                var weight: Double = 0
                if freq < left || freq > right {
                    weight = 0
                } else if freq <= center {
                    weight = (freq - left) / (center - left)
                } else {
                    weight = (right - freq) / (right - center)
                }
                filters[m][k] = Float(max(weight, 0))
            }
        }
        return filters
    }

    private static func nextPowerOfTwo(_ n: Int) -> Int {
        var p = 1
        while p < n { p = p << 1 }
        return p
    }
}
