import Foundation

/// D6 (2026-09-28, TURN-stuck-on-P2P fix, owner-requested) — pure decision
/// logic for whether `QAudionWebRtcCallController` should fire ONE probing
/// ICE restart to try to move a call that settled on a TURN relay pair back
/// onto a direct (host/srflx/prflx) pair. Ported from Android's
/// `P2pProbeGate` (`feature-call/.../data/webrtc/P2pProbeGate.kt`) — same
/// numbers, same branches — mirroring how `RestartIceDecisions` in this same
/// directory already ports Android's `IceRestartGate`/`CallController`
/// restart timing. Contains NO WebRTC/PeerConnection state, same discipline
/// as every other pure-decision file here, so it can be pinned by unit tests
/// without a live call.
///
/// See the rootcause:turn analysis (workflow journal, section "D6") for the
/// full design: fired ONLY by the offerer (caller) — never the answerer, to
/// avoid glare with `restart-ice-req-v1` / this file's own N6 re-probe — and
/// only once per call. The controller reuses its own existing `restartIce`
/// machinery to actually perform the restart; this type only decides WHEN
/// that call is allowed to fire. The old pair keeps carrying media until the
/// new one is selected — standard ICE-restart semantics, unchanged by this
/// gate — and the gate must never itself cause a downgrade: if, after the
/// restart, the pair is still relay, the caller logs `result=relay` and does
/// nothing further.
public enum P2pProbeDecisions {

    /// ICE must have been CONNECTED/COMPLETED on a relay pair for at least
    /// this long before probing. Matches Android's
    /// `P2pProbeGate.MIN_CONNECTED_ON_RELAY_MS`.
    public static let minConnectedOnRelayMs: Int64 = 8_000

    /// A DISCONNECTED/FAILED excursion inside this lookback window blocks
    /// the probe. Matches Android's `P2pProbeGate.RECENT_DISCONNECT_LOOKBACK_MS`.
    public static let recentDisconnectLookbackMs: Int64 = 20_000

    /// Inputs to [shouldProbe], mirroring Android's `P2pProbeGate.Input`
    /// field-for-field.
    ///
    /// - Parameters mirror the Android type; see that file's kdoc for the
    ///   full rationale of each one. `transportForcesWs` has no exact iOS
    ///   equivalent surfaced to the ICE layer today (the sealed-frame WS
    ///   relay bypass is architecturally separate from the RTCPeerConnection
    ///   this gate restarts — see `TransportGate.swift`); callers pass
    ///   `false` until/unless such a mode is added, same as Android would if
    ///   it had no FORCE_WS concept.
    public struct Input: Equatable {
        public let isInitiator: Bool
        public let pairKind: RouteTier
        public let relayPairSinceMs: Int64?
        public let nowMs: Int64
        public let peerSentNonRelayCandidate: Bool
        public let lastDisconnectOrFailedAtMs: Int64?
        public let transportForcesTurn: Bool
        public let transportForcesWs: Bool
        public let renegotiationInProgress: Bool
        public let callActive: Bool
        public let alreadyProbedThisCall: Bool
        public let killSwitchActive: Bool

        public init(
            isInitiator: Bool,
            pairKind: RouteTier,
            relayPairSinceMs: Int64?,
            nowMs: Int64,
            peerSentNonRelayCandidate: Bool,
            lastDisconnectOrFailedAtMs: Int64?,
            transportForcesTurn: Bool,
            transportForcesWs: Bool,
            renegotiationInProgress: Bool,
            callActive: Bool,
            alreadyProbedThisCall: Bool,
            killSwitchActive: Bool
        ) {
            self.isInitiator = isInitiator
            self.pairKind = pairKind
            self.relayPairSinceMs = relayPairSinceMs
            self.nowMs = nowMs
            self.peerSentNonRelayCandidate = peerSentNonRelayCandidate
            self.lastDisconnectOrFailedAtMs = lastDisconnectOrFailedAtMs
            self.transportForcesTurn = transportForcesTurn
            self.transportForcesWs = transportForcesWs
            self.renegotiationInProgress = renegotiationInProgress
            self.callActive = callActive
            self.alreadyProbedThisCall = alreadyProbedThisCall
            self.killSwitchActive = killSwitchActive
        }
    }

    public static func shouldProbe(_ input: Input) -> Bool {
        if input.killSwitchActive { return false }
        if !input.isInitiator { return false }
        if input.alreadyProbedThisCall { return false }
        if !input.callActive { return false }
        if input.renegotiationInProgress { return false }
        if input.transportForcesTurn || input.transportForcesWs { return false }
        if input.pairKind != .relay { return false }
        if !input.peerSentNonRelayCandidate { return false }
        guard let since = input.relayPairSinceMs else { return false }
        if input.nowMs - since < minConnectedOnRelayMs { return false }
        if let lastBad = input.lastDisconnectOrFailedAtMs,
           input.nowMs - lastBad < recentDisconnectLookbackMs {
            return false
        }
        return true
    }
}
