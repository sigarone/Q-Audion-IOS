import Foundation

/// W-GHOSTCALL (2026-09-25) — the pure decisions behind the "ghost call" fix
/// (incident e3acecd7, 2026-09-23 15:04:43-15:04:52): a call that had already
/// ended came back to life as a ringing, answerable CallKit call.
///
/// Timeline of the incident, from the device log (15:04): the caller hangs up
/// over the WS at 43.794 (`opaquehang rx`, `reportCallEnded` + `endCall` at
/// 43.795), the server still sends its `call_cancelled` VoIP push, the push
/// handler reports the SAME uuid to CallKit at 44.445 (`callkit report ok=1
/// dup=0`: CallKit had already dropped it, so this was a brand-new ring), the
/// user taps Answer at 45.726 and `performAcceptIncoming` — which never asked
/// whether the call was still alive — runs an in-call state with no call id for
/// 6.6 s while the server rejects the `call_accepted` (F4 foreign call_id).
///
/// These types decide ONLY what to do; they own no CallKit object and no app
/// state, the same split as `CallKitProviderResetPolicy`. Every input is a plain
/// value the caller reads from `AppState`, so the rules are unit-testable
/// without a live `CXProvider`. Each rule is inert unless a uuid is in one of
/// the `RecentlyEndedCallLedger` instances (or, for the answer guard, is not the
/// active call): a normal call never reaches a "refuse" branch.
public enum GhostCallPolicy {

    // MARK: - Incoming cancel push

    /// What the `call_cancelled` VoIP push handler reports to CallKit.
    public struct CancelReportPlan: Equatable, Sendable {
        /// The uuid to `reportIncomingCall` and immediately `reportCallEnded`.
        public let reportUuid: UUID
        /// `true` when `reportUuid` is a fresh throwaway, not the call's own uuid.
        public let isPlaceholder: Bool
    }

    /// Apple's PushKit rule is that every VoIP push must be answered with a
    /// reported incoming call, so the cancel handler can never simply skip the
    /// report. What it CAN choose is which uuid to report:
    ///
    /// - the call is still known (ringing under CallKit, not ended here): report
    ///   its own uuid, exactly as before — CallKit recognises it (Code=2) and the
    ///   `reportCallEnded` that follows dismisses THAT ring;
    /// - the call already ended here: its uuid must NOT be used again, CallKit no
    ///   longer knows it and would show a new ring for a dead call. Report a
    ///   fresh `placeholder` instead (satisfies the mandate) and end it at once.
    ///
    /// `placeholder` is supplied by the caller (`UUID()`), so this stays a pure,
    /// deterministic function.
    public static func cancelReportPlan(
        callId: UUID,
        isRecentlyEnded: Bool,
        placeholder: UUID
    ) -> CancelReportPlan {
        guard isRecentlyEnded else {
            return CancelReportPlan(reportUuid: callId, isPlaceholder: false)
        }
        return CancelReportPlan(reportUuid: placeholder, isPlaceholder: true)
    }
}
