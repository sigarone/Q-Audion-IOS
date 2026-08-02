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
/// ## Rule 3 — a live event is not the only way to be re-added
///
/// Rule 2 on its own was not enough, and the way it failed is worth spelling
/// out because it is invisible in a happy-path test. The ONLY clear path used
/// to be a live inbound `group_membership_changed` with an add operation. The
/// server fans that event out **only to members holding a fresh WebSocket at
/// that instant** — `fanOutMembershipChanged` skips a uid with no live client
/// and falls back to "the client will converge on its own next GET". A user
/// whose phone was off when an admin re-added them therefore never saw the
/// event, and the tombstone was never lifted: that group was gone from that
/// device permanently. Ten minutes offline was enough.
///
/// ``reconcileTombstoneDecision`` closes that hole without needing any event
/// at all, by combining the tombstone with what the server reports at
/// reconcile time. The key is that the delete already recorded whether the
/// server-side leave actually succeeded:
///
/// * leave succeeded, yet the server STILL lists me as a member → the only
///   thing that can make both true is somebody adding me back. A positive,
///   self-evident re-add signal that survives any amount of offline time.
///   Clear the tombstone.
/// * leave did NOT succeed and the server lists me → my departure never
///   reached the server. That is not a re-add. Keep the tombstone (the chat
///   stays gone, as the user asked) and retry the leave now.
/// * the server does not list me → steady state after a good delete. Keep the
///   tombstone, skip the group.
///
/// This keys on real membership STATE rather than on an event, which is also
/// what makes it immune to the catch-up replay described below. The live path
/// is kept — it is still correct, and faster when the user is online — and
/// both paths converge on the same state.
///
/// ## The catch-up replay, and why `replay` has to be honoured
///
/// `bcrypto-server` runs `replayMembershipCatchup` at EVERY server start, i.e.
/// after every deploy. For each recently-active group it re-emits
/// `group_membership_changed` built from the LAST membership-log entry — so a
/// group whose most recent mutation was an add is replayed carrying
/// `operation: "member_added"` and that member's `subject_user_id`, verbatim.
/// Read as a live event that is indistinguishable from a genuine re-add, and
/// it would clear the tombstone and resurrect every deleted group chat on
/// every deploy.
///
/// The server does mark them: `fanOutMembershipChanged` sets
/// `payload["replay"] = true` on the catch-up path, and that flag does reach
/// the client payload (verified at the emit site, not assumed — the iOS
/// consumer already parses it as `data["replay"] as? Bool`). So
/// ``classifyMembershipEventForTombstone`` takes `isReplay` as a REQUIRED
/// argument: a replayed event is a snapshot no matter what its `operation`
/// says, and no call site can forget to decide.
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

/// Did the server actually record the departure?
///
/// This one bit is what the tombstone has to remember, because it is what
/// makes ``reconcileTombstoneDecision`` able to tell "an admin re-added me"
/// apart from "my leave never landed" later on, with no live event and after
/// any amount of offline time. Only `.left` counts: `.rejected`,
/// `.unreachable` and `.notAttempted` all leave the server believing this
/// user is still a member.
public func serverLeaveConfirmed(_ outcome: GroupLeaveOutcome) -> Bool {
    switch outcome {
    case .left:
        return true
    case .rejected, .unreachable, .notAttempted:
        return false
    }
}

// MARK: - Resurrection sources

/// Every way a deleted group can come back into local state. Each one is
/// classified as either passive (must respect the tombstone) or an explicit
/// re-add (clears it).
public enum GroupResurrectionSource: Sendable, Hashable, CaseIterable {
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
    /// A reconcile sweep found this user in the server's roster for a group
    /// whose leave the server CONFIRMED — see ``reconcileTombstoneDecision``.
    ///
    /// Distinct from ``passiveReconcileListing`` even though both come out of
    /// the same `GET /api/v1/groups`: this one has already been checked
    /// against the recorded leave outcome, so it is a deduced re-add rather
    /// than a bare listing. It exists as its own case so the reconcile path
    /// speaks the same vocabulary as the live one and passes through the same
    /// choke point instead of side-stepping it. Never produce it from a
    /// listing alone.
    case reconcileReAddAfterConfirmedLeave
}

/// Does this source count as the explicit re-add that lifts a tombstone?
public func clearsGroupTombstone(_ source: GroupResurrectionSource) -> Bool {
    switch source {
    case .membershipEventAddingSelf, .p2pMemberAddedNamingSelf, .acceptedInvite,
         .reconcileReAddAfterConfirmedLeave:
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
///   - operation: the server's `operation` field, in one of two vocabularies.
///     Every LIVE mutation emits a REST verb — `add`, `remove`, `leave`,
///     `admin_add`, `admin_remove` — while the membership-log tokens
///     (`member_added`, `member_removed`, `member_left`) come from
///     `replayMembershipCatchup` re-reading the log. Verified against every
///     `fanOutMembershipChanged` call site in
///     `bcrypto-server/cmd/bcrypto-lite`: `member_added` is emitted from the
///     replay path and ONLY the replay path.
///
///     Which is why `isReplay` had to be added rather than just dropping the
///     token from the switch: accepting `member_added` as a re-add did not
///     merely risk misreading a replay, it misread *every* one of them — that
///     branch could not fire on anything else. The token is still accepted
///     below as defence in depth (a future server could fan it out live), but
///     it is currently unreachable in production, so do not "simplify" the
///     replay guard away on the grounds that the token is handled.
///   - subjectUserId: the event's `subject_user_id`.
///   - selfUserId: this device's user id. Empty never matches, so an
///     unauthenticated state cannot accidentally clear a tombstone.
///   - isReplay: the event's `replay` flag. **Required, deliberately not
///     defaulted.** `replayMembershipCatchup` re-emits the last
///     membership-log entry at every server start, so a replayed event
///     carries a real `operation: "member_added"` and a real
///     `subject_user_id` — byte-identical to a genuine re-add. Only this
///     flag separates them, and defaulting it to `false` would mean a call
///     site that forgot to plumb it resurrects every deleted group chat on
///     every deploy. A replay is always a snapshot.
public func classifyMembershipEventForTombstone(
    operation: String,
    subjectUserId: String,
    selfUserId: String,
    isReplay: Bool
) -> GroupResurrectionSource {
    // Checked before `operation`: the catch-up burst replays the genuine
    // add token, so reading the operation first would classify it as a
    // re-add and lift the tombstone.
    guard !isReplay else { return .serverMembershipSnapshot }
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

// MARK: - Reconcile-time decision (the offline-proof re-add signal)

/// What a reconcile sweep should do about one tombstoned group.
///
/// See ``reconcileTombstoneDecision`` for the reasoning; this is its result
/// type, kept as an enum so the caller has to handle every branch and the
/// `groupdel` log can name the one that ran.
public enum GroupTombstoneReconcileDecision: Sendable, Hashable, CaseIterable {
    /// No tombstone for this group. Reconcile it exactly as before — nothing
    /// in this feature applies.
    case reconcileNormally
    /// The leave succeeded and the server lists this user anyway: an admin
    /// re-added them. Lift the tombstone and let the group come back fresh.
    case clearTombstoneAndAdmit
    /// The leave never reached the server and the server therefore still
    /// lists this user. NOT a re-add. Keep the chat gone locally and retry
    /// the leave.
    case keepTombstoneAndRetryLeave
    /// Steady state after a successful delete: tombstone held, server agrees
    /// this user is out. Skip the group.
    case keepTombstone
}

/// Decide the fate of a tombstoned group from membership STATE, with no live
/// event involved.
///
/// This is the fix for the hole described in "Rule 3" at the top of this
/// file: the live `group_membership_changed` clear path only reaches users
/// who happen to hold a fresh WebSocket at the instant of the re-add, so a
/// user who was merely offline stayed locked out of that group forever.
/// Every input here comes from state that is still true minutes, hours or
/// days later, which is what makes it work after any amount of offline time
/// — and what makes it immune to the catch-up replay, since a replay changes
/// no membership state.
///
/// The load-bearing insight is the middle branch. "The server lists me as a
/// member" is ambiguous on its own — it is equally true when an admin added
/// me back and when my own leave never landed — so it can never be a re-add
/// signal by itself. Pairing it with the recorded leave outcome disambiguates
/// it completely:
///
/// | tombstone | leave confirmed | server lists me | meaning |
/// |---|---|---|---|
/// | no  | –   | –   | not our business → ``reconcileNormally`` |
/// | yes | yes | yes | I left, I am back ⇒ re-added → ``clearTombstoneAndAdmit`` |
/// | yes | no  | yes | my leave never landed → ``keepTombstoneAndRetryLeave`` |
/// | yes | –   | no  | delete completed → ``keepTombstone`` |
///
/// Note the middle row is not merely a policy choice, it is the only reading
/// that is consistent: if the leave never reached the server then nobody was
/// ever told this user departed, so there was nothing for an admin to "add
/// them back" from. Retrying the leave is what finally makes the user's
/// delete real — and it is the retry the UI copy is allowed to promise.
///
/// - Parameters:
///   - hasTombstone: whether this device deleted this group.
///   - serverLeaveConfirmed: the bit recorded at delete time (and refreshed
///     by a successful retry) — see ``serverLeaveConfirmed(_:)``.
///   - serverListsSelfAsMember: whether the roster the server just returned
///     for this group contains this user.
public func reconcileTombstoneDecision(
    hasTombstone: Bool,
    serverLeaveConfirmed: Bool,
    serverListsSelfAsMember: Bool
) -> GroupTombstoneReconcileDecision {
    guard hasTombstone else { return .reconcileNormally }
    guard serverListsSelfAsMember else { return .keepTombstone }
    return serverLeaveConfirmed ? .clearTombstoneAndAdmit : .keepTombstoneAndRetryLeave
}

/// How long to wait between two automatic retries of the same group's leave.
///
/// The reconcile sweep runs on every chat-list appear and every WS reconnect,
/// which a user flipping between tabs can trigger many times a minute. The
/// retry must not turn that into a signed-POST-per-tap storm against a server
/// that is evidently already refusing or unreachable.
public let groupLeaveRetryMinimumInterval: TimeInterval = 60

/// Is enough time gone since the last automatic leave retry for this group?
///
/// - Parameters:
///   - lastAttemptAt: when the retry last ran; `nil` when it never has, which
///     always allows one immediately.
///   - now: current time, injected so this is testable without sleeping.
public func shouldRetryServerLeaveNow(
    lastAttemptAt: Date?,
    now: Date,
    minimumInterval: TimeInterval = groupLeaveRetryMinimumInterval
) -> Bool {
    guard let last = lastAttemptAt else { return true }
    let elapsed = now.timeIntervalSince(last)
    // A NEGATIVE elapsed means the wall clock moved backwards (timezone edit,
    // NTP correction, a restored backup). Treat the stamp as stale and allow
    // the retry: the alternative is a delete that silently stops trying to
    // reach the server until the clock catches up.
    if elapsed < 0 { return true }
    return elapsed >= minimumInterval
}
