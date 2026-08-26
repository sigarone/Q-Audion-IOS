import Foundation

/// W-PLPFEEDBACK (2026-08-25) — pure policy for the encoder's expected-
/// packet-loss knob (`OpusCodec.setPacketLossPct`), driven by the PEER's
/// periodic `PLP:<percent>` report.
///
/// Port of Android's `PlpPolicy` (`com.bcrypto.qaudion.audio.PlpPolicy`),
/// kept byte-identical so both platforms converge on the same encoder
/// setting from the same reported loss.
///
/// The knob was a compile-time 30 (see `OpusCodec.Config.secure`'s W523
/// note): correct insurance for the worst uplink measured then, and a
/// standing ~25% redundancy tax on every clean link since. This policy makes
/// it track reality, with the asymmetry that matters for audio:
///
///  - **Fast up.** Loss above the current setting means frames are being
///    lost that the LBRR budget was not sized for — every under-provisioned
///    frame is an audible hole RIGHT NOW, so the response is a jump:
///    straight to the observed loss plus `upHeadroomPct`, clamped to
///    `[minPct, maxPct]`.
///  - **Slow decay.** Loss below the current setting only means bits are
///    being wasted, which is inaudible — so the setting walks down
///    `decayStepPct` per report, never below the observed loss itself and
///    never below `minPct`.
///
/// Never decaying below the observed loss is what makes the pair stable: a
/// decay that undershot a persistent loss rate would trip the fast-up branch
/// on the next report and oscillate forever. With the floor at
/// `ceil(observed)`, a steady loss rate converges in a few steps and holds.
///
/// Pure and stateless — the current value lives with the caller
/// (`CallService`), which calls `next(currentPct:observedLossPct:)` on each
/// `PLP:` report and applies the result via
/// `QAudionCallIntegration.reconfigureAudioCodec(bitrateKbps:plp:)`.
/// Deliberately NOT rate-limited here: the cadence of calls IS the decay
/// clock (mirrors `CallAudioBridge.PLP_REPORT_INTERVAL_MS` — 4 s on the
/// Android side, matched by `CallService`'s own report timer).
public enum PlpPolicy {

    /// Policy floor. Non-zero on purpose: with in-band FEC enabled, a small
    /// standing LBRR budget is cheap insurance against the first loss after a
    /// long clean stretch (the report that would raise the knob arrives only
    /// AFTER that loss is already audible).
    public static let minPct = 5

    /// Ceiling: past ~40 the encoder spends so much of the fixed CBR budget
    /// on redundancy that quality degrades more than the loss it insures
    /// against.
    public static let maxPct = 40

    /// Overshoot added on the fast-up jump. The observed rate is a trailing
    /// sample of a link that is currently getting WORSE (that is why the
    /// branch fired), so provisioning exactly to it would chase the loss from
    /// behind, one report-interval at a time.
    public static let upHeadroomPct = 5

    /// Per-report step of the slow decay. Small on purpose: over-
    /// provisioning is inaudible, so there is no hurry.
    public static let decayStepPct = 2

    /// The next value for the encoder's expected-loss knob.
    ///
    /// - Parameters:
    ///   - currentPct: the value currently applied to the encoder. Coerced
    ///     into `[minPct, maxPct]` first, so a caller arriving from a state
    ///     this policy did not produce (the compile-time 30, a stale pref, 0)
    ///     still lands inside the contract.
    ///   - observedLossPct: the peer-reported loss over the last window, in
    ///     percent. Negatives are treated as 0; values over 100 as 100.
    /// - Returns: the value to hand to `OpusCodec.setPacketLossPct`. Always
    ///   within `[minPct, maxPct]`.
    public static func next(currentPct: Int, observedLossPct: Double) -> Int {
        next(currentPct: currentPct, observedLossPct: observedLossPct, floorPct: minPct)
    }

    /// W-PLPBWTIER (2026-08-26) — route-tier-aware variant. A TURN-relayed
    /// route (`RouteTier.relay`, already computed for video's own bandwidth
    /// clamp — see `VideoBandwidthCap.swift`) is a real, KNOWN-WORSE
    /// structural signal, available the MOMENT the route resolves
    /// (`QAudionWebRtcCallController.resolveAndApplyRouteTier`, fired on
    /// every call's ICE `.connected`, audio-only calls included — not
    /// gated behind video telemetry) — an extra relay hop, historically
    /// higher loss/jitter than a direct P2P path, and known BEFORE the
    /// first peer `PLP:` report even exists. `minPct`'s own kdoc already
    /// explains why a non-zero standing floor exists at all ("insurance
    /// against the first loss after a long clean stretch — the report that
    /// would raise the knob arrives only AFTER that loss is already
    /// audible"): this raises that same floor specifically for calls
    /// already known to be on the worse-case transport, closing the exact
    /// gap the purely-reactive base `next(currentPct:observedLossPct:)`
    /// cannot close by construction — there is no report to react to yet
    /// on a route that just resolved to relay.
    ///
    /// Deliberately does NOT touch `maxPct`/`upHeadroomPct`/`decayStepPct`,
    /// or the CBR packet size itself (`OpusCodec.Config`'s fixed block
    /// budget) — this only changes how much of the SAME fixed-size
    /// packet's existing redundancy budget the policy is willing to reach
    /// for on a relay call. The wire bitrate stays the locked
    /// constant-32kbps-on-every-network contract.
    public static func next(currentPct: Int, observedLossPct: Double, routeTier: RouteTier) -> Int {
        next(currentPct: currentPct, observedLossPct: observedLossPct, floorPct: minPct(for: routeTier))
    }

    /// The floor `next(...)` will never decay below, and the coercion bound
    /// applied to `currentPct` on entry. `.relay` raises it above the
    /// unconditional `minPct` — see the route-tier overload's kdoc for why;
    /// `.direct`/`.unknown` keep today's floor unchanged.
    public static func minPct(for routeTier: RouteTier) -> Int {
        switch routeTier {
        case .relay:            return 10
        case .direct, .unknown: return minPct
        }
    }

    private static func next(currentPct: Int, observedLossPct: Double, floorPct: Int) -> Int {
        let floor = min(max(floorPct, minPct), maxPct)
        let cur = min(max(currentPct, floor), maxPct)
        guard observedLossPct.isFinite else { return cur }
        // ceil, not round: 0.2% observed loss is real loss, and the branch
        // decision below must see it as "at least 1", never as clean.
        let obs = Int(min(max(observedLossPct, 0), 100).rounded(.up))
        if obs > cur {
            return min(max(obs + upHeadroomPct, floor), maxPct)
        }
        return max(max(cur - decayStepPct, obs), floor)
    }
}
