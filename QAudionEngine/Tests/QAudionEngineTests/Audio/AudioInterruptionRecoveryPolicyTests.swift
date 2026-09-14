import XCTest
@testable import QAudionEngine

/// W-AUDIORESUME + W-MEDIARESET + W-AUDIOBEACON (2026-09-01) — pins the pure
/// in-call audio lifecycle decisions `AudioCapture` acts on, without a live
/// `AVAudioSession`. Same discipline as `RestartIceDecisionsTests` /
/// `GroupDecoderMemoryPressureDecisionsTests`. Evidence for every branch:
/// audit memory reference_ios_stability_audit_2026_09_01, P1 (1)/(2).
final class AudioInterruptionRecoveryPolicyTests: XCTestCase {

    private typealias Policy = AudioInterruptionRecoveryPolicy
    private typealias Beacon = AudioEngineStateBeacon

    // MARK: - Constants and kill switches

    /// The ladder is 1 s then 3 s from `.ended`, bounded to exactly two
    /// retries. Rollback of the whole behaviour is the two flags below.
    func test_constants_matchTheDocumentedLadderAndDefaults() {
        XCTAssertEqual(Policy.resumeRetryOffsetsMs, [1_000, 3_000])
        XCTAssertEqual(Policy.maxResumeAttempts, 2)
        XCTAssertTrue(Policy.resumeWithoutHintEnabled)
        XCTAssertTrue(Policy.mediaServicesResetRebuildEnabled)
        XCTAssertTrue(Beacon.enabled)
        XCTAssertEqual(Beacon.intervalSec, 10)
    }

    // MARK: - Retry schedule

    /// Delays are relative to the previous attempt so the retries land on
    /// the absolute 1 s / 3 s offsets: 1000 ms, then 2000 ms, then give up.
    func test_retryDelays_landOnAbsoluteOffsetsThenGiveUp() {
        XCTAssertEqual(Policy.resumeRetryDelayMs(attemptIndex: 0), 1_000)
        XCTAssertEqual(Policy.resumeRetryDelayMs(attemptIndex: 1), 2_000)
        XCTAssertNil(Policy.resumeRetryDelayMs(attemptIndex: 2))
        XCTAssertNil(Policy.resumeRetryDelayMs(attemptIndex: 99))
    }

    /// A negative index is a caller error, never "retry forever".
    func test_retryDelays_negativeIndexIsExhausted() {
        XCTAssertNil(Policy.resumeRetryDelayMs(attemptIndex: -1))
    }

    /// The schedule tracks the offsets table, not copied literals — and a
    /// non-monotonic table can never produce a negative delay.
    func test_retryDelays_followCustomOffsets() {
        XCTAssertEqual(Policy.resumeRetryDelayMs(attemptIndex: 0, offsetsMs: [500, 700, 4_000]), 500)
        XCTAssertEqual(Policy.resumeRetryDelayMs(attemptIndex: 1, offsetsMs: [500, 700, 4_000]), 200)
        XCTAssertEqual(Policy.resumeRetryDelayMs(attemptIndex: 2, offsetsMs: [500, 700, 4_000]), 3_300)
        XCTAssertNil(Policy.resumeRetryDelayMs(attemptIndex: 3, offsetsMs: [500, 700, 4_000]))
        XCTAssertEqual(Policy.resumeRetryDelayMs(attemptIndex: 1, offsetsMs: [3_000, 1_000]), 0)
        XCTAssertNil(Policy.resumeRetryDelayMs(attemptIndex: 0, offsetsMs: []))
    }

    // MARK: - Interruption ended

    /// The happy path is untouched: `.shouldResume` means resume now, for
    /// every owner and regardless of the kill switch.
    func test_ended_withHint_resumesNow_forEveryOwner() {
        XCTAssertEqual(Policy.interruptionEndedAction(shouldResumeHint: true, ownership: .voiceCall), .resumeNow)
        XCTAssertEqual(Policy.interruptionEndedAction(shouldResumeHint: true, ownership: .passive), .resumeNow)
        XCTAssertEqual(
            Policy.interruptionEndedAction(shouldResumeHint: true, ownership: .voiceCall, resumeWithoutHint: false),
            .resumeNow)
    }

    /// THE BUG: no hint during a voice call used to be a permanent dead
    /// engine (AudioCapture.swift:2081 at audit time). Now: bounded retry.
    func test_ended_withoutHint_inVoiceCall_retriesLater() {
        XCTAssertEqual(Policy.interruptionEndedAction(shouldResumeHint: false, ownership: .voiceCall), .retryLater)
    }

    /// The non-call case (enrollment / unlock / group fallback) stays exactly
    /// as it was: no resume without a hint.
    func test_ended_withoutHint_passiveOwner_ignores() {
        XCTAssertEqual(Policy.interruptionEndedAction(shouldResumeHint: false, ownership: .passive), .ignore)
    }

    /// Kill switch off = the pre-2026-09-01 behaviour for the call case too.
    func test_ended_withoutHint_killSwitchOff_ignores() {
        XCTAssertEqual(
            Policy.interruptionEndedAction(shouldResumeHint: false, ownership: .voiceCall, resumeWithoutHint: false),
            .ignore)
    }

    // MARK: - Hinted resume threw

    func test_hintedResumeFailed_inVoiceCall_retriesLater() {
        XCTAssertEqual(Policy.hintedResumeFailedAction(ownership: .voiceCall), .retryLater)
    }

    func test_hintedResumeFailed_passiveOrDisabled_ignores() {
        XCTAssertEqual(Policy.hintedResumeFailedAction(ownership: .passive), .ignore)
        XCTAssertEqual(Policy.hintedResumeFailedAction(ownership: .voiceCall, resumeWithoutHint: false), .ignore)
    }

    // MARK: - Media services reset

    /// Running capture: rebuild through the existing restart machine (which
    /// arms the anti-thrash suppress window itself).
    func test_mediaReset_runningCapture_rebuildsEngine() {
        XCTAssertEqual(Policy.mediaServicesResetAction(isRunning: true), .rebuildEngine)
    }

    /// Not running (mid-interruption / ladder pending): only forget the
    /// session configuration; the next start() reconfigures.
    func test_mediaReset_notRunning_invalidatesSessionOnly() {
        XCTAssertEqual(Policy.mediaServicesResetAction(isRunning: false), .invalidateSessionOnly)
    }

    func test_mediaReset_killSwitchOff_ignores() {
        XCTAssertEqual(Policy.mediaServicesResetAction(isRunning: true, enabled: false), .ignore)
        XCTAssertEqual(Policy.mediaServicesResetAction(isRunning: false, enabled: false), .ignore)
    }

    // MARK: - Beacon gating and ages

    /// Only a voice-call capture beacons; everything else is byte-identical
    /// to before (no timer, no lines).
    func test_beacon_runsOnlyForVoiceCallOwner() {
        XCTAssertTrue(Beacon.shouldRun(ownership: .voiceCall))
        XCTAssertFalse(Beacon.shouldRun(ownership: .passive))
        XCTAssertFalse(Beacon.shouldRun(ownership: .voiceCall, enabled: false))
    }

    func test_beacon_ageSeconds_neverAndFloorAndClamp() {
        XCTAssertEqual(Beacon.ageSeconds(lastAtMs: 0, nowMs: 50_000), Beacon.neverSeconds)
        XCTAssertEqual(Beacon.neverSeconds, -1)
        XCTAssertEqual(Beacon.ageSeconds(lastAtMs: 47_500, nowMs: 50_000), 2)
        XCTAssertEqual(Beacon.ageSeconds(lastAtMs: 50_000, nowMs: 50_000), 0)
        // A clock read slightly before the writer's store must never go negative.
        XCTAssertEqual(Beacon.ageSeconds(lastAtMs: 50_100, nowMs: 50_000), 0)
        // Clamp: the token must stay under the redactor's blob threshold forever.
        XCTAssertEqual(Beacon.maxAgeSeconds, 99_999)
        XCTAssertEqual(Beacon.ageSeconds(lastAtMs: 1, nowMs: 9_000_000_000), Beacon.maxAgeSeconds)
    }

    // MARK: - Beacon line shape

    private func sample(mic: Int64 = 0, play: Int64 = 0, restarts: Int = 0) -> Beacon.Snapshot {
        Beacon.Snapshot(engineRunning: true, captureRunning: true, voiceProcessingActive: true,
                        otherAudioPlaying: false, outputRouteCode: Beacon.routeCodeSpeaker,
                        inputRouteCode: Beacon.routeCodeBuiltInMic, micAgeSeconds: mic,
                        playoutAgeSeconds: play, interrupted: false, engineRestarts: restarts)
    }

    /// The exact line, pinned: a dashboard query keys on these tokens.
    func test_beacon_line_exactFormat() {
        XCTAssertEqual(
            Beacon.line(sample()),
            "audiobeacon eng=1 run=1 vpio=1 other=0 out=2 in=10 mic_s=0 ply_s=0 intr=0 rst=0")
        let dead = Beacon.Snapshot(engineRunning: false, captureRunning: false, voiceProcessingActive: false,
                                   otherAudioPlaying: true, outputRouteCode: Beacon.routeCodeNone,
                                   inputRouteCode: Beacon.routeCodeNone, micAgeSeconds: Beacon.neverSeconds,
                                   playoutAgeSeconds: 37, interrupted: true, engineRestarts: 3)
        XCTAssertEqual(
            Beacon.line(dead),
            "audiobeacon eng=0 run=0 vpio=0 other=1 out=-1 in=-1 mic_s=-1 ply_s=37 intr=1 rst=3")
    }

    /// The remote-log redactor blobs any 12+ char `[A-Za-z0-9+/=_-]` run and
    /// drops bracketed prefixes — which is exactly why no `[AudioCapture]`
    /// line has ever reached Loki. Every token of the beacon must stay under
    /// that limit even at extreme values, and there must be no prefix.
    func test_beacon_line_everyTokenSurvivesTheRedactor() {
        let extreme = sample(mic: Beacon.maxAgeSeconds, play: Beacon.maxAgeSeconds, restarts: 9_999)
        for line in [Beacon.line(sample()), Beacon.line(extreme)] {
            XCTAssertFalse(line.hasPrefix("["), line)
            for token in line.split(separator: " ") {
                XCTAssertLessThanOrEqual(token.count, Beacon.maxTokenLength, "token too long for the redactor: \(token)")
            }
        }
    }

    /// The route legend is a stable wire contract for the dashboard: pin it.
    func test_beacon_routeLegend_isStable() {
        XCTAssertEqual(Beacon.routeCodeNone, -1)
        XCTAssertEqual(Beacon.routeCodeOther, 0)
        XCTAssertEqual(Beacon.routeCodeReceiver, 1)
        XCTAssertEqual(Beacon.routeCodeSpeaker, 2)
        XCTAssertEqual(Beacon.routeCodeWired, 3)
        XCTAssertEqual(Beacon.routeCodeBluetoothHFP, 4)
        XCTAssertEqual(Beacon.routeCodeBluetoothA2DP, 5)
        XCTAssertEqual(Beacon.routeCodeBluetoothLE, 6)
        XCTAssertEqual(Beacon.routeCodeCarAudio, 7)
        XCTAssertEqual(Beacon.routeCodeAirPlay, 8)
        XCTAssertEqual(Beacon.routeCodeUsb, 9)
        XCTAssertEqual(Beacon.routeCodeBuiltInMic, 10)
    }
}
