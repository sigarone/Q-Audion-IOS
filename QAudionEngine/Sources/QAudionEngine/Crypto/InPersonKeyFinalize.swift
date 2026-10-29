import Foundation

/// The evidence of a call that finalizes an in-person key (docs/security/CALL_KEY_PRIORITY.md section 4a, F2).
///
/// A round of a call counts when its handshake signature verified under the identity key the key is bound to and the
/// peer's key confirmation MAC verified, and either (a) the round's selected PSK is the key, or (b) the peer's signed
/// advertisement matched the key through a v3 tag (a match against the static fingerprint does not count).
///
/// Pure: the app resolves the vault entries and calls `CallKeyPriorityStore.finalize` for each name returned.
public enum InPersonKeyFinalize {

    /// An in-person key held in the vault, as the call sees it.
    public struct Key: Equatable, Sendable {
        /// The vault account name.
        public let name: String
        /// `PskAdvertising.canonicalFingerprint(forPsk:)` of the key material.
        public let fingerprint: String
        /// The identity key captured at the pairing (`SovereignKeyVault.nfcPeerIdentityKey(name:)`).
        public let boundIdentityKey: Data?

        public init(name: String, fingerprint: String, boundIdentityKey: Data?) {
            self.name = name
            self.fingerprint = fingerprint
            self.boundIdentityKey = boundIdentityKey
        }
    }

    /// What one round of a call established.
    public struct Round: Equatable, Sendable {
        /// The handshake signature of the round verified.
        public let sigOk: Bool
        /// The identity key that signed the round; nil unless the signature verified.
        public let signerIdentityKey: Data?
        /// The peer's key confirmation MAC of the round verified.
        public let kcmacVerified: Bool
        /// The fingerprint of the PSK the round selected, nil when none.
        public let selectedFingerprint: String?
        /// The peer's advertisement was read as v3 tags (`PskAdvertResolver.Dialect.v3Blinded`).
        public let advertIsBlinded: Bool
        /// The fingerprints of the local keys the peer's advertisement matched.
        public let matchedFingerprints: [String]

        public init(sigOk: Bool, signerIdentityKey: Data?, kcmacVerified: Bool, selectedFingerprint: String?,
                    advertIsBlinded: Bool, matchedFingerprints: [String]) {
            self.sigOk = sigOk
            self.signerIdentityKey = signerIdentityKey
            self.kcmacVerified = kcmacVerified
            self.selectedFingerprint = selectedFingerprint
            self.advertIsBlinded = advertIsBlinded
            self.matchedFingerprints = matchedFingerprints
        }
    }

    /// The names of the in-person keys the round finalizes. Empty unless the signature and the MAC both verified.
    public static func namesToFinalize(round: Round, localKeys: [Key]) -> [String] {
        guard round.sigOk, round.kcmacVerified,
              let signer = round.signerIdentityKey, !signer.isEmpty else { return [] }
        var names: [String] = []
        for key in localKeys {
            guard CallKeyPriority.inPersonDevice(ofAccount: key.name) != nil,
                  let bound = key.boundIdentityKey, bound == signer else { continue }
            let selected = round.selectedFingerprint == key.fingerprint
            let matchedByTag = round.advertIsBlinded && round.matchedFingerprints.contains(key.fingerprint)
            if (selected || matchedByTag) && !names.contains(key.name) {
                names.append(key.name)
            }
        }
        return names
    }
}

/// Deletions that wait for the end of a call.
///
/// A rekey this phone started advertises its keys in the OFFER and later resolves the ACCEPT's echoed selection
/// against the vault (`QAudionCallIntegration.pskForEchoedSelection`). A key deleted in between would break that
/// resolution, so while such a rekey waits for its ACCEPT the finalizations of the call are held, and run when the
/// call ends. A later verified round with no rekey waiting runs them earlier.
public struct DeferredInPersonFinalize: Equatable, Sendable {
    private var heldByCall: [String: [String]] = [:]

    public init() {}

    /// - Returns: the names to finalize now: all of `names` when no rekey of this phone waits for its ACCEPT, plus
    ///   whatever was held for the call before; nothing when one waits (the names are held).
    public mutating func submit(callId: String, names: [String], rekeyWaitingForAccept: Bool) -> [String] {
        let key = callId.lowercased()
        var all = heldByCall[key] ?? []
        for name in names where !all.contains(name) { all.append(name) }
        if rekeyWaitingForAccept {
            heldByCall[key] = all.isEmpty ? nil : all
            return []
        }
        heldByCall[key] = nil
        return all
    }

    /// The call ended: everything held for it, which is then finalized.
    public mutating func flush(callId: String) -> [String] {
        heldByCall.removeValue(forKey: callId.lowercased()) ?? []
    }

    /// The call ended. A call that ended on a handshake failure finalizes nothing: what was held for it is dropped
    /// (deleting earlier keys is not undone, and the next good call finalizes them again).
    public mutating func flushOnEnd(callId: String, endedOnHandshakeFailure: Bool) -> [String] {
        let held = flush(callId: callId)
        return endedOnHandshakeFailure ? [] : held
    }
}

/// Where a handshake failure that ended a call was learned from.
public enum HandshakeFailureSource: Equatable, Sendable {
    /// This device detected it.
    case local
    /// The peer reported it over the authenticated media leg (the control frame).
    case authenticatedPeer
    /// A reason carried by a message the server relays in the clear. It labels the call history, nothing more:
    /// a relay could forge it, so it neither drops finalization nor changes the verdict.
    case relay

    /// Trust rank: local over authenticated peer over relay.
    private var rank: Int {
        switch self {
        case .local: return 3
        case .authenticatedPeer: return 2
        case .relay: return 1
        }
    }

    /// The source to keep when a second report arrives for the same call: never weaker than what is recorded
    /// (a peer sends both the authenticated frame and the relayed envelope, in either order).
    public static func strongest(_ recorded: HandshakeFailureSource?, _ incoming: HandshakeFailureSource) -> HandshakeFailureSource {
        guard let recorded else { return incoming }
        return incoming.rank > recorded.rank ? incoming : recorded
    }
}

/// What the end of a call does to trust, decided from how it ended.
public struct CallEndTrust: Equatable, Sendable {
    /// The held in-person finalizations may run.
    public let finalizeInPersonKeys: Bool
    /// The stashed assurance verdict is replaced by the failure outcome (or dropped) instead of persisted.
    public let downgradeStashedVerdict: Bool

    /// `failureSource` is nil for an end with no handshake failure recorded. `identityHeldUnconfirmed` is true when the
    /// call's media was still held for an identity the user never confirmed: not a clean end.
    public static func decide(failureSource: HandshakeFailureSource?, identityHeldUnconfirmed: Bool) -> CallEndTrust {
        let authenticatedFailure = failureSource == .local || failureSource == .authenticatedPeer
        return CallEndTrust(
            finalizeInPersonKeys: !authenticatedFailure && !identityHeldUnconfirmed,
            downgradeStashedVerdict: authenticatedFailure)
    }

    /// The verdict to persist for a stashed one: unchanged, the failure outcome of `reason`, or none.
    public static func verdictToPersist(
        stashed: AssuranceState, failureSource: HandshakeFailureSource?, reason: String
    ) -> AssuranceState? {
        decide(failureSource: failureSource, identityHeldUnconfirmed: false).downgradeStashedVerdict
            ? FatalAssuranceOutcome.persisted(forReason: reason) : stashed
    }
}
