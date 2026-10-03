import Foundation

/// W-CALLERBUSY (2026-10-03) — what the caller does when the server answers its `call_offer` with
/// `call_busy` or `call_peer_offline`, as a pure value so the whole decision can be tested without `AppState`.
///
/// ## The defect this closes
///
/// The two handlers used to tear the call down by hand (`callService.endCall()` plus a manual state reset)
/// instead of going through `AppState.endCall`. What that left open, from a live trace of 2026-10-03 10:43
/// (iPhone 1.0.1205 calling an Android phone that was in another call, three dials in 24 s):
///   - the CallKit outgoing call (`activeCallKitId`) was never reported ended, so iOS still held one call group
///     and refused the next `CXStartCallAction` with `CXErrorCodeRequestTransactionError.maximumCallGroupsReached`
///     (code 7) until the app's own watchdog closed it ~41 s later;
///   - the outgoing call record and the ring-back fallback timer were never closed either;
///   - nothing told the user: no tone, and `errorMessage` ("Occupato") is not read by any call screen while
///     `ContentView` switches to Home as soon as `isInCall` is false.
/// The reference behaviour is Android's: a 425 Hz busy tone (0.5 s on / 0.5 s off, about 3 s), the word "Occupato"
/// on the outgoing screen, the history row closed as busy.
///
/// ## What the outcome decides
///
/// Everything that differs between the two envelopes, and nothing about the latch or the gate: the id gate
/// (`CallerAcceptLatch.terminalEnvelopeArrived`) has already decided that this envelope ends the current outgoing
/// call and has reset the latch. The teardown that follows is `AppState.endCall(notifyPeerInBand: false, ...)`
/// parameterised with this value.
public enum CallerTerminalOutcome: String, CaseIterable, Equatable, Sendable {
    /// The callee is in another answered call (`call_busy`).
    case busy
    /// The callee has no live connection (`call_peer_offline`).
    case peerOffline = "peer_offline"

    /// The outcome of a caller-side terminal envelope. `nil` for `.cancel`: that envelope is the incoming-call
    /// cancel too and keeps its own routing (`AppState.routeCallCancel`).
    public init?(kind: CallerAcceptLatch.TerminalKind) {
        switch kind {
        case .busy: self = .busy
        case .peerOffline: self = .peerOffline
        case .cancel: return nil
        }
    }

    /// The token stored on the call record (`CallRecord.closeReason`), and reported as the call's end reason in the
    /// telemetry: the same strings the handlers always reported (`busy`, `peer_offline`).
    public var closeToken: String { rawValue }

    /// Why CallKit is told the outgoing call ended. Never `.failed`: nothing failed, the far end could not take the
    /// call. A busy callee is an unanswered call; an unreachable one ended from the remote side.
    public var callKitEndReason: CallEndReason {
        switch self {
        case .busy: return .unanswered
        case .peerOffline: return .remoteEnded
        }
    }

    /// Whether the teardown tells the callee anything (`call_hangup` envelope, the opaque `HANGUP`, the in-band control
    /// frame): never. The call never rang there (a busy callee is inside ANOTHER call, an unreachable one has no
    /// connection), so a hangup would reach a callee that is mid-call with someone else. Android
    /// `hangup(reason = "busy" | "peer_offline", notifyPeer = false)` sends nothing either.
    public var sendsHangupToPeer: Bool { false }

    /// The busy tone plays for `call_busy` only. An unreachable callee gets the message on screen, no tone
    /// (Android plays none for it either).
    public var playsBusyTone: Bool { self == .busy }

    /// How long the outgoing screen keeps the outcome on screen before returning to Home. Long enough to read the
    /// word and to hear the whole tone (3 s) for a busy callee; a redial or the close button ends it sooner.
    public var holdSeconds: TimeInterval {
        switch self {
        case .busy: return 3.0
        case .peerOffline: return 2.5
        }
    }

    /// Key of the user-facing word on the outgoing screen (Localizable.xcstrings): `call.outgoing.<token>`.
    public var messageKey: String { "call.outgoing." + rawValue }

    /// Key of the call-history label (Localizable.xcstrings): `call_history.close.<token>`.
    public var historyLabelKey: String { "call_history.close." + rawValue }

    /// The allow-list check: the outcome when `token` is exactly one of the two tokens, else `nil`. Used by the
    /// call-record store so a free-form string never lands in `closeReason`.
    public static func accepted(_ token: String?) -> CallerTerminalOutcome? {
        guard let token else { return nil }
        return CallerTerminalOutcome(rawValue: token)
    }
}
