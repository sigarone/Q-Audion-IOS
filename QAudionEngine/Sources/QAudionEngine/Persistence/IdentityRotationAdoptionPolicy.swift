import Foundation

/// 2026-09-19 — when a peer's identity key rotated (the server publishes the new key, the handshake that
/// presented it verified) but the user had SAS-verified the PREVIOUS key, the app refuses to swap the pin
/// silently: a server-published key set proves the server said so, not that the same human is on the other
/// end. The refusal used to be a dead end. This decides when the user's FRESH SAS confirmation on the call
/// that presented the key may adopt it.
///
/// Both conditions are required:
///  - the pending rotation belongs to the peer of the call being confirmed, so one call's confirmation can
///    never adopt a key that was presented for someone else;
///  - the call's session key (and so its SAS words) is bound to the signed handshake transcript, which
///    contains the signer identity keys. Then a relay that swapped the key would have produced different
///    words on the two ends, and matching words vouch for the key itself. Without that binding the words
///    say nothing about the identity key, and the refusal must stay.
public enum IdentityRotationAdoptionPolicy {
    public static func mayAdopt(
        pendingPeerId: String?,
        activePeerId: String?,
        sessionKeyTranscriptBound: Bool
    ) -> Bool {
        guard let pendingPeerId, !pendingPeerId.isEmpty,
              let activePeerId, pendingPeerId == activePeerId else { return false }
        return sessionKeyTranscriptBound
    }
}
