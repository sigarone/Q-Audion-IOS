import Foundation

/// W-AUDIORESUME + W-MEDIARESET + W-AUDIOBEACON (2026-09-01) — pure decision
/// helpers for `AudioCapture`'s in-call audio-session lifecycle. Evidence:
/// audit memory `reference_ios_stability_audit_2026_09_01`, P1 (1)/(2) —
/// an iOS call lost audio in the background while the process stayed alive
/// for 80 s and NOTHING in the shipped logs could say whether the engine was
/// running, which route it was on, or when the mic last delivered a frame;
/// `AudioCapture.handleInterruption` (`.ended` without `.shouldResume`)
/// returned without ever trying to resume, and
/// `AVAudioSession.mediaServicesWereResetNotification` was not observed at
/// all (only a comment in `VideoCallPipeline.swift` mentioned it).
///
/// These types contain NO AVFoundation / engine state so every number and
/// branch below is pinned by `AudioInterruptionRecoveryPolicyTests` without
/// a live audio session — same discipline as `RestartIceDecisions` /
/// `GroupDecoderMemoryPressureDecisions`. `AudioCapture` owns the actual
/// timers, notifications and engine rebuilds; this file only decides.
public enum AudioInterruptionRecoveryPolicy {

    // MARK: - Session ownership

    /// Who owns the audio session an `AudioCapture` instance runs under.
    ///
    /// `.passive` is the default and is byte-for-byte today's behaviour:
    /// voice enrollment, voice unlock and the group-call fallback capture
    /// never set anything and keep giving up on an interruption that ends
    /// without a resume hint. `.voiceCall` is set by the 1:1 `CallService`
    /// on its own capture: for the duration of a call the audio session
    /// belongs to the app (CallKit or not), so an interruption ending without
    /// `.shouldResume` — the OS's "I'm not sure you want it back" hint, not a
    /// prohibition — is worth a bounded retry rather than a silent dead call.
    public enum SessionOwnership: Equatable {
        case passive
        case voiceCall
    }

    // MARK: - Kill switches (compile-time, default = new behaviour)

    /// W-AUDIORESUME — retry the resume after an interruption that ended
    /// WITHOUT `.shouldResume` (or whose hinted resume threw) while a voice
    /// call owns the session. Rollback is this line going back to `false`:
    /// `interruptionEndedAction` then returns `.ignore` for the no-hint
    /// case exactly as the pre-2026-09-01 code did.
    public static let resumeWithoutHintEnabled: Bool = true

    /// W-MEDIARESET — rebuild the engine and re-run the session
    /// configuration when the media server resets under a running capture.
    /// `false` restores the old "not observed at all" behaviour.
    public static let mediaServicesResetRebuildEnabled: Bool = true

    // MARK: - Resume retry schedule

    /// Absolute offsets, measured from the interruption `.ended`
    /// notification, at which a resume is retried: 1 s, then 3 s. Bounded on
    /// purpose — after the last one the call is declared audio-lost and a
    /// diagnostic line is emitted (see `AudioCapture.scheduleResumeRetry`).
    /// The first retry is not immediate because the session that just got
    /// handed back is frequently still being torn down by the interrupting
    /// app; the second is the last chance before the peer's media-dead
    /// watchdog would fire anyway.
    public static let resumeRetryOffsetsMs: [Int64] = [1_000, 3_000]

    /// How many retries the schedule above allows before giving up.
    public static var maxResumeAttempts: Int { resumeRetryOffsetsMs.count }

    /// Delay before retry number `attemptIndex` (0-based), measured from the
    /// PREVIOUS retry (or from the `.ended` notification for the first one),
    /// so the retries land on the absolute offsets of `offsetsMs`. `nil`
    /// means the schedule is exhausted — give up and report audio lost. A
    /// negative index is a caller error and is treated as exhausted rather
    /// than as "retry forever".
    public static func resumeRetryDelayMs(attemptIndex: Int,
                                          offsetsMs: [Int64] = resumeRetryOffsetsMs) -> Int64? {
        guard attemptIndex >= 0, attemptIndex < offsetsMs.count else { return nil }
        let previous: Int64 = attemptIndex == 0 ? 0 : offsetsMs[attemptIndex - 1]
        return max(0, offsetsMs[attemptIndex] - previous)
    }

    // MARK: - Interruption ended

    /// What `AudioCapture.handleInterruption` does on `.ended`.
    ///   - `.resumeNow`   — the OS said `.shouldResume`: today's happy path,
    ///                      untouched (immediate `start()`).
    ///   - `.ignore`      — no hint and nobody owns the session for a call
    ///                      (or the kill switch is off): today's behaviour.
    ///   - `.retryLater`  — no hint but a voice call owns the session: start
    ///                      the bounded 1 s / 3 s ladder.
    public enum InterruptionEndedAction: Equatable {
        case resumeNow
        case ignore
        case retryLater
    }

    public static func interruptionEndedAction(
        shouldResumeHint: Bool,
        ownership: SessionOwnership,
        resumeWithoutHint: Bool = resumeWithoutHintEnabled
    ) -> InterruptionEndedAction {
        if shouldResumeHint { return .resumeNow }
        guard resumeWithoutHint, ownership == .voiceCall else { return .ignore }
        return .retryLater
    }

    /// What to do when the HINTED resume (`.shouldResume` present) threw from
    /// `start()`. Today that was a single `print` and a permanently dead
    /// engine — the W-AUDIODEATH failure class, reached from the one path
    /// W-AUDIODEATH's ladder did not cover. Under a voice call it joins the
    /// same bounded ladder; everywhere else it stays a print.
    public enum ResumeFailureAction: Equatable {
        case ignore
        case retryLater
    }

    public static func hintedResumeFailedAction(
        ownership: SessionOwnership,
        resumeWithoutHint: Bool = resumeWithoutHintEnabled
    ) -> ResumeFailureAction {
        guard resumeWithoutHint, ownership == .voiceCall else { return .ignore }
        return .retryLater
    }

    // MARK: - Media services reset

    /// What `AudioCapture` does on `AVAudioSession.mediaServicesWereReset`.
    /// After a reset every audio object is orphaned and the session
    /// configuration is gone, so:
    ///   - `.rebuildEngine`          — capture is running: invalidate the
    ///     session configuration (so the next `start()` re-runs
    ///     setCategory/setActive) and go through the EXISTING route-restart
    ///     machine (`restartEngineForRoute`, which arms the same
    ///     anti-thrash suppress window and the W-AUDIODEATH recovery ladder).
    ///   - `.invalidateSessionOnly`  — capture is not running (mid-
    ///     interruption, or a recovery ladder attempt is pending): just
    ///     invalidate the configuration; whichever path calls `start()`
    ///     next (interruption `.ended`, the ladder) reconfigures.
    ///   - `.ignore`                 — kill switch off.
    public enum MediaServicesResetAction: Equatable {
        case rebuildEngine
        case invalidateSessionOnly
        case ignore
    }

    public static func mediaServicesResetAction(
        isRunning: Bool,
        enabled: Bool = mediaServicesResetRebuildEnabled
    ) -> MediaServicesResetAction {
        guard enabled else { return .ignore }
        return isRunning ? .rebuildEngine : .invalidateSessionOnly
    }
}

/// W-AUDIOBEACON (2026-09-01) — the periodic engine-state line `AudioCapture`
/// prints every `intervalSec` while a voice-call capture is alive, so a
/// background audio loss becomes diagnosable from the remote logs (it was
/// not on 2026-09-01: the process was alive for 80 s and no shipped line
/// said whether the engine was). Rides the EXISTING transport — `print()` →
/// `RuntimeLogSink` stdout tee (level info, tag "stdout") → ship-ios-logs
/// → Loki — no new channel.
///
/// The line is deliberately prefix-free and every token is short: the
/// remote-log redactor (`scripts/ship-ios-logs.py`, `RE_RESIDUAL_B64` /
/// `RE_BASE64_BLOB`) blobs or drops ANY run of 12+ `[A-Za-z0-9+/=_-]`
/// characters, which is why every `[AudioCapture] W-XXXX: …` line this file
/// has ever printed arrives as nothing at all (verified against the real
/// redactor: `"[AudioCapture] W-AUDIODEATH: engine recovered on attempt 1"`
/// → dropped). `maxTokenLength` pins that constraint in the tests.
public enum AudioEngineStateBeacon {

    /// Kill switch. `false` = no timer is ever armed.
    public static let enabled: Bool = true

    /// Beacon cadence. 10 s is coarse enough to be free on the main queue
    /// (one route read + a handful of integer reads) and fine enough to
    /// bracket a loss to within one server-side media-dead window.
    public static let intervalSec: Int = 10

    /// Longest token the redactor lets through untouched (12+ is blobbed).
    public static let maxTokenLength: Int = 11

    /// Sentinel age for "never happened" (no mic / playout frame yet).
    public static let neverSeconds: Int64 = -1

    /// Ages are clamped here (27.7 h) so `key=` + digits can never reach the
    /// redactor's 12-char blob threshold — verified: `play_s=86400` (12
    /// chars) was blobbed by the real redactor, `mic_s=86400` (11) was not.
    public static let maxAgeSeconds: Int64 = 99_999

    // Output/input route legend (numeric on purpose — port names are
    // free words to the redactor). Mapped from `AVAudioSession.Port` in
    // `AudioCapture.routeCode(for:)`.
    public static let routeCodeNone: Int = -1
    public static let routeCodeOther: Int = 0
    public static let routeCodeReceiver: Int = 1
    public static let routeCodeSpeaker: Int = 2
    public static let routeCodeWired: Int = 3
    public static let routeCodeBluetoothHFP: Int = 4
    public static let routeCodeBluetoothA2DP: Int = 5
    public static let routeCodeBluetoothLE: Int = 6
    public static let routeCodeCarAudio: Int = 7
    public static let routeCodeAirPlay: Int = 8
    public static let routeCodeUsb: Int = 9
    public static let routeCodeBuiltInMic: Int = 10

    /// Only a voice-call capture beacons; enrollment / unlock / group
    /// fallback captures stay byte-for-byte as they were (no timer, no
    /// extra lines).
    public static func shouldRun(ownership: AudioInterruptionRecoveryPolicy.SessionOwnership,
                                 enabled: Bool = enabled) -> Bool {
        enabled && ownership == .voiceCall
    }

    /// Whole seconds since `lastAtMs` (monotonic ms), or `neverSeconds`
    /// when `lastAtMs` is 0 (nothing recorded yet). Never negative, clamped
    /// to `maxAgeSeconds`.
    public static func ageSeconds(lastAtMs: Int64, nowMs: Int64) -> Int64 {
        guard lastAtMs > 0 else { return neverSeconds }
        return min(maxAgeSeconds, max(0, nowMs - lastAtMs) / 1_000)
    }

    /// One sample of the engine state, as read by `AudioCapture` on its
    /// owning (main) queue.
    public struct Snapshot: Equatable {
        public let engineRunning: Bool        // `AVAudioEngine.isRunning` of the live engine (false if nil)
        public let captureRunning: Bool       // `AudioCapture.isRunning` (our own flag)
        public let voiceProcessingActive: Bool
        public let otherAudioPlaying: Bool    // `AVAudioSession.isOtherAudioPlaying`
        public let outputRouteCode: Int
        public let inputRouteCode: Int
        public let micAgeSeconds: Int64       // since the tap last delivered a buffer
        public let playoutAgeSeconds: Int64   // since a frame was last handed to the player node
        public let interrupted: Bool          // between `.began` and `.ended`
        public let engineRestarts: Int        // canonical per-call restart counter

        public init(engineRunning: Bool, captureRunning: Bool, voiceProcessingActive: Bool,
                    otherAudioPlaying: Bool, outputRouteCode: Int, inputRouteCode: Int,
                    micAgeSeconds: Int64, playoutAgeSeconds: Int64, interrupted: Bool,
                    engineRestarts: Int) {
            self.engineRunning = engineRunning
            self.captureRunning = captureRunning
            self.voiceProcessingActive = voiceProcessingActive
            self.otherAudioPlaying = otherAudioPlaying
            self.outputRouteCode = outputRouteCode
            self.inputRouteCode = inputRouteCode
            self.micAgeSeconds = micAgeSeconds
            self.playoutAgeSeconds = playoutAgeSeconds
            self.interrupted = interrupted
            self.engineRestarts = engineRestarts
        }
    }

    /// The log line. Built token by token (no inline `+` chains at a
    /// `print` site — CLAUDE.md lesson 13) so the caller prints ONE string.
    public static func line(_ s: Snapshot) -> String {
        var parts: [String] = []
        parts.append("audiobeacon")
        parts.append("eng=" + flag(s.engineRunning))
        parts.append("run=" + flag(s.captureRunning))
        parts.append("vpio=" + flag(s.voiceProcessingActive))
        parts.append("other=" + flag(s.otherAudioPlaying))
        parts.append("out=" + String(s.outputRouteCode))
        parts.append("in=" + String(s.inputRouteCode))
        parts.append("mic_s=" + String(s.micAgeSeconds))
        parts.append("ply_s=" + String(s.playoutAgeSeconds))
        parts.append("intr=" + flag(s.interrupted))
        parts.append("rst=" + String(s.engineRestarts))
        return parts.joined(separator: " ")
    }

    private static func flag(_ value: Bool) -> String {
        value ? "1" : "0"
    }
}
