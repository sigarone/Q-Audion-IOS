import Foundation

/// R-REKEY-INIT (WIRE_SPEC §3.7.2) — who starts a rekey round of a 1:1 call, and R-E-STRICT — where
/// the key round epoch comes from.
public enum RekeyRolePolicy {

    /// Only the CALLER (the signer of the call's initial OFFER, frame role "o") ever initiates a
    /// rekey, on every platform; the callee only responds. A rekey OFFER that reaches the caller is
    /// still answered (it goes through the responder path, never into the buffer that an in-flight
    /// own round reads its ACCEPT from).
    public static func mayInitiateRekey(isCaller: Bool, isActive: Bool, hasPendingAttempt: Bool) -> Bool {
        isCaller && isActive && !hasPendingAttempt
    }

    /// What to do with a freshly derived session key.
    public enum EpochResolution: Equatable {
        /// The key round epoch `E = rekeyRound - 1` of the SIGNED round that derived the key.
        case epoch(Int32)
        /// The round of the key cannot be resolved: the call ends (`handshake_malformed`). There is
        /// no local counter to fall back to: a counted epoch would silently disagree with the peer's
        /// the first time a round is missed, and every frame would land in an empty ring slot.
        case endCall(reason: String)
    }

    /// R-E-STRICT: `E` always comes from the signed round of the installed key, or the call ends.
    public static func resolveKeyEpoch(signedRound: UInt32?) -> EpochResolution {
        guard let signedRound, let epoch = QAudionCallIntegration.keyEpoch(forRekeyRound: signedRound) else {
            return .endCall(reason: "handshake_malformed")
        }
        return .epoch(epoch)
    }
}
