import Foundation

/// W-GHOSTCALL (2026-09-25) — the pure decisions behind the "ghost call" fix
/// (incident e3acecd7, 2026-09-23 15:04:43-15:04:52): a call that had already
/// ended came back to life as a ringing, answerable CallKit call.
///
/// `e3acecd7` here and in the files that share this fix is the first 8 hex
/// digits of that call's id, as the device logs print them (`id=<8 hex>`); it is
/// not a commit hash. Times are UTC.
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
    ///
    /// Known residual (design, not a bug): the decision follows the ledger, so a
    /// cancel push that lands after the ledger entry expired (over the TTL) or in a
    /// fresh process (empty ledger) still reports the call's own uuid, i.e. a
    /// ring that is briefly visible until the handler's `reportCallEnded` follows.
    /// The strong protection is `answerVerdict`, not this plan: for a dead call a
    /// tap on that ring finds `activeCallKitId != uuid` and is refused.
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

    // MARK: - Answer guard

    /// Outcome of asking "may this CallKit answer start a call?".
    public enum AnswerVerdict: Equatable, Sendable {
        /// The uuid is the call this app is running/ringing and has not ended.
        case accept
        /// The uuid is a placeholder the cancel-push handler invented: there is
        /// nothing behind it, ever.
        case refuseGhostPlaceholder
        /// The uuid ended here a moment ago (the fading ring of a call that is
        /// already over).
        case refuseRecentlyEnded
        /// The uuid is not the call this app currently holds: no call at all
        /// (`activeCallKitId == nil`) or a DIFFERENT call is active — accepting
        /// would overwrite the live call's id.
        ///
        /// Latent limit: the TRUST-6 opaque-wakeup placeholder is deliberately NOT
        /// in `activeCallKitId` until the real `call_incoming` arrives, so an
        /// Answer tapped on it before then lands here too (see the note at
        /// `onIncomingOpaqueCallWakeup` in AppState).
        case refuseNotActive

        /// Stable numeric code for the remote log line (`answerguard refuse=1
        /// why=<code>`). The format is designed to carry fixed words and
        /// numeric tails only, with no free prose and no identifier beyond 8 hex
        /// digits. Whether such a line reaches the log pipeline is decided by
        /// the phone-log redactor's word allow-list (a separate shipper
        /// vocabulary change): the words of the new lines must be on that list,
        /// and the numeric tail alone does not make a line pass. Do not assume
        /// the line is shipped until that change is released.
        public var logCode: Int {
            switch self {
            case .accept: return 0
            case .refuseGhostPlaceholder: return 1
            case .refuseRecentlyEnded: return 2
            case .refuseNotActive: return 3
            }
        }
    }

    /// The single rule every accept path funnels through (CallKit answer,
    /// in-app banner, notification, CallKit-free): a call may be accepted only if
    /// `uuid == activeCallKitId`, it is not in the recently-ended ledger and it is
    /// not a ghost placeholder. Anything else is refused — before this rule
    /// `performAcceptIncoming` accepted whatever uuid it was handed, which is how
    /// a tap on the ring of a dead call became an in-call state with no call id.
    ///
    /// Inert for a normal call: every incoming path sets `activeCallKitId` before
    /// it reports the ring to CallKit, and nothing puts a live call's uuid in
    /// either ledger. The refusals are checked most-specific first so the log
    /// names the real cause.
    public static func answerVerdict(
        uuid: UUID,
        activeCallKitId: UUID?,
        isRecentlyEnded: Bool,
        isGhostPlaceholder: Bool
    ) -> AnswerVerdict {
        if isGhostPlaceholder { return .refuseGhostPlaceholder }
        if isRecentlyEnded { return .refuseRecentlyEnded }
        guard activeCallKitId == uuid else { return .refuseNotActive }
        return .accept
    }

    // MARK: - End action for a stale uuid

    /// Whether a CallKit "end call" (`CXEndCallAction`, handled by `onEndCall`)
    /// must be IGNORED because it names a call that is already over while a
    /// DIFFERENT call is live.
    ///
    /// `onEndCall` does not look at the uuid: it ends whatever call the app
    /// holds. That is right for the live call's own uuid and wrong for the
    /// leftover ring of a dead call, which `refuseStaleAnswer` leaves in place
    /// while another call is active (ending it at CallKit would drain the live
    /// call's shared audio session): a tap on Reject there would hang up the live
    /// call.
    ///
    /// Deliberately narrow — inert unless BOTH hold: a different call is active,
    /// and a ledger KNOWS this uuid is dead (recently ended, or a ghost
    /// placeholder). Every other end (the live call's own uuid, no call held, a
    /// uuid no ledger knows) keeps ending as before, so an id mismatch can never
    /// swallow a legitimate end. The provider still fulfils this END action (only
    /// an ANSWER the app refuses is failed, see `AnswerVerdict`), which is what
    /// dismisses the stale ring.
    public static func shouldIgnoreEndForStaleUuid(
        uuid: UUID,
        activeCallKitId: UUID?,
        isRecentlyEnded: Bool,
        isGhostPlaceholder: Bool
    ) -> Bool {
        guard let active = activeCallKitId, active != uuid else { return false }
        return isRecentlyEnded || isGhostPlaceholder
    }

    // MARK: - Answered without a call

    /// How long an accepted answer may sit with no call behind it before the
    /// watchdog ends it. 3 s: an incoming call has its peer set within
    /// milliseconds of the ring (PushKit sets it before the ring is reported, the
    /// WS path right after the report, in the same task), so this only has to
    /// outlast scheduling noise. Incident e3acecd7 stayed in that state 6.6 s.
    public static let answeredWithoutCallGraceSeconds: TimeInterval = 3

    /// True when the call identified by `expectedUuid` was answered
    /// (`answeredCallKitId` still names it — `endCall` clears it) but the app
    /// still has no peer for it (`callContactId` nil or empty): an "in call" with
    /// nobody on the line. The uuid comparison keeps a timer armed for an old
    /// answer from ending a LATER call.
    public static func isAnsweredWithoutCall(
        answeredCallKitId: UUID?,
        expectedUuid: UUID,
        callContactId: String?
    ) -> Bool {
        guard answeredCallKitId == expectedUuid else { return false }
        guard let peer = callContactId else { return true }
        return peer.isEmpty
    }

    // MARK: - Missed call under CallKit

    /// Whether a remote hangup / cancel / timeout arrived while an INCOMING call
    /// was still ringing, i.e. whether it must be recorded as a missed call.
    ///
    /// `callState == .ringing` is only half the answer. When CallKit owns the ring
    /// (PushKit-woken, or a background WS call) `callState` deliberately stays
    /// `.idle` until the user answers (see the `call_incoming` handler and
    /// `noCallInFlight`), so a caller that gave up on its own timeout was never
    /// recorded as missed (e3acecd7, F-08: `endCall ... state=idle`, no
    /// `hangup-while-ringing` line). What identifies that ring instead is: a
    /// CallKit id is held, it was never answered, and the incoming ring flag is
    /// still up.
    ///
    /// `incomingRingVisible` is NOT optional. `activeCallKitId` is also held for
    /// the whole life of an OUTGOING call, and `callWasAnswered` (which is only
    /// ever set by the callee's accept path) is false there too: without the ring
    /// flag, every remote hangup of an answered outgoing call would be recorded as
    /// missed. The flag is set only for incoming calls and cleared on answer and
    /// on every teardown.
    public static func wasRingingAtRemoteHangup(
        callStateIsRinging: Bool,
        hasActiveCallKitId: Bool,
        callWasAnswered: Bool,
        incomingRingVisible: Bool
    ) -> Bool {
        if callStateIsRinging { return true }
        return hasActiveCallKitId && !callWasAnswered && incomingRingVisible
    }

    /// Whether the `call_cancelled` VoIP push must record the call as missed
    /// ITSELF, evaluated just before it clears the ring flag.
    ///
    /// `wasRingingAtRemoteHangup` needs the ring flag, and the push handler
    /// clears that flag to hide the stale ring UI. When the push beats the
    /// caller's WS hangup, the later `handleRemoteCallHangup` therefore sees no
    /// ring and records nothing, and if that hangup never arrives (app
    /// suspended, WS dead) the missed call is lost for good. Recording it here,
    /// while the flag is still up, closes that gap; the hangup that may follow
    /// finds no record id left and is a no-op for the call history.
    ///
    /// `cancelCallId` must be the call the app is holding (`activeCallKitId`): a
    /// cancel for some OTHER call must never mark the ringing one missed. An
    /// answered call has its ring flag cleared already; `callWasAnswered` is the
    /// belt and braces.
    public static func shouldRecordMissedOnCancelPush(
        cancelCallId: UUID,
        activeCallKitId: UUID?,
        callWasAnswered: Bool,
        incomingRingVisible: Bool
    ) -> Bool {
        guard activeCallKitId == cancelCallId else { return false }
        return !callWasAnswered && incomingRingVisible
    }
}
