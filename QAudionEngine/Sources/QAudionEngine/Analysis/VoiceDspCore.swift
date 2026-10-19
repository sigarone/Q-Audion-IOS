import Foundation

/// Shared parameters and low-level kernels of the remote-voice analysis.
///
/// ## Why a 60 ms window
///
/// The decoded audio reaches the analyser in buffers of 10, 20 or 60 ms (the
/// native playback tap hands over ~10 ms), and the engine used to analyse ONE
/// such buffer on its own. That is too short for every measurement it makes: a
/// pitch search is capped at half the buffer (no pitch below ~200 Hz on 10 ms),
/// a formant fit has no harmonic structure to work with, and a harmonics-to-noise
/// ratio needs several periods. So the engine keeps the most recent 60 ms of
/// received audio in a ring and analyses THAT, once per 100 ms of audio time,
/// whatever the chunk size.
///
/// Every constant below is part of the specification in
/// docs/voice-analysis-spec.md, which the Android engine implements with the same
/// numbers, so the two platforms produce the same readings. The section numbers
/// in the comments are the ones of that file.
///
/// Everything here is allocation-free once constructed: the buffers are raw
/// memory owned by `VoiceWindow` and the per-measurement scratch classes.
enum VoiceDsp {
    // 1. Input, framing and cadence
    static let sampleRate = 48_000
    /// 60 ms of 48 kHz audio.
    static let windowSamples = 2_880
    /// One analysis per 100 ms of AUDIO time (not wall clock).
    static let hopSamples = 4_800
    /// 10 ms envelope frame of the speech-rate measurement.
    static let frameSamples = 480
    static let framesPerStep = hopSamples / frameSamples
    /// A discontinuity this long (2 s) or longer clears everything.
    static let longGapSamples = 96_000

    // 3. Front end shared by pitch, formants and HNR: low-pass + decimate by 3.
    static let decimation = 3
    static let sampleRate16 = 16_000
    /// 63-tap Hamming-windowed sinc, cutoff 7 kHz. (2880 - 63) is divisible by 3,
    /// so the last output ends exactly on the newest sample.
    static let firTaps = 63
    static let firCutoffHz = 7_000.0
    /// Valid-only outputs of the decimating FIR over one window.
    static let samples16 = (windowSamples - firTaps) / decimation + 1   // 940

    // 4. Pitch and voicing
    /// Digital-silence floor of the mean-removed window RMS.
    static let silenceRms = 1.0e-4
    /// Period search range in 16 kHz samples (444 Hz down to 59.3 Hz). The bounds
    /// sit outside 16000/400 and 16000/60 on purpose: a candidate at the edge of
    /// the range gets no parabolic refinement, and the range check afterwards
    /// decides what is in range.
    static let tauMin = 36
    static let tauMax = 270
    /// YIN integration window: every one of the 940 samples is used at the
    /// largest lag.
    static let yinWindow = samples16 - tauMax                          // 670
    static let yinAbsolute = 0.15
    static let yinRelative = 0.05
    static let voicedPeriodicity = 0.45
    static let minF0Hz = 60.0
    static let maxF0Hz = 400.0

    // 5. HNR and breathiness
    static let hnrHalfSpan = 2
    static let hnrRatioMin = 0.0001
    static let hnrRatioMax = 0.9999
    static let hnrCapDb = 40.0
    static let hnrKeep = 5
    static let hnrMinVoiced = 3
    /// A value survives up to this many steps (1 s) after the last voiced one.
    static let hnrHoldSteps = 10

    // 6. Formants
    static let lpcOrder = 18
    static let preEmphasis = 0.97
    static let whiteNoiseCorrection = 1.0e-6
    static let formantMinHz = 90.0
    /// Poles wider than this are harmonics or noise, not resonances.
    static let maxFormantBandwidthHz = 300.0
    /// Roots this wide model the spectral tilt, not a resonance: they do not
    /// block the search for F2.
    static let f2IgnoreBandwidthHz = 500.0
    static let f1Range: ClosedRange<Double> = 200.0...1100.0
    static let f2Range: ClosedRange<Double> = 600.0...3200.0
    /// A resonance can only be placed if the harmonics sample it at least 2.5
    /// times before it: below 2.5 x f0 the envelope is under-sampled and the
    /// fitted pole lands on a harmonic instead.
    static let harmonicRatio = 2.5
    static let formantMedianKeep = 3

    // 7. Speech rate
    static let historyFrames = 600          // 6 s
    static let lookBackFrames = 30          // 300 ms
    static let ringFrames = historyFrames + lookBackFrames
    static let energyFloor = 1.0e-10        // -100 dB
    static let activeRangeDb = 25.0
    static let nucleusDipDb = 3.0
    static let refractoryFrames = 10        // 100 ms
    static let pauseMinFrames = 30          // an inactive run LONGER than this is a pause
    static let minSpeakingFrames = 200      // 2 s
    static let maxSyllablesPerSec = 12.0

    // 9. Display
    static let displaySteps = 10            // 1 s of audio time
}

/// Minimal complex number for the polynomial root finder. A dedicated struct
/// (rather than a dependency) keeps the package free of new imports. Division and
/// square root follow the formulas of the reference implementation, so that the
/// root finder takes the same path on the same input.
struct VDComplex {
    var re: Double
    var im: Double

    init(_ re: Double, _ im: Double = 0) {
        self.re = re
        self.im = im
    }

    var magnitude: Double { hypot(re, im) }

    static func + (l: VDComplex, r: VDComplex) -> VDComplex { VDComplex(l.re + r.re, l.im + r.im) }
    static func - (l: VDComplex, r: VDComplex) -> VDComplex { VDComplex(l.re - r.re, l.im - r.im) }
    static func * (l: VDComplex, r: VDComplex) -> VDComplex {
        VDComplex(l.re * r.re - l.im * r.im, l.re * r.im + l.im * r.re)
    }
    static func * (l: Double, r: VDComplex) -> VDComplex { VDComplex(l * r.re, l * r.im) }

    /// Complex division by scaling with the larger component of the divisor.
    static func / (a: VDComplex, b: VDComplex) -> VDComplex {
        let absRe = abs(b.re)
        let absIm = abs(b.im)
        if absRe >= absIm {
            if absRe == 0 { return VDComplex(0, 0) }
            let ratio = b.im / b.re
            let denom = b.re + b.im * ratio
            return VDComplex((a.re + a.im * ratio) / denom, (a.im - a.re * ratio) / denom)
        }
        let ratio = b.re / b.im
        let denom = b.re * ratio + b.im
        return VDComplex((a.re * ratio + a.im) / denom, (a.im * ratio - a.re) / denom)
    }
    static func / (l: Double, r: VDComplex) -> VDComplex { VDComplex(l, 0) / r }

    /// Principal square root (the sign of a zero imaginary part is kept).
    func squareRoot() -> VDComplex {
        if re == 0 && im == 0 { return VDComplex(0, im) }
        var ax = abs(re)
        let ay = abs(im)
        let s: Double
        if ax < Double.leastNormalMagnitude && ay < Double.leastNormalMagnitude {
            ax = scalbn(ax, 53)
            s = scalbn((ax + hypot(ax, scalbn(ay, 53))).squareRoot(), -27)
        } else {
            ax /= 8.0
            s = 2.0 * (ax + hypot(ax, ay / 8.0)).squareRoot()
        }
        let d = ay / (2.0 * s)
        if re >= 0 {
            return VDComplex(s, copysign(d, im))
        }
        return VDComplex(d, copysign(s, im))
    }
}

/// The most recent 60 ms of received audio, plus its 16 kHz view.
///
/// Fed one sample at a time by the engine (or in bulk by the tests);
/// `snapshot()` linearises the ring, removes the mean, measures the RMS and
/// produces the decimated window every measurement works on. Not thread-safe:
/// owned by `VoiceAnalysisEngine`, which serialises access.
final class VoiceWindow {
    private let ring: UnsafeMutablePointer<Double>
    private var writeIndex = 0
    private var filled = 0

    /// Mean-removed 48 kHz window, oldest sample first (valid after `snapshot`).
    let linear: UnsafeMutablePointer<Double>
    /// 16 kHz view of the mean-removed window, 940 samples (valid after `snapshot`).
    /// No second mean removal: every measurement that needs one does it itself.
    let x16: UnsafeMutablePointer<Double>
    private let fir: UnsafeMutablePointer<Double>

    /// RMS of the mean-removed 48 kHz window (valid after `snapshot`).
    private(set) var rms: Double = 0

    var isFilled: Bool { filled >= VoiceDsp.windowSamples }

    init() {
        ring = UnsafeMutablePointer<Double>.allocate(capacity: VoiceDsp.windowSamples)
        ring.initialize(repeating: 0, count: VoiceDsp.windowSamples)
        linear = UnsafeMutablePointer<Double>.allocate(capacity: VoiceDsp.windowSamples)
        linear.initialize(repeating: 0, count: VoiceDsp.windowSamples)
        x16 = UnsafeMutablePointer<Double>.allocate(capacity: VoiceDsp.samples16)
        x16.initialize(repeating: 0, count: VoiceDsp.samples16)
        fir = UnsafeMutablePointer<Double>.allocate(capacity: VoiceDsp.firTaps)
        fir.initialize(repeating: 0, count: VoiceDsp.firTaps)
        Self.buildFir(into: fir)
    }

    deinit {
        ring.deallocate()
        linear.deallocate()
        x16.deallocate()
        fir.deallocate()
    }

    func reset() {
        for i in 0..<VoiceDsp.windowSamples { ring[i] = 0 }
        writeIndex = 0
        filled = 0
        rms = 0
    }

    /// Append one sample (normalised to [-1, 1)).
    @inline(__always)
    func push(_ sample: Double) {
        ring[writeIndex] = sample
        writeIndex += 1
        if writeIndex == VoiceDsp.windowSamples { writeIndex = 0 }
        if filled < VoiceDsp.windowSamples { filled += 1 }
    }

    /// Append `count` samples.
    func append(_ samples: UnsafePointer<Double>, count: Int) {
        for i in 0..<count { push(samples[i]) }
    }

    /// Linearise, remove the mean, measure the RMS, decimate to 16 kHz.
    /// Only valid once `isFilled`.
    func snapshot() {
        let capacity = VoiceDsp.windowSamples
        var k = writeIndex            // oldest sample once the ring is full
        var sum = 0.0
        for i in 0..<capacity {
            let v = ring[k]
            linear[i] = v
            sum += v
            k += 1
            if k == capacity { k = 0 }
        }
        let mean = sum / Double(capacity)
        var sq = 0.0
        for i in 0..<capacity {
            let v = linear[i] - mean
            linear[i] = v
            sq += v * v
        }
        rms = (sq / Double(capacity)).squareRoot()

        // Decimating FIR, valid region only: y[m] = sum_k h[k] * x[3m + k].
        let taps = VoiceDsp.firTaps
        let n16 = VoiceDsp.samples16
        for m in 0..<n16 {
            let base = VoiceDsp.decimation * m
            var acc = 0.0
            for t in 0..<taps { acc += fir[t] * linear[base + t] }
            x16[m] = acc
        }
    }

    private static func buildFir(into h: UnsafeMutablePointer<Double>) {
        let taps = VoiceDsp.firTaps
        let wc = 2.0 * Double.pi * VoiceDsp.firCutoffHz / Double(VoiceDsp.sampleRate)
        let mid = (taps - 1) / 2
        var total = 0.0
        for k in 0..<taps {
            let m = Double(k - mid)
            let ideal = (k == mid) ? wc / Double.pi : sin(wc * m) / (Double.pi * m)
            let w = 0.54 - 0.46 * cos(2.0 * Double.pi * Double(k) / Double(taps - 1))
            h[k] = ideal * w
            total += h[k]
        }
        for k in 0..<taps { h[k] /= total }
    }
}
