import Foundation

/// W-CKMAINBLOCK (2026-09-02) — pure decisions for how CallKit-triggered
/// audio-engine / camera work is scheduled relative to the main thread.
///
/// Evidence: audit memory `reference_ios_stability_audit_2026_09_01`, P1 (8)
/// — `CXProvider.setDelegate(self, queue: nil)` puts EVERY
/// `CXProviderDelegate` callback on the MAIN queue (Apple docs,
/// `setDelegate(_:queue:)`: "If nil, delegate methods are performed on the
/// main queue"). That is ONE shared serial queue for every delegate method,
/// so a later CallKit action (mute, end call, a second answer) is stuck
/// behind whichever earlier callback is still running — a delegate-triggered
/// call that blocks the main thread for long enough starves every
/// subsequently-delivered CallKit action too, and long enough risks the
/// system watchdog (0x8badf00d). Two concrete blocking points were found on
/// this exact call chain (`CallKitProvider` → `CallService`/
/// `VideoCallPipeline` → `AudioCapture`/`AudioProcessingPipeline`):
///   - `setVoiceProcessingEnabled` observed to block (see
///     `AudioProcessingPipeline`'s W-GRPVPIO-CRASH-5 comment).
///   - `AVCaptureSession.stopRunning()` — Apple's own doc: "This method is
///     synchronous and blocks until the session stops running completely."
///
/// These types decide ONLY whether/how to offload the blocking call; they
/// own no queue, no engine and no capture session — `CallService` and
/// `VideoCallPipeline` do the actual dispatch, same split as
/// `AudioInterruptionRecoveryPolicy` vs `AudioCapture`.
public enum CallKitWorkOffloadPolicy {

    // MARK: - Kill switches (compile-time)

    /// W-CKMAINBLOCK-VIDEO — `VideoCallPipeline.stop()` used to call
    /// `captureQueue.sync { session.stopRunning() }`, blocking the CALLING
    /// thread (main, when `stop()` runs from a CallKit-triggered teardown —
    /// e.g. `providerDidReset` → `onProviderReset` → `videoPipeline?.stop()`,
    /// or the normal end-call path) for however long the camera HAL takes to
    /// physically stop. `start()` in the SAME file already avoids the
    /// equivalent block for `startRunning()` (`captureQueue.async` +
    /// `withCheckedContinuation`, see that file's W565 comment, itself
    /// quoting this same Apple guidance). This mirrors that ALREADY-SHIPPED
    /// pattern for the paired stop operation — no new queue, no new thread
    /// touching `captureSession` (`captureQueue` already owns every
    /// mutation, and is serial, so ordering against a later `setupSession()`
    /// or `start()` is preserved) — so default = new behaviour (pure fix,
    /// no known risk). `false` restores the exact old synchronous-wait
    /// behaviour.
    public static let asyncStopRunningEnabled: Bool = true

    /// W-CKMAINBLOCK-AUDIO — whether `CallService` starts the 1:1
    /// `AudioCapture` `AVAudioEngine` on a dedicated background queue
    /// (diagnostics logged from that same queue — `RTLog`/`print` are both
    /// safe off-main) instead of inline on whatever thread called
    /// `startAudioIOIfReady()` (main, via `CallKitProvider`'s
    /// `onAudioSessionActivated` closure ⇐ `didActivate`). UNLIKE the video
    /// fix above, this has NO existing in-file/in-class precedent for a
    /// background queue, and `AudioCapture`/`AudioProcessingPipeline` were
    /// never audited for concurrent access from two different call-site
    /// threads at once (this one + the existing main-thread callers:
    /// `handleCallAnswered`, `activateIncomingCallAudio`, the W469 fallback
    /// timers). Default OFF — the mechanism is real and tested, but
    /// unverified live; flip only after confirming on a device (see the
    /// "da provare su device" list in the commit/report for this item).
    public static let audioEngineBackgroundQueueEnabled: Bool = false

    // MARK: - Pure decisions

    /// What `VideoCallPipeline.stop()` should do with `stopRunning()`.
    public enum StopRunningDispatch: Equatable {
        /// Today's behaviour: block the caller until the session physically
        /// stops.
        case blockingSync
        /// Queue the stop and return immediately; `captureQueue`'s FIFO
        /// order still runs it before any later session mutation.
        case fireAndForgetAsync
    }

    public static func stopRunningDispatch(
        enabled: Bool = asyncStopRunningEnabled
    ) -> StopRunningDispatch {
        enabled ? .fireAndForgetAsync : .blockingSync
    }

    /// What `CallService.startAudioIOIfReady()` should do with the
    /// `AudioCapture.start()` call.
    public enum AudioEngineDispatch: Equatable {
        /// Today's behaviour: run inline, on whatever thread called in.
        case inlineOnCallingThread
        /// Run on a dedicated background queue; no result is awaited by the
        /// caller. `RTLog` hops back to `@MainActor` internally for the
        /// success/failure diagnostics, so this needs no completion handler
        /// of its own — the "completion" the CallKit-delegate pattern calls
        /// for is that internal hop, not a callback threaded through here.
        case backgroundQueueFireAndForget
    }

    public static func audioEngineDispatch(
        enabled: Bool = audioEngineBackgroundQueueEnabled
    ) -> AudioEngineDispatch {
        enabled ? .backgroundQueueFireAndForget : .inlineOnCallingThread
    }
}
