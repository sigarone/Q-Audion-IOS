import Foundation

/// W-BWCAP (2026-08-25) — mirrors Android's `PeerBitrateCap.kt` object,
/// byte-for-byte behavior (`FLOOR_BPS`, `coerceAtLeast`, `min`
/// intersection). The PEER's self-reported receive-side bitrate cap for
/// the video WE send them, in bps — carried on `opaque_message` with the
/// `VBWCAP:<int bps>` prefix (`AndroidHandshakeBundle.CallPiggyBack
/// .videoBwCap`). Process-wide singleton-shaped signal, same pattern as
/// `VideoStallSelfHeal`'s pure state: a cross-cutting call-domain fact
/// `QAudionWebRtcCallController` consults without threading it through
/// every call site.
///
/// `nil` = no report received yet this call (or the peer never sent one —
/// legacy peer, capability not negotiated) — no extra clamp applied,
/// today's behavior. `floorBps` guards against a malformed or adversarial
/// report zeroing video out entirely — standard industry behavior for a
/// receiver-driven cap (a floor under the cap, never under the minimum
/// send bitrate).
public enum VideoBandwidthCap {

    public static let floorBps: Int = 30_000

    private static let lock = NSLock()
    /// Guarded by `lock`; `nonisolated(unsafe)` matches the established
    /// pattern for lock-guarded mutable state elsewhere in this target
    /// (see `IOSEarbudGattProxy`'s `peripheral`/`attestPopChar`).
    private static nonisolated(unsafe) var _peerCapBps: Int?

    /// Current peer-reported cap, or `nil` if none received this call.
    public static var peerCapBps: Int? {
        lock.lock(); defer { lock.unlock() }
        return _peerCapBps
    }

    /// Called on each inbound VBWCAP report.
    public static func update(reportedBps: Int) {
        lock.lock(); defer { lock.unlock() }
        _peerCapBps = max(reportedBps, floorBps)
    }

    /// Called at call start/end so a stale cap from the PREVIOUS call can
    /// never leak into a new one.
    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        _peerCapBps = nil
    }

    /// Pure helper: intersect a locally-decided send cap with the peer's
    /// reported receive cap, if any. Mirrors Android's
    /// `PeerBitrateCap.clamp`.
    public static func clamp(_ localMaxBps: Int) -> Int {
        guard let peer = peerCapBps else { return localMaxBps }
        return min(localMaxBps, peer)
    }
}

/// W-ROUTECLAMP (2026-08-25) — the selected ICE candidate-pair's route
/// classification. Mirrors Android's `PeerConnectionHolder.PairKind` /
/// `classifyFromStats`: a pair is `.relay` when EITHER end's
/// `candidateType` WebRTC-Stats value is `"relay"` (a TURN allocation is
/// involved on either side), `.direct` otherwise (host/srflx/prflx on
/// both ends). `.unknown` is the pre-resolution state (no succeeded
/// candidate-pair stat seen yet) — callers must not apply a clamp for it.
public enum RouteTier: Equatable {
    case unknown
    case direct
    case relay

    /// Outgoing video sender ceiling for this tier, bps. Matches Android's
    /// `pc.setBitrate(min, current, max)` MAX bound exactly
    /// (`resolveSelectedPairKind`, `PeerConnectionHolder.kt:2951-2959`,
    /// W-ROUTECLAMP 2026-08-25) — the closest iOS equivalent primitive is
    /// the per-encoding `RTCRtpEncodingParameters.maxBitrateBps`, applied
    /// on the video `RTCRtpSender` rather than as a whole-PeerConnection
    /// BWE hint (iOS's `RTCPeerConnection` does not expose Android's
    /// `setBitrate(min:current:max:)` global-BWE call in this vendored
    /// framework's public surface — unverified, see the call site's doc).
    /// `nil` for `.unknown` — nothing to apply yet.
    public var senderMaxBitrateBps: Int? {
        switch self {
        case .unknown: return nil
        // Android's actual MAX bound for `pc.setBitrate(min, current, max)`
        // is 4_500_000 for Direct / 1_000_000 for Relay
        // (`resolveSelectedPairKind`, PeerConnectionHolder.kt:2953/2956) —
        // NOT the 3_200_000/800_000 "current/start" estimate hint, which
        // has no iOS equivalent (`RTCRtpEncodingParameters.maxBitrateBps`
        // is a hard ceiling, unlike Android's BWE start estimate that can
        // grow past it up to `max`).
        case .direct:  return 4_500_000
        case .relay:   return 1_000_000
        }
    }

    /// Classify from the WebRTC-Stats `candidateType` strings of the
    /// succeeded pair's local and remote candidates ("host"/"srflx"/
    /// "prflx"/"relay", or empty when unresolved).
    public static func classify(localType: String, remoteType: String) -> RouteTier {
        guard !localType.isEmpty || !remoteType.isEmpty else { return .unknown }
        return (localType == "relay" || remoteType == "relay") ? .relay : .direct
    }
}

/// W-ROUTETIERDWELL (2026-08-26, best-practices audit item 3) — pure
/// decision helper adding multi-poll dwell confirmation to a route-tier
/// reclassification, mirroring the asymmetric hysteresis
/// `QAudionWebRtcCallController.evaluateBackpressure` already applies to the
/// CPU-backpressure knob (`backpressureSustainPolls` / `backpressureRecover
/// Polls`) in the SAME controller. Before this, `resolveAndApplyRouteTier`
/// committed a Direct↔Relay reclassification — and therefore the 4.5x sender
/// ceiling swing (`RouteTier.senderMaxBitrateBps`: 4_500_000 vs 1_000_000) —
/// on a single poll's classification, unlike the other two adaptive video
/// knobs in the same controller (backpressure above; `AbrController`'s AIMD
/// sustain counters on the WS-relay path), both of which require sustained
/// agreement before acting. A single noisy/transient candidate-pair stat
/// (e.g. a momentary `prflx`→`relay` blip during continual ICE gathering,
/// see `resolveAndApplyRouteTier`'s own "belt-and-braces poll for the whole
/// call" doc) could previously slam outgoing video to a quarter of its
/// ceiling and back for no real network reason.
///
/// Extracted as pure state (no PeerConnection/WebRTC types) so the
/// transition logic can be pinned by unit tests without a live stats
/// callback — same discipline `RestartIceDecisions` / `MediaDeadDecisions` /
/// `UpgradeFlowDecisions` already use elsewhere in this directory.
public struct RouteTierDwell: Equatable {

    /// Consecutive polls agreeing on a DIRECT→RELAY reclassification
    /// (ceiling DEGRADING) required before it commits. Matches
    /// `QAudionWebRtcCallController.backpressureSustainPolls` (2 polls ×
    /// 3s cadence ≈ 6s) — same speed as trusting "you're CPU-limited".
    public static let sustainPolls = 2

    /// Consecutive polls agreeing on a RELAY→DIRECT reclassification
    /// (ceiling RECOVERING) required before it commits. Matches
    /// `QAudionWebRtcCallController.backpressureRecoverPolls` (3 polls ×
    /// 3s cadence ≈ 9s) — deliberately slower to trust a recovery than a
    /// degradation, same asymmetry as W-BACKPRESSURE and the WS-relay
    /// `AbrController`'s AIMD increase path.
    public static let recoverPolls = 3

    /// The currently-committed tier — what `senderMaxBitrateBps` should be
    /// derived from right now. `.unknown` until the first poll resolves.
    public private(set) var committed: RouteTier

    private var pending: RouteTier = .unknown
    private var dwellPolls: Int = 0

    public init(committed: RouteTier = .unknown) {
        self.committed = committed
    }

    /// Feed one poll's freshly classified tier. Callers must not pass
    /// `.unknown` (mirrors `resolveAndApplyRouteTier`'s existing
    /// `tier != .unknown` guard on the raw classification — there is
    /// nothing to dwell-confirm about "no succeeded pair yet").
    ///
    /// Returns `true` exactly when `committed` changed as a result of this
    /// observation — the caller should re-apply the composed sender clamp
    /// and fire its "ceiling changed" callback ONLY on a `true` return, same
    /// as the pre-dwell code did on every raw tier change.
    @discardableResult
    public mutating func observe(_ tier: RouteTier) -> Bool {
        precondition(tier != .unknown, "RouteTierDwell.observe must not be called with .unknown")
        guard tier != committed else {
            // Poll agrees with what's already committed — nothing pending,
            // whether or not a competing tier was mid-dwell a moment ago.
            pending = .unknown
            dwellPolls = 0
            return false
        }
        // First-ever resolution this call (coming from `.unknown`): commit
        // immediately. There is no previous ceiling being swung AWAY FROM —
        // this is establishing the call's starting ceiling, not a
        // reclassification, so hysteresis would only delay applying the
        // correct starting value (matches the pre-dwell behavior for this
        // one case, and mirrors why `resolveAndApplyRouteTier` is also
        // called eagerly once on ICE-connect).
        guard committed != .unknown else {
            committed = tier
            pending = .unknown
            dwellPolls = 0
            return true
        }
        if tier == pending {
            dwellPolls += 1
        } else {
            pending = tier
            dwellPolls = 1
        }
        let required = (tier == .relay) ? Self.sustainPolls : Self.recoverPolls
        guard dwellPolls >= required else { return false }
        committed = tier
        pending = .unknown
        dwellPolls = 0
        return true
    }

    /// Per-call teardown reset — mirrors `VideoBandwidthCap.reset()` /
    /// `QAudionWebRtcCallController`'s own per-call state clear so a
    /// previous call's dwell counters never bleed into the next one.
    public mutating func reset() {
        committed = .unknown
        pending = .unknown
        dwellPolls = 0
    }
}

/// W-BWECOMPOSE (2026-08-27, best-practices audit item 1) — pure decision
/// helper composing GoogCC's own `availableOutgoingBitrate` congestion
/// estimate — already read, read-only, by `QAudionWebRtcCallController
/// .pollVideoStatsOnce` since `3967cc7` but never wired to any behavior —
/// into the sender-ceiling chain `applyComposedVideoSenderClamp` already
/// composes (route tier x CPU backpressure, intersected with the peer's
/// reported VBWCAP via `VideoBandwidthCap.clamp`). Mirrors the AIMD
/// threshold-rule SHAPE this package's app-target sibling `AbrController`
/// already uses on the WS-relay path — decrease immediately on a bad
/// reading, require several consecutive healthy readings before trusting a
/// recovery — per the best-practices audit's own suggested approach,
/// rather than inventing a new algorithm. The hysteresis here is one-sided
/// (decrease-fast / increase-slow) over a CONTINUOUS bps value, unlike
/// `RouteTierDwell`'s symmetric N-polls-either-way dwell over a discrete
/// state — closer in shape to `QAudionWebRtcCallController
/// .evaluateBackpressure`'s own `backpressureRecoverPolls` (3 consecutive
/// healthy 3s polls to recover) than to `RouteTierDwell`.
///
/// This is purely an ADDITIONAL narrowing clamp: `applyComposedVideoSenderClamp`
/// intersects it via `min()` with what route-tier x backpressure x VBWCAP
/// already computed — it can only ever LOWER that ceiling further, never
/// raise it above what those already allow. A single noisy or absent
/// GoogCC sample therefore cannot regress today's behavior beyond "one more
/// min() term"; `.max` (no constraint) is the safe default before the
/// first real sample this call and after `reset()`.
public struct BweSenderCeiling: Equatable {

    /// Headroom kept below GoogCC's own reported ceiling. GoogCC's
    /// `availableOutgoingBitrate` is a probe-based, continuously
    /// re-estimated filter output (delay-based + loss-based detectors), not
    /// a hard measured maximum — sending flat AT its reported value leaves
    /// no margin for the estimate's own next downward correction and risks
    /// immediately re-triggering the congestion it just resolved. 15%
    /// headroom is a conservative, DOCUMENTED starting choice (not a
    /// measured/tuned constant — this box has no live-device numbers to
    /// tune against, matching the read site's own now-superseded
    /// "read-only, needs live-device numbers first" caveat); revisit with
    /// real call telemetry once available.
    public static let marginFactor: Double = 0.85

    /// Consecutive healthy (BWE-implied ceiling >= currently-held ceiling)
    /// polls required before the BWE-side ceiling is allowed to rise.
    /// Matches `QAudionWebRtcCallController.backpressureRecoverPolls`.
    public static let recoverPolls = 3

    /// The currently-held BWE-side ceiling, bps. `.max` = no constraint
    /// applied yet (no valid sample observed this call, or every sample so
    /// far has been invalid/absent) — `applyComposedVideoSenderClamp`'s
    /// `min()` with this value is then a no-op: exactly today's
    /// pre-this-change behavior.
    public private(set) var ceilingBps: Int = .max

    private var healthyPolls: Int = 0

    public init() {}

    /// Feed one poll's raw `availableOutgoingBitrate` sample (bps). `<= 0`
    /// (the read site's own "absent" sentinel — see `bweAvailableOutgoingBps`)
    /// means "no information this poll": the held ceiling is left exactly
    /// as it was rather than reset to `.max` — a single missed poll must
    /// not suddenly remove a real, recently-observed constraint.
    ///
    /// Returns `true` exactly when `ceilingBps` changed as a result of this
    /// observation — callers should re-apply the composed sender clamp only
    /// on a `true` return, same discipline `RouteTierDwell.observe`
    /// establishes for the route-tier clamp above.
    @discardableResult
    public mutating func observe(rawAvailableOutgoingBps: Double) -> Bool {
        guard rawAvailableOutgoingBps > 0 else { return false }
        let candidate = Int(rawAvailableOutgoingBps * Self.marginFactor)
        if candidate < ceilingBps {
            // Congestion (or the first-ever sample this call): apply
            // immediately — same "no dwell on the way down" urgency as
            // `evaluateBackpressure`'s CPU-limited branch and the AIMD
            // decrease paths in `AbrController`.
            ceilingBps = candidate
            healthyPolls = 0
            return true
        } else if candidate > ceilingBps {
            healthyPolls += 1
            guard healthyPolls >= Self.recoverPolls else { return false }
            healthyPolls = 0
            ceilingBps = candidate
            return true
        } else {
            healthyPolls = 0
            return false
        }
    }

    /// Per-call teardown reset — same discipline as `VideoBandwidthCap
    /// .reset()` / `RouteTierDwell.reset()` so a previous call's BWE
    /// history never bleeds into the next one.
    public mutating func reset() {
        ceilingBps = .max
        healthyPolls = 0
    }
}
