import Foundation

/// Sequential change-point detector over a stream of speaker-verification
/// scores. Answers ONE question — "is the voice being scored right now a
/// different voice from the one that was being scored a moment ago" — and
/// deliberately does NOT answer "is this voice the enrolled contact".
///
/// 2026-08-29 port of Android's
/// `analysis/speakerchange/SpeakerChangeDetector.kt`. The parameters below
/// were arrived at there by a measured sweep and are carried over unchanged
/// so both platforms make the same decision from the same evidence; the
/// mechanism may differ between platforms but the invariant may not.
///
/// ## Why this exists next to `ContactVoiceContinuityGate`
///
/// That gate low-pass-filters the per-tick score with an exponential moving
/// average and compares the result against two fixed constants. Both halves
/// are the wrong instrument for detecting a handover. A moving average is a
/// filter, not a detector: its reaction time follows from its smoothing
/// constant and no false-alarm rate can be stated for it. And its constants
/// are absolute levels fitted, as that class's own documentation records, to
/// a single real call containing only matching speech — no impostor score
/// has ever been measured in this system.
///
/// This class never uses an absolute level. It estimates the location and
/// scale of the score UNDER THE CURRENT SPEAKER, online, from the call
/// itself, and tests for a downward shift relative to that estimate. Both
/// the reference and the measurement come from the same call over the same
/// codec between the same devices, so every condition-dependent bias
/// cancels.
///
/// ## The test
///
/// Scores become standardized deviations below the reference,
/// `z = (median - score) / sigma`, so a positive `z` means a worse match
/// than this speaker has been giving. Those accumulate with the one-sided
/// cumulative-sum recursion `S = max(0, S + z - k)`, where `k` is half the
/// shift size to be caught promptly. Subtracting `k` is what makes the
/// statistic fall back to zero under a stationary input instead of drifting
/// upward into a false alarm. The alarm fires when `S` exceeds the
/// threshold, and the threshold maps onto an expected interval between
/// false alarms — the property the moving average could not offer.
///
/// ## Reference estimation
///
/// Median and median absolute deviation over a bounded window, not a mean
/// and a standard deviation. Both of the latter have breakdown point zero:
/// on Android, one unlucky warm-up sample two and a half deviations from the
/// truth left the scale estimate at nearly twice its real value for the rest
/// of the run and made a genuine handover undetectable. The median pair has
/// breakdown point one half and shrugs the same sample off.
///
/// Learning is uncensored — every steady sample is admitted — because any
/// rule that admits good-looking samples and skips bad-looking ones biases
/// the location up and the scale down, which inflates every subsequent
/// standardized deviation. Learning stops for good once the window is full,
/// which is what prevents the reference from sliding toward a new speaker
/// and draining the evidence as fast as it builds.
///
/// ## Threading
///
/// Not internally synchronized: the only caller drives it from a single
/// serial queue. A second caller must serialize externally.
public final class SpeakerChangeDetector {

    public enum State {
        /// Not enough scores yet to have a reference worth testing against.
        case unknown
        /// Reference established, accumulated evidence below threshold.
        case steady
        /// Accumulator over threshold, not yet sustained.
        case suspect
        /// Sustained. The voice is not the one the reference was built on.
        case changed
    }

    public struct Evaluation {
        public let state: State
        public let score: Float
        public let referenceMedian: Float?
        public let referenceSigma: Float?
        public let z: Float
        public let statistic: Float
        public let transitionedToChanged: Bool
    }

    public private(set) var state: State = .unknown
    public private(set) var statistic: Float = 0

    private let warmupSamples: Int
    private let shiftSigma: Float
    private let alarmThresholdSigma: Float
    private let confirmSamples: Int
    private let sigmaFloor: Float

    private var window: [Float]
    private var windowCount = 0
    private var consecutiveOverThreshold = 0

    public init(
        warmupSamples: Int = SpeakerChangeDetector.defaultWarmupSamples,
        shiftSigma: Float = SpeakerChangeDetector.defaultShiftSigma,
        alarmThresholdSigma: Float = SpeakerChangeDetector.defaultAlarmThresholdSigma,
        confirmSamples: Int = SpeakerChangeDetector.defaultConfirmSamples,
        sigmaFloor: Float = SpeakerChangeDetector.defaultSigmaFloor
    ) {
        self.warmupSamples = warmupSamples
        self.shiftSigma = shiftSigma
        self.alarmThresholdSigma = alarmThresholdSigma
        self.confirmSamples = confirmSamples
        self.sigmaFloor = sigmaFloor
        self.window = [Float](repeating: 0, count: Self.baselineWindow)
    }

    /// Feed one verification score.
    ///
    /// `nil` is a genuine no-op and must never be coerced into a number: the
    /// scoring path returns nil for a window too quiet to embed, and reading
    /// silence as a bad match would make every pause in the conversation
    /// look like a handover. Same contract as `ContactVoiceContinuityGate`.
    @discardableResult
    public func feed(_ score: Float?) -> Evaluation? {
        guard let score, score.isFinite else { return nil }

        let center = currentCenter()
        let sigma = currentSigma()
        guard windowCount >= warmupSamples, let center, let sigma else {
            observe(score)
            state = .unknown
            return Evaluation(
                state: state, score: score, referenceMedian: nil, referenceSigma: nil,
                z: 0, statistic: statistic, transitionedToChanged: false
            )
        }

        let z = (center - score) / sigma
        let k = shiftSigma / 2
        statistic = max(0, statistic + z - k)

        let wasChanged = state == .changed
        if statistic > alarmThresholdSigma {
            consecutiveOverThreshold += 1
            state = consecutiveOverThreshold > confirmSamples ? .changed : .suspect
        } else {
            consecutiveOverThreshold = 0
            state = .steady
        }

        if state == .steady { observe(score) }

        let transitioned = !wasChanged && state == .changed
        return Evaluation(
            state: state, score: score, referenceMedian: center, referenceSigma: sigma,
            z: z, statistic: statistic, transitionedToChanged: transitioned
        )
    }

    /// Discard the reference and start over on whoever is speaking now.
    ///
    /// A handover is rarely the last event of a call — the handset usually
    /// goes back — and a detector that latched would report the return as
    /// continued mismatch rather than as a second change.
    public func reanchor() {
        windowCount = 0
        statistic = 0
        consecutiveOverThreshold = 0
        state = .unknown
    }

    /// Full reset, for a new call or a new contact template.
    public func reset() { reanchor() }

    // MARK: - Internals

    private func currentCenter() -> Float? {
        guard windowCount > 0 else { return nil }
        return median(of: Array(window[0..<windowCount]))
    }

    /// Median absolute deviation rescaled to a standard-deviation-equivalent,
    /// floored, and inflated while the window is short.
    ///
    /// The inflation is not cosmetic. Any scale estimate from a handful of
    /// observations is noisy, and this detector divides by it: an estimate
    /// landing at sixty percent of the true value inflates every standardized
    /// deviation by the same factor, eating the reference value and lowering
    /// the effective threshold at once. Without it, Android measured a false
    /// alarm roughly every fifty-seven samples of stationary input instead of
    /// the thousand the parameters imply. The term decays as the window
    /// fills, and it can only ever make an alarm harder.
    private func currentSigma() -> Float? {
        guard windowCount >= 2 else { return nil }
        let values = Array(window[0..<windowCount])
        let med = median(of: values)
        let mad = median(of: values.map { abs($0 - med) })
        let scaled = Self.madToSigma * mad * (1 + Self.smallSampleInflation / Float(windowCount))
        return max(scaled, sigmaFloor)
    }

    /// Admit one score into the reference window. A no-op once full — see the
    /// class documentation for why the reference freezes rather than sliding.
    private func observe(_ score: Float) {
        let i = windowCount
        guard i < Self.baselineWindow else { return }
        window[i] = score
        windowCount = i + 1
    }

    private func median(of values: [Float]) -> Float {
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    // MARK: - Tuning

    /// Six samples before the detector can fire at all. Shorter would let the
    /// opening moments of a call — where the far end is often still adjusting
    /// position, volume and route — define a reference nothing later matches.
    public static let defaultWarmupSamples = 6

    /// The shift, in reference deviations, tuned to be caught promptly. Set
    /// for the subtle case of two similar voices; an obvious handover trips
    /// any setting.
    public static let defaultShiftSigma: Float = 1.5

    /// From Android's measured sweep: with the shift and confirmation values
    /// below, a stationary stream runs about a thousand samples between
    /// confirmed false alarms, while a genuine three-deviation shift reaches
    /// `.suspect` in about two samples and `.changed` in about four.
    public static let defaultAlarmThresholdSigma: Float = 3.0

    /// Two further samples must hold above threshold before `.suspect`
    /// becomes `.changed` — the deliberate cost of not letting a cough, a
    /// laugh or one clipped window paint the badge red. It leaves the amber
    /// state, the one the user sees first, exactly as fast.
    public static let defaultConfirmSamples = 2

    /// A run of near-identical scores drives the scale estimate toward zero,
    /// and this class divides by it.
    public static let defaultSigmaFloor: Float = 0.03

    /// Scores that make up the frozen reference — about thirty seconds of
    /// scored speech at the call path's cadence.
    static let baselineWindow = 16

    static let smallSampleInflation: Float = 2.0

    /// Consistency constant making the median absolute deviation an unbiased
    /// estimator of the standard deviation for normal data.
    static let madToSigma: Float = 1.4826
}
