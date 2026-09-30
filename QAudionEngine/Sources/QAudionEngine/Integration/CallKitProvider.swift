import Foundation
#if canImport(CallKit) && os(iOS)
@preconcurrency import CallKit
import AVFoundation
import UIKit
import WebRTC

public final class CallKitProvider: NSObject, CallKitManaging, CXProviderDelegate, @unchecked Sendable {

    private let provider: CXProvider
    private let controller: CXCallController

    /// W-CKLEDGER (2026-09-01) — the W495 rejected/suppressed set, the
    /// W-WAKEONLY natively-reported set and the outstanding set used to be
    /// three unlocked `private var Set<UUID>` on this `@unchecked Sendable`
    /// type. Not every access is on main: this class is not `@MainActor`, so
    /// its `async` members run on the cooperative pool while
    /// `registerSuppressedCall` / `releaseFromSystemUI` / `endAllOutstanding`
    /// and the CXProviderDelegate callbacks (queue nil ⇒ main) run on the main
    /// thread — and the PushKit+WS `dup=1` report below is two pool threads
    /// mutating the same Set at once. All three now live behind one NSLock in
    /// `CallKitCallLedger` (each set's own rationale is documented there);
    /// every check-then-act below is a single atomic ledger call. See audit
    /// memory reference_ios_stability_audit_2026_09_01, P1 item 9.
    private let ledger = CallKitCallLedger()

    /// Where this type's diagnostics go. Set by the app to forward into the
    /// remote log; nil in tests and in any target that has no log sink.
    ///
    /// A closure rather than a direct call, because the engine does not — and
    /// should not — know about the app's logging stack. Same primitive-only
    /// boundary the mesh runtime keeps.
    public var log: ((String) -> Void)?
    /// Fired when the user answers. Returns whether the app ACCEPTED the answer:
    /// `false` = it refused a dead / placeholder call (W-GHOSTCALL, incident
    /// e3acecd7), in which case the provider fails the native answer action and
    /// skips the audio-session activation that normally follows, because there is
    /// no call to activate it for. A nil handler counts as accepted (the
    /// pre-existing behaviour).
    public var onAnswerCall: ((UUID) async -> Bool)?
    public var onEndCall: ((UUID) async -> Void)?
    public var onMutedChanged: ((UUID, Bool) async -> Void)?
    /// W-CKHOLD (2026-09-02) — fired from `provider(_:perform:
    /// CXSetHeldCallAction)` when the SYSTEM (not our own UI) puts this
    /// call on hold or takes it off — another CallKit call becoming
    /// active, or a Siri "hold my call" request. See B5, audit memory
    /// reference_ios_stability_audit_2026_09_01, P2: until now this action
    /// reached no delegate method at all, so CallKit's Hold button
    /// silently failed (the action was never fulfilled).
    public var onHoldChanged: ((UUID, Bool) async -> Void)?
    /// W464 — fired when CallKit has activated the shared AVAudioSession.
    /// This is the ONLY safe moment to start `AVAudioEngine` (mic capture
    /// + speaker playback). Starting the engine before this point throws
    /// "Session activation failed" and the call has no audio. AppState
    /// wires this to `CallService.handleAudioSessionActivated()`.
    ///
    /// W-ADMGATE (2026-09-26) — now carries WHO activated the session:
    /// `.callKit` from `provider(_:didActivate:)`, `.selfExpectingCallKit`
    /// from this app's own activation after a CXStart/CXAnswer action (CallKit's
    /// didActivate still expected), `.selfManaged` from an activation CallKit
    /// will never follow (suppressed/foreground answer, wake-only). Only a
    /// native-SRTP call reads it (WebRTC's own audio unit must start on a
    /// CallKit-activated session); every other consumer ignores it.
    public var onAudioSessionActivated: ((AudioSessionActivationSource) -> Void)?
    /// W464 — fired when CallKit released the audio session (call ended
    /// or interrupted). AppState wires this to
    /// `CallService.handleAudioSessionDeactivated()`.
    public var onAudioSessionDeactivated: (() -> Void)?
    /// W571 — fired when CallKit resets all calls (system-level reset).
    /// AppState wires this to tear down any active audio/video pipeline
    /// and clear call state so resources are released properly.
    public var onProviderReset: (() -> Void)?

    public override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = true
        cfg.maximumCallsPerCallGroup = 1
        cfg.maximumCallGroups = 1
        cfg.supportedHandleTypes = [.phoneNumber, .generic]
        // W571 — privacy: exclude encrypted VoIP calls from the system
        // Recents list (default = true leaks call metadata to iOS Recents
        // which may sync via iCloud). Set false for privacy by design.
        cfg.includesCallsInRecents = false
        // Note: CXProviderConfiguration has no supportsHolding property;
        // the Hold button appears when provider implements
        // provider(_:perform:CXSetHeldCallAction) (verified against Apple's
        // CXSetHeldCallAction docs, 2026-09-02) — see that method below.
        // `reportIncomingCall` also stamps `CXCallUpdate.supportsHolding`
        // explicitly rather than relying on its undocumented default.
        //
        // Custom ringtone: the bundled "qaudion_ringtone.caf" (Copy-Bundle-
        // Resources, see project.yml) plays instead of the default iOS ringtone
        // so an incoming Q-Audion call is audibly ours. iOS falls back to the
        // system ringtone automatically if the file is ever missing.
        cfg.ringtoneSound = "qaudion_ringtone.caf"
        // Brand the native call UI with the Q-Audion lock glyph (template image
        // from Assets.xcassets/CallKitGlyph — alpha defines the shape, tinted by
        // the system). Best-effort: a nil/absent asset just leaves the default.
        cfg.iconTemplateImageData = UIImage(named: "CallKitGlyph")?.pngData()
        self.provider = CXProvider(configuration: cfg)
        self.controller = CXCallController()
        super.init()
        self.provider.setDelegate(self, queue: nil)
    }

    // MARK: - CallKitManaging

    public func reportIncomingCall(uuid: UUID, callerName: String, hasVideo: Bool) async {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.hasVideo = hasVideo
        // W-CKHOLD (2026-09-02) — explicit rather than relying on
        // CXCallUpdate's default: this is what makes the native Hold
        // affordance appear at all (see `provider(_:perform:
        // CXSetHeldCallAction)` below for the handler side).
        update.supportsHolding = true
        // Tag the native (cleartext) call UI as an encrypted Q-Audion call. The
        // caller name itself is resolved from the LOCAL address book by the call
        // sites (PushKit + WS), so this only appends the security marker.
        // W-L10N-BATCH1 (2026-09-08) — this is a plain String property, not a
        // SwiftUI LocalizedStringKey, so it needs an explicit lookup; the
        // engine target has no `import UIKit`/app bundle assumption issue
        // here since String(localized:) resolves against the main app
        // bundle's own Localizable.xcstrings at runtime regardless of which
        // module the call site lives in.
        let encryptedTag = String(localized: "callkit.encrypted_tag", defaultValue: "Cifrata", comment: "Suffix appended to the caller name on the native CallKit incoming-call screen, e.g. 'Marco · 🔒 Encrypted'")
        update.localizedCallerName = callerName + " · 🔒 " + encryptedTag
        // W-CALLDIAG: every native report attempt logged (uuid + hasVideo). Two
        // reports for the same uuid ⇒ Code=2 below (the "seconda chiamata in
        // chiaro" duplicate the user sees on voice + video). The source (PushKit
        // vs WS) is logged at the call sites in AppState.
        // W-GHOSTCALL (2026-09-25) — the "am I the first report?" question is now
        // one atomic claim taken BEFORE the await (`beginReport`). It used to be a
        // plain read of the natively-reported set, which is only filled once
        // CallKit has answered: two reports of the same uuid issued in the same
        // millisecond (a doubled PushKit push, e3acecd7 03.221/03.222) both read
        // "not reported yet", so the second one's Code=2 refusal was taken for a
        // genuine rejection. The second report still goes to CallKit (one report
        // per push is the PushKit mandate); it is only labelled a duplicate.
        let claimed: Bool = ledger.beginReport(uuid)
        let alreadyUp: Bool = !claimed
        // Only the report that took the claim releases it: a duplicate that comes
        // back from CallKit first must not reopen the "first report" window while
        // the claimer is still in flight.
        defer { if claimed { ledger.finishReport(uuid) } }
        // I8 FIX — truncate the call UUID (same convention as AppState's
        // W-CALLDIAG lines for this same call) instead of printing it whole.
        print("[CallKitProvider] W-CALLDIAG reportNewIncomingCall uuid=\(uuid.uuidString.prefix(8))… hasVideo=\(hasVideo) alreadyReported=\(alreadyUp)")
        do {
            try await provider.reportNewIncomingCall(with: uuid, update: update)
            // W-WAKEONLY (native UI up) + outstanding, one atomic insert.
            let outstanding: Int = ledger.recordNativeReport(uuid)
            log?("callkit report ok=1 dup=\(alreadyUp ? 1 : 0) outstanding=\(outstanding)")
        } catch {
            // W478 — log instead of silently dropping. CallKit rejects with:
            //   Code=2 callUUIDAlreadyExists (PushKit+WS duplicate),
            //   Code=3 filteredByDoNotDisturb (Focus / DnD active on device),
            //   Code=4 filteredByBlockList.
            // Only Code=3/4 (and any first-attempt Code=2 we didn't cause
            // ourselves) mean the system call UI genuinely never appeared —
            // that is the ONLY case where arming the in-app manual-answer
            // fallback is correct. When `alreadyUp` is true this rejection is
            // OUR OWN second call (PushKit+WS both reported the same uuid):
            // the FIRST call already succeeded, a real native CallKit UI is
            // live and answerable right now. Arming the fallback here used to
            // stack the in-app ringing banner on top of that working native
            // UI — the "seconda chiamata in chiaro" the user sees, and
            // answering FROM the fallback banner did nothing because the
            // call CallKit actually knows about was reported by the other
            // branch, never latched to this banner's answer path.
            let nsErr = error as NSError
            // W-GHOSTCALL — Code=2 (callUUIDAlreadyExists) is not a rejection
            // either: CallKit already HAS this call and its native UI is live, so
            // the manual-answer fallback must not be armed over it, whichever
            // report of the uuid got the refusal. See CallKitReportFailurePolicy.
            let armFallback: Bool = CallKitReportFailurePolicy.shouldArmManualAnswer(
                alreadyReported: alreadyUp, errorCode: nsErr.code)
            // I8 FIX — truncated uuid, see above.
            print("[CallKitProvider] reportNewIncomingCall rejected (domain=\(nsErr.domain) code=\(nsErr.code)) alreadyReported=\(alreadyUp) — \(armFallback ? "arming in-app manual answer path" : "native UI already live, NOT arming fallback") for \(uuid.uuidString.prefix(8))…")
            // Numeric tail so this survives the remote-log redactor: without it
            // the whole CallKit path is invisible off-device, and a rejection
            // that costs the user an incoming call looks exactly like silence.
            log?("callkit report ok=0 code=\(nsErr.code) dup=\(alreadyUp ? 1 : 0)")
            if armFallback {
                ledger.recordRejected(uuid)
            }
        }
    }

    public func reportCallEnded(uuid: UUID, reason: CallEndReason) async {
        // W-RTCLOCKMIGRATE (2026-09-09) — balances every `activateAudioSession`
        // call. Live evidence this was missing: `RTCAudioSession.activationCount`
        // on a real device climbed 1 -> 3 across a start-then-answer pair of
        // calls (should climb by exactly 1 per call if each is balanced) —
        // `activateAudioSession` called the locked `setActive(true)` on every
        // call start/answer, but nothing ever called the matching
        // `setActive(false)` through the SAME counted API, so the count (and
        // whatever internal state WebRTC's automatic mode derives from it)
        // could only ever climb, never return to the balanced baseline a
        // fresh, single call assumes — a real candidate for why this exact
        // symptom compounds across a session and only clears on a full
        // process restart. `reportCallEnded` is the one choke point every
        // call-end path (local hangup, remote hangup, unanswered) already
        // funnels through, mirroring the two call-start paths this balances.
        //
        // W-DOUBLEDECR (2026-09-09) — the balance above shipped with its own
        // bug: `reportCallEnded` fires more than once for the same logical
        // call end on real devices (confirmed live: `activationCount` went
        // 2 -> 1 -> -1 for one call). Originally guarded with
        // `ledger.forget(uuid)`'s "was outstanding" result — WRONG signal,
        // caught by a second live test: the foreground/W520 answer path
        // (`AppState.swift`) deliberately never calls `reportIncomingCall`,
        // so `outstandingUUIDs` never has that call's uuid on the answering
        // side AT ALL — the deactivate silently never fired there, in
        // exactly the two-devices-foregrounded scenario every test tonight
        // used. `consumeAudioSelfActivation()` tracks the actual thing that
        // matters — did THIS app call the locked `setActive(true)` for the
        // current call — independent of CallKit's own native-UI bookkeeping.
        // See `CallKitCallLedger`'s kdoc for the full trace of both bugs.
        // W-DRAINACTIVATION (2026-09-10) — raw device traces from tonight's
        // live tests (two separate builds, both confirmed via unredacted
        // SSH pulls, not the Loki-redacted view) show `activationCount`
        // climbing net +1 to +2 across consecutive back-to-back calls and
        // NEVER returning to a clean 0 baseline — directly correlated with
        // the native AudioUnit's later Start() failing with CoreAudio's
        // generic 'what' error and with WebRTC's own InitPlayOrRecord
        // failing outright on the next call. Root cause: at least THREE
        // independent code paths can each increment this ONE shared
        // counter for what is logically a single call — (1) this app's own
        // explicit self-activation above, now called unconditionally after
        // every answer/start regardless of whether didActivate will also
        // fire; (2) CallKit's own native `provider(_:didActivate:)`, when
        // it DOES also fire for the same call (`audioSessionDidActivate:`
        // increments too); (3) WebRTC's own internal
        // `AudioDeviceIOS::InitPlayOrRecord`/`beginWebRTCSession:`, which
        // activates independently the moment the local audio track starts.
        // A single boolean-gated `setActive(false)` here only ever
        // balanced source (1) — sources (2) and (3) are meant to
        // self-balance via their own paired deactivate (`didDeactivate`,
        // `ShutdownPlayOrRecord`/`UnconfigureAudioSession`), but real
        // device evidence shows that pairing is not reliable enough in
        // practice for back-to-back calls to prevent a net leak.
        //
        // Fix (external second opinion sought and confirmed, given this
        // exact code path's history of three prior production regressions):
        // drain the counter fully at this one choke point instead of
        // decrementing by a fixed amount. `RTCAudioSession.setActive(false)`
        // only touches the real OS session when its own internal
        // `shouldSetActive` is true (activationCount == 1) — every extra
        // call beyond that is a documented no-op against the hardware, so
        // looping it is safe. Bounded (not `while true`) as a defensive cap
        // against a genuine future bug elsewhere holding the count up
        // indefinitely; this app's own architecture guarantees at most one
        // active 1:1 call, so nothing legitimate should still be holding
        // an activation when a call is genuinely ending. Runs entirely
        // inside the existing `lockForConfiguration`/`unlockForConfiguration`
        // pair, serializing the drain against any concurrent activation
        // (including the next call's own) the same way every other mutation
        // of this shared session already is.
        //
        // W-ADMBALANCE (2026-09-26) — native-SRTP (manual audio mode) calls
        // only: ONE locked setActive(false), balancing this app's own
        // self-activation and nothing else. In manual mode WebRTC's own
        // configure/unconfigure of the session are paired by the unit's
        // disable (CallService switches it off before the PeerConnection
        // closes) and CallKit's didDeactivate balances its own didActivate.
        // Draining those too made THIS app deactivate the real session while
        // CallKit was about to (Apple's CallKit guidance: the app must not),
        // and — with a next call already activated — deactivate that one.
        // Legacy calls keep the drain above byte-for-byte
        // (`NativeAudioUnitGateDecisions.deactivationCalls`).
        // W-ADMBALANCE-UUID (2026-09-26) — "native call" is looked up by THIS
        // report's uuid (recorded at that call's own CallKit start/answer,
        // `recordNativeBalanceIfNativeCall`), not read from a process-wide
        // flag armed by whichever PeerConnection armed last: this report runs
        // in an unawaited Task, so a NEXT native call could arm before it and
        // have its flag consumed here. Consumed once per uuid.
        // W-SELFACTID (2026-09-27) — the self-activation mark of a native call
        // is keyed by the same uuid and consumed in the same critical section:
        // the OLD call's late report used to take the NEXT call's mark (one
        // process-wide flag) and leave the next call's own activation
        // unbalanced. Calls with native SRTP off keep the process-wide flag.
        let endBalance = ledger.consumeEndBalance(uuid)
        let nativeManualCall = endBalance.nativeManualCall
        if !endBalance.selfActivated, nativeManualCall || endBalance.duplicateNative {
            let dupFlag = endBalance.duplicateNative ? 1 : 0
            log?("admgate W-SELFACTID endbal=0 dup=\(dupFlag)")
        }
        if endBalance.selfActivated {
            let rtcSession = RTCAudioSession.sharedInstance()
            rtcSession.lockForConfiguration()
            // `activationCount` is imported as Int32 (ObjC `int`) — the CI
            // build rejected passing it where Int is expected.
            let countBefore = rtcSession.activationCount
            let plannedIterations = NativeAudioUnitGateDecisions.deactivationCalls(
                activationCount: Int(countBefore), nativeManualCall: nativeManualCall)
            var drainedCount = 0
            while rtcSession.activationCount > 0 && drainedCount < plannedIterations {
                do {
                    try rtcSession.setActive(false)
                } catch {
                    print("[CallKitProvider] setActive(false) fail site=reportCallEnded iter=\(drainedCount) code=\((error as NSError).code) err=\(error.localizedDescription)")
                    break
                }
                drainedCount += 1
            }
            let countAfter = rtcSession.activationCount
            let activeAfter = rtcSession.isActive ? 1 : 0
            print("[CallKitProvider] reportCallEnded audio session drained iterations=\(drainedCount) activationCount=\(countAfter)")
            rtcSession.unlockForConfiguration()
            if nativeManualCall {
                let line = "admgate endbal=1 before=\(countBefore) iter=\(drainedCount) after=\(countAfter) act=\(activeAfter)"
                log?(line)
            }
        }
        ledger.forget(uuid)
        let cxReason: CXCallEndedReason
        switch reason {
        case .userEnded: cxReason = .remoteEnded
        case .remoteEnded: cxReason = .remoteEnded
        case .unanswered: cxReason = .unanswered
        case .declined: cxReason = .declinedElsewhere
        case .failed: cxReason = .failed
        }
        provider.reportCall(with: uuid, endedAt: Date(), reason: cxReason)
    }

    /// End every CallKit call this process still has open.
    ///
    /// The safety net for the failure that actually hurts: a call the app has
    /// finished with, still open as far as iOS is concerned. The system then
    /// treats the phone as busy and can refuse the next incoming report, so the
    /// user stops being reachable with nothing on screen to explain it. Called
    /// when the app settles into idle and when it comes back to the foreground,
    /// so the two states cannot drift for longer than that.
    ///
    /// Returns how many it had to close, which is the number worth logging: it
    /// should be zero, and a non-zero one is a path that forgot to end its call.
    @discardableResult
    public func endAllOutstanding(reason: CallEndReason = .remoteEnded) -> Int {
        // W-CKLEDGER — snapshot + clear in one critical section; the CallKit
        // reports below run on the snapshot, same set and same order as before.
        let stale: Set<UUID> = ledger.drainOutstanding()
        guard !stale.isEmpty else { return 0 }
        let cxReason: CXCallEndedReason
        switch reason {
        case .userEnded, .remoteEnded: cxReason = .remoteEnded
        case .unanswered: cxReason = .unanswered
        case .declined: cxReason = .declinedElsewhere
        case .failed: cxReason = .failed
        }
        for uuid in stale {
            provider.reportCall(with: uuid, endedAt: Date(), reason: cxReason)
        }
        log?("callkit reconcile closed=\(stale.count)")
        return stale.count
    }

    /// How many calls this process believes are still open with CallKit.
    public var outstandingCallCount: Int { ledger.outstandingCount }

    public func startOutgoingCall(handle: String, hasVideo: Bool) async throws -> UUID {
        let uuid = UUID()
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        action.isVideo = hasVideo
        let txn = CXTransaction(action: action)
        try await controller.request(txn)
        ledger.recordOutstanding(uuid)
        return uuid
    }

    public func reportCallConnected(uuid: UUID) async {
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    public func setMuted(uuid: UUID, isMuted: Bool) async throws {
        let action = CXSetMutedCallAction(call: uuid, muted: isMuted)
        try await controller.request(CXTransaction(action: action))
    }

    public func setOnHold(uuid: UUID, isOnHold: Bool) async throws {
        let action = CXSetHeldCallAction(call: uuid, onHold: isOnHold)
        try await controller.request(CXTransaction(action: action))
    }

    /// W520 — register a call UUID as "suppressed" so that answerCall() uses
    /// the manual audio-session activation path instead of going through
    /// CXCallController. Called for WS foreground incoming calls where we
    /// intentionally skip reportNewIncomingCall to avoid showing the native
    /// iOS phone UI (which looks identical to a plain voice call and would
    /// confuse users who need to distinguish encrypted calls from cleartext).
    public func registerSuppressedCall(_ uuid: UUID) {
        ledger.recordRejected(uuid)
    }

    /// W-WAKEONLY — "CallKit for wake only". After the user answers a
    /// push-woken call we dismiss the SYSTEM in-call UI (which iOS keeps on top
    /// of our window) by reporting the CallKit call ended, so the app's own SAS
    /// in-call screen becomes the call surface. The call itself stays alive in
    /// the app (sealed audio over WS/DC). `reportCall(endedAt:)` is a one-way
    /// notification — it does NOT fire `provider(_:perform:CXEndCallAction)`, so
    /// AppState.endCall() is NOT triggered and the call is not torn down. Only
    /// releases a call whose NATIVE UI was actually shown; returns whether it did
    /// (so the caller knows to switch to self-managed audio). iOS will likely
    /// fire `provider(_:didDeactivate:)` shortly after — AppState re-asserts the
    /// session there (see reactivateAudioSessionForSelfManagedCall).
    @discardableResult
    public func releaseFromSystemUI(_ uuid: UUID) -> Bool {
        // W-CKLEDGER — atomic test-and-remove: the call stays outstanding.
        guard ledger.releaseNativeReport(uuid) else { return false }
        provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        // I8 FIX — truncated uuid, see above.
        print("[CallKitProvider] W-WAKEONLY — released system call UI for \(uuid.uuidString.prefix(8))…")
        return true
    }

    /// W-WAKEONLY — re-assert the shared AVAudioSession after CallKit released
    /// its hold (we dismissed the system UI but the call is still live in-app).
    /// Reuses the proven answer-time activation (retry + fire
    /// onAudioSessionActivated → CallService restarts the engines if needed).
    ///
    /// W-SELFACTID (2026-09-27) — `uuid`: the CallKit uuid of the self-managed
    /// call, so a native-SRTP call's re-activation is marked under its own
    /// uuid (see `CallKitCallLedger.markAudioSelfActivated`). `nil` keeps the
    /// process-wide mark, as before.
    public func reactivateAudioSessionForSelfManagedCall(uuid: UUID? = nil) async {
        await activateAudioSession(logSite: "answer", source: .selfManaged, uuid: uuid)
    }

    /// Group calls v2 — the end of a group call that CallKit does not track
    /// (a foreground accept, CallKit-free mode, or a promoted group that outlived
    /// the 1:1 CallKit call it started on). Such a call self-activated the shared
    /// session with `reactivateAudioSessionForSelfManagedCall(uuid: nil)`, which
    /// marks the process-wide self-activation flag, and it has no uuid to
    /// `reportCallEnded`, so nothing ever paid the matching deactivation: the
    /// session stayed active after the call and every later call started from a
    /// skewed `activationCount` (W-DRAINACTIVATION class). This pays ONE balancing
    /// deactivation, exactly what a native call's report pays, and only when the
    /// flag says one is owed; no CXProvider report (there is no call to end).
    public func balanceSelfManagedGroupActivation() {
        // A fresh uuid is never native, so `consumeEndBalance` takes the
        // process-wide test-and-clear (true once after a self-activation).
        guard ledger.consumeEndBalance(UUID()).selfActivated else { return }
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        let countBefore = rtcSession.activationCount
        let planned = NativeAudioUnitGateDecisions.deactivationCalls(
            activationCount: Int(countBefore), nativeManualCall: true)
        var done = 0
        while rtcSession.activationCount > 0 && done < planned {
            do {
                try rtcSession.setActive(false)
            } catch {
                print("[CallKitProvider] setActive(false) fail site=groupEnd code=\((error as NSError).code)")
                break
            }
            done += 1
        }
        let countAfter = rtcSession.activationCount
        rtcSession.unlockForConfiguration()
        log?("admgate grpendbal=1 before=\(countBefore) iter=\(done) after=\(countAfter)")
    }

    /// W478 — answer an incoming call via the CallKit CXCallController.
    /// This path is triggered by the in-app answer button; it fires the same
    /// CXAnswerCallAction that the system UI button would fire, ensuring the
    /// `provider(_:perform:CXAnswerCallAction)` delegate callback runs and
    /// transitions the call to `.active` (same as tapping Answer on lock screen).
    ///
    /// W495 — if CallKit previously rejected reportNewIncomingCall for this
    /// UUID (Focus/DnD), CXCallController.request would also fail because
    /// CallKit never registered the call. In that case we fall back to a
    /// direct answer: manually activate AVAudioSession, fire
    /// onAudioSessionActivated, and call onAnswerCall directly — identical
    /// to what CXProviderDelegate would do on a successful CallKit path.
    public func answerCall(uuid: UUID) async throws {
        // W-CKLEDGER — atomic test-and-remove, so two concurrent answerCall for
        // the same uuid take the manual path once (as two sequential ones did).
        if ledger.takeRejected(uuid) {
            // W497 — mirror the EXACT order of CXProviderDelegate callbacks on
            // a normal CallKit answer:
            //   1. provider(_:perform:CXAnswerCallAction) → onAnswerCall (sets up
            //      callIntegration, WebRTC tracks, etc.)
            //   2. provider(_:didActivate:) → onAudioSessionActivated (starts
            //      AVAudioEngine capture/playback)
            //
            // The previous order (activate THEN answer) started the audio engine
            // before callIntegration existed → mic/speaker silent, level bars frozen.
            let accepted: Bool = (await onAnswerCall?(uuid)) ?? true
            // W-GHOSTCALL — refused (dead / placeholder call): nothing to activate.
            guard accepted else {
                log?("callkit answer refused=1 path=manual")
                return
            }
            recordNativeBalanceIfNativeCall(uuid)
            // W556-fix — deterministic self-activation with retry. The old
            // single `try? setActive(true)` could fail silently (swallowed) and
            // then onAudioSessionActivated() started the engine on an INACTIVE
            // session → capture.start() failed → silent call. See
            // activateAudioSession(logSite:).
            // W-ADMGATE — CallKit never registered this call: no didActivate.
            await activateAudioSession(logSite: "answer", source: .selfManaged, uuid: uuid)
            return
        }
        let action = CXAnswerCallAction(call: uuid)
        try await controller.request(CXTransaction(action: action))
    }

    /// W-ADMBALANCE-UUID (2026-09-26) — record `uuid` for `reportCallEnded`'s
    /// single balancing deactivation when THIS call runs native SRTP (manual
    /// audio mode). Called at the call's own CallKit start / answer (CallKit
    /// or manual path), where the native-SRTP decision read is this call's:
    /// an outgoing `startCall` takes its keyed snapshot before it requests
    /// the CXStartCallAction, and an incoming call latches its snapshot at
    /// `call_incoming`, before it can normally be answered. An answer that
    /// lands before `call_incoming` (push-woken call) finds no snapshot yet
    /// and reads the live value `call_incoming` is about to latch — that is
    /// what `isNativeSrtpEnabledLocally` (snapshot ?? live) returns. With the
    /// toggle off it is `false` on every path: nothing is recorded and every
    /// call end keeps the legacy drain.
    private func recordNativeBalanceIfNativeCall(_ uuid: UUID) {
        guard CallCapabilities.isNativeSrtpEnabledLocally else { return }
        ledger.recordNativeBalance(uuid)
    }

    /// W556-fix — deterministically bring the AVAudioSession to ACTIVE after the
    /// user answers, then start the audio engine via `onAudioSessionActivated`.
    ///
    /// ROOT CAUSE (device logs, build 597): for a FOREGROUND / UI-suppressed
    /// answer, CallKit does NOT call `provider(_:didActivate:)`. Apple only
    /// guarantees `didActivate` when CallKit OWNS the session AND performs an
    /// inactive→active transition; a suppressed call (no
    /// `reportNewIncomingCall`) — or a session left active by a prior call —
    /// skips it. The previous code waited for `didActivate` (never came) and a
    /// racy 0.7s timer fallback whose guard got nilled by a re-entrant
    /// duplicate `call_incoming`. Net result: the `AVAudioEngine` NEVER started
    /// → no mic TX and decrypted RX frames never played (total silence both
    /// directions — the "iPhone non sente e non trasmette nulla" bug).
    ///
    /// FIX (validated by external review): self-activate AFTER the answer is
    /// processed. `setActive(true)` can transiently fail right after the answer
    /// transaction (`cannotStartPlaying` / `cannotInterruptOthers`), so retry a
    /// few times with a short delay; only fire `onAudioSessionActivated` once
    /// the session is genuinely active so the engine start sees a live session.
    /// Idempotent: if `didActivate` DOES arrive too, `onAudioSessionActivated`
    /// re-runs harmlessly (the engine guards on its own `isRunning`).
    ///
    /// W-CKSTARTACTIVATE (2026-09-09) — this was answer-only until tonight.
    /// The exact same root cause ("a session left active by a prior call...
    /// skips [didActivate]") applies identically to the OUTGOING/caller side
    /// on a back-to-back call — live evidence: call e7e8e96a, iPad placing a
    /// call 8s after its own previous call ended, native audio-srtp's sender
    /// activates but `AVAudioSession.currentRoute.inputs.count` is 0 the
    /// whole call (`audioIO noinput=1 inp=0`), and `handleAudioSessionDeactivated`
    /// never fired even once for the prior call — CallKit kept the session
    /// continuously "active" across the gap and, on THIS path only, nothing
    /// ever re-asserted it. `provider(_:perform: CXStartCallAction)` set the
    /// category and just trusted `didActivate` to follow, with no fallback —
    /// the asymmetry itself was the bug, not a new mechanism to invent.
    /// `logSite` is cosmetic (keeps the two callers' log lines
    /// distinguishable); the retry/forward logic is identical either way.
    ///
    /// W-RTCLOCKMIGRATE (2026-09-09) — this used to mutate the raw
    /// `AVAudioSession.sharedInstance()` directly, then tell `RTCAudioSession`
    /// about it after the fact via `audioSessionDidActivate` (the "outside"
    /// notification). That channel is for genuinely-outside activation — its
    /// own header doc: "used to inform RTCAudioSession when the audio session
    /// activation state has changed outside of RTCAudioSession... when
    /// CallKit activates the audio session for the application." This
    /// function is OUR OWN app code doing the activating, not CallKit, so it
    /// was using the wrong half of the API — and the header is explicit
    /// about the right half: "Callers should not call setters on
    /// AVAudioSession directly." `RTCAudioSession` tracks its own
    /// `isActive`/`activationCount` ONLY through calls that go through its
    /// own `lockForConfiguration`/`setCategory`/`setActive` proxies; a direct
    /// `AVAudioSession.setActive(true)` is invisible to that bookkeeping
    /// regardless of any notification sent afterward. This is exactly the
    /// gap `reference_ios_callkit_webrtc_audio_activation_race_2026_09_08.md`
    /// (session memory, written the night before tonight's audio-srtp work)
    /// already named as the real fix and flagged as unimplemented: "the only
    /// architecturally sound fix is migrating EVERY session mutation... the
    /// app's own category/mode/buffer-duration calls AND the CallKit-
    /// activation relay — through the wrapper's lock." Confirmed against the
    /// actual pinned `webrtc-sdk/webrtc@m144_release` header (fetched, not
    /// assumed) before writing this. `useManualAudio` is still never touched
    /// — this is the automatic-mode-compatible half of the fix, not the
    /// 1053/1056/1066 manual-mode regression class.
    ///
    /// W-SELFACTID (2026-09-27) — `uuid`: the CallKit uuid this activation is
    /// made for; the self-activation mark of a native-SRTP call is keyed by it
    /// (see `CallKitCallLedger.markAudioSelfActivated`).
    private func activateAudioSession(logSite: String, source: AudioSessionActivationSource, uuid: UUID?) async {
        let rtcSession = RTCAudioSession.sharedInstance()
        // W-NOMIXOPTION (2026-09-10) — best-practices audit: `.interruptSpoken
        // AudioAndMixWithOthers` is Apple's documented option for apps whose
        // OWN audio is occasional and spoken over background audio
        // (navigation, exercise) — never intended for continuous full-duplex
        // telephony, and Apple's own docs say to pair it with `duckOthers`
        // "unless you have a specific reason not to", which this app never
        // did. It also asks iOS to treat the session as mixable/non-exclusive,
        // in tension with what a voice-processing (echo-cancelling) I/O unit
        // needs to do its job. The vendored WebRTC engine's own default
        // `RTCAudioSessionConfiguration` never sets it — only
        // `allowBluetoothHFP`/`allowBluetooth`. Matching that default exactly.
        #if !targetEnvironment(simulator)
        let audioOpts: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        #else
        let audioOpts: AVAudioSession.CategoryOptions = []
        #endif
        rtcSession.lockForConfiguration()
        // W-NEGATIVEFLOOR (2026-09-10) — live evidence tonight, right after
        // W-DRAINACTIVATION shipped: `activationCount` went NEGATIVE (-1)
        // between one call ending and the next starting. Confirmed from
        // WebRTC's own `RTCAudioSession.mm` source: `decrementActivationCount`
        // has NO floor at 0 — `reportCallEnded`'s drain loop correctly
        // stopped at exactly 0, but WebRTC's OWN internal deactivate
        // (`ShutdownPlayOrRecord`/`UnconfigureAudioSession`, tied to the
        // peer connection's async native teardown) fired a moment LATER,
        // after the drain had already returned, decrementing an
        // already-zeroed counter below 0 — exactly the race the drain
        // fix's own external review flagged as a residual risk. Waiting for
        // that teardown to finish first is not an option (confirmed
        // repeatedly tonight: no completion signal exists for it).
        // Symmetric fix instead: pay off any such deficit HERE, at the one
        // point every call-start path already funnels through, rather than
        // chasing the unpredictable tail end of the previous call. Same
        // safe idiom as the drain loop — `setActive(true)`'s own
        // `shouldSetActive` only depends on `!isActive`, not the exact
        // count, so redundant activate calls from a negative baseline are
        // still no-ops against real hardware beyond the first.
        if rtcSession.activationCount < 0 {
            let maxCorrectionIterations = 10
            var corrected = 0
            while rtcSession.activationCount < 0 && corrected < maxCorrectionIterations {
                do {
                    try rtcSession.setActive(true)
                } catch {
                    print("[CallKitProvider] setActive(true) floor-correction fail site=\(logSite) iter=\(corrected) code=\((error as NSError).code) err=\(error.localizedDescription)")
                    break
                }
                corrected += 1
            }
            print("[CallKitProvider] \(logSite) corrected negative activationCount iterations=\(corrected) activationCount=\(rtcSession.activationCount)")
        }
        do {
            try rtcSession.setCategory(.playAndRecord, mode: .voiceChat, options: audioOpts)
        } catch {
            // W-SIGSWALLOW (2026-09-01) — was `try?`: a refused category is
            // the first link in a silent-call chain and left no line (audit
            // memory reference_ios_stability_audit_2026_09_01, P1 item 7).
            // Flow unchanged; the setActive retry loop below still runs.
            print("[CallKitProvider] setCategory fail site=\(logSite) code=\((error as NSError).code) err=\(error.localizedDescription)")
        }
        for attempt in 0..<4 {
            // W-GHOSTCALL (2026-09-25) — take the configuration lock again for
            // every retry. It is held on entry to attempt 0 (taken above: category
            // and first setActive stay ONE critical section) and is RELEASED before
            // the wait below, because it must never be held across an `await`: the
            // lock is thread-affine and the task may resume on another thread. The
            // evidence: in e3acecd7 attempt 0 failed and attempts 1-3, run after
            // the old 120 ms sleep with the lock still nominally held, all failed
            // with code=-1 "Must call ... lockForConfiguration".
            if attempt > 0 {
                rtcSession.lockForConfiguration()
            }
            do {
                try rtcSession.setActive(true)
                print("[CallKitProvider] \(logSite) audio session ACTIVE (attempt \(attempt)) activationCount=\(rtcSession.activationCount)")
                rtcSession.unlockForConfiguration()
                // W-SELFACTIVATED (2026-09-09) — mark that this call now owes
                // a matching setActive(false), independent of whether
                // CallKit's own native UI/ledger ever heard about this call
                // (it deliberately doesn't for a foreground/W520 answer —
                // see the ledger's own kdoc for why that distinction is the
                // whole point of this flag).
                // W-SELFACTID — keyed by this call's uuid on a native call.
                ledger.markAudioSelfActivated(uuid)
                onAudioSessionActivated?(source)
                return
            } catch {
                // W-SETACTIVEFAIL (2026-09-10) — the live device trace that
                // led here showed OUR OWN setActive(true) failing with real,
                // never-before-diagnosed AVAudioSession errors ("Session
                // activation failed", "Must call ... before calling this
                // method") right as `RTCAudioSession`'s shared
                // activationCount climbed anyway from an INDEPENDENT
                // increment (WebRTC's own internal InitPlayOrRecord) —
                // exactly the state a later native AudioUnit Start() then
                // rejected with a generic CoreAudio error. Only
                // `localizedDescription` was logged before, which is
                // apparently redacted client-side for some of these
                // messages — the numeric code and the session's own
                // activationCount/isActive at the moment of failure are not.
                let nsErr = error as NSError
                print("[CallKitProvider] setActive retry \(attempt) site=\(logSite) code=\(nsErr.code) activationCount=\(rtcSession.activationCount) isActive=\(rtcSession.isActive ? 1 : 0): \(error.localizedDescription)")
                // W-GHOSTCALL — release BEFORE the await (see the top of the
                // loop): the lock must never be held across a suspension point.
                rtcSession.unlockForConfiguration()
                try? await Task.sleep(nanoseconds: 120_000_000) // 120 ms
            }
        }
        // W571 — last resort: fire onAudioSessionActivated anyway. The audio
        // engine's start() re-checks session state and surfaces real failures
        // in its own log. NOT firing here would leave the call permanently
        // silent (engine never starts). The four-retry window (480ms total)
        // covers transient system audio-session contention; a genuine session
        // failure (e.g. hardware in use by another app) will surface as
        // AudioCapture.start() throwing, which produces a user-visible log
        // and eventually a call-quality banner. This is the lesser evil vs.
        // a silent dead call.
        print("[CallKitProvider] setActive never confirmed after 4 attempts site=\(logSite) — forcing engine start (session may be marginal)")
        // W-GHOSTCALL — no unlock here any more: every failed attempt above has
        // already released the configuration lock before its wait.
        onAudioSessionActivated?(source)
    }

    // MARK: - CXProviderDelegate

    public func providerDidReset(_ provider: CXProvider) {
        // W571 — system-level reset: CallKit has invalidated all active calls.
        // Delegate cleanup to AppState so audio engine, video pipeline, and
        // network resources are released; call state is cleared to idle.
        // Omitting this caused resource leaks (audio engine, WS handlers,
        // video capture session) on system resets (rare but reproducible
        // when switching between apps that use CallKit concurrently).
        ledger.clearRejected()
        onProviderReset?()
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // W-RTCLOCKMIGRATE-2 (2026-09-10) — this was the one remaining raw
        // `AVAudioSession.sharedInstance().setCategory(...)` call in this
        // file made OUTSIDE both `provider(_:didActivate:)` (CallKit's own
        // blessed "outside" channel, forwarded via `audioSessionDidActivate`)
        // and `RTCAudioSession`'s lock — invisible to its bookkeeping
        // regardless of the locked `activateAudioSession` call moments
        // later. Found via a best-practices audit matching a pattern
        // several Apple Developer Forums threads describe: an app's own
        // AVAudioSession mutation outside both the CallKit delegate
        // callbacks and RTCAudioSession's lock can race CallKit's own
        // internal activation — silently no-op'ing it, or leaving a later
        // AudioUnit Start() blocked against a HAL state that never
        // converged. Matches two of the three failure signatures
        // reproduced live tonight. Migrated to the same locked path
        // `activateAudioSession` already uses; timing is unchanged — this
        // still runs before `reportOutgoingCall`/`fulfill()`.
        let rtcSession = RTCAudioSession.sharedInstance()
        #if !targetEnvironment(simulator)
        let audioOpts: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        #else
        let audioOpts: AVAudioSession.CategoryOptions = []
        #endif
        rtcSession.lockForConfiguration()
        do {
            try rtcSession.setCategory(.playAndRecord, mode: .voiceChat, options: audioOpts)
        } catch {
            // W-SIGSWALLOW (2026-09-01) — was `try?`; log the OSStatus, keep the flow.
            print("[CallKitProvider] setCategory fail site=start code=\((error as NSError).code) err=\(error.localizedDescription)")
        }
        rtcSession.unlockForConfiguration()
        // W-NATIVESPKR (2026-09-26) — native-SRTP calls only: start from
        // output override `.none` (reference-implementation parity).
        NativeAudioSessionGate.resetOutputOverrideForNativeCall(site: 1)
        recordNativeBalanceIfNativeCall(action.callUUID)
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        action.fulfill()
        // W-CKSTARTACTIVATE (2026-09-09) — the answer side has had this
        // exact self-activation fallback since build 597 (see
        // activateAudioSession's kdoc for the root cause it was built for);
        // this side never got it. Same asymmetry-is-the-bug reasoning
        // applies unchanged: fulfill() has already closed the start
        // transaction, so setActive(true) no longer races it.
        let startedUUID: UUID = action.callUUID
        Task {
            // W-ADMGATE — CallKit's own didActivate is still expected.
            await activateAudioSession(logSite: "start", source: .selfExpectingCallKit, uuid: startedUUID)
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // I8 FIX — truncated uuid, see above.
        print("[CallKitProvider] W-CALLFG-DIAG provider(perform: CXAnswerCallAction) ENTER uuid=\(action.callUUID.uuidString.prefix(8))…")
        Task {
            let accepted: Bool = (await onAnswerCall?(action.callUUID)) ?? true
            // W-GHOSTCALL — the app refused this answer (dead / placeholder call,
            // e3acecd7): no call exists, so the action FAILS instead of being
            // fulfilled (a fulfilled answer leaves CallKit believing the stale
            // call is answered and active, and able to put a live call on hold),
            // and the audio session is not activated for it.
            guard accepted else {
                action.fail()
                log?("callkit answer refused=1 path=native")
                return
            }
            action.fulfill()
            print("[CallKitProvider] W-CALLFG-DIAG provider(perform: CXAnswerCallAction) — onAnswerCall done, action.fulfill() called uuid=\(action.callUUID.uuidString.prefix(8))…")
            // W-NATIVESPKR (2026-09-26) — native-SRTP calls only.
            NativeAudioSessionGate.resetOutputOverrideForNativeCall(site: 2)
            recordNativeBalanceIfNativeCall(action.callUUID)
            // W556-fix — guarantee the engine starts even if CallKit never
            // calls provider(_:didActivate:) (the foreground-answer case). Safe
            // to self-activate AFTER fulfill: the answer transaction is closed,
            // so setActive(true) no longer hits the "session activation failed"
            // race. Idempotent with didActivate if it does arrive.
            // W-ADMGATE — CallKit's own didActivate is still expected.
            await activateAudioSession(logSite: "answer", source: .selfExpectingCallKit, uuid: action.callUUID)
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task {
            await onEndCall?(action.callUUID)
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task {
            await onMutedChanged?(action.callUUID, action.isMuted)
            action.fulfill()
        }
    }

    /// W-CKHOLD (2026-09-02) — B5: the system (another CallKit call
    /// becoming active, or Siri) places THIS call on/off hold. Previously
    /// unimplemented, so CallKit's own Hold action was requested and never
    /// fulfilled or failed — it just silently timed out, and audio/video
    /// kept flowing while the system UI believed the call was held.
    /// Mirrors the shape of every other `perform` handler in this file:
    /// hand the UUID + new hold state to the app layer, then fulfill.
    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        Task {
            await onHoldChanged?(action.callUUID, action.isOnHold)
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // W464 — keep these options in sync with
        // AudioProcessingPipeline.configureForVoIP(): if CallKit installs
        // a poorer category (e.g. no .defaultToSpeaker) it silently
        // downgrades the routing the app just configured.
        // W-NOMIXOPTION (2026-09-10) — see `activateAudioSession`'s own kdoc;
        // kept in sync per this method's own W464 comment above.
        #if !targetEnvironment(simulator)
        let audioOpts: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        #else
        let audioOpts: AVAudioSession.CategoryOptions = []
        #endif
        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: audioOpts)
        } catch {
            // W-SIGSWALLOW (2026-09-01) — was `try?`; log the OSStatus, keep the flow.
            print("[CallKitProvider] setCategory fail site=didActivate code=\((error as NSError).code) err=\(error.localizedDescription)")
        }
        do {
            try audioSession.setActive(true)
        } catch {
            // W-SIGSWALLOW — same: `onAudioSessionActivated` still fires so
            // the engine start surfaces the real failure in its own log.
            print("[CallKitProvider] setActive fail site=didActivate code=\((error as NSError).code) err=\(error.localizedDescription)")
        }
        // W-CKAUDIOFORWARD (2026-09-09) — this delegate callback IS CallKit
        // telling us the session just activated; forward it to WebRTC's
        // audio session the same way activateAudioSession(logSite:) above
        // does for the self-activation path, so both routes into an active
        // session reach WebRTC identically. useManualAudio is untouched.
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        // W464 — the session is now active: this is the moment
        // CallService may safely start its AVAudioEngine capture/playback.
        onAudioSessionActivated?(.callKit)
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // W-CKAUDIOFORWARD (2026-09-09) — symmetric with the activate side;
        // WebRTC's audio session needs to hear this deactivation too, not
        // just this app's own onAudioSessionDeactivated flag flip.
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        // System took the audio session — engine should pause mic capture.
        onAudioSessionDeactivated?()
    }
}
#endif
