import Foundation

/// W-GRPNAME (2026-08-02) — the rules behind "a group is never nameless, not
/// even for a second". iOS half of a three-platform contract; the Desktop twin
/// is `src/main/messaging/GroupCreation.ts` (+ `test/messaging/
/// groupCreation.spec.ts`, `groupCreationFanout.spec.ts`), which this file is
/// deliberately modelled on field-for-field so the two cannot drift.
///
/// ## What went wrong before this existed
///
/// Creating a group used to be two independent calls: `POST /api/v1/groups`
/// registered the roster, and a SEPARATE `PUT …/metadata` published the
/// (client-encrypted) name afterwards. Group `1a751eae` was created at
/// 06:34:08 and only reached `metadata_version = 1` at 06:34:46 — 38 seconds
/// of a nameless group, and permanent had that second call failed. A member
/// who learns of a group from a server snapshot has no other source for its
/// name, so it renders the raw hex id ("3fedc2e7…") forever.
///
/// The fix is one atomic call: `POST /api/v1/groups` now carries
/// `metadata_blob_b64` + `metadata_version`, persisted in the SAME server
/// transaction as the group row, so a group is never visible without its
/// name. The separate PUT stays — it is the RENAME path, and it doubles as
/// the fallback whenever the create call did not manage to publish (see
/// ``groupCreatePublishVerdict``).
///
/// ## The ordering trap this file cannot enforce (but must document)
///
/// The blob is sealed with the creating device's group send-chain. A member
/// installs that chain from our `sender_key_init`, which carries `CK_n` at the
/// index `n` we had reached when it was built, and `handleSenderKeyInit` sets
/// `lastSeen = n - 1`: chain keys ratchet FORWARD only, so anything encrypted
/// at an index below `n` is undecryptable for them, permanently. The caller
/// MUST ship its `sender_key_init` envelopes BEFORE sealing the creation
/// metadata blob. Seal first and the name is cryptographically unreachable for
/// every member — the exact symptom this whole change exists to remove, in a
/// new disguise.
///
/// Pure by design: no Keychain, no UserDefaults, no network.

// MARK: - Version

/// The `metadata_version` a client stamps on the blob it publishes in the
/// CREATE call. Server contract, verbatim: when a blob is present the version
/// must be >= 1 — 0 means "this group has no metadata", so stamping 0 on a
/// real blob is the same defect as sending no blob at all. Desktop twin:
/// `GROUP_METADATA_INITIAL_VERSION`.
public let initialGroupMetadataVersion: UInt32 = 1

/// The founding `group_epoch` of a brand-new group — shared by every platform
/// AND the server (`store.Group{GroupEpoch: 1}`; iOS bootstraps `GroupState`
/// at 1 in `GroupChatService.session`). Leaving it at Go's zero value once
/// broke Android↔iOS outright, so 0 is never adopted from a response. Desktop
/// twin: `GROUP_INITIAL_EPOCH`.
public let initialGroupEpoch: UInt32 = 1

// MARK: - What is worth publishing

/// The name to seal into the creation blob, or nil when there is nothing
/// worth publishing.
///
/// Two rejections, both of which would otherwise be worse than publishing
/// nothing:
///
/// * **blank** — an empty name renders as no name at all, yet it would still
///   burn `metadata_version = 1`. Every later rename has to beat that version
///   through the monotonic guard, so the group would be harder to name, not
///   easier.
/// * **a synthesized placeholder** — see ``isSynthesizedGroupPlaceholderName``.
///   Publishing one makes "Gruppo a1b2c3d4…" the group's canonical, encrypted,
///   server-stored name for everybody, at which point no client can tell it
///   apart from a name the user actually chose.
public func groupNameToPublishAtCreation(_ rawName: String) -> String? {
    let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !isSynthesizedGroupPlaceholderName(trimmed) else { return nil }
    return trimmed
}

/// True when `name` is one of the placeholder shapes this app synthesises
/// locally for a group whose real (encrypted) name has not arrived yet:
///
/// * `"Gruppo a1b2c3d4…"` — the current form (`DisplayName.shortGroupFallback`).
/// * `"a1b2c3d4…"` — the legacy bare hex fragment older builds persisted
///   directly into the registry. This is literally what "the group renamed
///   itself to a hex fragment" looked like on screen.
///
/// Used to keep a placeholder out of anything that would make it permanent:
/// the creation blob, and the epoch re-seal that republishes a group's
/// current name under a fresh crypto epoch.
///
/// Deliberately narrow. `"Gruppo 3 membri"` — the fallback the create sheet
/// synthesises when the user leaves the name field empty — is a REAL
/// user-facing name and must pass: only an exactly-8-character hex stem
/// followed by the ellipsis counts.
public func isSynthesizedGroupPlaceholderName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasSuffix("…") else { return false }
    let body = String(trimmed.dropLast())
    let prefix = "Gruppo "
    let stem = body.hasPrefix(prefix) ? String(body.dropFirst(prefix.count)) : body
    guard stem.count == 8 else { return false }
    return stem.allSatisfy { $0.isHexDigit }
}

// MARK: - Reading the create response

/// Why the name is (or is not) live on the server after `POST /groups`.
/// Mirrors Desktop's `CreatePublishReason` case for case.
public enum GroupCreatePublishReason: String, Sendable, Equatable, CaseIterable {
    /// Blob accepted at the epoch we sealed it for — nothing more to do.
    case published = "published"
    /// We never sealed one (blank name / engine error) — publish it the old way.
    case noBlob = "no-blob"
    /// Server stored no version: a build that ignores the new fields.
    case serverIgnoredBlob = "server-ignored-blob"
    /// Server minted a different epoch: the blob we sent is unreadable.
    case epochMismatch = "epoch-mismatch"
}

/// What the create response means for the group's name. Mirrors Desktop's
/// `CreatePublishVerdict`.
public struct GroupCreatePublishVerdict: Sendable, Equatable {
    /// The name is live server-side under ``publishedVersion``.
    public let namePublished: Bool
    /// Version the server actually stored (0 when nothing was stored).
    public let publishedVersion: UInt32
    /// The server's epoch when it disagrees with ours, else nil. Desktop
    /// rebuilds its local `GroupState` at this epoch; iOS has no in-place
    /// rebuild primitive and logs it instead — see the call site, and note
    /// the branch is unreachable in practice (the server creates at epoch 1
    /// and answers 409 for an existing group, which never reaches here).
    public let rebuildAtEpoch: UInt32?
    /// Publish the name with the ordinary `PUT …/metadata` instead.
    public let needsMetadataPut: Bool
    public let reason: GroupCreatePublishReason

    public init(namePublished: Bool, publishedVersion: UInt32, rebuildAtEpoch: UInt32?,
                needsMetadataPut: Bool, reason: GroupCreatePublishReason) {
        self.namePublished = namePublished
        self.publishedVersion = publishedVersion
        self.rebuildAtEpoch = rebuildAtEpoch
        self.needsMetadataPut = needsMetadataPut
        self.reason = reason
    }
}

/// Read the create response.
///
/// EPOCH FIRST, and it dominates: the 0xE4 group wire binds `group_epoch` into
/// its AAD, so a blob sealed at our epoch cannot be opened by anyone once the
/// group actually lives at another one — an accepted-but-unreadable blob is
/// WORSE than none, because its `metadata_version` would then suppress the
/// retry through the monotonic guard.
///
/// A server epoch of 0 (absent) is never adopted: that is the exact value
/// whose adoption once broke Android↔iOS, and every client bootstraps at
/// ``initialGroupEpoch`` anyway.
///
/// Only the server's own `metadata_version` echo is trusted. A build that does
/// not yet understand the two new fields accepts the request and answers
/// without one, which means the group really has NO metadata stored; recording
/// a fabricated 1 would make the monotonic guard drop the first REAL
/// `group_metadata_changed` as stale, leaving this device on a name nobody
/// else has and no event able to correct it.
public func groupCreatePublishVerdict(
    sentBlob: Bool,
    localEpoch: UInt32,
    serverEpoch: UInt32,
    serverMetadataVersion: UInt32
) -> GroupCreatePublishVerdict {
    if serverEpoch >= 1, serverEpoch != localEpoch {
        return GroupCreatePublishVerdict(
            namePublished: false, publishedVersion: 0, rebuildAtEpoch: serverEpoch,
            needsMetadataPut: true, reason: .epochMismatch)
    }
    guard sentBlob else {
        return GroupCreatePublishVerdict(
            namePublished: false, publishedVersion: 0, rebuildAtEpoch: nil,
            needsMetadataPut: true, reason: .noBlob)
    }
    guard serverMetadataVersion >= initialGroupMetadataVersion else {
        return GroupCreatePublishVerdict(
            namePublished: false, publishedVersion: 0, rebuildAtEpoch: nil,
            needsMetadataPut: true, reason: .serverIgnoredBlob)
    }
    return GroupCreatePublishVerdict(
        namePublished: true, publishedVersion: serverMetadataVersion,
        rebuildAtEpoch: nil, needsMetadataPut: false, reason: .published)
}

// MARK: - The creation fan-out

/// True when a `group_membership_changed` frame carries a client-signed
/// envelope, i.e. somebody's device attested to this membership fact.
///
/// The creation fan-out does NOT: nothing signs a group into existence
/// (`POST /groups` has no signed envelope in its body), so the server emits
/// the event with empty `envelope_canonical_b64` / `envelope_signature_b64` —
/// exactly like the crash-recovery `snapshot` replay. Verified against the
/// Desktop twin, whose `groupCreationFanout.spec.ts` pins the same shape and
/// which reaches the identical conclusion from the other direction (it DOES
/// verify signatures and treats an unattested frame as a hint only).
///
/// **Honest scope — read before trusting this for anything else.** This is a
/// PRESENCE check, not a verification: iOS does not check the signature
/// cryptographically anywhere in the membership path
/// (`handleGroupMembershipChanged` trusts the bearer-authed, cert-pinned WS
/// session — its own kdoc says so), and a hostile server can put arbitrary
/// bytes in both fields. So this defends against exactly one thing: the
/// server's OWN legitimately-unsigned frames (creation fan-out, crash-recovery
/// snapshot) being misread as attested user actions. That is the same class of
/// guard as the `replay` flag — a correctness rule about server-generated
/// non-attestations, not a cryptographic control — and it is the class of bug
/// that actually bites (a deploy-time replay resurrecting every deleted chat
/// is on record; a hostile bcrypto server rewriting rosters is not, and would
/// have far more direct paths anyway, since iOS applies the roster verbatim).
///
/// Real verification — Desktop already does Ed25519 over
/// `canonicalMembershipJson` — is the follow-up that would make this a
/// security boundary. Until then, do not describe it as one.
public func membershipEventIsAttested(envelopeB64: String, signatureB64: String) -> Bool {
    let env = envelopeB64.trimmingCharacters(in: .whitespacesAndNewlines)
    let sig = signatureB64.trimmingCharacters(in: .whitespacesAndNewlines)
    return !env.isEmpty && !sig.isEmpty
}

/// ``classifyMembershipEventForTombstone(operation:subjectUserId:selfUserId:isReplay:)``
/// with the attestation check in front of it.
///
/// Why this overload had to exist the moment the server started fanning out at
/// creation: that event is an `operation: "add"` naming a member of the
/// founding roster, unsigned. Fed to the plain classifier it reads as
/// `.membershipEventAddingSelf` — a genuine re-add — and clears the tombstone
/// of a group the user deleted. Nothing about a bare server assertion should
/// be able to do that; a re-add is a claim somebody's ADMIN KEY has to make.
///
/// This does not lock a legitimately re-added user out: `handleAddMember`
/// fans out the admin's real signed envelope (so the live clear path still
/// works), and the offline-proof path — `reconcileTombstoneDecision`, which
/// needs no event at all — is unaffected either way.
public func classifyMembershipEventForTombstone(
    operation: String,
    subjectUserId: String,
    selfUserId: String,
    isReplay: Bool,
    isAttested: Bool
) -> GroupResurrectionSource {
    guard isAttested else { return .serverMembershipSnapshot }
    return classifyMembershipEventForTombstone(
        operation: operation, subjectUserId: subjectUserId,
        selfUserId: selfUserId, isReplay: isReplay)
}
