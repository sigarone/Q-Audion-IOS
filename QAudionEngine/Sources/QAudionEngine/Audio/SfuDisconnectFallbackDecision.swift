import Foundation

/// W-GRPSFUMIDFALLBACK (2026-08-27, best-practices audit item 2) — pure
/// decision helper for `GroupCallController.handleSfuDisconnectedMidCall`:
/// should THIS `didDisconnectWithError` event (already filtered by
/// `LiveKitGroupCallRoom.isIntentionalDisconnect` before it ever reaches
/// this controller — a genuine SFU failure, not an app-initiated
/// disconnect such as a normal call-end, a fast SFU rejoin's own teardown,
/// or `handleSfuToken`'s own connect-failure cleanup) actually engage the
/// mid-call WS-relay mesh fallback?
///
/// Extracted so the "still the active call, AND a room genuinely exists to
/// fall back FROM" guard is directly unit-testable without constructing a
/// live `GroupCallController`/LiveKit `Room` — same "pure decision struct"
/// discipline `RouteTierDwell` / `BweSenderCeiling` (WebRTC/
/// VideoBandwidthCap.swift) already use in this package for the 1:1 path.
///
/// `false` on a stale/redelivered event: either a DIFFERENT call is now
/// active (this callback fired for a call that already ended and a new
/// one started), or `sfuRoom` is already `nil` (this same fallback, or a
/// normal `teardown()`, already ran for this call and cleared it under the
/// same lock) — same "only once" discipline `handleSfuToken`'s own
/// `stillCurrent` check and `handleSfuUnavailable`'s guard already apply
/// to their own fallback triggers.
public enum SfuDisconnectFallbackDecision {
    public static func shouldFallBack(eventCallId: String, activeCallId: String?, hasSfuRoom: Bool) -> Bool {
        guard hasSfuRoom else { return false }
        return eventCallId == activeCallId
    }
}
