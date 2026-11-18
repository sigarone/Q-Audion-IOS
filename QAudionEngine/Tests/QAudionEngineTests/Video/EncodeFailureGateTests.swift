import XCTest
@testable import QAudionEngine

/// The encode-failure gate: a refused frame rebuilds the session at most once per interval and only while armed, and
/// logs once per episode.
final class EncodeFailureGateTests: XCTestCase {

    private let invalid = HevcEncoder.EncoderError.encodeFailed(EncodeFailureGate.invalidSessionStatus)

    func testInvalidSessionAsksForARebuildOncePerInterval() {
        let gate = EncodeFailureGate()
        gate.arm()
        XCTAssertEqual(gate.noteFailure(invalid, nowMs: 10_000), EncodeFailureGate.Decision(recreate: true, log: true))
        // The same episode, inside the interval: no second rebuild, no second log line.
        XCTAssertEqual(gate.noteFailure(invalid, nowMs: 10_033), EncodeFailureGate.Decision(recreate: false, log: false))
        XCTAssertEqual(gate.noteFailure(invalid, nowMs: 10_999), EncodeFailureGate.Decision(recreate: false, log: false))
        // The interval passed and the frames still fail: another rebuild, still no new log line.
        XCTAssertEqual(gate.noteFailure(invalid, nowMs: 11_000), EncodeFailureGate.Decision(recreate: true, log: false))
    }

    func testAnAcceptedFrameEndsTheEpisode() {
        let gate = EncodeFailureGate()
        gate.arm()
        XCTAssertTrue(gate.noteFailure(invalid, nowMs: 1_000).log)
        gate.noteSuccess()
        XCTAssertTrue(gate.noteFailure(invalid, nowMs: 5_000).log)
    }

    func testNothingIsRebuiltWhileDisarmed() {
        let gate = EncodeFailureGate()
        XCTAssertFalse(gate.noteFailure(invalid, nowMs: 1_000).recreate)
        gate.arm()
        gate.disarm()
        XCTAssertFalse(gate.noteFailure(invalid, nowMs: 9_000).recreate)
    }

    func testOtherFailuresNeverRebuild() {
        let gate = EncodeFailureGate()
        gate.arm()
        let other: [Error] = [
            HevcEncoder.EncoderError.encodeFailed(-12902),
            HevcEncoder.EncoderError.sessionCreateFailed(EncodeFailureGate.invalidSessionStatus),
            HevcEncoder.EncoderError.prepareFailed(EncodeFailureGate.invalidSessionStatus),
            NSError(domain: "test", code: Int(EncodeFailureGate.invalidSessionStatus))
        ]
        for (index, failure) in other.enumerated() {
            XCTAssertFalse(gate.noteFailure(failure, nowMs: Int64(index) * 5_000).recreate)
        }
    }

    func testAMissingSessionIsRebuiltOnlyAfterAFailedRebuild() {
        let gate = EncodeFailureGate()
        gate.arm()
        let missing = HevcEncoder.EncoderError.sessionNotInitialised
        // A frame that meets a session another thread is replacing does not start a second rebuild.
        XCTAssertFalse(gate.noteFailure(missing, nowMs: 1_000).recreate)
        XCTAssertTrue(gate.noteFailure(invalid, nowMs: 2_000).recreate)
        gate.noteRecreateResult(succeeded: false)
        XCTAssertFalse(gate.noteFailure(missing, nowMs: 2_500).recreate)
        XCTAssertTrue(gate.noteFailure(missing, nowMs: 3_000).recreate)
        gate.noteRecreateResult(succeeded: true)
        XCTAssertFalse(gate.noteFailure(missing, nowMs: 9_000).recreate)
    }

    func testARefusalWithOnlyAResultCodeRebuildsOnlyWhenRebuildable() {
        let gate = EncodeFailureGate()
        gate.arm()
        XCTAssertEqual(gate.noteRefusal(rebuildable: false, nowMs: 1_000), EncodeFailureGate.Decision(recreate: false, log: true))
        XCTAssertEqual(gate.noteRefusal(rebuildable: true, nowMs: 1_010), EncodeFailureGate.Decision(recreate: true, log: false))
        XCTAssertEqual(gate.noteRefusal(rebuildable: true, nowMs: 1_900), EncodeFailureGate.Decision(recreate: false, log: false))
        XCTAssertEqual(gate.noteRefusal(rebuildable: true, nowMs: 2_010), EncodeFailureGate.Decision(recreate: true, log: false))
        gate.disarm()
        XCTAssertFalse(gate.noteRefusal(rebuildable: true, nowMs: 9_000).recreate)
    }
}
