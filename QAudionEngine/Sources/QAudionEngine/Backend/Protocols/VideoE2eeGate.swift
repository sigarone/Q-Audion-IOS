import Foundation

/// F-02 (2026-07-26) — the one decision that governs whether 1:1 video may leave
/// this device, as a pure function, because getting it wrong is silent.
///
/// `sframe-v1` is a plaintext capability string the server relays between the two
/// legs. A server that deletes it from both sides, and rewrites the SDP
/// `a=fingerprint` to its own DTLS identity, gets video whose only wrapper is a
/// transport it terminates. Until this, iOS handled that case by latching
/// `.legacy` and carrying on — the code comment said so in as many words: "video
/// still flows, without frame-level E2EE ... unlike Android, which disables the
/// video track outright". Android refused; the attacker targeted iOS instead.
///
/// The mistake had a shape worth naming: two OPPOSITE situations were treated the
/// same. "The session key has not arrived yet" and "the peer declined frame
/// encryption" both ended in a degrade, so a downgrade looked like a not-ready-yet
/// and nothing reported it.
///
/// `failClosed` disables VIDEO, never the call: audio is sealed on its own path
/// and keeps flowing. That is what keeps this inside W-NOBRICK.
///
/// Mirrors `shared/videoE2eeGate.ts` (Desktop) and `VideoE2eeGate.kt` (Android).
public enum VideoE2eeDecision: String, Equatable, Sendable {
    /// No usable key yet. The caller is invoked again; change nothing.
    case defer_
    /// The peer did not agree. Disable video and say so.
    case failClosed
    /// Install the cryptor, then lift any earlier refusal.
    case install
}

public enum VideoE2eeGate {
    /// - Parameters:
    ///   - hasSessionKey: a real 32-byte session key is available (an all-zero
    ///     placeholder does NOT count — that is the earbud-SPE stand-in).
    ///   - peerHeardFrom: capabilities have been negotiated at least once.
    ///   - useSFrame: the negotiated intersection contains `sframe-v1`.
    public static func decide(
        hasSessionKey: Bool,
        peerHeardFrom: Bool,
        useSFrame: Bool
    ) -> VideoE2eeDecision {
        guard peerHeardFrom else { return .defer_ }
        // Order matters: a peer that declined frame encryption is refused whether
        // or not a key ever turns up. Checking the key first would silently turn
        // a downgrade back into a deferral on the slow path.
        guard useSFrame else { return .failClosed }
        return hasSessionKey ? .install : .defer_
    }
}
