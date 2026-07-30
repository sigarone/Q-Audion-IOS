import Foundation
import Accelerate

public final class LfccExtractor {
    public static let sampleRate = 48000
    public static let preEmphasis: Float = 0.97
    // 2026-07-30 fix: was 1200 (25ms). Every caller in this app (enrollment,
    // in-call learning, unlock verification) feeds ONE 20ms/960-sample raw
    // PCM frame per extract() call — see AudioConstants.samplesPerFrame,
    // the atomic frame unit the whole audio pipeline is built on. With
    // frameSize=1200, `samples.count >= frameSize` never held for a single
    // frame, so extract() always returned [] and SpeakerVerifier's
    // enrollment/verification never worked (100% reproducible, confirmed on
    // a real device: 3 full enrollment passes, always stuck at "processing"
    // — CI never caught it because QAudionEngineTests/SpeakerVerifierTests
    // is skip-listed in engine-tests.yml). 960 matches the real per-call
    // frame size, so a single frame now always yields exactly 1 analysis
    // window (hopSize=480 divides it evenly), and SpeakerVerifier's
    // existing extract-per-frame design (which it inherited from the same
    // per-frame contract) starts working without needing a rewrite.
    public static let frameSize = 960   // 20ms at 48kHz
    public static let hopSize = 480      // 10ms at 48kHz
    public static let fftSize = 512
    public static let numFilters = 40
    public static let numCoeffs = 20
    public static let numDeltas = 2
    public static let totalFeatures = numCoeffs * (1 + numDeltas)  // 60

    private var hammingWindow: [Float]

    public init() {
        hammingWindow = [Float](repeating: 0, count: LfccExtractor.frameSize)
        vDSP_hamm_window(&hammingWindow, vDSP_Length(LfccExtractor.frameSize), 0)
    }

    /// Extract LFCC features from PCM Int16 data. Returns [numFrames x 60] flattened array.
    public func extract(pcmData: Data) -> [Float] {
        let samples = pcmToFloat(pcmData)
        guard samples.count >= LfccExtractor.frameSize else { return [] }

        // Pre-emphasis
        let emphasized = preEmphasize(samples)

        // Frame into overlapping windows
        let numFrames = max(1, (emphasized.count - LfccExtractor.frameSize) / LfccExtractor.hopSize + 1)
        var allCoeffs: [[Float]] = []

        for i in 0..<numFrames {
            let start = i * LfccExtractor.hopSize
            let end = min(start + LfccExtractor.frameSize, emphasized.count)
            var frame = Array(emphasized[start..<end])
            if frame.count < LfccExtractor.frameSize {
                frame.append(contentsOf: [Float](repeating: 0, count: LfccExtractor.frameSize - frame.count))
            }

            // Apply Hamming window
            vDSP_vmul(frame, 1, hammingWindow, 1, &frame, 1, vDSP_Length(LfccExtractor.frameSize))

            // FFT (use first fftSize samples)
            let spectrum = computeFFT(Array(frame.prefix(LfccExtractor.fftSize)))

            // Mel filterbank
            let filterEnergies = applyFilterbank(spectrum)

            // Log
            let logEnergies = filterEnergies.map { log10(max($0, 1e-10)) }

            // DCT to get cepstral coefficients
            let cepstral = dct(logEnergies, numCoeffs: LfccExtractor.numCoeffs)
            allCoeffs.append(cepstral)
        }

        // Compute delta and delta-delta
        let deltas = computeDeltas(allCoeffs)
        let deltaDeltas = computeDeltas(deltas)

        // Concatenate: [coeffs | delta | delta-delta] per frame
        var result: [Float] = []
        for i in 0..<allCoeffs.count {
            result.append(contentsOf: allCoeffs[i])
            result.append(contentsOf: i < deltas.count ? deltas[i] : [Float](repeating: 0, count: LfccExtractor.numCoeffs))
            result.append(contentsOf: i < deltaDeltas.count ? deltaDeltas[i] : [Float](repeating: 0, count: LfccExtractor.numCoeffs))
        }
        return result
    }

    private func pcmToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        var floats = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let int16Ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<count { floats[i] = Float(int16Ptr[i]) / 32768.0 }
        }
        return floats
    }

    private func preEmphasize(_ samples: [Float]) -> [Float] {
        guard samples.count > 1 else { return samples }
        var result = [Float](repeating: 0, count: samples.count)
        result[0] = samples[0]
        for i in 1..<samples.count {
            result[i] = samples[i] - LfccExtractor.preEmphasis * samples[i - 1]
        }
        return result
    }

    private func computeFFT(_ frame: [Float]) -> [Float] {
        let n = frame.count
        let log2n = vDSP_Length(log2(Float(n)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return [Float](repeating: 0, count: n / 2)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var realPart = frame.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }
        var imagPart = frame.enumerated().filter { $0.offset % 2 == 1 }.map { $0.element }
        if realPart.count < n/2 { realPart.append(contentsOf: [Float](repeating: 0, count: n/2 - realPart.count)) }
        if imagPart.count < n/2 { imagPart.append(contentsOf: [Float](repeating: 0, count: n/2 - imagPart.count)) }

        // Use withUnsafeMutableBufferPointer so the raw pointers stored inside
        // DSPSplitComplex are guaranteed to remain valid for the entire vDSP call chain.
        var magnitudes = [Float](repeating: 0, count: n / 2)
        // force-unwraps safe: computeFFT is `private`, its only caller
        // passes frame.prefix(fftSize) where frame is always padded to
        // >= frameSize (1200) and fftSize == 512 — n is always 512, so
        // realPart/imagPart (padded to n/2 == 256 above) are never empty.
        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                // swiftlint:disable:next force_unwrapping
                var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }
        return magnitudes
    }

    private func applyFilterbank(_ spectrum: [Float]) -> [Float] {
        // Linear-spaced triangular filterbank (LFCC uses linear, not mel)
        let nfft = spectrum.count
        let maxFreq = Float(LfccExtractor.sampleRate) / 2.0
        var energies = [Float](repeating: 0, count: LfccExtractor.numFilters)
        let step = maxFreq / Float(LfccExtractor.numFilters + 1)

        for f in 0..<LfccExtractor.numFilters {
            let lo = Float(f) * step
            let center = Float(f + 1) * step
            let hi = Float(f + 2) * step
            for k in 0..<nfft {
                let freq = Float(k) * maxFreq / Float(nfft)
                var weight: Float = 0
                if freq >= lo && freq < center { weight = (freq - lo) / (center - lo) } else if freq >= center && freq <= hi { weight = (hi - freq) / (hi - center) }
                energies[f] += spectrum[k] * weight
            }
        }
        return energies
    }

    private func dct(_ input: [Float], numCoeffs: Int) -> [Float] {
        let n = input.count
        var output = [Float](repeating: 0, count: numCoeffs)
        for k in 0..<numCoeffs {
            var sum: Float = 0
            for i in 0..<n {
                sum += input[i] * cos(Float.pi * Float(k) * (Float(i) + 0.5) / Float(n))
            }
            output[k] = sum
        }
        return output
    }

    private func computeDeltas(_ features: [[Float]]) -> [[Float]] {
        guard features.count > 2 else { return features.map { _ in [Float](repeating: 0, count: LfccExtractor.numCoeffs) } }
        var deltas: [[Float]] = []
        for i in 0..<features.count {
            let prev = i > 0 ? features[i - 1] : features[i]
            let next = i < features.count - 1 ? features[i + 1] : features[i]
            var delta = [Float](repeating: 0, count: prev.count)
            for j in 0..<prev.count { delta[j] = (next[j] - prev[j]) / 2.0 }
            deltas.append(delta)
        }
        return deltas
    }
}
