import Foundation

/// W-GRPDEL (2026-08-02) — the rules behind "delete a group chat from my
/// device, even though I did not create it". Third of a three-platform port;
/// the twins are Android's `GroupDeletionPolicy.kt` and Desktop's
/// `src/main/group/groupDeletionPolicy.ts`. The three clients have to agree
/// about which groups still exist for a user.
///
/// ## What went wrong before this existed
///
/// `POST /api/v1/groups/{gid}/leave` used to answer **400 "you are not a
/// member of this group"** when the caller had already left. Every client
/// renders that as "this chat does not exist" — and then keeps the local row,
/// because the leave "failed". The conversation became permanently
/// undeletable. The server rejected that call 160 times in seven days in
/// production before it was fixed (bcrypto-server 54c9f5d made leave
/// idempotent: already-left now answers 200 with no membership change).
///
/// The client half of the fix is here, and it rests on two rules.
///
/// ## Rule 1 — the local purge is unconditional (fail-open)
///
/// The user asked to delete this chat. The server call is a courtesy to the
/// other members, not a precondition. Offline, 401, 403, 5xx, a timeout, a
/// cert-pinning failure, a malformed id, no auth token at all: the local
/// state is purged and the tombstone is written regardless. Anything else
/// re-creates the original bug in a new shape — a row the network can make
/// undeletable.
///
/// ## Rule 2 — a tombstone is cleared only by an explicit re-add
///
/// Every client re-syncs from `GET /api/v1/groups` on launch and on WS
/// reconnect, and the server's catch-up burst replays the full roster.
/// Without a tombstone the deleted chat is back within seconds — this is
/// observed behaviour, not a hypothetical. But a tombstone that can never be
/// cleared is equally broken: the user could never be re-added to that group
/// again, on that device, ever.
///
/// The distinction that makes both safe: a group merely APPEARING in a
/// listing or a snapshot is not consent to have it back. An event that names
/// THIS user as newly added is. So ``GroupResurrectionSource`` is split on
/// exactly that, and ``classifyMembershipEventForTombstone`` reads it off
/// `operation` + `subject_user_id` rather than off "the roster contains me",
/// which is true on every snapshot replay too.
///
/// ## Scope
///
/// Deleting a group purges that group's sender-key / crypto state. Every
/// OTHER group's state is untouched — the purge is keyed on one group id and
/// nothing here widens it.

// MARK: - Id normalization

/// Collapse either wire form of a group id to the single key a tombstone is
/// stored and looked up under.
///
/// This is load-bearing, and the most likely way to ship a tombstone that
/// silently does nothing. The server speaks **dashed UUIDs** (`group_id` in
/// every WS event, the `{gid}` REST path segment); the local
/// `GroupRegistry` / `GroupChatService` / `GroupMessageStore` all key on
/// **dash-stripped lowercase hex**. A tombstone written under one form and
/// read under the other never matches, and the symptom — the group comes
/// back on the next reconcile — is indistinguishable from having no
/// tombstone at all.
public func normalizedGroupTombstoneKey(_ rawGroupId: String) -> String {
    return rawGroupId
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "-", with: "")
        .lowercased()
}

// MARK: - Leave outcome

/// What the server leave call actually did. Every case purges locally; the
/// distinction exists so the `groupdel` log says which branch was taken —
/// several bugs in this feature area stayed undiagnosable for days precisely
/// because the failing paths left no trace.
public enum GroupLeaveOutcome: Sendable, Equatable {
    /// 2xx. Either a real departure or the idempotent already-left no-op —
    /// the server deliberately reports both as success, and the client must
    /// not try to tell them apart.
    case left
    /// The server answered, but not with a 2xx.
    case rejected(status: Int)
    /// No HTTP response at all: offline, DNS, TLS/pinning, timeout,
    /// cancellation.
    case unreachable
    /// The call was never made — no auth token, no identity key to sign the
    /// envelope with, or an id that could not be put on the wire. Distinct
    /// from `unreachable` so the log can say "we never even tried".
    case notAttempted
}

/// Classify the result of `POST /api/v1/groups/{gid}/leave`.
///
/// - Parameters:
///   - succeeded: whether the call returned a 2xx.
///   - httpStatus: the status when the server answered at all; `nil` for a
///     transport-level failure that never got one.
public func classifyGroupLeave(succeeded: Bool, httpStatus: Int?) -> GroupLeaveOutcome {
    if succeeded { return .left }
    guard let status = httpStatus else { return .unreachable }
    return .rejected(status: status)
}

/// Rule 1, as a function a call site cannot accidentally forget to apply.
///
/// Deliberately takes the outcome and ignores it. Written this way — rather
/// than as an `if` at the call site — so the regression test can enumerate
/// every outcome and prove none of them skips the purge.
public func shouldPurgeLocalGroupState(after outcome: GroupLeaveOutcome) -> Bool {
    _ = outcome
    return true
}

/// Same rule for the tombstone. A leave that never reached the server is the
/// case that MOST needs one: the server still lists this user as a member,
/// so the next reconcile would bring the chat straight back.
public func shouldWriteGroupTombstone(after outcome: GroupLeaveOutcome) -> Bool {
    _ = outcome
    return true
}

// MARK: - Resurrection sources

/// Every way a deleted group can come back into local state. Each one is
/// classified as either passive (must respect the tombstone) or an explicit
/// re-add (clears it).
public enum GroupResurrectionSource: Sendable, Equatable, CaseIterable {
    /// `GET /api/v1/groups` on launch / WS reconnect merely listing the
    /// group. The server still has this user as a member whenever the leave
    /// call failed — this is THE resurrection path.
    case passiveReconcileListing
    /// A `group_membership_changed` that re-states the roster without
    /// naming this user as newly added: `operation: "snapshot"`, a catch-up
    /// replay, an admin promote/demote, or somebody else's add.
    case serverMembershipSnapshot
    /// A group TEXT/attachment frame arriving for a group we have no local
    /// entry for. The sender does not know we left, and store-and-forward
    /// can deliver frames queued before the delete.
    case inboundGroupMessage
    /// `group_membership_changed` with an ADD operation whose
    /// `subject_user_id` is this user. An admin put us back.
    case membershipEventAddingSelf
    /// The P2P `qa_grp:1 member_added` envelope naming this user. Same
    /// meaning as above over the 1:1 ratchet instead of the server fan-out.
    case p2pMemberAddedNamingSelf
    /// The user tapped accept on a group invite. Explicit by construction.
    ///
    /// Note the asymmetry: RECEIVING an invite does not clear the tombstone,
    /// accepting it does. An unaccepted invite creates no local group state,
    /// so clearing on receipt would only re-open the resurrection hole for
    /// anyone who can send us one.
    case acceptedInvite
}

/// Does this source count as the explicit re-add that lifts a tombstone?
public func clearsGroupTombstone(_ source: GroupResurrectionSource) -> Bool {
    switch source {
    case .membershipEventAddingSelf, .p2pMemberAddedNamingSelf, .acceptedInvite:
        return true
    case .passiveReconcileListing, .serverMembershipSnapshot, .inboundGroupMessage:
        return false
    }
}

/// Should this attempt to (re-)create local state for the group be dropped?
///
/// The single question every resurrection path asks. `hasTombstone == false`
/// always answers no, so a group that was never deleted is never affected.
public func shouldSkipGroupResurrection(source: GroupResurrectionSource, hasTombstone: Bool) -> Bool {
    guard hasTombstone else { return false }
    return !clearsGroupTombstone(source)
}

/// Read a `group_membership_changed` event as either "an admin added me back"
/// or "the roster was merely re-stated".
///
/// The server reuses ONE event shape for adds, removes, admin promote/demote
/// and catch-up snapshots, and the roster contains this user in all of them —
/// so membership of `members[]` says nothing. Only `operation` + `subject_user_id`
/// do.
///
/// - Parameters:
///   - operation: the server's `operation` field. It is the REST verb
///     (`"add"`) on a live mutation and the membership-log token
///     (`"member_added"`) on the start-up catch-up replay; both vocabularies
///     are accepted, everything else is a snapshot.
///   - subjectUserId: the event's `subject_user_id`.
///   - selfUserId: this device's user id. Empty never matches, so an
///     unauthenticated state cannot accidentally clear a tombstone.
public func classifyMembershipEventForTombstone(
    operation: String,
    subjectUserId: String,
    selfUserId: String
) -> GroupResurrectionSource {
    guard !selfUserId.isEmpty, subjectUserId == selfUserId else {
        return .serverMembershipSnapshot
    }
    switch operation {
    case "add", "member_added":
        return .membershipEventAddingSelf
    default:
        return .serverMembershipSnapshot
    }
}
