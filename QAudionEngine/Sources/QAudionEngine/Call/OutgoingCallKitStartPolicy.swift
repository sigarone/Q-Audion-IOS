import Foundation

/// W-CALLERBUSY (2026-10-03, review of #169) — what to do with the CallKit call that `CallKitManaging.startOutgoingCall`
/// has just returned, when the outgoing call it was started for may already be over.
///
/// ## The window
///
/// `AppState.startCall` asks CallKit for the outgoing call in a `Task`. `startOutgoingCall` returns only after the
/// `CXStartCallAction` round trip, and `activeCallKitId` is assigned from its result, AFTER that `await`. A
/// `call_busy` / `call_peer_offline` can land before it: in the 10:43 incident of 2026-10-03 the server's busy
/// arrived 577 ms after the dial and the CallKit start was fulfilled at about 691 ms. `AppState.endCall` then finds
/// `activeCallKitId == nil` and reports nothing to CallKit; the late assignment re-creates the very orphan the
/// teardown exists to close (iOS keeps one call group open, the next `CXStartCallAction` fails with
/// `maximumCallGroupsReached`, code 7), and a call that is `.idle` and not in flight is never reaped by the
/// teardown's own reaper because that sits inside the `activeCallKitId` branch.
///
/// ## The decision
///
/// `callStillCurrent` is whether the call the start was issued for is still THE current outgoing call (the app is in
/// a call and the accept latch still names this call's wire id: every ending, local or from the server, clears it,
/// and a redial replaces it). Current: the CallKit call is adopted as `activeCallKitId`, exactly as before. Not
/// current: the call is over, so it is not adopted and it is reported ended at once, with the reason the teardown
/// would have used (`CallerTerminalOutcome.callKitEndReason`: `.unanswered` for busy, `.remoteEnded` for an
/// unreachable callee; `.userEnded`, the `AppState.endCall` default, for any other ending). Never `.failed`.
public enum OutgoingCallKitStartPolicy {

    public enum Decision {
        /// The call is still the current one: store the CallKit uuid as `activeCallKitId`.
        case adopt
        /// The call ended while CallKit was starting: do not store the uuid, report it ended with this reason.
        case endAtOnce(CallEndReason)
    }

    /// - Parameters:
    ///   - callStillCurrent: the call the CallKit start was issued for is still the current outgoing call.
    ///   - endedBy: how a caller-side terminal envelope ended that call, when one did (`nil` for any other ending).
    public static func decide(callStillCurrent: Bool, endedBy: CallerTerminalOutcome?) -> Decision {
        if callStillCurrent { return .adopt }
        return .endAtOnce(endedBy?.callKitEndReason ?? .userEnded)
    }
}

/// W-CALLERBUSY — how the outgoing call `callId` ended, when a caller-side terminal envelope ended it. `AppState`
/// keeps the last one (a single slot) so a CallKit start that finishes after the teardown can report the same
/// reason; a record of another call never answers for this one.
public struct CallerTerminalEndRecord: Equatable, Sendable {
    /// The wire call id the envelope named, lowercased.
    public let callId: String
    public let outcome: CallerTerminalOutcome

    public init(callId: String, outcome: CallerTerminalOutcome) {
        self.callId = callId.lowercased()
        self.outcome = outcome
    }

    /// The outcome when this record is about `callId` (case-insensitive), else `nil`. An empty id never matches.
    public func outcome(forCallId callId: String) -> CallerTerminalOutcome? {
        guard !callId.isEmpty, callId.lowercased() == self.callId else { return nil }
        return outcome
    }
}
