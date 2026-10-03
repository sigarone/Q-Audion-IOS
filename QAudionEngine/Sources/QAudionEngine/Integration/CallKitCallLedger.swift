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

    /// W-SELFACTIVATED (2026-09-09) — separate from all three sets above on
    /// purpose. Those track whether CallKit's NATIVE UI/ledger knows about a
    /// call; this tracks something CallKit has no visibility into at all:
    /// whether THIS APP called `RTCAudioSession`'s own locked `setActive(true)`
    /// for the current call (`CallKitProvider.activateAudioSession`) and
    /// therefore owes it a matching `setActive(false)`.
    ///
    /// Live evidence this distinction is real, not cosmetic: the foreground
    /// answer path (`AppState.swift`, W520 "single-dialer") deliberately
    /// SKIPS `reportIncomingCall` to avoid a double system dialer — so
    /// `outstandingUUIDs` never gets that call's uuid at all, on the
    /// answering side, for the exact scenario two devices testing calls
    /// foregrounded next to each other hit on every single call. An earlier
    /// version of this fix reused `outstandingUUIDs`/`forget(_:)` as the
    /// idempotency guard for the `RTCAudioSession` deactivate — silently
    /// correct for the caller side (always outstanding via
    /// `recordOutstanding`) and silently WRONG for the answering side in
    /// this exact foreground scenario, so the answering device's
    /// `activationCount` climbed every call with no way back down. This
    /// flag is a boolean, not a per-uuid set, because the 1:1 call model
    /// this app assumes throughout (`state == .idle` guards before a new
    /// call starts) never has more than one call's activation pending at
    /// once.
    ///
    /// W-SELFACTID (2026-09-27) — that assumption does not hold across a
    /// back-to-back pair: `reportCallEnded` runs in an unawaited Task, so the
    /// OLD call's report can run after the NEXT call self-activated, take the
    /// next call's mark and leave the next call's own report with nothing to
    /// balance. This flag now serves ONLY calls with native SRTP off (their
    /// behaviour is unchanged, byte for byte); a native-SRTP call's mark is
    /// keyed by its CallKit uuid in `selfActivatedNativeUUIDs` below.
    private var audioSelfActivated = false

    /// W-SELFACTID (2026-09-27) — CallKit uuids of native-SRTP calls whose
    /// `activateAudioSession` succeeded, i.e. that owe exactly one balancing
    /// `setActive(false)`. Same keying and same lifetime as
    /// `nativeBalanceUUIDs` (a native call is recorded there BEFORE its
    /// activation runs, on every path that passes a uuid), consumed only by
    /// that SAME uuid's `reportCallEnded`: another call's mark is never taken.
    /// A leftover entry (a call ended only through `endAllOutstanding`, or a
    /// late activation retry that lands after its own `reportCallEnded`
    /// already ran — see ``markAudioSelfActivated(_:)``) is inert, since call
    /// uuids are never reused.
    private var selfActivatedNativeUUIDs: Set<UUID> = []

    /// W-NATIVEEVICT (2026-09-27) — every CallKit uuid this process has ever
    /// recorded as a native-SRTP call (``recordNativeBalance(_:)``), kept for
    /// the LIFETIME of the process, unlike `nativeBalanceUUIDs` (cleared at
    /// that uuid's own `reportCallEnded`). This is what recognises a LATE,
    /// out-of-order arrival for that uuid — a delayed `activateAudioSession`
    /// retry, or a repeated `reportCallEnded` (W-DOUBLEDECR) — as belonging to
    /// a native call, so it can be kept out of the legacy, process-wide
    /// bookkeeping (`audioSelfActivated`) instead of silently leaking into
    /// whichever unrelated legacy call happens to be live when it lands.
    ///
    /// Deliberately unbounded, replacing an earlier count-capped list (8
    /// entries): a small cap let a uuid age out of memory before such a
    /// delayed arrival showed up, at which point it was indistinguishable
    /// from a uuid that was never native — exactly the leak this set exists
    /// to close. Call uuids are never reused, and a phone call is rare enough
    /// against the process's own lifetime (killed and relaunched far more
    /// often than it places thousands of calls) that the memory cost is a
    /// few dozen bytes per call, not a leak of its own.
    private var nativeUUIDs: Set<UUID> = []

    /// W-GHOSTCALL (2026-09-25) — uuids whose `reportNewIncomingCall` has been
    /// asked of CallKit and CallKit has not replied yet. Exists only to make
    /// "am I the first report of this uuid?" one atomic test-and-set taken BEFORE
    /// the await (see `beginReport`): the old check read `nativelyReportedUUIDs`,
    /// which is only filled AFTER CallKit's reply to the report comes back, so two
    /// reports of the same uuid issued within the same millisecond (a doubled
    /// PushKit push, e3acecd7: 03.221 and 03.222) both saw "not reported yet".
    private var reportsInFlight: Set<UUID> = []

    /// W-ADMBALANCE-UUID (2026-09-26) — CallKit uuids of native-SRTP (manual
    /// audio mode) calls, recorded when the call's CallKit start/answer runs
    /// and consumed by that SAME uuid's `reportCallEnded`, which then issues
    /// the single balancing deactivation instead of the legacy drain. Keyed
    /// by uuid, not a process-wide flag: `reportCallEnded` runs in an
    /// unawaited Task, so a NEW native call could arm a shared flag before
    /// the OLD call's report consumed it (the old report then took the new
    /// call's flag and the new call fell back to the drain). A call with
    /// native SRTP off is never recorded, so its end is the legacy drain.
    /// Deliberately NOT cleared by `drainOutstanding`/`clearRejected`: a record
    /// must survive until its own `reportCallEnded`, and a leftover one (a call
    /// ended only through `endAllOutstanding`) is inert, since call uuids are
    /// never reused - one UUID per native call that skipped its report.
    private var nativeBalanceUUIDs: Set<UUID> = []

    /// W-CALLERBUSY (review of #169) — uuids whose `reportCallEnded` has already run, oldest first, capped at
    /// `endedCapacity` (a uuid is never reused, so an aged-out entry only means "an activation that late is not
    /// something this app can still be racing"). Read by ``markAudioSelfActivatedUnlessEnded(_:)``: an outgoing
    /// call's `CXStartCallAction` handler fulfils and then spawns an unstructured `Task` that activates the audio
    /// session, so a `call_busy` can have ended the call (and run the end balance) BEFORE that activation lands.
    /// `outstandingUUIDs` cannot answer "has this call ended": an outgoing uuid is recorded there only after
    /// `startOutgoingCall`'s `await` returns, which can be AFTER that activation, and a foreground answer never is.
    private var endedUUIDs: [UUID] = []
    private static let endedCapacity = 128

    init() {}

    /// W-ADMBALANCE-UUID — `uuid` is a native-SRTP call (its end owes the
    /// single balancing deactivation). Idempotent.
    func recordNativeBalance(_ uuid: UUID) {
        lock.lock()
        defer { lock.unlock() }
        nativeBalanceUUIDs.insert(uuid)
        nativeUUIDs.insert(uuid)
    }

    /// W-ADMBALANCE-UUID — atomic test-and-remove: `true` exactly once, and
    /// only for a uuid recorded by ``recordNativeBalance(_:)``. Another call's
    /// record is never consumed. (`reportCallEnded` now goes through
    /// ``consumeEndBalance(_:)``, which consumes the record and the uuid's
    /// self-activation mark together.)
    func consumeNativeBalance(_ uuid: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return nativeBalanceUUIDs.remove(uuid) != nil
    }

    /// Called the instant `activateAudioSession` successfully calls
    /// `RTCAudioSession`'s locked `setActive(true)`. Marks that a matching
    /// deactivate is now owed, independent of whatever CallKit's own native
    /// UI/ledger state for this call happens to be.
    ///
    /// W-SELFACTID (2026-09-27) — `uuid` is the CallKit uuid the activation
    /// was made for. A uuid ever recorded as native (``nativeUUIDs``, set by
    /// ``recordNativeBalance(_:)`` before the activation) is marked under its
    /// own key; anything else — a call with native SRTP off, or no uuid —
    /// sets the process-wide flag exactly as before. The native check and the
    /// mark are one critical section.
    ///
    /// W-NATIVEEVICT (2026-09-27) — checked against ``nativeUUIDs``, not
    /// `nativeBalanceUUIDs`: a native call's activation retry can land AFTER
    /// its own `reportCallEnded` already consumed `nativeBalanceUUIDs`'s
    /// entry (the report runs in an unawaited Task; the retry has its own
    /// bounded delay loop). That late mark has nothing left to balance for
    /// its OWN call, but it must still be recognised as native and kept under
    /// its own key — a no-op the uuid's own end already resolved — rather
    /// than falling to the process-wide flag below, which the NEXT unrelated
    /// legacy call would then wrongly consume as its own self-activation.
    func markAudioSelfActivated(_ uuid: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        markAudioSelfActivatedLocked(uuid)
    }

    private func markAudioSelfActivatedLocked(_ uuid: UUID?) {
        if let uuid, nativeUUIDs.contains(uuid) {
            selfActivatedNativeUUIDs.insert(uuid)
        } else {
            audioSelfActivated = true
        }
    }

    /// What a successful `setActive(true)` of `activateAudioSession` owes.
    enum SelfActivationOutcome: Equatable {
        /// The call is still open: the activation is marked (``markAudioSelfActivated(_:)``) and the normal
        /// callbacks run. The end of the call will balance it.
        case owed
        /// The call's `reportCallEnded` already ran, so its end balance was decided WITHOUT this activation and
        /// nothing will ever balance it: the caller must `setActive(false)` at once, and must not run
        /// `onAudioSessionActivated` (it would set `CallService.audioSessionActive = true` after the teardown
        /// cleared it and pre-satisfy the W464 gate of the NEXT call). Nothing is marked.
        case callAlreadyEnded
    }

    /// W-CALLERBUSY (review of #169) — ``markAudioSelfActivated(_:)`` for an activation that may land after the
    /// call's own end, decided in ONE critical section with the ended mark ``consumeEndBalance(_:)`` leaves:
    /// whichever of the two runs second sees the other. Activation first: ``SelfActivationOutcome/owed``, and the
    /// end report finds the mark and balances it (the normal order). End first:
    /// ``SelfActivationOutcome/callAlreadyEnded``, and the mark is NOT set, so neither the uuid's own key nor the
    /// process-wide legacy flag (which the next, unrelated call would consume as its own self-activation) is
    /// touched. A `nil` uuid cannot have ended.
    func markAudioSelfActivatedUnlessEnded(_ uuid: UUID?) -> SelfActivationOutcome {
        lock.lock()
        defer { lock.unlock() }
        if let uuid, endedUUIDs.contains(uuid) { return .callAlreadyEnded }
        markAudioSelfActivatedLocked(uuid)
        return .owed
    }

    /// What `reportCallEnded` must do to balance `uuid`'s self-activation.
    struct EndBalance: Equatable {
        /// `uuid` is a native-SRTP call (see ``recordNativeBalance(_:)``):
        /// at most ONE balancing deactivation, never the legacy drain.
        let nativeManualCall: Bool
        /// A self-activation is owed for this report.
        let selfActivated: Bool
        /// A repeated report of a native uuid already balanced: nothing to do.
        let duplicateNative: Bool
    }

    /// W-SELFACTID (2026-09-27) — the call-end decision for `uuid`, in ONE
    /// critical section (replaces the two separate test-and-clears, native
    /// record then process-wide flag):
    /// * native uuid, first report: its record and ITS OWN self-activation
    ///   mark are consumed; another call's mark is never taken, so the old
    ///   call's late report cannot eat the next call's activation.
    /// * native uuid, repeated report: nothing owed, and the legacy flag is
    ///   left alone.
    /// * anything else (native SRTP off): the process-wide flag, test-and-clear,
    ///   exactly as before — true only the first time after a self-activation,
    ///   so a duplicate `reportCallEnded` cannot double-decrement
    ///   `RTCAudioSession.activationCount` (W-DOUBLEDECR).
    ///
    /// W-NATIVEEVICT (2026-09-27) — the repeated-report check reads
    /// ``nativeUUIDs`` (unbounded, lifetime of the process), not a
    /// count-capped recent list: the uuid is never forgotten, so a duplicate
    /// report can never age out and fall through to the legacy flag below no
    /// matter how many other calls ended in between.
    func consumeEndBalance(_ uuid: UUID) -> EndBalance {
        lock.lock()
        defer { lock.unlock() }
        // W-CALLERBUSY — from here on an activation for this uuid is late (see `endedUUIDs`).
        if !endedUUIDs.contains(uuid) {
            endedUUIDs.append(uuid)
            if endedUUIDs.count > Self.endedCapacity { endedUUIDs.removeFirst(endedUUIDs.count - Self.endedCapacity) }
        }
        if nativeBalanceUUIDs.remove(uuid) != nil {
            let selfActivated = selfActivatedNativeUUIDs.remove(uuid) != nil
            return EndBalance(nativeManualCall: true, selfActivated: selfActivated, duplicateNative: false)
        }
        if nativeUUIDs.contains(uuid) {
            return EndBalance(nativeManualCall: false, selfActivated: false, duplicateNative: true)
        }
        guard audioSelfActivated else {
            return EndBalance(nativeManualCall: false, selfActivated: false, duplicateNative: false)
        }
        audioSelfActivated = false
        return EndBalance(nativeManualCall: false, selfActivated: true, duplicateNative: false)
    }

    /// Whether `reportNewIncomingCall` already succeeded for this uuid. Read
    /// BEFORE the provider awaits CallKit, so a second report of the same
    /// uuid (PushKit + WS) can be told apart from a genuine rejection.
    /// W-GHOSTCALL: the provider now uses `beginReport`, which also covers a
    /// report that is still in flight; this plain read stays for diagnostics.
    func isNativelyReported(_ uuid: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return nativelyReportedUUIDs.contains(uuid)
    }

    /// W-GHOSTCALL — atomic claim, taken right before `reportNewIncomingCall` is
    /// awaited. `true` for exactly one caller per uuid: the first one, while no
    /// other report of it is in flight and none has succeeded. Every later caller
    /// gets `false` and must treat its report as a duplicate (it still reports to
    /// CallKit — the PushKit mandate is one report per push — but must not arm the
    /// manual-answer fallback if CallKit refuses it). The claimer calls
    /// `finishReport` when CallKit has replied to the report, success or failure.
    func beginReport(_ uuid: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if nativelyReportedUUIDs.contains(uuid) || reportsInFlight.contains(uuid) {
            return false
        }
        reportsInFlight.insert(uuid)
        return true
    }

    /// W-GHOSTCALL — release the claim taken by `beginReport`. Idempotent. Called
    /// after `recordNativeReport` on success, so there is no instant at which the
    /// uuid is in neither set; on failure the uuid simply stops being "in flight"
    /// and a later report of it is a first report again.
    func finishReport(_ uuid: UUID) {
        lock.lock()
        defer { lock.unlock() }
        reportsInFlight.remove(uuid)
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
    /// W-RTCLOCKMIGRATE (2026-09-09) — returns whether `uuid` was actually
    /// still outstanding, i.e. whether this is the FIRST `forget` for it.
    /// `reportCallEnded` is called more than once for the same logical call
    /// end on real devices (confirmed live: two calls for the same UUID on
    /// one test call) — callers that do work meant to happen exactly once
    /// per call (like balancing an `RTCAudioSession` activate/deactivate
    /// pair) need this to avoid acting on the same call end twice.
    @discardableResult
    func forget(_ uuid: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        callKitRejectedUUIDs.remove(uuid)
        nativelyReportedUUIDs.remove(uuid)
        return outstandingUUIDs.remove(uuid) != nil
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

/// W-GHOSTCALL (2026-09-25) — whether a refused `reportNewIncomingCall` may arm
/// the in-app manual-answer fallback (`CallKitCallLedger.recordRejected`).
///
/// Arming means "CallKit never showed this call, so answer it by hand from the
/// in-app banner": `answerCall` then skips `CXAnswerCallAction` and self-activates
/// audio. That is only right when the system UI genuinely never appeared. Two
/// refusals say the opposite:
/// - this report is a duplicate of one already in flight or already up
///   (`alreadyReported`, from `CallKitCallLedger.beginReport`): the first report's
///   own outcome decides;
/// - CallKit's own reply is Code=2 `callUUIDAlreadyExists`: CallKit already HAS
///   this call, its native UI is live and answerable. Arming the fallback over it
///   is what e3acecd7 did at 15:04:03.222 (`callkit report ok=0 code=2 dup=0`,
///   then "arming in-app manual answer path" with the native UI alive), and a
///   later in-app answer would then skip the real CXAnswerCallAction.
/// Code 3 (Focus/DnD) and 4 (block list) still arm it, as before.
enum CallKitReportFailurePolicy {

    /// `CXErrorCodeIncomingCallError.callUUIDAlreadyExists`.
    static let callUUIDAlreadyExistsCode: Int = 2

    static func shouldArmManualAnswer(alreadyReported: Bool, errorCode: Int) -> Bool {
        guard !alreadyReported else { return false }
        return errorCode != callUUIDAlreadyExistsCode
    }
}
