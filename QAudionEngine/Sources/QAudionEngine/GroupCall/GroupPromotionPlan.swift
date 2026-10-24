import Foundation

/// What the creator of a promotion sends, in what order (GROUP_CALLS_V2 2.7, Promotion token): the recipients of
/// the `group_call_create` after the client's own validation, the group call id minted up front, and
/// the signed token that names both. Pure: the signer, the clock and the id source are passed in.
public enum GroupPromotionPlan {

    /// What `promoteToGroupCall` hands to the controller.
    public struct Plan: Equatable, Sendable {
        /// The recipients of the `group_call_create`. With a token these are exactly the token's
        /// invitees (canonical, sorted); without one, the validated list in its own spelling.
        public let recipients: [String]
        /// The group call id the create goes out under: a random UUID in lower case.
        public let groupCallId: String
        /// nil when a precondition of the token (GROUP_CALLS_V2 2.7) failed: no token is sent and the peer rings.
        public let token: GroupPromotionToken.Built?
        /// Why there is no token (log only).
        public let withoutTokenWhy: String?
    }

    /// The client's own recipient validation: no empty id, not this account, no duplicate after case
    /// folding (the first spelling stays). The 1:1 peer comes first.
    public static func validatedRecipients(peerUserId: String, others: [String], selfUserId: String) -> [String] {
        var out: [String] = []
        for id in [peerUserId] + others {
            if id.isEmpty { continue }
            if !selfUserId.isEmpty && GroupCallIds.ieq(id, selfUserId) { continue }
            if GroupCallIds.contains(out, id) { continue }
            out.append(id)
        }
        return out
    }

    /// Plans the promotion of the live 1:1 call `oneToOneCallId` with `peerUserId`.
    ///
    /// - Parameters:
    ///   - anchor: the anchor of that call: it must hold the round-1 binding and this device's own key.
    ///   - liveSigningPublicKey: the public half of the identity key this device holds now; it must be
    ///     the key that signed its round-1 bundle.
    ///   - sign: signs `PROMO_TBS` with that identity key.
    public static func plan(
        peerUserId: String,
        others: [String],
        selfUserId: String,
        oneToOneCallId: String,
        anchor: OneToOneAnchor,
        liveSigningPublicKey: Data?,
        nowMs: UInt64,
        groupCallId: String,
        sign: (Data) -> Data?
    ) -> Plan {
        let recipients = validatedRecipients(peerUserId: peerUserId, others: others, selfUserId: selfUserId)
        func withoutToken(_ why: String) -> Plan {
            return Plan(recipients: recipients, groupCallId: groupCallId, token: nil, withoutTokenWhy: why)
        }
        guard anchor.canSign, let binding = anchor.acceptBinding1, let ownKey = anchor.ownSignerKey else {
            return withoutToken("no_binding")
        }
        guard let liveKey = liveSigningPublicKey, liveKey == ownKey else { return withoutToken("key_changed") }
        do {
            let built = try GroupPromotionToken.build(
                groupCallId: groupCallId, fromCallId: oneToOneCallId, acceptBinding1: binding,
                creatorUserId: selfUserId, signerKey: ownKey, peerUserId: peerUserId, invitees: recipients,
                issuedAtMs: nowMs, sign: sign)
            return Plan(recipients: built.fields.invitees, groupCallId: groupCallId, token: built, withoutTokenWhy: nil)
        } catch {
            return withoutToken("build_failed")
        }
    }
}
