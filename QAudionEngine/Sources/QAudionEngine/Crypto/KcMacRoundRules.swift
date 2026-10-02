import Foundation

/// The key-confirmation context of ONE key round of a 1:1 call (WIRE_SPEC §3.7.1): the round's
/// `K_kc`, its `kc_transcript`, and whether this side was that round's "init" (the signer of that
/// round's OFFER_v6; the other side, the signer of its ACCEPT_v6, is "resp").
public struct KcMacRound: Equatable {
    public let kcKey: Data
    public let transcript: Data
    public let isInitiator: Bool

    public init(kcKey: Data, transcript: Data, isInitiator: Bool) {
        self.kcKey = kcKey
        self.transcript = transcript
        self.isInitiator = isInitiator
    }
}

/// Pure rules of the per-round KCMAC exchange that the app layer applies (R-KCMAC, §3.7.1):
///
/// - the exchange runs on EVERY key round, each round with its own context and roles;
/// - the `KCMAC:` message carries no round field: a MAC is attributed to a round by content;
/// - a receiver keeps, for the rest of the call, the peer MAC it verified for each decided round; an
///   inbound MAC byte-identical to one of them is a DUPLICATE: dropped silently, never judged
///   `wrong`, and the duplicate test comes BEFORE the judgment against the live round;
/// - a MAC that is not a duplicate and arrives while no round is armed and undecided is held (at
///   most one at a time, at most 512 characters of payload, at most 10 s) and judged when the next
///   round is armed.
public enum KcMacRoundRules {

    /// A peer MAC for a round this side has not armed yet is held at most this long.
    public static let earlyHoldSeconds: TimeInterval = 10
    /// Longest `KCMAC:` payload (base64 characters) that may be held.
    public static let maxHeldPayloadCharacters = 512
    /// Wire payload of a `KCMAC:` message: `role byte (1) || MAC (32)`.
    public static let payloadLength = 33

    /// The 32-byte MAC of a well-formed `KCMAC:` payload (base64 of `role || MAC`), `nil` otherwise.
    public static func mac(inPayload raw: String) -> Data? {
        guard let bytes = Data(base64Encoded: raw), bytes.count == payloadLength else { return nil }
        return Data(bytes.suffix(from: bytes.index(after: bytes.startIndex)))
    }

    /// True when `raw` is the PEER's valid MAC for `round`: the role byte is the complement of this
    /// side's role in that round and the MAC verifies under the round's key and transcript.
    public static func isPeerMac(raw: String, of round: KcMacRound) -> Bool {
        guard let bytes = Data(base64Encoded: raw), bytes.count == payloadLength,
              let peerMac = mac(inPayload: raw) else { return false }
        let expectedPeerRole: UInt8 = round.isInitiator ? 0x02 : 0x01
        guard bytes[bytes.startIndex] == expectedPeerRole else { return false }
        return KeyConfirmation.verify(
            received: peerMac, kcKey: round.kcKey, asInitiator: !round.isInitiator, transcript: round.transcript)
    }

    /// True when `raw` carries a MAC byte-identical to one the call already verified for a decided
    /// round (`decidedPeerMacs`, kept for the whole call): a retransmission, or the previous
    /// round's MAC arriving after the next round was armed.
    public static func isDuplicate(raw: String, decidedPeerMacs: [Data]) -> Bool {
        guard let peerMac = mac(inPayload: raw) else { return false }
        return decidedPeerMacs.contains(peerMac)
    }

    /// Most decided peer MACs remembered per call (the oldest is dropped first).
    public static let maxDecidedPeerMacs = 256

    /// Remember the verified peer MAC of a decided round for the rest of the call, bounded at
    /// `maxDecidedPeerMacs` (like desktop) so a very long call cannot grow the list without limit.
    public static func recordDecided(_ mac: Data, in decided: inout [Data]) {
        decided.append(mac)
        if decided.count > maxDecidedPeerMacs {
            decided.removeFirst(decided.count - maxDecidedPeerMacs)
        }
    }

    /// Whether an early MAC may be held now: it is small enough and no other early MAC is held
    /// (a held one that is older than `earlyHoldSeconds` no longer counts: it is stale).
    public static func mayHoldEarly(raw: String, heldAt: Date?, now: Date) -> Bool {
        guard raw.count <= maxHeldPayloadCharacters else { return false }
        if let heldAt, isEarlyHoldFresh(heldAt: heldAt, now: now) { return false }
        return true
    }

    /// Whether a MAC held since `heldAt` may still be verified at `now`.
    public static func isEarlyHoldFresh(heldAt: Date, now: Date) -> Bool {
        return now.timeIntervalSince(heldAt) <= earlyHoldSeconds
    }
}
