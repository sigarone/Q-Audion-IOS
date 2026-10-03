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

/// Payload helpers of the per-round KCMAC exchange (R-KCMAC, §3.7.1). The exchange runs on EVERY key round, each
/// round with its own context and roles, and the `KCMAC:` message carries no round field: the attribution of an
/// inbound MAC to a round by content, the duplicate test and the held set live in `KcMacRoundBook`
/// (R-KCMAC-ROUNDS).
public enum KcMacRoundRules {

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
}
