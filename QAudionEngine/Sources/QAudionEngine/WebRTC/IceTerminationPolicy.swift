import Foundation

/// W-ICEGRACE (2026-07-21) — what a WebRTC ICE/connection-state edge should do
/// to a live 1:1 call.
public enum IceTerminationAction: Equatable, Sendable {
    /// No call to tear down (already idle/ended) — ignore the edge.
    case none
    /// Terminal ICE state (`.failed` / `.closed`): the transport is gone for
    /// good, end the call now.
    case endImmediately
    /// Recoverable ICE state (`.disconnected`): give the connection a grace
    /// window to heal itself before ending anything.
    case endAfterGrace
}

/// W-ICEGRACE — pure decision behind `AppState.handleIceTermination`.
///
/// ICE `.disconnected` is explicitly a RECOVERABLE state in the WebRTC spec —
/// it routinely self-heals within a second or two across a WiFi/cellular
/// hiccup. Only `.failed` and `.closed` are terminal. iOS nevertheless called
/// `endCall()` on the very first `.disconnected` edge, with zero grace, while
/// Android has always armed a 3000 ms window (`DISCONNECT_GRACE_MS`,
/// `CallTransportFactory.kt:821`) and fallen back to the WS relay instead of
/// hanging up.
///
/// Device-verified asymmetry, call f884668c (2026-07-21, iOS↔Android 1:1
/// audio): iOS ended the call at 21.9s (`call.media.summary`
/// end_reason=user_hangup, mic tx frozen at 970 frames) ~0.3s after Android
/// logged "ICE DISCONNECTED — arming 3000ms grace" for the SAME call; Android
/// rode it out and reports duration_ms=85098 for its own leg. Same wire event,
/// opposite behavior — a pure platform-parity gap, live since 2026-05-18.
///
/// Extracted top-level (no WebRTC/AppState types) so this contract has its own
/// regression test, same shape as `VideoTransceiverPhantomGuard` and
/// `AudioDcBackpressureGate`. If the grace ever needs to change, change it here
/// AND in Android's `DISCONNECT_GRACE_MS` together — the two are a protocol
/// pair, not two independent tunables.
public func iceTerminationAction(callIsLive: Bool, iceIsTerminal: Bool) -> IceTerminationAction {
    guard callIsLive else { return .none }
    return iceIsTerminal ? .endImmediately : .endAfterGrace
}
