import Foundation
#if canImport(CallKit) && os(iOS)
@preconcurrency import CallKit
import AVFoundation
import UIKit

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
    public var onAnswerCall: ((UUID) async -> Void)?
    public var onEndCall: ((UUID) async -> Void)?
    public var onMutedChanged: ((UUID, Bool) async -> Void)?
    /// W464 — fired when CallKit has activated the shared AVAudioSession.
    /// This is the ONLY safe moment to start `AVAudioEngine` (mic capture
    /// + speaker playback). Starting the engine before this point throws
    /// "Session activation failed" and the call has no audio. AppState
    /// wires this to `CallService.handleAudioSessionActivated()`.
    public var onAudioSessionActivated: (() -> Void)?
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
        // provider(_:perform:CXSetHeldCallAction). Since we implement
        // setOnHold() via CXCallController, hold is available but
        // signaling-layer hold/resume is a no-op — acceptable.
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
        // Tag the native (cleartext) call UI as an encrypted Q-Audion call. The
        // caller name itself is resolved from the LOCAL address book by the call
        // sites (PushKit + WS), so this only appends the security marker.
        update.localizedCallerName = callerName + " · 🔒 Cifrata"
        // W-CALLDIAG: every native report attempt logged (uuid + hasVideo). Two
        // reports for the same uuid ⇒ Code=2 below (the "seconda chiamata in
        // chiaro" duplicate the user sees on voice + video). The source (PushKit
        // vs WS) is logged at the call sites in AppState.
        let alreadyUp: Bool = ledger.isNativelyReported(uuid)
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
            // I8 FIX — truncated uuid, see above.
            print("[CallKitProvider] reportNewIncomingCall rejected (domain=\(nsErr.domain) code=\(nsErr.code)) alreadyReported=\(alreadyUp) — \(alreadyUp ? "native UI already live, NOT arming fallback" : "arming in-app manual answer path") for \(uuid.uuidString.prefix(8))…")
            // Numeric tail so this survives the remote-log redactor: without it
            // the whole CallKit path is invisible off-device, and a rejection
            // that costs the user an incoming call looks exactly like silence.
            log?("callkit report ok=0 code=\(nsErr.code) dup=\(alreadyUp ? 1 : 0)")
            if !alreadyUp {
                ledger.recordRejected(uuid)
            }
        }
    }

    public func reportCallEnded(uuid: UUID, reason: CallEndReason) async {
        // W495 + W-WAKEONLY — clean up every ledger entry on call end.
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
    public func reactivateAudioSessionForSelfManagedCall() async {
        await activateAudioSessionForAnswer()
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
            await onAnswerCall?(uuid)
            // W556-fix — deterministic self-activation with retry. The old
            // single `try? setActive(true)` could fail silently (swallowed) and
            // then onAudioSessionActivated() started the engine on an INACTIVE
            // session → capture.start() failed → silent call. See
            // activateAudioSessionForAnswer().
            await activateAudioSessionForAnswer()
            return
        }
        let action = CXAnswerCallAction(call: uuid)
        try await controller.request(CXTransaction(action: action))
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
    private func activateAudioSessionForAnswer() async {
        let session = AVAudioSession.sharedInstance()
        #if !targetEnvironment(simulator)
        let audioOpts: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .interruptSpokenAudioAndMixWithOthers]
        #else
        let audioOpts: AVAudioSession.CategoryOptions = [.interruptSpokenAudioAndMixWithOthers]
        #endif
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: audioOpts)
        } catch {
            // W-SIGSWALLOW (2026-09-01) — was `try?`: a refused category is
            // the first link in a silent-call chain and left no line (audit
            // memory reference_ios_stability_audit_2026_09_01, P1 item 7).
            // Flow unchanged; the setActive retry loop below still runs.
            print("[CallKitProvider] setCategory fail site=answer code=\((error as NSError).code) err=\(error.localizedDescription)")
        }
        for attempt in 0..<4 {
            do {
                try session.setActive(true)
                print("[CallKitProvider] answer audio session ACTIVE (attempt \(attempt))")
                onAudioSessionActivated?()
                return
            } catch {
                print("[CallKitProvider] setActive retry \(attempt): \(error.localizedDescription)")
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
        print("[CallKitProvider] setActive never confirmed after 4 attempts — forcing engine start (session may be marginal)")
        onAudioSessionActivated?()
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
        let audioSession = AVAudioSession.sharedInstance()
        #if !targetEnvironment(simulator)
        let audioOpts: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .interruptSpokenAudioAndMixWithOthers]
        #else
        let audioOpts: AVAudioSession.CategoryOptions = [.interruptSpokenAudioAndMixWithOthers]
        #endif
        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: audioOpts)
        } catch {
            // W-SIGSWALLOW (2026-09-01) — was `try?`; log the OSStatus, keep the flow.
            print("[CallKitProvider] setCategory fail site=start code=\((error as NSError).code) err=\(error.localizedDescription)")
        }
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // I8 FIX — truncated uuid, see above.
        print("[CallKitProvider] W-CALLFG-DIAG provider(perform: CXAnswerCallAction) ENTER uuid=\(action.callUUID.uuidString.prefix(8))…")
        Task {
            await onAnswerCall?(action.callUUID)
            action.fulfill()
            print("[CallKitProvider] W-CALLFG-DIAG provider(perform: CXAnswerCallAction) — onAnswerCall done, action.fulfill() called uuid=\(action.callUUID.uuidString.prefix(8))…")
            // W556-fix — guarantee the engine starts even if CallKit never
            // calls provider(_:didActivate:) (the foreground-answer case). Safe
            // to self-activate AFTER fulfill: the answer transaction is closed,
            // so setActive(true) no longer hits the "session activation failed"
            // race. Idempotent with didActivate if it does arrive.
            await activateAudioSessionForAnswer()
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

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // W464 — keep these options in sync with
        // AudioProcessingPipeline.configureForVoIP(): if CallKit installs
        // a poorer category (e.g. no .defaultToSpeaker) it silently
        // downgrades the routing the app just configured.
        #if !targetEnvironment(simulator)
        let audioOpts: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .interruptSpokenAudioAndMixWithOthers]
        #else
        let audioOpts: AVAudioSession.CategoryOptions = [.interruptSpokenAudioAndMixWithOthers]
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
        // W464 — the session is now active: this is the moment
        // CallService may safely start its AVAudioEngine capture/playback.
        onAudioSessionActivated?()
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // System took the audio session — engine should pause mic capture.
        onAudioSessionDeactivated?()
    }
}
#endif
