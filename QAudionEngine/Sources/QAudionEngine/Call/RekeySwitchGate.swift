import Foundation

/// Re-key media-deafness (skew) fix — Swift port of Android's already-shipped
/// `feature/feature-call/domain/RekeySwitchGate.kt`.
///
/// A mid-call re-key installs a new decode key immediately (so this device
/// can decode a peer's frames tagged with the new epoch as soon as they
/// arrive) but must NOT switch this device's own outbound frames to the new
/// epoch until the peer is actually ready to decode them — otherwise the
/// peer goes deaf/blind for however long its own key derivation lags behind.
/// `RekeySwitchGate` is the pure coordination primitive that decides, given
/// a race between "peer confirmed epoch N is ready" (`call_media_ready`) and
/// "2s timeout elapsed", exactly once which one gets to trigger the actual
/// sender switch for a given epoch. It does no I/O, holds no key material,
/// and knows nothing about WebRTC, signalling, or the call lifecycle — the
/// caller (`QAudionWebRtcCallController`) owns `arm`ing it when a new epoch's
/// key is installed and calling `attemptSwitch` from both the ready-handler
/// and the timeout-handler racing it.
///
/// CLAUDE.md §16: this file takes only `Int32` params — never `AppState` —
/// so it does not trip the Sendable-inference build break (same discipline
/// `NativeVideoFrameCryptor`/`NativeAudioFrameCryptor` already follow).
///
/// Correctness properties (required, verified for Android's Kotlin port,
/// ported here rather than re-derived — see
/// `docs/superpowers/specs/2026-09-04-rekey-media-deafness-skew.md`):
/// - **Idempotent switch**: `attemptSwitch` returns `true` at most once per
///   epoch, however many times it's called for that epoch.
/// - **Exact-epoch match**: a stale (already-superseded) or premature
///   (not-yet-armed) epoch is rejected WITHOUT mutating any state, so a
///   rejected call can never block the actually-pending epoch from
///   switching later.
/// - **No skipped epoch**: as long as every `arm` is eventually raced by
///   both a ready-handler and a 2s-timeout-handler calling `attemptSwitch`,
///   every armed epoch is switched exactly once, in order.
///
/// Android's version used an `AtomicReference` + compare-and-swap retry
/// loop because it tracked two independent atomics that couldn't be updated
/// together. Swift has no lock-free CAS primitive as ergonomic as Kotlin's
/// here, so this port uses a plain `NSLock` guarding a small `State` struct
/// instead — the idiomatic equivalent already used by both
/// `NativeVideoFrameCryptor` and `NativeAudioFrameCryptor` in this same
/// module. Because `attemptSwitch` holds the lock for its entire
/// check-and-mutate body (and `arm` also takes the lock, so it can never
/// interleave with an in-flight `attemptSwitch`), a single critical section
/// is sufficient and closes the TOCTOU race Android's CAS loop had to guard
/// against explicitly — by construction, not by replicating Android's
/// specific fix mechanism.
public final class RekeySwitchGate: @unchecked Sendable {

    private struct State {
        var pendingEpoch: Int32 = -1
        var switchedEpoch: Int32 = -1
    }

    private var state = State()
    private let lock = NSLock()

    public init() {}

    /// Arms the gate for `epoch` — the epoch whose key was just installed
    /// and whose sender switch is now pending on a ready signal or timeout.
    public func arm(_ epoch: Int32) {
        lock.lock(); defer { lock.unlock() }
        state.pendingEpoch = epoch
    }

    /// The most recently armed epoch, or `-1` if `arm` has never been called.
    public func currentPendingEpoch() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return state.pendingEpoch
    }

    /// Attempts to switch the sender to `epoch`. Returns `true` exactly once
    /// per epoch — the first caller (ready-handler or timeout-handler,
    /// whichever wins the race) that matches the currently-armed epoch and
    /// hasn't already switched it. Returns `false` for a stale epoch (already
    /// switched, or superseded by a later `arm`), a premature epoch (not yet
    /// armed), or a repeat call for an epoch already switched — none of
    /// which mutate state.
    public func attemptSwitch(_ epoch: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard epoch == state.pendingEpoch, state.switchedEpoch < epoch else { return false }
        state.switchedEpoch = epoch
        return true
    }
}
