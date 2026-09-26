import Foundation

/// W-STALESEALER (2026-09-26) — pure decision for whether a relay-sealer install that was
/// scheduled while a call was live is still for a call that has not since ended.
///
/// `AppState` keeps a monotonic "call generation" counter that its `endCall()` bumps exactly
/// once per real teardown (guarded by `endCall()`'s own idempotency latch, so a second,
/// racing `endCall()` call for the same teardown never double-bumps it). Both the caller and
/// the responder `onRelaySessionReady` wiring capture that counter's value once, at the moment
/// the call's integration is wired, and pass it here — together with the CURRENT value — right
/// before `CallService.installRelaySealers` would run. A re-key round of the SAME call fires
/// the closure again with no intervening `endCall()`, so the generation is unchanged and the
/// install proceeds normally; a call that ended between the closure firing (on the engine's
/// callback thread) and the actual install (hopped to `@MainActor`, and sometimes further
/// deferred behind the identity-confirmation SAS gate in `pendingIdentityGatedMedia`) bumped
/// the generation in between, so the install is dropped instead of arming a sealer for a call
/// that no longer exists.
public enum RelaySealerInstallGuard {
    /// `true` when no `endCall()` teardown has happened since the closure that wants to
    /// install now was wired (i.e. the two generations still match).
    public static func shouldInstall(capturedGeneration: Int, currentGeneration: Int) -> Bool {
        return capturedGeneration == currentGeneration
    }
}
