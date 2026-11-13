import Foundation

// What the two round-1 bundles decide about the outer relay layer, and what a failure of the key exchange does. Pure functions over
// the analyses of the bundles as sent and as received (`CapsBind.analyze`): the decision is taken from the bytes, never from state.

/// The `relayKem` member of a bundle as the raw text states it.
public enum RelayKemState: Equatable, Sendable {
    case absent
    /// Present but not usable: a duplicate, an extra member, a missing member, a wrong type, a wrong length, non-canonical base64.
    case invalid
    case valid(RelayKemWire)
}

public struct RelayDecision: Equatable, Sendable {

    public enum Outer: Equatable, Sendable {
        /// The per-round keys of the exchange seal the relay layer.
        case kout
        /// The older directional sealer, when `srtpDirKeyV1` is negotiated.
        case legacy
        /// No outer layer at all (the call goes on with the inner layer over the DataChannel only).
        case rule3
    }

    public let outer: Outer
    public let relayKemInEffect: Bool
    public let relayRotInEffect: Bool

    /// The word of the protection line: `ind`, `indrot`, `same` or `off`.
    public var token: String {
        switch outer {
        case .kout: return relayRotInEffect ? "indrot" : "ind"
        case .legacy: return "same"
        case .rule3: return "off"
        }
    }

    /// Both round-1 bundles bind their capabilities, both carry `relayKemV1` and a valid member. `relayRotV1` needs both bundles to
    /// carry it as well and is never in effect without the exchange.
    static func inEffect(own: BundleCapsBind, peer: BundleCapsBind) -> (kem: Bool, rot: Bool) {
        guard CapsBind.isActive(own: own, peer: peer),
              own.tags.contains("relayKemV1"), peer.tags.contains("relayKemV1") else { return (false, false) }
        guard case .valid = own.relay, case .valid = peer.relay else { return (false, false) }
        let rot = own.tags.contains("relayRotV1") && peer.tags.contains("relayRotV1")
        return (true, rot)
    }

    static func decide(own: BundleCapsBind, peer: BundleCapsBind, srtpDirKeyV1Negotiated: Bool) -> RelayDecision {
        let effect = inEffect(own: own, peer: peer)
        if effect.kem {
            return RelayDecision(outer: .kout, relayKemInEffect: true, relayRotInEffect: effect.rot)
        }
        return RelayDecision(outer: srtpDirKeyV1Negotiated ? .legacy : .rule3, relayKemInEffect: false, relayRotInEffect: false)
    }
}

/// Why a round gave up its outer keys (the closed words of the protection line and of the log).
enum OuterHoldReason: Int, Equatable, Sendable {
    case x25519Zero = 1
    case relayKem = 2
    case slotCollision = 3

    var word: String {
        switch self {
        case .x25519Zero: return "x25519_zero"
        case .relayKem: return "relay_kem"
        case .slotCollision: return "slot_collision"
        }
    }
}

/// What a failure of the key exchange does (the vectors `failureClassification`). Nothing here ends a call.
public enum RelayFailurePolicy {

    public enum Phase: Equatable, Sendable {
        case round1
        case rekey
    }

    public enum Failure: Equatable, Sendable {
        /// The X25519 output was all zeros, or the library threw on a low-order point (the same outcome).
        case x25519Zero
        /// Round 1 only: any other local failure after the ACCEPT was received (4b).
        case otherAfterAccept
        /// Rekey only: any other local failure of the derivation.
        case otherLocalException
        /// Rekey only: the peer's member is absent or invalid under `relayRotV1`.
        case peerRelayKemAbsentOrInvalid
    }

    public struct Outcome: Equatable, Sendable {
        public let reason: String
        public let kOutInstalled: Bool
        public let legacySealerInstalled: Bool
        /// The outer layer is off (round 1: the failure after the ACCEPT, or a zero without `srtpDirKeyV1`).
        public let outerOff: Bool
        /// The `outer-off-v1` word goes out, on the DataChannel only.
        public let sendsOuterOffV1: Bool
        /// Round 1: the exchange is not in effect after the failure. A rekey: it stays active, the set stays on its epoch.
        public let relayKemInEffect: Bool
        public let endsCall: Bool
    }

    public static func classify(phase: Phase, failure: Failure, srtpDirKeyV1: Bool) -> Outcome {
        switch phase {
        case .round1:
            if failure == .otherAfterAccept {
                return Outcome(reason: "local_install", kOutInstalled: false, legacySealerInstalled: false, outerOff: true,
                               sendsOuterOffV1: true, relayKemInEffect: true, endsCall: false)
            }
            return Outcome(reason: OuterHoldReason.x25519Zero.word, kOutInstalled: false, legacySealerInstalled: srtpDirKeyV1,
                           outerOff: !srtpDirKeyV1, sendsOuterOffV1: false, relayKemInEffect: false, endsCall: false)
        case .rekey:
            let reason: OuterHoldReason = failure == .x25519Zero ? .x25519Zero : .relayKem
            return Outcome(reason: reason.word, kOutInstalled: false, legacySealerInstalled: false, outerOff: false,
                           sendsOuterOffV1: false, relayKemInEffect: true, endsCall: false)
        }
    }
}
