import Foundation
import QAudionEngine

/// P0-1c follow-up (2026-08-05, coordinated fix plan cluster 2) — real
/// Ed25519 verification for `group_membership_changed` events on a group
/// ALREADY known locally, closing the gap `membershipEventIsAttested`'s
/// own kdoc admits: "iOS still does not verify the signature". Mirrors
/// Android's `HandleMembershipChangeUseCase.verifyMembershipEnvelope` and
/// the server's `verifyEnvelopeSignature` (groups_membership.go) step for
/// step — the canonical envelope format is `GroupMembershipEnvelope`,
/// already used on the SEND side for every admin add/remove/leave/
/// promote/demote this device performs.
///
/// Deliberately NOT called for `operation == "snapshot"` — see
/// `AppState.handleGroupMembershipChanged`'s call site. A snapshot is a
/// server-stated roster fact with no signing actor (same reason group
/// CREATION ships an empty envelope, per that event's own honest-scope
/// note), not a claim any Ed25519 key makes.
enum GroupMembershipVerifier {

    /// Maps the SIGNED envelope's `t` token (the outbound vocabulary any
    /// admin's own device signs — `GroupMembershipEnvelope.opAdd` etc.) to
    /// the INBOUND WS `operation` field this event carries. These are two
    /// DIFFERENT token sets by server contract (see
    /// `GroupMembershipEnvelope.opAdminAdd`'s own kdoc) — never conflate
    /// them. The wire `operation` itself carries the short REST-verb form
    /// ("add"/"remove"/"leave"/"admin_add"/"admin_remove") on a live
    /// mutation but the long membership-log form ("member_added" etc., —
    /// identical to the envelope's own `t` spelling) on a start-up catch-up
    /// replay (see `AppState.isMembershipRemoval`'s kdoc) — both spellings
    /// are accepted here for exactly that reason.
    private static func operationMatches(signedT: String, wireOperation: String) -> Bool {
        switch signedT {
        case GroupMembershipEnvelope.opAdd:
            return wireOperation == "add" || wireOperation == GroupMembershipEnvelope.opAdd
        case GroupMembershipEnvelope.opRemove:
            return wireOperation == "remove" || wireOperation == GroupMembershipEnvelope.opRemove
        case GroupMembershipEnvelope.opLeave:
            return wireOperation == "leave" || wireOperation == GroupMembershipEnvelope.opLeave
        case GroupMembershipEnvelope.opAdminAdd:
            return wireOperation == "admin_add" || wireOperation == GroupMembershipEnvelope.opAdminAdd
        case GroupMembershipEnvelope.opAdminRemove:
            return wireOperation == "admin_remove" || wireOperation == GroupMembershipEnvelope.opAdminRemove
        default:
            return false
        }
    }

    /// Verify one `group_membership_changed` event for a group already
    /// known locally. Returns `true` only when every step below succeeds;
    /// the caller MUST drop the ENTIRE event on `false` — not apply the
    /// roster with one field skipped, since the signature covers the
    /// event as a whole.
    ///
    /// Steps (mirrors Android's `verifyMembershipEnvelope`):
    ///  1. Envelope/signature must both be present.
    ///  2. Fetch the actor's CURRENT published Ed25519 identity key
    ///     (`BCryptoKmsClient.fetchUserIdentityKey`) — iOS has no local
    ///     contact-key cache trusted for this purpose (unlike Android's
    ///     `contactDao`), so this is a live fetch every time; the same
    ///     trust model the server itself already enforces at submission
    ///     time (`verifyEnvelopeSignature` reads the actor's CURRENT
    ///     `SigningPubKey` too).
    ///  3. Verify the Ed25519 signature over the RAW canonical envelope
    ///     bytes exactly as transmitted — never bytes reconstructed
    ///     locally, which would verify tautologically.
    ///  4. Parse those SAME bytes as JSON and cross-check every signed
    ///     field against the outer WS-event field it corresponds to. This
    ///     is what stops a malicious/compromised relay from re-wrapping a
    ///     real, previously-observed (envelope, signature) pair inside a
    ///     different outer frame — signature verification alone would
    ///     still pass since it only ever checks the envelope bytes in
    ///     isolation.
    ///  5. Replay-guard on the SIGNED `e_proposed`/`ts` (never the outer
    ///     fields) via `GroupMembershipReplayGuard`.
    @MainActor
    static func verify(
        groupIdWire: String,
        groupIdHex: String,
        wireOperation: String,
        actorUserId: String,
        subjectUserId: String,
        envelopeCanonicalB64: String,
        envelopeSignatureB64: String,
        kmsClient: BCryptoKmsClient,
        sovereignIdentity: SovereignIdentityManager
    ) async -> Bool {
        let gShort: String = String(groupIdHex.prefix(8))

        guard !envelopeCanonicalB64.isEmpty, !envelopeSignatureB64.isEmpty else {
            RTLog.warn("group", "verify: missing envelope/signature g=" + gShort)
            return false
        }
        guard let envelopeBytes = Data(base64Encoded: envelopeCanonicalB64),
              let signatureBytes = Data(base64Encoded: envelopeSignatureB64) else {
            RTLog.warn("group", "verify: envelope/signature not valid base64 g=" + gShort)
            return false
        }
        guard let actorPub = await kmsClient.fetchUserIdentityKey(userId: actorUserId),
              actorPub.count == 32 else {
            RTLog.warn("group", "verify: no identity key for actor g=" + gShort)
            return false
        }
        let sigOk = sovereignIdentity.verifySignature(
            publicKey: actorPub, challenge: envelopeBytes, signature: signatureBytes)
        guard sigOk else {
            RTLog.warn("group", "verify: signature check failed g=" + gShort)
            return false
        }
        guard let parsedAny = try? JSONSerialization.jsonObject(with: envelopeBytes),
              let parsed = parsedAny as? [String: Any] else {
            RTLog.warn("group", "verify: envelope not parseable JSON g=" + gShort)
            return false
        }
        let signedBy: String = (parsed["by"] as? String) ?? ""
        let signedG: String = (parsed["g"] as? String) ?? ""
        let signedT: String = (parsed["t"] as? String) ?? ""
        let signedUid: String = (parsed["uid"] as? String) ?? ""
        let fieldsMatch: Bool =
            signedBy == actorUserId &&
            signedG == groupIdWire &&
            signedUid == subjectUserId &&
            operationMatches(signedT: signedT, wireOperation: wireOperation)
        guard fieldsMatch else {
            RTLog.warn("group", "verify: signed fields do not match outer frame g=" + gShort)
            return false
        }
        guard let eProposedNum = parsed["e_proposed"] as? NSNumber,
              let tsNum = parsed["ts"] as? NSNumber else {
            RTLog.warn("group", "verify: missing e_proposed/ts in signed envelope g=" + gShort)
            return false
        }
        let signedEProposed: Int64 = eProposedNum.int64Value
        let signedTs: Int64 = tsNum.int64Value
        guard signedEProposed >= 0, signedTs >= 0 else {
            RTLog.warn("group", "verify: negative e_proposed/ts in signed envelope g=" + gShort)
            return false
        }
        let admitted = GroupMembershipReplayGuard.shared.check(
            groupId: groupIdHex, eProposed: signedEProposed, ts: signedTs)
        guard admitted else { return false }
        return true
    }
}
