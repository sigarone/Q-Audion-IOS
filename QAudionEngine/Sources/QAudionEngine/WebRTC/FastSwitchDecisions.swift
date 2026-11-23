import Foundation

/// Pure decisions behind the faster media switch on a network change during a 1:1 call
/// (flag `calls.ice_fastswitch`, default off) and behind the selected-pair route tier.
/// No WebRTC, no sockets: the call controller and the signalling socket feed plain values in.
public enum FastSwitchDecisions {

    /// The restart reason the call controller uses for an OS-reported interface change.
    public static let interfaceChangeReason: String = "interface-change"

    /// With the flag on, a signalling-socket reconnect on a path edge may run this often (the
    /// legacy path-edge debounce is 15 s and the legacy action is "do not reconnect").
    public static let socketKickDebounceSec: TimeInterval = 3.0

    /// At most this many flag-driven reconnects inside `socketKickWindowSec`: a path monitor that
    /// reports an edge every few seconds must not turn into a reconnect storm during a call.
    public static let socketKickMaxPerWindow: Int = 3
    public static let socketKickWindowSec: TimeInterval = 30.0

    public enum PathEdgeAction: Equatable {
        /// Do nothing at all (debounced, or a live authenticated socket is already there).
        case ignore
        /// Legacy behaviour: only retune the keepalive, the ping/pong staleness check owns recovery.
        case adaptiveTimingOnly
        /// Flag on and a call is active: reconnect the signalling socket now.
        case reconnectNow
    }

    /// What the signalling socket does on a genuine path edge (network recovered or transport switched).
    /// - Parameters:
    ///   - legacyDebounceSec: the socket's own path-edge debounce (15 s).
    ///   - recentKicks: flag-driven reconnects already done inside the last `socketKickWindowSec`.
    ///   - interfaceTypeChanged: the primary interface TYPE changed (Wi-Fi, cellular, wired). A
    ///     socket bound to the old interface is dead even if it still looks authenticated, so with
    ///     the flag on, in a call, this overrides the live-socket check (debounce and cap stay).
    public static func pathEdgeAction(flagOn: Bool,
                                      inActiveCall: Bool,
                                      hasLiveAuthenticatedTask: Bool,
                                      interfaceTypeChanged: Bool = false,
                                      sinceLastKickSec: TimeInterval,
                                      legacyDebounceSec: TimeInterval,
                                      recentKicks: Int) -> PathEdgeAction {
        let fast = flagOn && inActiveCall
        let debounce = fast ? socketKickDebounceSec : legacyDebounceSec
        if sinceLastKickSec < debounce { return .ignore }
        if hasLiveAuthenticatedTask && !(fast && interfaceTypeChanged) { return .ignore }
        guard fast else { return .adaptiveTimingOnly }
        if recentKicks >= socketKickMaxPerWindow { return .adaptiveTimingOnly }
        return .reconnectNow
    }

    /// True when this restart is the interface-change one and the flag is on: it reuses the ICE
    /// server list the connection already holds and skips the relay UDP re-probe. First call setup
    /// and every other restart reason (ice-failed watchdog, relay fleet change, p2p probe) still
    /// probe.
    /// The parked resend of that restart (`interface-change.parked-resend`) is the same attempt, so
    /// it counts too. `forceProbe` is the explicit marker of the one fallback restart (never the
    /// reason text): it always takes the normal path.
    /// `peerRequestBypass`: the restart answers a peer request that `peerRequestAction` let past the debounce and the
    /// gate; it takes the cached servers as well.
    public static func usesCachedServersForRestart(flagOn: Bool, reason: String, forceProbe: Bool = false,
                                                   peerRequestBypass: Bool = false) -> Bool {
        guard flagOn, !forceProbe else { return false }
        if peerRequestBypass && reason == peerRequestReason { return true }
        return reason == interfaceChangeReason
            || reason == interfaceChangeReason + RestartIceDecisions.parkedResendReasonSuffix
    }

    /// The restart reason of a `restart_ice_request` received from the peer.
    public static let peerRequestReason: String = "peer-requested-ice-restart"
    /// Trigger label written on the timing lines of such a restart.
    public static let peerRequestTrigLabel: String = "peer_req"

    public enum PeerRequestAction: Equatable {
        /// Behaviour as before: the debounce and the gate apply, servers are refreshed.
        case normal
        /// Accept at once (no debounce, no gate), make a new offer with the cached servers.
        case bypassGates
        /// A duplicate, or a second new offer inside the storm bound: nothing is done.
        case drop
        /// A restart offer of ours is in flight and unanswered: send that same offer again.
        case resendInflight
    }

    /// A peer request closer than this to the previous accepted one is a duplicate.
    public static let peerRequestDuplicateMs: Int64 = 1_000
    /// At most one NEW offer per this long from peer requests.
    public static let peerRequestNewOfferMs: Int64 = 2_000

    /// What the offering side does with a peer restart request. Only with the flag on, as the offering side, and
    /// for the peer-request reason; everything else is `.normal`. The request itself is the signal that the peer's
    /// network changed, so the local ICE state does not matter.
    /// - Parameters:
    ///   - hasUnansweredOffer: a restart offer was sent after the last answer and no answer has come back.
    ///   - sinceLastAcceptedMs: time since the previous accepted peer request (nil: none yet).
    ///   - sinceLastNewOfferMs: time since the previous new offer made for a peer request (nil: none yet).
    public static func peerRequestAction(flagOn: Bool, initiator: Bool, reason: String,
                                         hasUnansweredOffer: Bool,
                                         sinceLastAcceptedMs: Int64? = nil,
                                         sinceLastNewOfferMs: Int64? = nil) -> PeerRequestAction {
        guard flagOn, initiator, reason == peerRequestReason else { return .normal }
        if let s = sinceLastAcceptedMs, s < peerRequestDuplicateMs { return .drop }
        if hasUnansweredOffer { return .resendInflight }
        if let s = sinceLastNewOfferMs, s < peerRequestNewOfferMs { return .drop }
        return .bypassGates
    }

    /// The answering side asks the offering side for a restart on an interface change. With the flag on, a trigger
    /// the debounce or the gate would refuse still sends (or re-arms) the request: the gate protects against
    /// overlapping offers, and this side makes none.
    public static func requestStillSentInsideGate(flagOn: Bool, initiator: Bool, reason: String,
                                                  peerUsesRequest: Bool) -> Bool {
        flagOn && !initiator && peerUsesRequest && reason == interfaceChangeReason
    }

    /// When the restart offer parks (signalling socket down), the park delivers a fresh offer
    /// only on the legacy path. On the fast path it re-sends the SAME already-applied offer:
    /// a second `createOffer(iceRestart)` would be a second restart for one trigger.
    public static func parkedResendMintsNewOffer(cachedServers: Bool) -> Bool { !cachedServers }

    /// After a fast restart was sent, no audio packet arriving on the new pair within this long
    /// means the cached servers may not fit the new network (UDP blocked, relay or bridge needed).
    public static let probeFallbackAfterSec: TimeInterval = 4.0

    /// True when the fast restart must be repeated once on the normal path (relay UDP re-probe and
    /// bridge decision). `baselinePackets` is the inbound audio packet count when the restart was
    /// sent (nil: the call has no inbound RTP row, nothing can be judged, no fallback);
    /// `packetsNow` is the count after the wait (nil: unreadable counts as no audio).
    /// `peerRestartApplied`: a peer-initiated restart offer was applied since the send; that
    /// restart is converging on its own and a second one would overlap it.
    public static func needsProbeFallback(fast: Bool, baselinePackets: Int64?, packetsNow: Int64?,
                                          peerRestartApplied: Bool = false) -> Bool {
        guard fast, !peerRestartApplied, let baseline = baselinePackets else { return false }
        guard let now = packetsNow else { return true }
        return now <= baseline
    }

    /// The reason of the one fallback restart: the parked-resend suffix exempts it from the 3 s
    /// debounce and the single-flight gate (it continues the same attempt); it is sent with
    /// `forceProbe: true`, which is what makes it take the normal path with the probe.
    public static let fallbackReason: String = interfaceChangeReason + RestartIceDecisions.parkedResendReasonSuffix
}

/// Process-wide copy of the flag for the signalling socket, which cannot see the call controller.
/// Set by the controller when its path monitor arms, cleared at teardown.
public final class CallFastSwitchGate: @unchecked Sendable {
    public static let shared = CallFastSwitchGate()
    private let lock = NSLock()
    private var enabled = false

    public var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    public func set(_ value: Bool) {
        lock.lock(); enabled = value; lock.unlock()
    }
}

/// One candidate pair as reported by the stats, reduced to what the route tier needs.
public struct IcePairSnapshot: Equatable {
    public let id: String
    public let state: String
    public let nominated: Bool
    public let localType: String
    public let remoteType: String

    public init(id: String, state: String, nominated: Bool, localType: String, remoteType: String) {
        self.id = id
        self.state = state
        self.nominated = nominated
        self.localType = localType
        self.remoteType = remoteType
    }

    public var tier: RouteTier { RouteTier.classify(localType: localType, remoteType: remoteType) }
}

/// The route tier follows the pair ICE actually selected, never "some pair that once succeeded":
/// after a network change the old relay pair can stay `succeeded` next to the new direct one, and
/// taking the first one in dictionary order classified a srflx/UDP call as relay.
public enum SelectedPairResolver {

    /// 1. the pair the transport names as selected; 2. the nominated succeeded pairs; 3. the
    /// succeeded pairs. In steps 2 and 3 the answer is only trusted when every candidate of the
    /// step has the same tier (an ambiguous mix returns nil, i.e. "unknown", and changes nothing).
    public static func select(selectedPairId: String?, pairs: [IcePairSnapshot]) -> IcePairSnapshot? {
        if let id = selectedPairId, let hit = pairs.first(where: { $0.id == id }) { return hit }
        let succeeded = pairs.filter { $0.state == "succeeded" }
        let nominated = succeeded.filter { $0.nominated }
        for group in [nominated, succeeded] where !group.isEmpty {
            let tiers = Set(group.map { $0.tier.rawKey })
            if tiers.count == 1 { return group.sorted { $0.id < $1.id }.first }
            return nil
        }
        return nil
    }

    public static func tier(selectedPairId: String?, pairs: [IcePairSnapshot]) -> RouteTier {
        select(selectedPairId: selectedPairId, pairs: pairs)?.tier ?? .unknown
    }
}

extension RouteTier {
    /// Stable key for set membership (the enum has no raw value).
    fileprivate var rawKey: Int {
        switch self {
        case .unknown: return 0
        case .direct: return 1
        case .relay: return 2
        }
    }
}
