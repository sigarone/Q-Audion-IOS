import XCTest
@testable import QAudionEngine

/// W-CKMAINBLOCK (2026-09-02) — pins the pure dispatch decisions
/// `VideoCallPipeline.stop()` and `CallService.startAudioIOIfReady()` act
/// on, without a live `AVCaptureSession`/`AVAudioEngine`. Same discipline as
/// `AudioInterruptionRecoveryPolicyTests` / `RestartIceDecisionsTests`.
/// Evidence: audit memory reference_ios_stability_audit_2026_09_01, P1 (8).
final class CallKitWorkOffloadPolicyTests: XCTestCase {

    private typealias Policy = CallKitWorkOffloadPolicy

    // MARK: - Kill switch defaults

    /// The video fix mirrors an ALREADY-SHIPPED in-file pattern (`start()`'s
    /// `startRunning()` hop) — default ON. The audio fix has no such
    /// precedent and was never verified live — default OFF. Rule: any
    /// behaviour change here is deliberate; a flipped default should be a
    /// reviewed edit to this test, never a silent regression.
    func test_defaults_videoOnAudioOff() {
        XCTAssertTrue(Policy.asyncStopRunningEnabled)
        XCTAssertFalse(Policy.audioEngineBackgroundQueueEnabled)
        XCTAssertFalse(Policy.voiceProcessingTeardownQueueEnabled)
    }

    // MARK: - stopRunningDispatch

    func test_stopRunningDispatch_followsTheSwitch() {
        XCTAssertEqual(Policy.stopRunningDispatch(enabled: true), .fireAndForgetAsync)
        XCTAssertEqual(Policy.stopRunningDispatch(enabled: false), .blockingSync)
    }

    /// Calling with no argument uses the shipped default (currently ON).
    func test_stopRunningDispatch_defaultArgumentMatchesTheKillSwitch() {
        XCTAssertEqual(Policy.stopRunningDispatch(), Policy.stopRunningDispatch(enabled: Policy.asyncStopRunningEnabled))
    }

    // MARK: - audioEngineDispatch

    func test_audioEngineDispatch_followsTheSwitch() {
        XCTAssertEqual(Policy.audioEngineDispatch(enabled: true), .backgroundQueueFireAndForget)
        XCTAssertEqual(Policy.audioEngineDispatch(enabled: false), .inlineOnCallingThread)
    }

    /// Calling with no argument uses the shipped default (currently OFF —
    /// today's exact behaviour, byte-for-byte, until this is verified live).
    func test_audioEngineDispatch_defaultArgumentMatchesTheKillSwitch() {
        XCTAssertEqual(Policy.audioEngineDispatch(), .inlineOnCallingThread)
    }

    // MARK: - voiceProcessingTeardownDispatch

    func test_voiceProcessingTeardownDispatch_followsTheSwitch() {
        XCTAssertEqual(Policy.voiceProcessingTeardownDispatch(enabled: true), .fireAndForgetAsync)
        XCTAssertEqual(Policy.voiceProcessingTeardownDispatch(enabled: false), .blockingSync)
    }

    /// Calling with no argument uses the shipped default (currently OFF —
    /// today's exact behaviour, byte-for-byte, until this is verified live).
    func test_voiceProcessingTeardownDispatch_defaultArgumentMatchesTheKillSwitch() {
        XCTAssertEqual(Policy.voiceProcessingTeardownDispatch(), .blockingSync)
    }
}
