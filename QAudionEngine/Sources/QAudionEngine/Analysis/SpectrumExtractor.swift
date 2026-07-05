import Foundation

/// Real short-time magnitude spectrum of a PCM frame, grouped into a handful
/// of log-spaced display bands — the honest data source for the in-call
/// remote-voice spectrum visual. Every band value is the ACTUAL FFT magnitude
/// of the received audio, so the bars move with what is really being said
/// (no synthetic shimmer / formant fake).
///
/// Direct port of Android `qaudion-engine/analysis/SpectrumExtractor.kt` —
/// constants, gating and AGC behaviour are byte-for-byte the same so the two
/// platforms' bars read identically.
///
/// Pipeline per call to `compute(_:sampleRate:)`:
///   1. take the most recent `fftLen` samples of the frame (zero-padded when
///      the frame is shorter), normalise int16 → float
///   2. Hann window
///   3. radix-2 FFT (self-contained, mirrors the Kotlin implementation)
///   4. magnitude of bins covering the voice band (~60 Hz .. `maxHz`)
///   5. group log-spaced into `bands` bands, log-compress, normalise to 0..1
///
/// Cheap: one 512-pt FFT per invocation on the caller's RX-processing
/// thread — the same one that already runs the guardian/voice-analysis
/// taps. No allocation on the steady state beyond the returned array; the
/// scratch buffers are reused.
///
/// NOT thread-safe: `compute` mutates the reused scratch buffers and the
/// AGC state, so it must only ever be called from the single RX
/// analysis/audio thread (exactly like the sibling `PitchExtractor` /
/// `GuardianMode` taps).
public final class SpectrumExtractor {
    public static let fftLen = 512
    /// Time-domain RMS below which the frame is treated as silence (empty bars).
    private static let silenceRms: Float = 0.006
    /// Absolute floor for the AGC reference so a very quiet (but non-silent)
    /// frame doesn't get amplified to full scale.
    private static let agcFloor: Float = 0.02

    private let bands: Int
    private let minHz: Float
    private let maxHz: Float

    private var re = [Float](repeating: 0, count: SpectrumExtractor.fftLen)
    private var im = [Float](repeating: 0, count: SpectrumExtractor.fftLen)
    private let hann: [Float]

    // Per-band [loBin, hiBin] ranges, computed lazily once the sample rate
    // is known (bin width depends on it).
    private var cachedRate = 0
    private var bandLo: [Int] = []
    private var bandHi: [Int] = []

    // Slow-adapting AGC peak so the display auto-scales to recent loudness
    // WITHOUT a silent frame blowing its own tiny noise up to full scale
    // (per-frame-peak normalisation did exactly that → full bars in
    // silence). Rises instantly to a new peak, decays ~1%/frame.
    private var runningPeak: Float = 0

    public init(bands: Int = 40, minHz: Float = 60, maxHz: Float = 6000) {
        self.bands = bands
        self.minHz = minHz
        self.maxHz = maxHz
        var window = [Float](repeating: 0, count: SpectrumExtractor.fftLen)
        for i in 0..<SpectrumExtractor.fftLen {
            window[i] = Float(
                0.5 - 0.5 * cos(2.0 * Double.pi * Double(i)
                                / Double(SpectrumExtractor.fftLen - 1))
            )
        }
        self.hann = window
    }

    private func ensureBands(sampleRate: Int) {
        if sampleRate == cachedRate && !bandLo.isEmpty { return }
        cachedRate = sampleRate
        let binHz = Float(sampleRate) / Float(Self.fftLen)
        let loBin = max(1, Int(minHz / binHz))
        let hiBin = min(Self.fftLen / 2 - 1, Int(maxHz / binHz))
        bandLo = [Int](repeating: 0, count: bands)
        bandHi = [Int](repeating: 0, count: bands)
        // Log-spaced edges from loBin..hiBin.
        let logLo = log(Double(loBin))
        let logHi = log(Double(hiBin))
        var prev = loBin
        for b in 0..<bands {
            let edge = Int(exp(logLo + (logHi - logLo) * Double(b + 1) / Double(bands)))
            bandLo[b] = prev
            bandHi[b] = max(prev, min(hiBin, edge))
            prev = bandHi[b] + 1
        }
    }

    /// Compute the normalised (0..1) log-magnitude spectrum of `pcm16`.
    /// Returns a fresh `[Float]` of size `bands`. Silent/empty input yields
    /// an all-zero array.
    public func compute(_ pcm16: [Int16], sampleRate: Int) -> [Float] {
        var out = [Float](repeating: 0, count: bands)
        if pcm16.isEmpty || sampleRate <= 0 { return out }
        ensureBands(sampleRate: sampleRate)

        // Load the last fftLen samples (zero-pad if shorter), Hann-windowed.
        for i in 0..<Self.fftLen {
            re[i] = 0
            im[i] = 0
        }
        let n = min(Self.fftLen, pcm16.count)
        let start = pcm16.count - n
        // Time-domain RMS gate: silence → all-zero bars. This is the fix for
        // "full bars in silence" — a near-silent frame never gets normalised
        // up. -46 dBFS ≈ 0.005 RMS is comfortably below speech, above hiss.
        var sumSq: Float = 0
        for i in 0..<n {
            let s = Float(pcm16[start + i]) / 32_768
            sumSq += s * s
            re[Self.fftLen - n + i] = s * hann[Self.fftLen - n + i]
        }
        let rms = n > 0 ? sqrt(sumSq / Float(n)) : 0
        if rms < Self.silenceRms {
            runningPeak *= 0.90             // let the AGC relax during silence
            return out                      // empty bars
        }

        fft()

        // Per-band mean magnitude (raw, no per-frame normalisation) written
        // straight into `out` — no extra scratch array (the Kotlin original
        // uses a `raw` temp; folding it into `out` is math-identical).
        var frameMax: Float = 0
        for b in 0..<bands {
            var acc: Float = 0
            var cnt = 0
            var k = bandLo[b]
            while k <= bandHi[b] {
                acc += sqrt(re[k] * re[k] + im[k] * im[k])
                cnt += 1
                k += 1
            }
            let avg = cnt > 0 ? acc / Float(cnt) : 0
            out[b] = avg
            if avg > frameMax { frameMax = avg }
        }
        // AGC: rise instantly to a louder frame, decay slowly otherwise, so
        // the display tracks recent loudness but silence collapses to empty.
        runningPeak = max(frameMax, runningPeak * 0.99)
        let ref = max(runningPeak, Self.agcFloor)
        for b in 0..<bands {
            // relative magnitude 0..1, mild gamma for a fuller analyser look.
            let rel = min(max(out[b] / ref, 0), 1)
            out[b] = Float(pow(Double(rel), 0.6))
        }
        return out
    }

    /// In-place radix-2 FFT over the reused `re`/`im` scratch buffers.
    /// Mirrors the Kotlin `fft(real, imag)` exactly (bit-reversal permutation
    /// then iterative butterflies). Every loop provably advances: the
    /// bit-reversal inner `while` halves `bit` each pass (terminates at 0),
    /// the butterfly walker steps `i += len` (len ≥ 2), and the outer stage
    /// doubles `len` each pass.
    private func fft() {
        let nn = Self.fftLen
        var j = 0
        for i in 1..<nn {
            var bit = nn >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var len = 2
        while len <= nn {
            let ang = -2.0 * Double.pi / Double(len)
            let wR = Float(cos(ang))
            let wI = Float(sin(ang))
            var i = 0
            while i < nn {
                var wr: Float = 1
                var wi: Float = 0
                let half = len / 2
                for k in 0..<half {
                    let ur = re[i + k]
                    let ui = im[i + k]
                    let vr = re[i + k + half] * wr - im[i + k + half] * wi
                    let vi = re[i + k + half] * wi + im[i + k + half] * wr
                    re[i + k] = ur + vr
                    im[i + k] = ui + vi
                    re[i + k + half] = ur - vr
                    im[i + k + half] = ui - vi
                    let newWr = wr * wR - wi * wI
                    wi = wr * wI + wi * wR
                    wr = newWr
                }
                i += len
            }
            len <<= 1
        }
    }
}
