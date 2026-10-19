import Foundation

/// Harmonics-to-noise ratio and breathiness of the received voice.
///
/// ## Method (Boersma; docs/voice-analysis-spec.md, section 5)
///
/// On the mean-removed 48 kHz window, Hann-windowed:
///   r(t) = [ra(t) / ra(0)] / [rw(t) / rw(0)]
/// where `ra` is the autocorrelation of the windowed signal and `rw` the
/// autocorrelation of the window itself (the correction that makes r a true
/// correlation coefficient of the signal rather than of the window). `r` is read at
/// the pitch period: the largest of the five lags around 48000 / f0, refined by a
/// parabola through its two neighbours when it is one of the three middle ones.
/// It is clamped to [0.0001, 0.9999] and
///   HNR = min(40, 10 log10(r / (1 - r))) dB.
/// A ratio of energies is independent of the amplitude by construction.
///
/// Only voiced steps are measured. The value exposed is the mean of the last five
/// voiced readings (breathiness: the mean of 1 - r over the same five); it is not
/// valid until three voiced steps have been measured, and it stays valid for one
/// second (10 steps) of audio after the last voiced step, so a pause between two
/// words does not blank it. When it is not valid, HNR and breathiness are 0.
public final class VoiceHealthMonitor {

    private let hann: UnsafeMutablePointer<Double>
    private let windowed: UnsafeMutablePointer<Double>
    /// rw(t), computed on first use (it does not depend on the signal).
    private let hannAutocorr: UnsafeMutablePointer<Double>
    private var hannAutocorrKnown: [Bool]
    private static let hannAutocorrLags = 1_024
    /// r(t) at the five lags around the period.
    private let lagRatios: UnsafeMutablePointer<Double>

    private var hnrValues: [Double] = []
    private var ratioValues: [Double] = []
    private var voicedCount = 0
    /// Steps since the last voiced one; nil until there has been one.
    private var sinceVoiced: Int?

    public init() {
        let n = VoiceDsp.windowSamples
        hann = UnsafeMutablePointer<Double>.allocate(capacity: n)
        windowed = UnsafeMutablePointer<Double>.allocate(capacity: n)
        for i in 0..<n {
            hann[i] = 0.5 - 0.5 * cos(2.0 * Double.pi * (Double(i) + 0.5) / Double(n))
            windowed[i] = 0
        }
        hannAutocorr = UnsafeMutablePointer<Double>.allocate(capacity: Self.hannAutocorrLags)
        hannAutocorr.initialize(repeating: 0, count: Self.hannAutocorrLags)
        hannAutocorrKnown = [Bool](repeating: false, count: Self.hannAutocorrLags)
        lagRatios = UnsafeMutablePointer<Double>.allocate(capacity: 2 * VoiceDsp.hnrHalfSpan + 1)
        lagRatios.initialize(repeating: 0, count: 2 * VoiceDsp.hnrHalfSpan + 1)
        hnrValues.reserveCapacity(VoiceDsp.hnrKeep + 1)
        ratioValues.reserveCapacity(VoiceDsp.hnrKeep + 1)
    }

    deinit {
        hann.deallocate()
        windowed.deallocate()
        hannAutocorr.deallocate()
        lagRatios.deallocate()
    }

    func reset() {
        hnrValues.removeAll(keepingCapacity: true)
        ratioValues.removeAll(keepingCapacity: true)
        voicedCount = 0
        sinceVoiced = nil
    }

    /// `window` must have been snapshotted; `f0Hz` is the pitch of that window
    /// (only used when `voiced`).
    func analyze(window: VoiceWindow, voiced: Bool, f0Hz: Double) -> VoiceAnalysisResult.VoiceHealth {
        if voiced, f0Hz > 0 {
            let (hnr, ratio) = instantHnr(window.linear, f0Hz: f0Hz)
            hnrValues.append(hnr)
            ratioValues.append(ratio)
            if hnrValues.count > VoiceDsp.hnrKeep {
                hnrValues.removeFirst()
                ratioValues.removeFirst()
            }
            voicedCount += 1
            sinceVoiced = 0
        } else if let since = sinceVoiced {
            sinceVoiced = since + 1
        }
        guard voicedCount >= VoiceDsp.hnrMinVoiced, let since = sinceVoiced, since <= VoiceDsp.hnrHoldSteps,
              !hnrValues.isEmpty else {
            return VoiceAnalysisResult.VoiceHealth(hnr: 0, breathiness: 0, hnrValid: false)
        }
        var hnrSum = 0.0
        var breathSum = 0.0
        for i in 0..<hnrValues.count {
            hnrSum += hnrValues[i]
            breathSum += 1.0 - ratioValues[i]
        }
        let n = Double(hnrValues.count)
        return VoiceAnalysisResult.VoiceHealth(hnr: Float(hnrSum / n), breathiness: Float(breathSum / n), hnrValid: true)
    }

    /// Boersma HNR (dB) and the clamped correlation `r` of one mean-removed 48 kHz
    /// window at the pitch `f0Hz`.
    func instantHnr(_ xc: UnsafePointer<Double>, f0Hz: Double) -> (hnr: Double, ratio: Double) {
        let n = VoiceDsp.windowSamples
        for i in 0..<n { windowed[i] = xc[i] * hann[i] }
        let ra0 = autocorr(windowed, 0)
        let rw0 = hannAutocorrelation(0)

        let period = Double(VoiceDsp.sampleRate) / f0Hz
        // A voiced step is 60...400 Hz, so the lags lie in 118...802; the clamp only
        // protects against a caller outside that contract.
        let span = VoiceDsp.hnrHalfSpan
        let centre = max(span + 1, min(Int((period + 0.5).rounded(.down)), n / 2))
        let count = 2 * span + 1
        for i in 0..<count {
            let lag = centre - span + i
            lagRatios[i] = (autocorr(windowed, lag) / ra0) / (hannAutocorrelation(lag) / rw0)
        }
        // Largest of the five (the first one on a tie), refined by a parabola when it
        // is one of the three middle ones.
        var best = 0
        for i in 1..<count where lagRatios[i] > lagRatios[best] { best = i }
        var chosen = lagRatios[best]
        if best > 0 && best < count - 1 {
            let ya = lagRatios[best - 1]
            let yb = lagRatios[best]
            let yc = lagRatios[best + 1]
            let den = ya - 2.0 * yb + yc
            if den < 0 { chosen = yb - (ya - yc) * (ya - yc) / (8.0 * den) }
        }
        let ratio = max(VoiceDsp.hnrRatioMin, min(VoiceDsp.hnrRatioMax, chosen))
        let hnr = min(VoiceDsp.hnrCapDb, 10.0 * log10(ratio / (1.0 - ratio)))
        return (hnr, ratio)
    }

    private func autocorr(_ s: UnsafePointer<Double>, _ lag: Int) -> Double {
        var acc = 0.0
        let n = VoiceDsp.windowSamples
        for i in 0..<(n - lag) { acc += s[i] * s[i + lag] }
        return acc
    }

    private func hannAutocorrelation(_ lag: Int) -> Double {
        guard lag >= 0, lag < Self.hannAutocorrLags else { return autocorr(hann, lag) }
        if !hannAutocorrKnown[lag] {
            hannAutocorr[lag] = autocorr(hann, lag)
            hannAutocorrKnown[lag] = true
        }
        return hannAutocorr[lag]
    }
}
