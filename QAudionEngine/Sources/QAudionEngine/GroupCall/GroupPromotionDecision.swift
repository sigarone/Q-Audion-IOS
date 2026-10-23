import Foundation

// The decision a device takes on an invite that claims to promote its live 1:1 call (GROUP_CALLS_V2
// 2.7, Consent): join with no ring, hold the invite silently for a moment, or ring. A pure
// function with every input passed in, so the whole truth table is pinned by the `predicate` vectors of
// `Resources/kat/promotion-token-kat.json` (replayed in `GroupPromotionTokenTests`).

public enum GroupPromotionDecision {

    /// Why an invite rings or waits (the numeric `why=` of the `grp promo dec=` log line).
    public enum Why: Int, Equatable, Sendable {
        case token = 1
        case noToken = 2
        case kcPending = 3
        case noAnchor = 4
        case poisoned = 5
        case consumed = 6
        case stale = 7
        case groupLive = 8
        case noMic = 9
        /// Not a promotion candidate.
        case notCandidate = 10

        /// The code of the spec.
        public var name: String {
            switch self {
            case .token: return "token"
            case .noToken: return "no_token"
            case .kcPending: return "kc_pending"
            case .noAnchor: return "no_anchor"
            case .poisoned: return "poisoned"
            case .consumed: return "consumed"
            case .stale: return "stale"
            case .groupLive: return "group_live"
            case .noMic: return "no_mic"
            case .notCandidate: return "not_candidate"
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Not a candidate: the invite takes today's path, ringing or busy-dropping.
        case fallback
        /// Join now, with no ring and no chime.
        case autoJoin
        /// A ring that is up and untouched is taken down locally (no decline), then the join.
        case convert
        /// A candidate that waits, silently, for its token or for the peer's KCMAC.
        case hold
        /// The invite rings with the manual Accept (or keeps ringing).
        case ring(Why)
        /// A ring is up and the user already acted: nothing is converted.
        case noConversion
    }

    public struct Input: Equatable, Sendable {
        /// `promoted` is the JSON literal true (`GroupCallWire.isJsonTrue`).
        public var promoted: Bool
        public var promotedFromCallId: String
        public var creatorId: String
        /// The 1:1 call in progress on this device and the user on its other end; nil without one.
        public var liveCallId: String?
        public var livePeerId: String?
        public var anchorDefined: Bool
        public var anchorPoisoned: Bool
        public var kcmacVerified: Bool
        /// The state of the token held for this invite's group call.
        public var token: PromotionTokenBook.Freshness
        /// A group call is connecting or active here (any call id).
        public var groupLive: Bool
        public var micGranted: Bool
        /// Monotonic ms since the invite was received.
        public var msSinceInvite: Int64
        /// A ring for this call is up (a push rang first, or the invite rang).
        public var ringUp: Bool
        /// The user already accepted or declined.
        public var userActed: Bool

        public init(promoted: Bool, promotedFromCallId: String, creatorId: String, liveCallId: String?,
                    livePeerId: String?, anchorDefined: Bool, anchorPoisoned: Bool, kcmacVerified: Bool,
                    token: PromotionTokenBook.Freshness, groupLive: Bool, micGranted: Bool, msSinceInvite: Int64,
                    ringUp: Bool, userActed: Bool) {
            self.promoted = promoted
            self.promotedFromCallId = promotedFromCallId
            self.creatorId = creatorId
            self.liveCallId = liveCallId
            self.livePeerId = livePeerId
            self.anchorDefined = anchorDefined
            self.anchorPoisoned = anchorPoisoned
            self.kcmacVerified = kcmacVerified
            self.token = token
            self.groupLive = groupLive
            self.micGranted = micGranted
            self.msSinceInvite = msSinceInvite
            self.ringUp = ringUp
            self.userActed = userActed
        }
    }

    /// `candidate(I)`: the invite is attested, a 1:1 call is live, the attestation names that call and
    /// the creator is its peer. `I.call_type`, the group id and the group name play no part.
    public static func isCandidate(_ input: Input) -> Bool {
        guard input.promoted, !input.promotedFromCallId.isEmpty, !input.creatorId.isEmpty else { return false }
        guard let liveCall = input.liveCallId, !liveCall.isEmpty,
              let livePeer = input.livePeerId, !livePeer.isEmpty else { return false }
        return GroupCallIds.ieq(liveCall, input.promotedFromCallId) && GroupCallIds.ieq(livePeer, input.creatorId)
    }

    /// GROUP_CALLS_V2 2.7, Consent. The decision runs on an invite received over the WebSocket, when a token is stored, when
    /// the peer's round-1 KCMAC verifies and when the hold timer expires.
    public static func decide(_ input: Input) -> Outcome {
        guard isCandidate(input) else { return .fallback }
        if input.ringUp && input.userActed { return .noConversion }
        if !input.anchorDefined { return .ring(.noAnchor) }
        if input.anchorPoisoned { return .ring(.poisoned) }
        if input.groupLive { return .ring(.groupLive) }
        if !input.micGranted { return .ring(.noMic) }
        switch input.token {
        case .consumed: return .ring(.consumed)
        case .stale: return .ring(.stale)
        case .fresh, .absent: break
        }
        if input.token == .fresh && input.kcmacVerified {
            return input.ringUp ? .convert : .autoJoin
        }
        // Only the token, the peer's KCMAC or both are missing.
        if !input.ringUp && input.msSinceInvite < GroupPromotionToken.inviteWaitMs { return .hold }
        return .ring(waitWhy(input.token))
    }

    /// What a candidate that is neither joined nor refused is waiting for: the token when none is held, the
    /// peer's round-1 KCMAC when the token is there.
    public static func waitWhy(_ token: PromotionTokenBook.Freshness) -> Why {
        return token == .absent ? .noToken : .kcPending
    }
}

// MARK: - Roster rule after an automatic join (GROUP_CALLS_V2 2.7, Consent)

/// The check every `group_call_update` of a call joined through an automatic promotion join must
/// pass, for the whole life of that call:
///
///     participants + ringing  is a subset of  token invitees + token creator   (compared with ieq)
///
/// While it holds nothing happens. When it fails the device leaves the group at once, with no
/// media key sent for that epoch and the microphone never enabled for it. The first update that passes
/// and lists this device's user releases the microphone hold. Safe to call from any thread.
public final class GroupAutoJoinGuard: @unchecked Sendable {

    public enum Verdict: Equatable, Sendable {
        /// The roster is within what the token proposed. `releaseMicrophone` is true once, on the first
        /// passing update that lists this device's user.
        case pass(releaseMicrophone: Bool)
        /// The roster names `extra` people the token did not list.
        case refuse(extra: Int)
    }

    private let allowed: Set<String>
    private let selfId: String
    private let lock = NSLock()
    private var released = false

    public init(creatorUserId: String, invitees: [String], selfUserId: String) {
        var set = Set<String>()
        set.insert(GroupCallIds.lower(creatorUserId))
        for invitee in invitees { set.insert(GroupCallIds.lower(invitee)) }
        self.allowed = set
        self.selfId = selfUserId
    }

    public func check(participants: [String], ringing: [String]?) -> Verdict {
        var extra = Set<String>()
        for id in participants + (ringing ?? []) {
            let key = GroupCallIds.lower(id)
            if !allowed.contains(key) { extra.insert(key) }
        }
        if !extra.isEmpty { return .refuse(extra: extra.count) }
        lock.lock()
        defer { lock.unlock() }
        if !released && GroupCallIds.contains(participants, selfId) {
            released = true
            return .pass(releaseMicrophone: true)
        }
        return .pass(releaseMicrophone: false)
    }
}
