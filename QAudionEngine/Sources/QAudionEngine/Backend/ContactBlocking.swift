import Foundation

/// BLOCK — what "the user blocked this contact" means on this device.
///
/// Blocking is directional. When the user (R) has blocked a contact (S), nothing S starts reaches R: private
/// messages, call offers and the pushes for them, private file announcements, group invites, key-exchange
/// offers, and the group calls S creates. The server is the first line (it never delivers S's traffic to R, and
/// it keeps R out of the groups and the group calls S creates or manages); the rules below are the second,
/// applied on the device to whatever still arrives (frames queued before the block, mesh packets, a push that
/// was already on its way).
///
/// On the one-to-one channels (private messages, the service channel, the call channel) a blocked sender can
/// still deliver three things, and everything else is dropped:
///  - the group key material (`sender_key_init`, `sender_key_rotate`) of a group the user is already a member
///    of (`dropsServicePayload`): without it S's later messages in that group could not be read;
///  - the media key of a group call the user is in now (`acceptsGroupCallControl`);
///  - whatever belongs to a one-to-one call that is already live on this device with S, for example when the
///    user blocks S in the middle of a call (`isLiveCallPeer`).
///
/// What is deliberately NOT filtered: the content of a group both people are already in. It arrives through the
/// group channel, not through the one-to-one channel the rules above guard. Nothing stops R from writing to or
/// calling S while S is blocked (the menus only offer "unblock"); S's answers are then dropped like any other
/// frame from S, except the handshake of a call R placed.
///
/// A group call S created never rings on the device, whether or not the two share a group
/// (`ringsForGroupCall`); a group call created by someone else in which S takes part works as usual.
///
/// The device never tells S about the block: a dropped call is simply not rung and not answered, exactly as
/// when the phone is off; no "blocked" reply exists.
public enum BlockPolicy {

    /// `qa_grp.t` of the two group envelopes that carry key material: the only group-layer envelopes a blocked
    /// sender may still deliver, and only for a group the user is already in.
    public static let groupKeyTypes: [String] = ["sender_key_init", "sender_key_rotate"]

    /// Ids compare trimmed and case-insensitively (a user id is a UUID; the server spells it in lower case,
    /// other sources may not).
    public static func normalized(_ userId: String) -> String {
        userId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func normalizedSet(_ ids: Set<String>) -> Set<String> {
        var out = Set<String>()
        for id in ids {
            let key = normalized(id)
            if !key.isEmpty { out.insert(key) }
        }
        return out
    }

    /// Is `senderId` in the blocked set? An absent or empty id is never blocked (nothing to match).
    public static func isBlocked(_ senderId: String?, in blocked: Set<String>) -> Bool {
        guard let senderId else { return false }
        let key = normalized(senderId)
        guard !key.isEmpty else { return false }
        for id in blocked where normalized(id) == key { return true }
        return false
    }

    // MARK: - Private service channel

    /// The group id (`g`, the hex form the group layer keys on) of a decrypted private service payload that is a
    /// group KEY envelope (`{"qa_grp":1,"t":"sender_key_init"|"sender_key_rotate","g":...}`); nil for anything
    /// else: another group envelope, another service payload, plain text, malformed JSON, an empty `g`.
    public static func groupKeyGroupId(inServicePayload raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let marker = object["qa_grp"] as? Int, marker == 1,
              let type = object["t"] as? String, groupKeyTypes.contains(type),
              let groupId = object["g"] as? String,
              !normalized(groupId).isEmpty else { return nil }
        return groupId
    }

    /// A decrypted private service payload (the service channel of a one-to-one conversation): is it dropped?
    /// From a sender who is not blocked, never. From a blocked sender, always (reactions, edits, deletes, avatar
    /// announcements, screenshot requests, timers, resend requests, group invites, member changes, removals,
    /// leaves) except one thing: a group KEY envelope for a group the user is already in (`isKnownGroup`
    /// answers for the envelope's own group id). Dropping a sender key of a shared group would make that
    /// person's later group messages undecryptable; accepting one for a group the user is not in would let a
    /// blocked contact reach a group they have no part in.
    public static func dropsServicePayload(
        senderBlocked: Bool, payload raw: String, isKnownGroup: (String) -> Bool
    ) -> Bool {
        guard senderBlocked else { return false }
        guard let groupId = groupKeyGroupId(inServicePayload: raw) else { return true }
        return !isKnownGroup(groupId)
    }

    /// Do the user and `otherId` both belong to one group of `groupMembers` (the member list of every group in
    /// the local registry)? Ids compare trimmed and case-insensitively; an empty id never matches.
    public static func sharesGroup(selfId: String, otherId: String, groupMembers: [[String]]) -> Bool {
        let me = normalized(selfId)
        let other = normalized(otherId)
        guard !me.isEmpty, !other.isEmpty else { return false }
        for members in groupMembers {
            var hasMe = false
            var hasOther = false
            for member in members {
                let key = normalized(member)
                if key == me { hasMe = true }
                if key == other { hasOther = true }
            }
            if hasMe && hasOther { return true }
        }
        return false
    }

    /// A frame that would not open (first failure): is it settled at once (acknowledged, no retry, no placeholder
    /// row, no resend request, no session recovery)? Never for a sender who is not blocked. For a blocked one,
    /// always, except a CONTROL frame (the service class) from a blocked sender who shares a group with the user
    /// (`sharesKnownGroup`, asked only in that case): it may carry the group key material the group needs, and
    /// it can have raced ahead of the session that opens it, so it keeps the normal retry path.
    public static func settlesUndecryptableFrame(
        senderBlocked: Bool, isControl: Bool, sharesKnownGroup: () -> Bool
    ) -> Bool {
        guard senderBlocked else { return false }
        guard isControl else { return true }
        return !sharesKnownGroup()
    }

    /// Is a group-call control envelope (the media key of a call) accepted from this sender? Always from a sender
    /// who is not blocked. From a blocked one only for a group call the user is in now: `callId` is the call the
    /// envelope names, `liveCallIds` the group calls the user is in or joining.
    public static func acceptsGroupCallControl(
        senderBlocked: Bool, callId: String?, liveCallIds: [String]
    ) -> Bool {
        guard senderBlocked else { return true }
        guard let callId, !normalized(callId).isEmpty else { return false }
        let wanted = normalized(callId)
        for live in liveCallIds where normalized(live) == wanted { return true }
        return false
    }

    /// The call id a decrypted group-call control envelope names; nil when it is not a valid `qa_grp:2` envelope
    /// (then a blocked sender's envelope is not accepted: there is no call to compare).
    public static func groupCallControlCallId(ofEnvelope json: String) -> String? {
        if case .envelope(let envelope) = GroupKeyEnvelope.parse(json: json) { return envelope.callId }
        return nil
    }

    /// Is `senderId` the other end of the one-to-one call that is live on this device (`livePeerId`, nil when no
    /// call is)? What such a sender sends about that call (an offer or a key-exchange offer in the middle of it,
    /// the answer to a call the user placed) is not "started by S" and is not dropped.
    public static func isLiveCallPeer(_ senderId: String, livePeerId: String?) -> Bool {
        guard let livePeerId else { return false }
        let sender = normalized(senderId)
        guard !sender.isEmpty else { return false }
        return sender == normalized(livePeerId)
    }

    // MARK: - Groups

    /// May the user be made a member of a group they do not know yet, by these people? False when any of
    /// them is blocked: the admin an add names, the actor of a server event. A group the user is already in is
    /// not asked about. Empty ids are never blocked. This is the device's second line and it only sees the
    /// actor: an add by another admin into a group a blocked contact manages is judged by the server.
    public static func refusesGroupJoin(by actors: [String], blocked: Set<String>) -> Bool {
        for actor in actors where isBlocked(actor, in: blocked) { return true }
        return false
    }

    /// Does an incoming GROUP call ring? Unless its creator is blocked: then never, whether or not the user and
    /// the creator share a group. The group id the invite carries plays no part (the creator chooses it).
    public static func ringsForGroupCall(creatorId: String, blocked: Set<String>) -> Bool {
        !isBlocked(creatorId, in: blocked)
    }

    // MARK: - Notifications

    /// Seconds to wait before each further attempt of `ContactBlockCoordinator.refreshFromServerWithRetry` after
    /// a failed one: about three minutes in all, then the next reconnect or sign-in asks again.
    public static let refreshRetryDelays: [TimeInterval] = [5, 15, 45, 120]

    /// The person a local notification or a pushed alert is about, from its `userInfo`: the peer of a private
    /// message or call, the creator of a group call alert. Nil for a group message notification (group content
    /// is not filtered) or when it names nobody. Empty ids are skipped. Keys: `peerUserId` (message), `peer_id`
    /// (call, missed call), `caller_id` (the call alert pushed by the server), and for a group call alert
    /// (`type == incoming_group_call`) `creator_id`.
    public static func oneToOnePeer(ofNotification userInfo: [AnyHashable: Any]) -> String? {
        func firstNonEmpty(_ keys: [String]) -> String? {
            for key in keys {
                if let value = userInfo[key] as? String, !normalized(value).isEmpty { return value }
            }
            return nil
        }
        if let type = userInfo["type"] as? String, type == "incoming_group_call" {
            return firstNonEmpty(["creator_id", "peer_id", "caller_id"])
        }
        if firstNonEmpty(["groupId", "group_id"]) != nil { return nil }
        return firstNonEmpty(["peerUserId", "peer_id", "caller_id"])
    }

    /// Is the local notification described by `userInfo` suppressed because the person it is about is blocked?
    public static func suppressesNotification(userInfo: [AnyHashable: Any], blocked: Set<String>) -> Bool {
        guard let peer = oneToOnePeer(ofNotification: userInfo) else { return false }
        return isBlocked(peer, in: blocked)
    }
}

/// BLOCK — the creator's side of a group the server could not fill completely. The reply of a group create
/// lists the members it left out (`could_not_add`, ids only, no reason: a contact who blocked the creator, an
/// unknown or deleted account and any other cause look the same). The creator's roster is cut to the members
/// who are in before any key or invite is sent, and the creator sees one notice that names nobody and says
/// nothing about why.
public enum GroupAddRefusal {

    /// HTTP status of an add-member request the server refused for the member's sake (`403`, body
    /// "member could not be added", no reason).
    public static let addRefusedStatus: Int = 403

    public struct Outcome: Equatable, Sendable {
        /// The requested members who stay, in their original order. The creator always stays.
        public let kept: [String]
        /// The requested members who are out (never the creator).
        public let dropped: [String]
        /// Does the creator get the notice? Exactly when somebody who was asked for is out.
        public var notifies: Bool { !dropped.isEmpty }
    }

    /// The ids in the `could_not_add` field of a create reply (a JSON array of user ids; absent when nobody
    /// was left out). Anything that is not a non-empty string is ignored, duplicates (trimmed, case-insensitive)
    /// are counted once.
    public static func couldNotAdd(fromReply field: Any?) -> [String] {
        guard let array = field as? [Any] else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for item in array {
            guard let id = item as? String else { continue }
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = BlockPolicy.normalized(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    /// Split `requested` (the roster the creator asked for, creator included) into who stays and who is out.
    public static func outcome(requested: [String], refused: [String], selfId: String) -> Outcome {
        let refusedKeys = Set(refused.map { BlockPolicy.normalized($0) }.filter { !$0.isEmpty })
        let me = BlockPolicy.normalized(selfId)
        var kept: [String] = []
        var dropped: [String] = []
        for id in requested {
            let key = BlockPolicy.normalized(id)
            if key != me && refusedKeys.contains(key) {
                dropped.append(id)
            } else {
                kept.append(id)
            }
        }
        return Outcome(kept: kept, dropped: dropped)
    }

    /// Is this status the server's refusal of an add-member request?
    public static func isAddRefusal(statusCode: Int) -> Bool {
        statusCode == addRefusedStatus
    }
}

/// The local copy of the blocked list. The server is the source of truth; this copy exists so the receive
/// paths can answer "is this sender blocked" synchronously, without a network round-trip.
public protocol BlockedListStorage {
    func blockedIds() -> Set<String>
    func insert(_ userId: String)
    func remove(_ userId: String)
    func replaceAll(_ ids: Set<String>)
}

/// BLOCK — the one place that blocks and unblocks, and that reloads the list from the server. Every entry
/// point (contact detail, contacts list, chat menu, any other screen) goes through it, so the server and the
/// local list are always changed together.
///
/// Rules:
///  - The server is asked first. The local list changes only after the server accepted, so there is never a
///    local "blocked" state the server does not have (the receive paths would drop traffic the server still
///    delivers, and a second device would disagree). A failure changes nothing and is reported, so the
///    caller can offer a retry.
///  - A failed request is re-checked against the server's own list: when the server already is in the wanted
///    state (an unblock of a contact it does not hold as blocked), the call counts as applied.
///  - Operations run one at a time, in the order they were asked, so a block followed at once by an unblock
///    cannot reach the server in the opposite order.
///  - `refreshFromServer` replaces the local list by the server's. It runs in the same queue, so it can never
///    overwrite the result of a block that is still in flight.
///  - A request belongs to the account that asked. `forgetSession` (sign-out, wipe) ends that account: an
///    answer that arrives for it afterwards is discarded, so it can neither put the old account's list back
///    nor start the new account's refresh interval.
@MainActor
public final class ContactBlockCoordinator {

    public enum Failure: Equatable, Sendable {
        /// The user id was empty.
        case invalidUser
        /// No signed-in backend to ask.
        case noConnection
        /// The server did not accept the request (network error, refusal) and its list does not show the
        /// wanted state either.
        case requestFailed
        /// The account that asked signed out before the request finished: nothing was changed locally, and
        /// there is nobody to tell (a retry would act on the next account).
        case accountChanged
    }

    public enum Outcome: Equatable, Sendable {
        case applied
        case failed(Failure)
    }

    private let api: () -> ContactsApi?
    private let storage: BlockedListStorage
    private let now: () -> Date
    private var tail: Task<Void, Never>?
    /// Counts the accounts that left (`forgetSession`). A request remembers the value it started with and
    /// acts on the result only while it is unchanged.
    private var generation: Int = 0
    /// When the local list was last replaced by the server's.
    public private(set) var lastRefresh: Date?

    public init(api: @escaping () -> ContactsApi?,
                storage: BlockedListStorage,
                now: @escaping () -> Date = Date.init) {
        self.api = api
        self.storage = storage
        self.now = now
    }

    /// Block (`blocked == true`) or unblock `userId`: server first, local list second.
    public func setBlocked(_ blocked: Bool, userId: String) async -> Outcome {
        let id = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return .failed(.invalidUser) }
        let account: Int = generation
        return await serialized { [self] () async -> Outcome in
            // Asked by an account that has left while this waited its turn: it is not done for the next one.
            guard account == self.generation else { return .failed(.accountChanged) }
            guard let backend = self.api() else { return .failed(.noConnection) }
            do {
                if blocked {
                    try await backend.blockContact(userId: id)
                } else {
                    try await backend.unblockContact(userId: id)
                }
            } catch {
                // The request may have failed because the server already is in the wanted state. Trust only
                // the server's own list, and only when it could be read.
                if await self.reload(backend, account: account),
                   BlockPolicy.isBlocked(id, in: self.storage.blockedIds()) == blocked {
                    return .applied
                }
                guard account == self.generation else { return .failed(.accountChanged) }
                return .failed(.requestFailed)
            }
            guard account == self.generation else { return .failed(.accountChanged) }
            if blocked {
                self.storage.insert(id)
            } else {
                self.storage.remove(id)
            }
            return .applied
        }
    }

    /// Replace the local list by the server's. False when there is no backend or the request failed (the
    /// local list is then left as it was), or when the account that asked left before the answer came.
    @discardableResult
    public func refreshFromServer() async -> Bool {
        let account: Int = generation
        return await serialized { [self] () async -> Bool in
            guard account == self.generation else { return false }
            guard let backend = self.api() else { return false }
            return await self.reload(backend, account: account)
        }
    }

    /// `refreshFromServer`, but not when the last successful refresh is younger than `minInterval` seconds
    /// (every reconnect of the signalling socket asks). False when it did not refresh.
    @discardableResult
    public func refreshFromServerIfDue(minInterval: TimeInterval = 60) async -> Bool {
        if let last = lastRefresh, now().timeIntervalSince(last) < minInterval { return false }
        return await refreshFromServer()
    }

    /// Make sure the local list has been loaded from the server for the account that is signed in now:
    /// `refreshFromServerIfDue`, and when the attempt fails (no backend yet, no network, a server error) try
    /// again after each of `retryDelays` seconds, so a list that could not be fetched at sign-in is not left
    /// empty until the next reconnect. True when the list is fresh (loaded now, or within `minInterval`).
    /// Ends early, false, when the account leaves (`forgetSession`) or the calling task is cancelled.
    /// `sleep` waits between attempts; a test passes its own.
    @discardableResult
    public func refreshFromServerWithRetry(
        minInterval: TimeInterval = 60,
        retryDelays: [TimeInterval] = BlockPolicy.refreshRetryDelays,
        sleep: (TimeInterval) async -> Void = { seconds in
            let nanos = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        }
    ) async -> Bool {
        let account: Int = generation
        var attempt = 0
        while true {
            if account != generation || Task.isCancelled { return false }
            if let last = lastRefresh, now().timeIntervalSince(last) < minInterval { return true }
            if await refreshFromServer() { return true }
            guard attempt < retryDelays.count else { return false }
            await sleep(retryDelays[attempt])
            attempt += 1
        }
    }

    /// The account that was signed in is gone (sign-out, remote wipe, account deletion; a different account
    /// signs in next): forget the refresh time so the next account's list is fetched at once, and end every
    /// request the old account still has in flight (their answers are discarded).
    public func forgetSession() {
        generation &+= 1
        lastRefresh = nil
    }

    // MARK: - Internals

    /// Read the server's list and make it the local one, unless `account` has left meanwhile.
    private func reload(_ backend: ContactsApi, account: Int) async -> Bool {
        do {
            let entries = try await backend.getBlockedContacts()
            guard account == generation else { return false }
            var ids = Set<String>()
            for entry in entries {
                let id = entry.userId.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty { ids.insert(id) }
            }
            storage.replaceAll(ids)
            lastRefresh = now()
            return true
        } catch {
            return false
        }
    }

    /// Run `body` after every operation asked before it has finished.
    private func serialized<T>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous: Task<Void, Never>? = tail
        let work = Task<T, Never> { @MainActor in
            _ = await previous?.value
            return await body()
        }
        tail = Task { @MainActor in
            _ = await work.value
        }
        return await work.value
    }
}
