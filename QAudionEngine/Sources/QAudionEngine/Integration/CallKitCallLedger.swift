import Foundation

/// W-CKLEDGER (2026-09-01) — thread-safe bookkeeping for the three call-UUID
/// sets `CallKitProvider` keeps. Extracted from the provider so the sets are
/// guarded by one lock and every check-then-act the provider needs is a
/// single atomic call; before this they were plain `private var Set<UUID>`
/// on an `@unchecked Sendable` type with no lock at all (see audit memory
/// reference_ios_stability_audit_2026_09_01, P1 item 9).
///
/// Why a lock is needed and not just a main-thread assertion: not every
/// access is on main. `CallKitProvider` is NOT `@MainActor`, so its `async`
/// members (`reportIncomingCall`, `reportCallEnded`, `startOutgoingCall`,
/// `answerCall`) run on the cooperative pool, while the synchronous members
/// (`registerSuppressedCall`, `releaseFromSystemUI`, `endAllOutstanding`) and
/// the `CXProviderDelegate` callbacks (delegate queue nil ⇒ main) run on the
/// main thread. The PushKit+WS duplicate report of the same uuid — the
/// `dup=1` case the provider already logs — is two pool threads mutating the
/// same `Set` at once, and `answerIncomingCall` / `endCall` each spawn an
/// unstructured `Task` around the async members.
///
/// Foundation-only and iOS-agnostic on purpose: `CallKitProvider` itself is
/// behind `#if canImport(CallKit) && os(iOS)` and owns a live `CXProvider`,
/// so its bookkeeping could never be pinned by a unit test. Same NSLock
/// idiom as `BinaryRelayWireFormLatch`, `CallRouter`, `SessionManager`.
///
/// No compile-time kill switch: the happy path (every CallKit call, its
/// order, every log line) is unchanged; the only behaviour this alters is
/// the concurrent case, which was a data race — a `Set` mutated from two
/// threads — not a defined behaviour anyone could depend on.
final class CallKitCallLedger: @unchecked Sendable {

    private let lock = NSLock()

    /// W495 — UUIDs for which CallKit rejected reportNewIncomingCall
    /// (Focus/DnD/block-list), plus W520 foreground-suppressed calls that were
    /// deliberately never reported. When the user taps Answer on the in-app
    /// banner for these calls the provider bypasses CXCallController (which
    /// would also fail) and answers directly, manually activating the audio
    /// session.
    private var callKitRejectedUUIDs: Set<UUID> = []

    /// W-WAKEONLY — UUIDs for which the NATIVE CallKit incoming UI was actually
    /// shown (reportNewIncomingCall succeeded). Only these can be "released"
    /// from the system UI after answer (the foreground-suppressed path never
    /// showed a native UI, so there is nothing to dismiss).
    private var nativelyReportedUUIDs: Set<UUID> = []

    /// Every call UUID this process has ever reported to CallKit and not yet
    /// ended. Distinct from `nativelyReportedUUIDs`, which is cleared the
    /// moment the system UI is dismissed while the call is still live.
    ///
    /// This one exists so a call can always be ended, from any path, without
    /// the caller having to remember whether it was reported and by which
    /// route. A CallKit call that outlives the app's own call is not a
    /// cosmetic problem: iOS believes the phone is busy, and the next incoming
    /// report can be refused — the user simply stops being reachable and
    /// nothing on screen says why.
    private var outstandingUUIDs: Set<UUID> = []

    init() {}

    /// Whether `reportNewIncomingCall` already succeeded for this uuid. Read
    /// BEFORE the provider awaits CallKit, so a second report of the same
    /// uuid (PushKit + WS) can be told apart from a genuine rejection.
    func isNativelyReported(_ uuid: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return nativelyReportedUUIDs.contains(uuid)
    }

    /// `reportNewIncomingCall` succeeded: the native UI is up (W-WAKEONLY) and
    /// the call is outstanding with CallKit. Returns the outstanding count as
    /// of this insert, for the provider's `callkit report ok=1` log line.
    @discardableResult
    func recordNativeReport(_ uuid: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        nativelyReportedUUIDs.insert(uuid)
        outstandingUUIDs.insert(uuid)
        return outstandingUUIDs.count
    }

    /// An outgoing call CallKit accepted via `CXStartCallAction`: outstanding,
    /// but never "natively reported" (there is no incoming UI to release).
    func recordOutstanding(_ uuid: UUID) {
        lock.lock()
        defer { lock.unlock() }
        outstandingUUIDs.insert(uuid)
    }

    /// CallKit rejected the report (W495) or the report was deliberately
    /// skipped for a foreground WS call (W520): arm the in-app manual-answer
    /// path for this uuid.
    func recordRejected(_ uuid: UUID) {
        lock.lock()
        defer { lock.unlock() }
        callKitRejectedUUIDs.insert(uuid)
    }

    /// Atomic test-and-remove for the manual-answer path: `true` exactly once
    /// per armed uuid. Two concurrent `answerCall` for the same uuid (double
    /// tap on the in-app banner) therefore take the manual path once, the
    /// way two sequential calls always did.
    func takeRejected(_ uuid: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return callKitRejectedUUIDs.remove(uuid) != nil
    }

    /// W-WAKEONLY — atomic test-and-remove of the "native UI shown" mark.
    /// `true` only if the native UI was actually up. Deliberately leaves the
    /// uuid outstanding: releasing the system UI does not end the call, and
    /// `endAllOutstanding` must still be able to close it later.
    func releaseNativeReport(_ uuid: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return nativelyReportedUUIDs.remove(uuid) != nil
    }

    /// Call ended: drop the uuid from every set (W495 + W-WAKEONLY cleanup).
    func forget(_ uuid: UUID) {
        lock.lock()
        defer { lock.unlock() }
        callKitRejectedUUIDs.remove(uuid)
        nativelyReportedUUIDs.remove(uuid)
        outstandingUUIDs.remove(uuid)
    }

    /// `endAllOutstanding` — take every outstanding uuid out of all three sets
    /// in one critical section and hand the snapshot back so the provider can
    /// report each one ended. A uuid that is only in `callKitRejectedUUIDs`
    /// (suppressed, never reported) is not outstanding and is left alone —
    /// exactly what the per-uuid loop did before this type existed.
    func drainOutstanding() -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        let stale = outstandingUUIDs
        for uuid in stale {
            nativelyReportedUUIDs.remove(uuid)
            callKitRejectedUUIDs.remove(uuid)
        }
        outstandingUUIDs.removeAll()
        return stale
    }

    /// `providerDidReset` (W571) — CallKit invalidated all calls; only the
    /// manual-answer arming is cleared here, as before. Outstanding /
    /// natively-reported bookkeeping is left to the app's reset handler.
    func clearRejected() {
        lock.lock()
        defer { lock.unlock() }
        callKitRejectedUUIDs.removeAll()
    }

    /// How many calls this process believes are still open with CallKit.
    var outstandingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outstandingUUIDs.count
    }
}
