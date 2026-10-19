import Foundation

/// Fundamental-frequency extractor and voicing decision over the 60 ms analysis
/// window.
///
/// ## Method
///
/// YIN on the 16 kHz view of the window (docs/voice-analysis-spec.md, section 4):
///   * below a digital-silence floor (window RMS under 1e-4, about 3 LSB) the
///     window is unvoiced and nothing else is computed;
///   * difference function over a 670-sample window for lags 1...270, cumulative
///     mean normalised;
///   * threshold = max(0.15, global minimum over lags 36...270 + 0.05); the first
///     stretch of lags below it is the candidate, and its lowest point the lag;
///   * parabolic refinement of that lag (not at the ends of the search range);
///   * voiced when the periodicity (1 - normalised difference at the integer lag)
///     is at least 0.45 AND the pitch lies in 60...400 Hz.
///
/// The search range (36...270) is wider than 60...400 Hz on purpose: a candidate
/// on the edge of the range gets no refinement, so the range check afterwards, not
/// the end of the search, decides what is in range. `voiced` and `f0Valid` are the
/// same flag.
///
/// The curve is computed in place into scratch memory owned by this object, so an
/// analysis allocates nothing.
public final class PitchExtractor {

    struct Estimate {
        /// 0 when unvoiced.
        var f0Hz: Double
        var voiced: Bool
        /// RMS of the mean-removed 48 kHz window.
        var rms: Double
        /// Refined period in 16 kHz samples (0 when no search ran).
        var lag16: Double
        /// 1 - normalised difference at the integer lag, 0...1; 0 below the silence floor.
        var periodicity: Double
    }

    /// Cumulative mean normalised difference, index = lag.
    private let cm: UnsafeMutablePointer<Double>

    public init() {
        cm = UnsafeMutablePointer<Double>.allocate(capacity: VoiceDsp.tauMax + 1)
        cm.initialize(repeating: 1, count: VoiceDsp.tauMax + 1)
    }

    deinit {
        cm.deallocate()
    }

    /// `window` must have been snapshotted.
    func extract(window: VoiceWindow) -> Estimate {
        let rms = window.rms
        guard rms >= VoiceDsp.silenceRms else {
            return Estimate(f0Hz: 0, voiced: false, rms: rms, lag16: 0, periodicity: 0)
        }
        return search(window.x16, rms: rms)
    }

    /// The YIN search proper, on a 940-sample 16 kHz view.
    func search(_ y: UnsafePointer<Double>, rms: Double) -> Estimate {
        let tauMin = VoiceDsp.tauMin
        let tauMax = VoiceDsp.tauMax
        let w = VoiceDsp.yinWindow

        cm[0] = 1
        var running = 0.0
        for tau in 1...tauMax {
            var d = 0.0
            for j in 0..<w {
                let diff = y[j] - y[j + tau]
                d += diff * diff
            }
            running += d
            cm[tau] = running > 0 ? d * Double(tau) / running : 1
        }

        var gmin = cm[tauMin]
        for tau in tauMin...tauMax where cm[tau] < gmin { gmin = cm[tau] }
        let threshold = max(VoiceDsp.yinAbsolute, gmin + VoiceDsp.yinRelative)

        // First stretch of lags below the threshold; its lowest point (the first
        // one on a tie) is the candidate.
        var tau = tauMin
        while tau < tauMax && cm[tau] >= threshold { tau += 1 }
        var best = tau
        tau += 1
        while tau <= tauMax && cm[tau] < threshold {
            if cm[tau] < cm[best] { best = tau }
            tau += 1
        }

        var lag = Double(best)
        if best > tauMin && best < tauMax {
            let a = cm[best - 1]
            let b = cm[best]
            let c = cm[best + 1]
            let den = a - 2.0 * b + c
            if den > 0 {
                lag = Double(best) + max(-0.5, min(0.5, 0.5 * (a - c) / den))
            }
        }
        let f0Candidate = Double(VoiceDsp.sampleRate16) / lag
        let periodicity = max(0.0, min(1.0, 1.0 - cm[best]))
        let voiced = periodicity >= VoiceDsp.voicedPeriodicity
            && f0Candidate >= VoiceDsp.minF0Hz && f0Candidate <= VoiceDsp.maxF0Hz
        return Estimate(f0Hz: voiced ? f0Candidate : 0, voiced: voiced, rms: rms,
                        lag16: lag, periodicity: periodicity)
    }
}
