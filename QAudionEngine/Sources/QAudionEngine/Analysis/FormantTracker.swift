import Foundation

/// Formant (vocal-tract resonance) tracker: F1 and F2 from the 16 kHz view of the
/// 60 ms analysis window (docs/voice-analysis-spec.md, section 6).
///
/// ## What was wrong before
///
/// The old tracker ran a 12th-order LPC at 48 kHz (where 12 poles cannot even
/// cover the 0-4 kHz band that holds the formants), seeded the result with fixed
/// "typical" values, applied a wrong sign and a wrong middle-element rule in the
/// Levinson recursion, and reported the highest spectral peaks instead of the
/// lowest resonances: F1 at 2-5 kHz and F2 always zero.
///
/// ## Method (identical on both platforms)
///
/// Pre-emphasis 0.97 (the first 16 kHz sample has no predecessor and is dropped),
/// Hamming window over the 939 remaining samples, autocorrelation LPC of order 18
/// (Levinson-Durbin, white-noise correction 1e-6), the roots of the prediction
/// polynomial (Laguerre with deflation and polishing on the original polynomial,
/// as in Numerical Recipes, written out here so the package takes no new
/// dependency), then, among the roots with a positive angle:
///   * a root is "kept" when |z| < 1, its frequency is above 90 Hz and its
///     bandwidth below 300 Hz;
///   * raw F1 = the first kept root in 200-1100 Hz; none: no formant this step;
///   * F1 is found only if it is at least 2.5 x f0. A raw candidate below that is
///     not replaced by a later root;
///   * F2 = the first root above raw F1 in 600-3200 Hz, skipping roots whose
///     bandwidth is 500 Hz or more (they model the spectral tilt, not a
///     resonance); it is found only if it is kept and at least 2.5 x f0. If that
///     root fails, F2 is not found: a later root is never promoted;
///   * only on voiced steps.
///
/// Whatever is not found stays `found = false` with value 0: it is never replaced
/// by a seed or by an earlier reading. The only smoothing is the median of the
/// last three FOUND values of the same formant. A step in which the root finder
/// fails finds nothing and leaves the histories alone; the histories are dropped
/// by an unvoiced step, so a reading never outlives the voiced stretch it was
/// measured in.
public final class FormantTracker {

    private static let order = VoiceDsp.lpcOrder
    private let preemph: UnsafeMutablePointer<Double>
    /// Hamming window over the pre-emphasised window (939 samples).
    private let hamming: UnsafeMutablePointer<Double>
    private let autocorr: UnsafeMutablePointer<Double>
    private let lpc: UnsafeMutablePointer<Double>
    private let lpcPrev: UnsafeMutablePointer<Double>
    private let original: UnsafeMutablePointer<VDComplex>
    private let work: UnsafeMutablePointer<VDComplex>
    private let roots: UnsafeMutablePointer<VDComplex>
    private let candFreq: UnsafeMutablePointer<Double>
    private let candBw: UnsafeMutablePointer<Double>
    private let candMag: UnsafeMutablePointer<Double>

    /// Last found values of F1 and F2 (at most three each).
    private var history: [[Double]] = [[], []]

    public init() {
        let m = VoiceDsp.samples16 - 1
        let p = Self.order
        preemph = UnsafeMutablePointer<Double>.allocate(capacity: m)
        preemph.initialize(repeating: 0, count: m)
        hamming = UnsafeMutablePointer<Double>.allocate(capacity: m)
        for i in 0..<m {
            hamming[i] = 0.54 - 0.46 * cos(2.0 * Double.pi * Double(i) / Double(m - 1))
        }
        autocorr = UnsafeMutablePointer<Double>.allocate(capacity: p + 1)
        autocorr.initialize(repeating: 0, count: p + 1)
        lpc = UnsafeMutablePointer<Double>.allocate(capacity: p + 1)
        lpc.initialize(repeating: 0, count: p + 1)
        lpcPrev = UnsafeMutablePointer<Double>.allocate(capacity: p + 1)
        lpcPrev.initialize(repeating: 0, count: p + 1)
        original = UnsafeMutablePointer<VDComplex>.allocate(capacity: p + 1)
        original.initialize(repeating: VDComplex(0), count: p + 1)
        work = UnsafeMutablePointer<VDComplex>.allocate(capacity: p + 1)
        work.initialize(repeating: VDComplex(0), count: p + 1)
        roots = UnsafeMutablePointer<VDComplex>.allocate(capacity: p)
        roots.initialize(repeating: VDComplex(0), count: p)
        candFreq = UnsafeMutablePointer<Double>.allocate(capacity: p)
        candFreq.initialize(repeating: 0, count: p)
        candBw = UnsafeMutablePointer<Double>.allocate(capacity: p)
        candBw.initialize(repeating: 0, count: p)
        candMag = UnsafeMutablePointer<Double>.allocate(capacity: p)
        candMag.initialize(repeating: 0, count: p)
        for i in 0..<2 { history[i].reserveCapacity(VoiceDsp.formantMedianKeep + 1) }
    }

    deinit {
        preemph.deallocate()
        hamming.deallocate()
        autocorr.deallocate()
        lpc.deallocate()
        lpcPrev.deallocate()
        original.deallocate()
        work.deallocate()
        roots.deallocate()
        candFreq.deallocate()
        candBw.deallocate()
        candMag.deallocate()
    }

    func reset() {
        for i in 0..<2 { history[i].removeAll(keepingCapacity: true) }
    }

    /// `window` must have been snapshotted; `f0Hz` is the pitch of that window.
    func extract(window: VoiceWindow, voiced: Bool, f0Hz: Double) -> VoiceAnalysisResult.Formants {
        guard voiced else {
            reset()
            return VoiceAnalysisResult.Formants()
        }
        guard let raw = pickFormants(window.x16, f0Hz: f0Hz) else {
            return VoiceAnalysisResult.Formants()
        }
        let f1 = smoothed(raw.f1, slot: 0)
        let f2 = smoothed(raw.f2, slot: 1)
        return VoiceAnalysisResult.Formants(f1: Float(f1 ?? 0), f2: Float(f2 ?? 0),
                                            f3: 0, f4: 0,
                                            f1Found: f1 != nil, f2Found: f2 != nil,
                                            f3Found: false, f4Found: false)
    }

    /// Median of the last three FOUND values of one formant; nil if this step
    /// found none (the history is left as it was, and nothing stale is returned).
    private func smoothed(_ value: Double?, slot: Int) -> Double? {
        guard let v = value else { return nil }
        history[slot].append(v)
        if history[slot].count > VoiceDsp.formantMedianKeep { history[slot].removeFirst() }
        return Self.median(history[slot])
    }

    // MARK: - Measurement

    /// Raw (unsmoothed) F1/F2 of one 16 kHz window; a nil entry is "not found".
    struct RawFormants {
        var f1: Double?
        var f2: Double?
    }

    /// Nil if the LPC or the root finder failed.
    func pickFormants(_ y: UnsafePointer<Double>, f0Hz: Double) -> RawFormants? {
        guard let count = candidates(y) else { return nil }
        let gate = VoiceDsp.harmonicRatio * f0Hz

        func kept(_ i: Int) -> Bool {
            candMag[i] < 1.0 && candFreq[i] > VoiceDsp.formantMinHz && candBw[i] < VoiceDsp.maxFormantBandwidthHz
        }

        var raw = RawFormants()
        var f1Index = -1
        for i in 0..<count where kept(i) && VoiceDsp.f1Range.contains(candFreq[i]) {
            f1Index = i
            break
        }
        guard f1Index >= 0 else { return raw }
        let f1Raw = candFreq[f1Index]
        if f1Raw >= gate { raw.f1 = f1Raw }

        for i in 0..<count {
            if candBw[i] >= VoiceDsp.f2IgnoreBandwidthHz { continue }
            if candFreq[i] > f1Raw && VoiceDsp.f2Range.contains(candFreq[i]) {
                if kept(i) && candFreq[i] >= gate { raw.f2 = candFreq[i] }
                break
            }
        }
        return raw
    }

    /// Roots with a positive imaginary part as (frequency, bandwidth, |z|),
    /// ascending in frequency, written into `candFreq`/`candBw`/`candMag`. Returns
    /// their number, or nil when the LPC or the root finder failed.
    func candidates(_ y: UnsafePointer<Double>) -> Int? {
        let p = Self.order
        let m = VoiceDsp.samples16 - 1

        // Pre-emphasis + Hamming window.
        for i in 0..<m {
            let e = y[i + 1] - VoiceDsp.preEmphasis * y[i]
            preemph[i] = e * hamming[i]
        }
        for k in 0...p {
            var acc = 0.0
            for i in 0..<(m - k) { acc += preemph[i] * preemph[i + k] }
            autocorr[k] = acc
        }
        autocorr[0] *= 1.0 + VoiceDsp.whiteNoiseCorrection
        guard autocorr[0] > 0 else { return nil }
        guard levinson() else { return nil }

        // A(z) = 1 + a1 z^-1 + ... + ap z^-p  ->  z^p + a1 z^(p-1) + ... + ap,
        // stored with ascending powers: original[j] = a_(p-j).
        for j in 0...p { original[j] = VDComplex(lpc[p - j]) }
        guard polynomialRoots(degree: p) else { return nil }

        var count = 0
        let sr = Double(VoiceDsp.sampleRate16)
        for i in 0..<p {
            let z = roots[i]
            guard z.im > 0 else { continue }
            let mag = z.magnitude
            let freq = atan2(z.im, z.re) * sr / (2.0 * Double.pi)
            let bw = mag > 0 ? -log(mag) * sr / Double.pi : Double.infinity
            // insertion sort by frequency
            var pos = count
            while pos > 0 && candFreq[pos - 1] > freq {
                candFreq[pos] = candFreq[pos - 1]
                candBw[pos] = candBw[pos - 1]
                candMag[pos] = candMag[pos - 1]
                pos -= 1
            }
            candFreq[pos] = freq
            candBw[pos] = bw
            candMag[pos] = mag
            count += 1
        }
        return count
    }

    /// Levinson-Durbin on `autocorr`; result in `lpc` (lpc[0] = 1). False if the
    /// recursion loses positive definiteness.
    private func levinson() -> Bool {
        let p = Self.order
        for i in 0...p { lpc[i] = 0 }
        lpc[0] = 1
        var err = autocorr[0]
        for i in 1...p {
            var acc = autocorr[i]
            for j in 1..<i { acc += lpc[j] * autocorr[i - j] }
            let k = -acc / err
            if !(abs(k) < 1.0) { return false }
            for j in 0...p { lpcPrev[j] = lpc[j] }
            for j in 1..<i { lpc[j] = lpcPrev[j] + k * lpcPrev[i - j] }
            lpc[i] = k
            err *= 1.0 - k * k
            if !(err > 0) { return false }
        }
        return true
    }

    // MARK: - Roots (Laguerre + deflation, polished on the original polynomial)

    private static let laguerreFraction: [Double] = [0.0, 0.5, 0.25, 0.75, 0.13, 0.38, 0.62, 0.88, 1.0]
    private static let laguerreEps = 1.0e-14
    private static let laguerreMt = 10
    private static let laguerreMaxIterations = 80

    /// One root of the polynomial with ascending coefficients `a[0...m]`,
    /// starting from `start`. `converged` is false if it did not converge.
    private static func laguerre(_ a: UnsafePointer<VDComplex>, degree m: Int, start: VDComplex)
        -> (root: VDComplex, converged: Bool) {
        let md = Double(m)
        var x = start
        for it in 1...laguerreMaxIterations {
            var b = a[m]
            var err = b.magnitude
            var d = VDComplex(0, 0)
            var f = VDComplex(0, 0)
            let abx = x.magnitude
            var j = m - 1
            while j >= 0 {
                f = x * f + d
                d = x * d + b
                b = x * b + a[j]
                err = b.magnitude + abx * err
                j -= 1
            }
            err *= laguerreEps
            if b.magnitude <= err { return (x, true) }
            let g = d / b
            let g2 = g * g
            let h = g2 - (2.0 * f) / b
            let sq = ((md - 1.0) * (md * h - g2)).squareRoot()
            var gp = g + sq
            let gm = g - sq
            let abp = gp.magnitude
            let abm = gm.magnitude
            if abp < abm { gp = gm }
            let dx: VDComplex
            if (abp > abm ? abp : abm) > 0 {
                dx = md / gp
            } else {
                dx = (1.0 + abx) * VDComplex(cos(Double(it)), sin(Double(it)))
            }
            let x1 = x - dx
            if x.re == x1.re && x.im == x1.im { return (x, true) }
            if it % laguerreMt != 0 {
                x = x1
            } else {
                x = x - laguerreFraction[it / laguerreMt] * dx
            }
        }
        return (x, false)
    }

    /// All roots of `original[0...m]` into `roots[0..<m]`; false if one of them
    /// did not converge.
    private func polynomialRoots(degree m: Int) -> Bool {
        for j in 0...m { work[j] = original[j] }
        var j = m
        while j >= 1 {
            let (x0, ok) = Self.laguerre(work, degree: j, start: VDComplex(0, 0))
            if !ok { return false }
            var x = x0
            if abs(x.im) <= 2.0 * Self.laguerreEps * abs(x.re) { x = VDComplex(x.re, 0) }
            roots[m - j] = x
            // Deflate: divide the working polynomial by (z - x).
            var b = work[j]
            var jj = j - 1
            while jj >= 0 {
                let c = work[jj]
                work[jj] = b
                b = x * b + c
                jj -= 1
            }
            j -= 1
        }
        for i in 0..<m {
            let (x, ok) = Self.laguerre(original, degree: m, start: roots[i])
            if !ok { return false }
            roots[i] = x
        }
        return true
    }

    /// Median of one to three values, without allocating.
    private static func median(_ values: [Double]) -> Double {
        switch values.count {
        case 1:
            return values[0]
        case 2:
            return 0.5 * (values[0] + values[1])
        default:
            let a = values[0], b = values[1], c = values[2]
            return max(min(a, b), min(max(a, b), c))
        }
    }
}
