import Foundation

// Group calls v2, 1:1 promotion and admission rules (docs/GROUP_CALLS_V2_SPEC.md,
// section "Promotion and admission"). Every decision here is a pure function or a
// small state machine with injected time, so each rule is pinned by
// `GroupPromotionPoliciesTests` without a socket, a PeerConnection or a clock. The app
// layer (`AppState`) and `GroupCallController` call them and carry out the answer.
// The consent of the 1:1 peer (the signed promotion token) is in `GroupPromotionToken.swift`,
// `GroupPromotionBook.swift` and `GroupPromotionDecision.swift`.
// User ids and call ids are compared ASCII case-insensitively everywhere (`GroupCallIds`).

// MARK: - 1:1 admission (D-B)

/// What a new 1:1 call (placed here, or accepted from a ring) may do while a group call
/// is live on this device (spec 27).
public enum GroupAdmissionPolicy {

    public enum Decision: Equatable, Sendable {
        /// No group call is live: the 1:1 call goes ahead.
        case proceed
        /// Another 1:1 call is already live (the existing rule, kept first).
        case refuseAlreadyInCall
        /// A group call is live: ask "leave the group?"; on yes leave it (the
        /// `group_call_leave` goes out before the media teardown) and then proceed, on no
        /// do nothing (an incoming 1:1 call is then declined as busy).
        case confirmLeaveGroup
    }

    /// A group call this device is in or joining. `.failed` is the transient state a
    /// fatal media error passes through on its way to `.idle`: nothing left to leave.
    public static func isLive(_ state: GroupCallController.State) -> Bool {
        switch state {
        case .connecting, .active: return true
        case .idle, .failed: return false
        }
    }

    /// `isInCall`: another 1:1 call is live right now (false for the accept of a ring,
    /// which is not a call yet).
    public static func decide(groupState: GroupCallController.State, isInCall: Bool) -> Decision {
        if isInCall { return .refuseAlreadyInCall }
        return isLive(groupState) ? .confirmLeaveGroup : .proceed
    }
}

// MARK: - Leaving a group call (D-A, D-B)

/// How this device leaves the live group call, whichever way it leaves (the confirmed "leave the
/// group?" question, the lone-call backstop, the hang-up of the group screen or of the system): the
/// creator that is the last one in the call ends it (nobody is left to keep it up for, and the
/// people still ringing are told it is over); everyone else just leaves, which keeps the call up
/// for the others.
public enum GroupExitPolicy {

    public enum Action: Equatable, Sendable {
        case leave
        case endForAll
    }

    public static func action(isCreator: Bool, participants: [String], selfId: String) -> Action {
        let others = participants.contains { !GroupCallIds.ieq($0, selfId) }
        return (isCreator && !others) ? .endForAll : .leave
    }
}

// MARK: - Self-promotion carve-out (D-P)

/// An invite that continues the 1:1 call this device is on, from the person it is with, is not
/// dropped as busy for that 1:1 call being live: it is the one busy state such an invite is meant
/// to interrupt. The carve-out only lets the invite through to the consent decision
/// (`GroupPromotionDecision`); it never joins anything by itself, and the server's attestation
/// alone never admits anyone: the peer joins without a ring only with a valid promotion token
/// (GROUP_CALLS_V2 2.7). A group call live here keeps the invite busy, there is nothing to bypass.
public enum GroupPromotionPolicy {

    /// `liveOneToOneCallId` / `liveOneToOnePeerId`: the 1:1 call live on this device right now and
    /// who is on its other end. Both ids are compared ASCII case-insensitively.
    public static func isSelfPromotion(
        promotedFromCallId: String,
        creatorId: String,
        liveOneToOneCallId: String?,
        liveOneToOnePeerId: String?
    ) -> Bool {
        guard !promotedFromCallId.isEmpty, !creatorId.isEmpty else { return false }
        guard let liveCall = liveOneToOneCallId, !liveCall.isEmpty,
              let livePeer = liveOneToOnePeerId, !livePeer.isEmpty else { return false }
        return GroupCallIds.ieq(liveCall, promotedFromCallId) && GroupCallIds.ieq(livePeer, creatorId)
    }
}

// MARK: - Lone call (D-A client backstop)

/// A group call whose roster is only this device, with nobody still ringing and no
/// promotion pending, is over after `backstopSeconds`: the client leaves (or ends, when
/// it is the creator). The server ends the same call by itself (`group_call_ended
/// {reason:"alone"}`); this is the backstop for a server that does not, and the constant
/// is the same on every platform: the 45 s ring plus a margin.
public enum GroupAlonePolicy {

    public static let backstopSeconds: Double = 50

    /// `participants` empty = the roster is not known yet (a joiner before its first
    /// `group_call_update`): not alone. `ringing` nil = the server does not report it
    /// (an older one): treated as nobody ringing.
    public static func isAlone(participants: [String], selfId: String, ringing: [String]?, promotionPending: Bool) -> Bool {
        guard !participants.isEmpty, !promotionPending else { return false }
        guard participants.allSatisfy({ GroupCallIds.ieq($0, selfId) }) else { return false }
        return (ringing ?? []).isEmpty
    }
}

/// The 50 s timer of `GroupAlonePolicy`: armed on the change to alone, cancelled by the
/// change to not alone (a join, a roster with another participant, a non-empty ringing
/// list, a pending promotion). `schedule` is injected so a test fires it by hand.
public final class GroupAloneWatchdog: @unchecked Sendable {

    public typealias Cancel = () -> Void
    public typealias Scheduler = (_ seconds: Double, _ work: @escaping () -> Void) -> Cancel

    /// `DispatchQueue.global` after `seconds`, the same idiom the controller's other timers use.
    public static let dispatchScheduler: Scheduler = { seconds, work in
        let item = DispatchWorkItem(block: work)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: item)
        return { item.cancel() }
    }

    public let seconds: Double
    private let scheduler: Scheduler
    private let lock = NSLock()
    private var cancelCurrent: Cancel?
    private var generation = 0

    /// Fired once per arming, on the scheduler's thread, only if still armed.
    public var onExpired: (() -> Void)?

    public init(seconds: Double = GroupAlonePolicy.backstopSeconds, scheduler: @escaping Scheduler = GroupAloneWatchdog.dispatchScheduler) {
        self.seconds = seconds
        self.scheduler = scheduler
    }

    public var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelCurrent != nil
    }

    public enum Change: Equatable, Sendable {
        case armed
        case cancelled
        case unchanged
    }

    /// Feeds the current "alone" verdict. Arms once on the change to alone (an alone
    /// roster that stays alone keeps its original deadline: another roster update is not a
    /// fresh start), cancels on the change away from it.
    @discardableResult
    public func update(alone: Bool) -> Change {
        lock.lock()
        if alone {
            if cancelCurrent != nil { lock.unlock(); return .unchanged }
            generation += 1
            let mine = generation
            let cancel = scheduler(seconds) { [weak self] in self?.fire(generation: mine) }
            cancelCurrent = cancel
            lock.unlock()
            return .armed
        }
        let cancel = cancelCurrent
        cancelCurrent = nil
        generation += 1
        lock.unlock()
        guard let cancel = cancel else { return .unchanged }
        cancel()
        return .cancelled
    }

    public func cancel() {
        _ = update(alone: false)
    }

    private func fire(generation fired: Int) {
        lock.lock()
        guard fired == generation, cancelCurrent != nil else { lock.unlock(); return }
        cancelCurrent = nil
        lock.unlock()
        onExpired?()
    }
}

// MARK: - Creator hand-over (D-C)

/// When the 1:1 leg of a promotion goes (spec 29). The creator keeps the 1:1 call until the 1:1
/// peer is a group participant, or the peer's invite is over, or the 1:1 call has ended, with a
/// 50 s cap; then it hangs up the 1:1 with reason `promoted-to-group`. The exception is the peer's
/// invite being over while the creator is alone in the group with nobody ringing: the promotion is
/// aborted, the 1:1 call stays and the group is left. A group that ends meanwhile aborts the
/// hand-over and keeps the 1:1 too. The invited peer runs the same decision with the creator as
/// "peer"; it never hangs up the 1:1 itself when it joined automatically (the creator does).
public enum GroupHandOverPolicy {

    /// The cap, from the moment the hand-over began (the server's 45 s ring plus a margin).
    public static let capSeconds: Double = 50
    /// The group media must be up by then, or the group is abandoned and the 1:1 stays.
    public static let mediaDeadlineSeconds: Double = 30

    public enum Reason: Int, Equatable, Sendable {
        /// The 1:1 peer is in the group roster.
        case peerJoined = 1
        /// The peer's invite is over: it is not in the roster and no longer in `ringing`
        /// (declined, ring timeout), and somebody else is in the group or still rings.
        case peerInviteOver = 2
        /// The 1:1 call ended by itself.
        case oneToOneEnded = 3
        /// The 50 s cap.
        case capReached = 4
    }

    public enum Outcome: Equatable, Sendable {
        case wait
        case handOver(Reason)
        /// The group media never came up: leave the group, keep the 1:1.
        case abandonMediaNotUp
        /// The group ended meanwhile: nothing to hand over, keep the 1:1.
        case abort
        /// The peer's invite is over and this device is alone in the group with nobody ringing: keep the
        /// 1:1 call and leave the group (the creator that is the last one in it ends it).
        case abortKeepOneToOne
    }

    public struct Inputs: Equatable, Sendable {
        public var peerId: String
        public var selfId: String
        public var participants: [String]
        /// nil: the server does not report the ringing list (an older one), or no update has
        /// arrived yet: the peer's invite is not known to be over.
        public var ringing: [String]?
        public var oneToOneLive: Bool
        public var groupEnded: Bool
        public var mediaConnected: Bool
        public var elapsedSeconds: Double

        public init(peerId: String, selfId: String, participants: [String], ringing: [String]?, oneToOneLive: Bool,
                    groupEnded: Bool, mediaConnected: Bool, elapsedSeconds: Double) {
            self.peerId = peerId
            self.selfId = selfId
            self.participants = participants
            self.ringing = ringing
            self.oneToOneLive = oneToOneLive
            self.groupEnded = groupEnded
            self.mediaConnected = mediaConnected
            self.elapsedSeconds = elapsedSeconds
        }
    }

    /// The peer's invite is over when the server's ringing list is known, the peer is not in
    /// it, and the peer is not a participant either.
    public static func peerInviteOver(peerId: String, participants: [String], ringing: [String]?) -> Bool {
        guard let ringing = ringing else { return false }
        return !GroupCallIds.contains(participants, peerId) && !GroupCallIds.contains(ringing, peerId)
    }

    /// This device is the only one in the group and the server reports nobody ringing.
    static func aloneWithNobodyRinging(selfId: String, participants: [String], ringing: [String]?) -> Bool {
        guard let ringing = ringing, ringing.isEmpty, !participants.isEmpty else { return false }
        return participants.allSatisfy { GroupCallIds.ieq($0, selfId) }
    }

    public static func decide(_ inputs: Inputs) -> Outcome {
        if inputs.groupEnded { return .abort }
        // The 1:1 leg is gone by itself: nothing to hang up, the promotion just completes.
        if !inputs.oneToOneLive { return .handOver(.oneToOneEnded) }
        // Without the group media the 1:1 call is all the user has: never hang it up.
        guard inputs.mediaConnected else {
            return inputs.elapsedSeconds >= mediaDeadlineSeconds ? .abandonMediaNotUp : .wait
        }
        if GroupCallIds.contains(inputs.participants, inputs.peerId) { return .handOver(.peerJoined) }
        if peerInviteOver(peerId: inputs.peerId, participants: inputs.participants, ringing: inputs.ringing) {
            // Nobody is in the group but this device and nobody rings: there is nothing to hand the
            // call over to. Abort, keep the 1:1 call.
            if aloneWithNobodyRinging(selfId: inputs.selfId, participants: inputs.participants,
                                      ringing: inputs.ringing) {
                return .abortKeepOneToOne
            }
            return .handOver(.peerInviteOver)
        }
        if inputs.elapsedSeconds >= capSeconds { return .handOver(.capReached) }
        return .wait
    }

    /// The 1:1 call ended while the hand-over was still pending: leave the group too when it
    /// is down to this device and nobody is still ringing (the server reports an empty
    /// `ringing` list). An unknown ringing list (an older server) keeps the group: the lone
    /// timer ends it if nobody comes.
    public static func shouldLeaveGroupWhenOneToOneEnds(
        promotionPending: Bool, participants: [String], selfId: String, ringing: [String]?
    ) -> Bool {
        guard promotionPending, !participants.isEmpty else { return false }
        guard participants.allSatisfy({ GroupCallIds.ieq($0, selfId) }) else { return false }
        guard let ringing = ringing else { return false }
        return ringing.isEmpty
    }
}
