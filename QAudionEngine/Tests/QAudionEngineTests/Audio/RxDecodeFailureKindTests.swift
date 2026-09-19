import XCTest
@testable import QAudionEngine

/// W-RXGATE (2026-09-19) — a frame that reaches the decoder before this side
/// has a session key is not a decrypt failure. See `RxDecodeFailureKind` for
/// the field call this comes from (74 of 185 frames counted as errors, a 40%
/// "loss" written into the next call's PLP, and a re-key 0.26 s after connect).
final class RxDecodeFailureKindTests: XCTestCase {

    private struct Boom: Error {}

    // MARK: - Classification

    func test_noActiveSessionIsPreSession() {
        XCTAssertEqual(RxDecodeFailureKind.classify(QAudionEngineError.noActiveSession), .preSession)
    }

    func test_everyOtherEngineErrorIsARealFailure() {
        XCTAssertEqual(RxDecodeFailureKind.classify(QAudionEngineError.notInitialized), .decrypt)
        XCTAssertEqual(RxDecodeFailureKind.classify(QAudionEngineError.malformedFrame("bad length")), .decrypt)
        XCTAssertEqual(
            RxDecodeFailureKind.classify(
                QAudionEngineError.invalidStateTransition(from: .initialized, to: .sessionActive)),
            .decrypt)
    }

    func test_nonEngineErrorsAreRealFailures() {
        // An AEAD authentication failure surfaces as a CryptoKit error, never as an engine error.
        XCTAssertEqual(RxDecodeFailureKind.classify(Boom()), .decrypt)
        XCTAssertEqual(
            RxDecodeFailureKind.classify(NSError(domain: "CryptoKit.CryptoKitError", code: 3)),
            .decrypt)
    }

    // MARK: - The real throw site

    func test_anEngineWithNoSessionThrowsSomethingClassifiedPreSession() throws {
        let frame = Data(repeating: 0x5A, count: 64)

        let fresh = QAudionEngine(config: .development())
        XCTAssertThrowsError(try fresh.processIncomingAudio(serializedFrame: frame)) { error in
            XCTAssertEqual(RxDecodeFailureKind.classify(error), .preSession)
        }

        // Initialised but no shared secret yet: the caller between sending the OFFER and processing the ACCEPT.
        let initialised = QAudionEngine(config: .development())
        try initialised.initialize()
        XCTAssertEqual(initialised.getState(), .initialized)
        XCTAssertThrowsError(try initialised.processIncomingAudio(serializedFrame: frame)) { error in
            XCTAssertEqual(RxDecodeFailureKind.classify(error), .preSession)
        }
    }

    func test_aBadFrameOnALiveSessionIsStillARealFailure() throws {
        let live = QAudionEngine(config: .development())
        try live.initialize()
        try live.initSession(sharedSecret: Data(repeating: 0x42, count: 32))
        XCTAssertEqual(live.getState(), .sessionActive)

        XCTAssertThrowsError(try live.processIncomingAudio(serializedFrame: Data(repeating: 0x5A, count: 64))) { error in
            XCTAssertEqual(RxDecodeFailureKind.classify(error), .decrypt)
        }
    }

    func test_afterTheSessionEndsFramesGoBackToPreSession() throws {
        let engine = QAudionEngine(config: .development())
        try engine.initialize()
        try engine.initSession(sharedSecret: Data(repeating: 0x42, count: 32))
        engine.destroySession()
        XCTAssertEqual(engine.getState(), .initialized)
        XCTAssertThrowsError(try engine.processIncomingAudio(serializedFrame: Data(repeating: 0x5A, count: 64))) { error in
            XCTAssertEqual(RxDecodeFailureKind.classify(error), .preSession)
        }
    }

    // MARK: - What it protects: the failure burst meter

    /// The shape of the 2026-09-19 field call: about 74 frames, 60 ms apart, all
    /// thrown before the caller's key existed. Gated the way `CallService`
    /// gates them, none of it reaches the meter, so no re-key is requested.
    func test_aPreSessionBurstNeverFiresTheRekeyTrigger() {
        let meter = AudioAeadFailureRekeyMeter()
        var fired = false
        for i in 0..<74 {
            let kind = RxDecodeFailureKind.classify(QAudionEngineError.noActiveSession)
            if kind == .decrypt, meter.noteFailure(nowMs: Int64(i) * 60) { fired = true }
        }
        XCTAssertFalse(fired)
    }

    /// The gate must not blind the real detector: a key that drifted fails
    /// every frame as an authentication error and still fires on the fifth.
    func test_aRealDecryptBurstStillFiresTheRekeyTrigger() {
        let meter = AudioAeadFailureRekeyMeter()
        var fired = false
        for i in 0..<5 {
            let kind = RxDecodeFailureKind.classify(Boom())
            if kind == .decrypt, meter.noteFailure(nowMs: Int64(i) * 60) { fired = true }
        }
        XCTAssertTrue(fired)
    }
}
