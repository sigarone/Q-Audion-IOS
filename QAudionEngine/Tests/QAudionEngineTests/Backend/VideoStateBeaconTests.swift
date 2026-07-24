import XCTest
@testable import QAudionEngine

/// WIRE_SPEC §8.9 — the beacon's ordering rules, pinned. Mirrors Android's
/// `VideoStateBeaconTest.kt` and Desktop's `VideoStateBeacon.spec.ts` case for
/// case.
///
/// These are the properties that make a REPEATED announcement safe. Get any of
/// them wrong and the beacon turns from a self-heal into a new way to strand a
/// lane, which is worse than the edge-only scheme it replaces.
final class VideoStateBeaconTests: XCTestCase {

    // MARK: - Last-writer-wins

    func testFirstNumberedAnnouncementIsAccepted() {
        XCTAssertTrue(VideoStateBeacon.shouldAccept(lastSeq: nil, incomingSeq: 1))
    }

    func testNewerSeqAcceptedOlderOrEqualDropped() {
        XCTAssertTrue(VideoStateBeacon.shouldAccept(lastSeq: 4, incomingSeq: 5))
        XCTAssertFalse(VideoStateBeacon.shouldAccept(lastSeq: 4, incomingSeq: 4))
        XCTAssertFalse(VideoStateBeacon.shouldAccept(lastSeq: 4, incomingSeq: 3))
    }

    /// The reordering case the seq exists for: a stale repeat (seq 2) arriving
    /// AFTER a fresh toggle (seq 3) must not resurrect the old lane value.
    /// Without this the heartbeat itself becomes a source of stuck lanes.
    func testDelayedRepeatCannotOverwriteNewerToggle() {
        var last: Int?
        for incoming in [2, 3, 2] where VideoStateBeacon.shouldAccept(lastSeq: last, incomingSeq: incoming) {
            last = VideoStateBeacon.nextStoredSeq(lastSeq: last, acceptedSeq: incoming)
        }
        XCTAssertEqual(last, 3)
        XCTAssertFalse(VideoStateBeacon.shouldAccept(lastSeq: last, incomingSeq: 2))
    }

    // MARK: - Interop with a peer that has not shipped the beacon

    func testLegacyPeerOmittingSeqIsAlwaysAccepted() {
        XCTAssertTrue(VideoStateBeacon.shouldAccept(lastSeq: nil, incomingSeq: nil))
        XCTAssertTrue(VideoStateBeacon.shouldAccept(lastSeq: 9, incomingSeq: nil))
    }

    /// A seq-less announcement must not reset the accepted window: if it did, a
    /// numbered repeat that had already been superseded would be let back in
    /// right after any legacy event.
    func testSeqlessAnnouncementLeavesTheWindowIntact() {
        let after = VideoStateBeacon.nextStoredSeq(lastSeq: 7, acceptedSeq: nil)
        XCTAssertEqual(after, 7)
        XCTAssertFalse(VideoStateBeacon.shouldAccept(lastSeq: after, incomingSeq: 6))
    }

    func testStoredSeqNeverMovesBackwards() {
        XCTAssertEqual(VideoStateBeacon.nextStoredSeq(lastSeq: 7, acceptedSeq: 3), 7)
        XCTAssertEqual(VideoStateBeacon.nextStoredSeq(lastSeq: 7, acceptedSeq: 8), 8)
        XCTAssertEqual(VideoStateBeacon.nextStoredSeq(lastSeq: nil, acceptedSeq: 2), 2)
    }

    // MARK: - Outbound numbering

    func testAdvanceStartsAtFirstSeqAndStrictlyIncreases() {
        XCTAssertEqual(VideoStateBeacon.advance(0), VideoStateBeacon.firstSeq)
        var seq = 0
        var prev = 0
        for _ in 0..<50 {
            seq = VideoStateBeacon.advance(seq)
            XCTAssertGreaterThan(seq, prev, "seq must strictly increase")
            prev = seq
        }
    }

    // MARK: - Announce trigger

    func testChangeAnnouncesAndUnchangedOnlyWhenForced() {
        XCTAssertTrue(VideoStateBeacon.shouldAnnounce(lastAnnouncedSending: false, sending: true, force: false))
        XCTAssertFalse(VideoStateBeacon.shouldAnnounce(lastAnnouncedSending: true, sending: true, force: false))
        // The heartbeat/reconnect path: repeating an unchanged value IS the point.
        XCTAssertTrue(VideoStateBeacon.shouldAnnounce(lastAnnouncedSending: true, sending: true, force: true))
    }

    func testNothingAnnouncedYetAlwaysAnnounces() {
        XCTAssertTrue(VideoStateBeacon.shouldAnnounce(lastAnnouncedSending: nil, sending: false, force: false))
    }

    // MARK: - The decisive property

    /// A dropped announcement must not be able to strand the lane: whatever the
    /// receiver last saw, the NEXT heartbeat carrying the true value is
    /// accepted and converges. Checked over the whole (lastSeen, truth) space
    /// rather than hand-picked cases, because the failure this replaces was
    /// precisely a case nobody thought to pick.
    func testEveryHeartbeatConvergesReceiverOntoSenderTruth() {
        for lastSeq in [nil, 1, 2, 5, 99] as [Int?] {
            for truth in [true, false] {
                let hb = (lastSeq ?? 0) + 1
                XCTAssertTrue(
                    VideoStateBeacon.shouldAccept(lastSeq: lastSeq, incomingSeq: hb),
                    "heartbeat seq=\(hb) must be accepted over lastSeq=\(String(describing: lastSeq))"
                )
                XCTAssertTrue(
                    VideoStateBeacon.shouldAnnounce(lastAnnouncedSending: truth, sending: truth, force: true),
                    "heartbeat must be emitted regardless of the unchanged value"
                )
            }
        }
    }
}
