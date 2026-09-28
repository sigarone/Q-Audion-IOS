import XCTest
@testable import QAudionEngine

/// W-MEDIAATACCEPT (option b) — §10 (I9): a crash while merely RINGING (no
/// PeerConnection built yet under option b) must not count toward the
/// native-SRTP crash streak; only `pc`/`media` (and the one-release
/// `snapshot` grandfather case) do.
final class CrashGuardDecisionsTests: XCTestCase {

    private func context(inCall: Bool = true, native: Bool = true, phase: String?) -> String {
        var s = "in_call=" + (inCall ? "1" : "0") + " native=" + (native ? "1" : "0")
        if let phase = phase { s += " phase=" + phase }
        return s
    }

    func testRingPhaseDoesNotCount() {
        XCTAssertFalse(CrashGuardDecisions.countsTowardStreak(context: context(phase: "ring")))
    }

    func testPcPhaseCounts() {
        XCTAssertTrue(CrashGuardDecisions.countsTowardStreak(context: context(phase: "pc")))
    }

    func testMediaPhaseCounts() {
        XCTAssertTrue(CrashGuardDecisions.countsTowardStreak(context: context(phase: "media")))
    }

    func testSnapshotPhaseCountsAsOneReleaseGrandfather() {
        XCTAssertTrue(CrashGuardDecisions.countsTowardStreak(context: context(phase: "snapshot")))
    }

    func testMissingPhaseTokenDoesNotCount() {
        // A context persisted by a build even older than `phase` itself.
        XCTAssertFalse(CrashGuardDecisions.countsTowardStreak(context: context(phase: nil)))
    }

    func testNotInCallNeverCounts() {
        XCTAssertFalse(CrashGuardDecisions.countsTowardStreak(context: context(inCall: false, phase: "pc")))
    }

    func testNonNativeNeverCounts() {
        XCTAssertFalse(CrashGuardDecisions.countsTowardStreak(context: context(native: false, phase: "pc")))
    }

    func testPhaseParsingIgnoresOtherTokens() {
        let ctx = "in_call=1 native=1 role=callee call8=abcd1234 phase=media"
        XCTAssertEqual(CrashGuardDecisions.phase(fromContext: ctx), .media)
    }

    func testUnrecognizedPhaseValueDoesNotCount() {
        XCTAssertFalse(CrashGuardDecisions.countsTowardStreak(context: context(phase: "bogus")))
    }

    // MARK: - shouldResetCrashStreakAtCallEnd (G6)

    func testResetRequiresAllThreeConditions() {
        XCTAssertTrue(CrashGuardDecisions.shouldResetCrashStreakAtCallEnd(
            nativeSnapshot: true, ended: true, reachedMedia: true))
    }

    func testResetSkippedWhenNotNative() {
        XCTAssertFalse(CrashGuardDecisions.shouldResetCrashStreakAtCallEnd(
            nativeSnapshot: false, ended: true, reachedMedia: true))
    }

    func testResetSkippedWhenTeardownDidNotOwnTheSnapshot() {
        XCTAssertFalse(CrashGuardDecisions.shouldResetCrashStreakAtCallEnd(
            nativeSnapshot: true, ended: false, reachedMedia: true))
    }

    func testResetSkippedWhenMediaNeverReached() {
        // A call that only rang/built its PC and was cancelled proves
        // nothing about the native path — must NOT reset the streak.
        XCTAssertFalse(CrashGuardDecisions.shouldResetCrashStreakAtCallEnd(
            nativeSnapshot: true, ended: true, reachedMedia: false))
    }
}
