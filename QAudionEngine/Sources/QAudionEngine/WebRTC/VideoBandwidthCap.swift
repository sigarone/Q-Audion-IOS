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
