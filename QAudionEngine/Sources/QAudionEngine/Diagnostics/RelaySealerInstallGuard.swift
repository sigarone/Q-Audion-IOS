import Foundation

/// W-STALESEALER (2026-09-26) — pure decision for whether a relay-sealer install that was
/// scheduled while a call was live is still for a call that has not since ended.
///
/// `CallService` keeps a monotonic "call generation" counter (`currentCallGeneration()`) that
/// its `endCall()` bumps unconditionally, exactly once per invocation — the single choke point
/// every terminal path in the app reaches, directly or through `AppState.endCall()`.
/// `QAudionCallIntegration` reads that counter (via its injected `provideCallGeneration`
/// closure) ONCE, at the START of processing each inbound handshake message — BEFORE any
/// `await` that message's handling may do (a network send, an earbud GATT round-trip) that
/// could let `endCall()` run in between — and threads it through to `onRelaySessionReady`'s
/// `generation` parameter. AppState passes that value straight into `CallService
/// .installRelaySealers(expectedGeneration:)` (never re-reading the counter itself, which
/// would be too late relative to those awaits), and that method calls this function twice:
/// once as a cheap early rejection, and once more atomically with publishing the sealer
/// references, under the same lock `endCall()` bumps under (closing the check-then-act race a
/// single check could not). The same snapshot-generation + atomic-restore pattern protects
/// `CallService.activateIncomingCallAudio`'s answer-time sealer snapshot/restore, the other
/// place that writes the sealer slots outside `installRelaySealers`. A re-key round of the SAME
/// call re-enters handshake processing with no intervening `endCall()`, so the generation is
/// unchanged and the install proceeds normally; a call that ended between the entry-time
/// capture and the actual install (an awaited send, a hop to `@MainActor`, or a wait behind the
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
