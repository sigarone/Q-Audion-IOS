import XCTest
@testable import QAudionEngine

/// 2026-09-19 service-message root fix — the settled-frames memory (a consumed
/// frame is never decrypted twice) and the CONTROL failure quorum (one failed
/// frame never drops a healthy session).
final class SettledFrameSetTests: XCTestCase {

    func test_defaultCapacity_is512() {
        XCTAssertEqual(SettledFrameSet.defaultCapacity, 512)
        XCTAssertEqual(SettledFrameSet().capacity, 512)
    }

    func test_containsWhatWasInserted_only() {
        var set = SettledFrameSet()
        XCTAssertFalse(set.contains("a"))
        set.insert("a")
        XCTAssertTrue(set.contains("a"))
        XCTAssertFalse(set.contains("b"))
        XCTAssertEqual(set.count, 1)
    }

    func test_insertIsIdempotent() {
        var set = SettledFrameSet()
        set.insert("a"); set.insert("a"); set.insert("a")
        XCTAssertEqual(set.count, 1)
    }

    func test_evictsTheOldestKeyFirst() {
        var set = SettledFrameSet(capacity: 3)
        for key in ["a", "b", "c", "d"] { set.insert(key) }
        XCTAssertFalse(set.contains("a"))
        XCTAssertTrue(set.contains("b"))
        XCTAssertTrue(set.contains("c"))
        XCTAssertTrue(set.contains("d"))
        XCTAssertEqual(set.count, 3)
    }

    func test_reinsertingDoesNotRefreshItsPosition() {
        var set = SettledFrameSet(capacity: 2)
        set.insert("a"); set.insert("b")
        set.insert("a")
        set.insert("c")
        XCTAssertFalse(set.contains("a"), "a stayed the oldest, so it is the one evicted")
        XCTAssertTrue(set.contains("b"))
        XCTAssertTrue(set.contains("c"))
    }

    func test_capacityIsAtLeastOne() {
        var set = SettledFrameSet(capacity: 0)
        set.insert("a"); set.insert("b")
        XCTAssertEqual(set.capacity, 1)
        XCTAssertEqual(set.count, 1)
        XCTAssertTrue(set.contains("b"))
    }

    func test_frameKeys_serverIdAndSenderScopedClientId() {
        var set = SettledFrameSet()
        set.insertFrame(serverMessageId: "srv-1", senderId: "alice", clientMsgId: "cmid-1", includeClientKey: true)
        XCTAssertTrue(set.containsFrame(serverMessageId: "srv-1", senderId: "alice", clientMsgId: nil))
        XCTAssertTrue(set.containsFrame(serverMessageId: "srv-2", senderId: "alice", clientMsgId: "cmid-1"),
                      "the same client_msg_id from the same sender is the same frame")
        XCTAssertFalse(set.containsFrame(serverMessageId: "srv-2", senderId: "bob", clientMsgId: "cmid-1"),
                       "another sender's UUID must never collide into a drop")
        XCTAssertFalse(set.containsFrame(serverMessageId: "srv-2", senderId: "alice", clientMsgId: nil))
        XCTAssertFalse(set.containsFrame(serverMessageId: "srv-2", senderId: "alice", clientMsgId: ""))
    }

    func test_placeholderSettlesOnlyTheServerId_soTheResendGetsThrough() {
        var set = SettledFrameSet()
        set.insertFrame(serverMessageId: "srv-1", senderId: "alice", clientMsgId: "cmid-1", includeClientKey: false)
        XCTAssertTrue(set.containsFrame(serverMessageId: "srv-1", senderId: "alice", clientMsgId: "cmid-1"),
                      "the failed frame itself is settled")
        XCTAssertFalse(set.containsFrame(serverMessageId: "srv-2", senderId: "alice", clientMsgId: "cmid-1"),
                       "the resend has a new server id and must NOT be swallowed")
    }

    func test_keyShapes_areStable() {
        XCTAssertEqual(SettledFrameSet.serverKey("x"), "s:x")
        XCTAssertEqual(SettledFrameSet.clientKey(senderId: "a", clientMsgId: "c"), "c:a:c")
    }
    func test_emptyServerId_isNeverASharedKey() {
        var set = SettledFrameSet()
        set.insertFrame(serverMessageId: "", senderId: "peer", clientMsgId: nil, includeClientKey: false)
        XCTAssertEqual(set.count, 0, "an empty server id settles nothing")
        XCTAssertFalse(set.containsFrame(serverMessageId: "", senderId: "peer", clientMsgId: nil))
        set.insertFrame(serverMessageId: "srv-1", senderId: "peer", clientMsgId: nil, includeClientKey: false)
        XCTAssertFalse(set.containsFrame(serverMessageId: "", senderId: "peer", clientMsgId: nil))
    }
}

final class ControlFailureTrackerTests: XCTestCase {

    func test_constants() {
        XCTAssertEqual(ControlFailureTracker.quorum, 3)
        XCTAssertEqual(ControlFailureTracker.windowMs, 120_000)
        XCTAssertEqual(ControlFailureTracker.cooldownMs, 600_000)
    }

    func test_aSingleFailedFrame_neverTriggersARepair() {
        var t = ControlFailureTracker()
        XCTAssertFalse(t.record(peerId: "p", frameId: "f1", nowMs: 0))
    }

    func test_twoDistinctFrames_stillNoRepair() {
        var t = ControlFailureTracker()
        XCTAssertFalse(t.record(peerId: "p", frameId: "f1", nowMs: 0))
        XCTAssertFalse(t.record(peerId: "p", frameId: "f2", nowMs: 1_000))
    }

    func test_threeDistinctFramesInTheWindow_triggerARepair_once() {
        var t = ControlFailureTracker()
        XCTAssertFalse(t.record(peerId: "p", frameId: "f1", nowMs: 0))
        XCTAssertFalse(t.record(peerId: "p", frameId: "f2", nowMs: 10_000))
        XCTAssertTrue(t.record(peerId: "p", frameId: "f3", nowMs: 20_000))
        // The log is reset and the cooldown holds: three more failures do nothing.
        XCTAssertFalse(t.record(peerId: "p", frameId: "f4", nowMs: 21_000))
        XCTAssertFalse(t.record(peerId: "p", frameId: "f5", nowMs: 22_000))
        XCTAssertFalse(t.record(peerId: "p", frameId: "f6", nowMs: 23_000))
    }

    func test_theSameFrameRepeated_countsOnce() {
        var t = ControlFailureTracker()
        for i in 0..<10 {
            XCTAssertFalse(t.record(peerId: "p", frameId: "same", nowMs: Int64(i) * 1_000))
        }
    }

    func test_failuresOutsideTheWindow_areForgotten() {
        var t = ControlFailureTracker()
        XCTAssertFalse(t.record(peerId: "p", frameId: "f1", nowMs: 0))
        XCTAssertFalse(t.record(peerId: "p", frameId: "f2", nowMs: 50_000))
        // f1 is now 130 s old (window is 120 s): only f2 and f3 count.
        XCTAssertFalse(t.record(peerId: "p", frameId: "f3", nowMs: 130_000))
    }

    func test_repairIsAllowedAgainAfterTheCooldown() {
        var t = ControlFailureTracker()
        _ = t.record(peerId: "p", frameId: "f1", nowMs: 0)
        _ = t.record(peerId: "p", frameId: "f2", nowMs: 1)
        XCTAssertTrue(t.record(peerId: "p", frameId: "f3", nowMs: 2))
        let later = ControlFailureTracker.cooldownMs + 100
        XCTAssertFalse(t.record(peerId: "p", frameId: "g1", nowMs: later))
        XCTAssertFalse(t.record(peerId: "p", frameId: "g2", nowMs: later + 1))
        XCTAssertTrue(t.record(peerId: "p", frameId: "g3", nowMs: later + 2))
    }

    func test_peersAreTrackedIndependently() {
        var t = ControlFailureTracker()
        XCTAssertFalse(t.record(peerId: "a", frameId: "f1", nowMs: 0))
        XCTAssertFalse(t.record(peerId: "b", frameId: "f2", nowMs: 1))
        XCTAssertFalse(t.record(peerId: "a", frameId: "f3", nowMs: 2))
        XCTAssertFalse(t.record(peerId: "b", frameId: "f4", nowMs: 3))
        XCTAssertTrue(t.record(peerId: "a", frameId: "f5", nowMs: 4))
        // b has its own log (f2, f4, f6) and no cooldown of its own.
        XCTAssertTrue(t.record(peerId: "b", frameId: "f6", nowMs: 5))
    }

    func test_aSuccessfulOpen_forgetsTheFailures() {
        var t = ControlFailureTracker()
        _ = t.record(peerId: "p", frameId: "f1", nowMs: 0)
        _ = t.record(peerId: "p", frameId: "f2", nowMs: 1)
        t.recordSuccess(peerId: "p")
        XCTAssertFalse(t.record(peerId: "p", frameId: "f3", nowMs: 2))
        XCTAssertFalse(t.record(peerId: "p", frameId: "f4", nowMs: 3))
    }

    // MARK: - isEvidence: which failed frames may count towards the quorum

    func test_isEvidence_aBacklogReplayIsNeverEvidence() {
        XCTAssertFalse(ControlFailureTracker.isEvidence(
            arrivedLive: false, serverTimestampMs: 10_000, sessionInstalledAtMs: 1_000, nowMs: 20_000))
        XCTAssertFalse(ControlFailureTracker.isEvidence(
            arrivedLive: false, serverTimestampMs: nil, sessionInstalledAtMs: nil, nowMs: 20_000))
    }

    func test_isEvidence_aFrameSealedBeforeTheInstall_isNotEvidence() {
        XCTAssertFalse(ControlFailureTracker.isEvidence(
            arrivedLive: true, serverTimestampMs: 999, sessionInstalledAtMs: 1_000, nowMs: 5_000),
            "sealed before this session existed here: it fails by construction")
    }

    func test_isEvidence_aFrameSealedAtOrAfterTheInstall_isEvidence() {
        XCTAssertTrue(ControlFailureTracker.isEvidence(
            arrivedLive: true, serverTimestampMs: 1_000, sessionInstalledAtMs: 1_000, nowMs: 5_000))
        XCTAssertTrue(ControlFailureTracker.isEvidence(
            arrivedLive: true, serverTimestampMs: 2_000, sessionInstalledAtMs: 1_000, nowMs: 5_000))
    }

    func test_isEvidence_withoutAServerTimestamp_aFreshSessionGetsTheBenefitOfTheDoubt() {
        let installed: Int64 = 1_000
        XCTAssertFalse(ControlFailureTracker.isEvidence(
            arrivedLive: true, serverTimestampMs: nil, sessionInstalledAtMs: installed,
            nowMs: installed + ControlFailureTracker.windowMs - 1))
        XCTAssertTrue(ControlFailureTracker.isEvidence(
            arrivedLive: true, serverTimestampMs: nil, sessionInstalledAtMs: installed,
            nowMs: installed + ControlFailureTracker.windowMs))
    }

    func test_isEvidence_aSessionThisLaunchNeverInstalled_countsLiveFrames() {
        XCTAssertTrue(ControlFailureTracker.isEvidence(
            arrivedLive: true, serverTimestampMs: 5, sessionInstalledAtMs: nil, nowMs: 10))
        XCTAssertTrue(ControlFailureTracker.isEvidence(
            arrivedLive: true, serverTimestampMs: nil, sessionInstalledAtMs: nil, nowMs: 10))
    }

    func test_staleFramesNeverReachTheQuorum_soAHealthySessionIsNotDropped() {
        var t = ControlFailureTracker()
        let installedAt: Int64 = 100_000
        // A dozen replayed / pre-install frames, filtered the way the app filters them.
        for i in 0..<12 {
            let counts = ControlFailureTracker.isEvidence(
                arrivedLive: i % 2 == 0, serverTimestampMs: installedAt - 1_000 - Int64(i),
                sessionInstalledAtMs: installedAt, nowMs: installedAt + 5_000)
            XCTAssertFalse(counts)
            if counts { _ = t.record(peerId: "p", frameId: "stale\(i)", nowMs: installedAt + 5_000) }
        }
        // Nothing was recorded: the quorum still needs three genuine failures.
        XCTAssertFalse(t.record(peerId: "p", frameId: "live1", nowMs: installedAt + 6_000))
        XCTAssertFalse(t.record(peerId: "p", frameId: "live2", nowMs: installedAt + 7_000))
        XCTAssertTrue(t.record(peerId: "p", frameId: "live3", nowMs: installedAt + 8_000))
    }
}
