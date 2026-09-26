import Foundation

/// W-STALESEALER (2026-09-26) — pure decision for whether a relay-sealer install that was
/// scheduled while a call was live is still for a call that has not since ended.
///
/// `CallService` keeps a monotonic "call generation" counter (`currentCallGeneration()`) that
/// its `endCall()` bumps unconditionally, exactly once per invocation — the single choke point
/// every terminal path in the app reaches, directly or through `AppState.endCall()`. Both the
/// caller and the responder `onRelaySessionReady` wiring in `AppState` read that counter
/// SYNCHRONOUSLY at FIRING time (not once at wiring time — the responder side caches and
/// reuses its `QAudionCallIntegration` across calls, so a value captured at wiring time could
/// already belong to a previous, ended call by the time a reused closure fires) and pass it
/// into `CallService.installRelaySealers(expectedGeneration:)`, which calls this function twice:
/// once as a cheap early rejection, and once more atomically with publishing the sealer
/// references, under the same lock `endCall()` bumps under (closing the check-then-act race a
/// single check could not). A re-key round of the SAME call fires the closure again with no
/// intervening `endCall()`, so the generation is unchanged and the install proceeds normally; a
/// call that ended between the closure firing (on the engine's callback thread) and the actual
/// install (hopped to `@MainActor`, and sometimes further deferred behind the
/// identity-confirmation SAS gate in `pendingIdentityGatedMedia`) bumped the generation in
/// between, so the install is dropped instead of arming a sealer for a call that no longer
/// exists.
public enum RelaySealerInstallGuard {
    /// `true` when no `endCall()` teardown has happened since the closure that wants to
    /// install now was wired (i.e. the two generations still match).
    public static func shouldInstall(capturedGeneration: Int, currentGeneration: Int) -> Bool {
        return capturedGeneration == currentGeneration
    }
}
