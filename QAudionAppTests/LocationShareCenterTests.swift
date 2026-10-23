import XCTest
@testable import QAudionApp
import QAudionEngine

/// The sender side of `LocationShareCenter` end to end, with the socket, the permission, the rows, the journal and the stop replaced by
/// fakes (`LocationCenterFixture`; WIRE_SPEC 14.6.1): no frame and no stop before the echo of the start, one frame per tick and never
/// closer than ten seconds, the final frame on the next tick after a stop, the socket held open while a share runs, nothing sent for a
/// share that never left the device, and the frames opened by a receiver that knows only what a peer knows (the start body and the two
/// user id strings). The end triggers, the timer, the restart and the rest of the platform behaviour are in `LocationShareCenterEndTests`.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
@MainActor
final class LocationShareCenterTests: XCTestCase {

    private var fx: LocationCenterFixture!
    private var center: LocationShareCenter { fx.center }
    private var peerId: String { LocationCenterFixture.peerId }
    private var selfId: String { LocationCenterFixture.selfId }

    override func setUp() {
        super.setUp()
        fx = LocationCenterFixture()
    }

    override func tearDown() {
        fx.tearDown()
        fx = nil
        super.tearDown()
    }

    // MARK: The contract

    func test_aLiveShareFollowsTheContractFromTheStartToTheFinalFrame() throws {
        let started = try fx.startShare()
        XCTAssertEqual(center.activeShares.map { $0.id }, [started.id])
        XCTAssertNotNil(center.connectionToken, "the socket is held open for as long as a share runs")
        XCTAssertEqual(fx.connectionRequests, 1)

        // The start body carries the key, as it goes to the peer: a receiver learns the share from it and from the two id strings.
        guard case .location(.live(let start, let position)) = LocationCodec.recognize(started.body, channel: .chat) else {
            return XCTFail("the start is not a valid live start")
        }
        let now: Int64 = LocationShareCenter.nowUnix()
        let receiver = try LocationShareReceiver(selfId: peerId, peerId: selfId, store: InMemoryLocationShareStore(), now: now)
        XCTAssertEqual(receiver.receiveStart(clientMsgId: started.id, live: start, position: position, now: now), .applied)

        // No frame before the echo of the start, whatever happens to the tick.
        center.tick(startClientMsgId: started.id)
        XCTAssertTrue(fx.frames.isEmpty, "no frame before the msg_sent echo")
        fx.handOver(started)
        center.tick(startClientMsgId: started.id)
        XCTAssertTrue(fx.frames.isEmpty, "the start was handed to the socket but was not acknowledged")

        fx.echo(started)
        center.tick(startClientMsgId: started.id)
        XCTAssertEqual(fx.frames.count, 1)
        XCTAssertEqual(fx.frames[0].recipient, peerId)
        XCTAssertEqual(fx.frames[0].payload.utf8.count, 52, "a frame is 37 bytes, 52 characters of base64")
        XCTAssertEqual(receiver.receiveFrame(payload: fx.frames[0].payload, now: now), .applied,
                       "a receiver with the user ids as strings opens the frame")

        // One frame per tick, never closer than TX_MIN_GAP.
        center.tick(startClientMsgId: started.id)
        XCTAssertEqual(fx.frames.count, 1)

        // The user stops: the strip goes at once, the final frame waits for the next tick, then the key is gone.
        center.stopShare(startClientMsgId: started.id, reason: "user", final: .onTick)
        XCTAssertTrue(center.activeShares.isEmpty)
        XCTAssertEqual(fx.frames.count, 1)
        center.tick(startClientMsgId: started.id)
        XCTAssertEqual(fx.frames.count, 2, "the final frame goes on the next tick, exempt from the minimum gap")
        XCTAssertNil(center.connectionToken, "the socket is let go when the last share ends")
        XCTAssertEqual(receiver.receiveFrame(payload: fx.frames[1].payload, now: now), .applied)
        XCTAssertEqual(receiver.share(id: started.id, now: now)?.reason, .stopped)

        // Nothing is left to tick.
        center.tick(startClientMsgId: started.id)
        XCTAssertEqual(fx.frames.count, 2)
    }

    func test_aStopBeforeTheStartLeftTheDeviceSendsNothing() throws {
        let started = try fx.startShare()
        center.stopShare(startClientMsgId: started.id, reason: "user", final: .onTick)
        XCTAssertTrue(center.activeShares.isEmpty)
        XCTAssertTrue(fx.frames.isEmpty)
        XCTAssertTrue(fx.stops.isEmpty)
        center.tick(startClientMsgId: started.id)
        XCTAssertTrue(fx.frames.isEmpty, "no frame for a start that never left, and the key is gone")
        XCTAssertNil(center.connectionToken)
    }

    func test_aStopAfterTheStartLeftButBeforeTheEchoBuildsNoFrame() throws {
        let started = try fx.startShare()
        fx.handOver(started)
        center.stopShare(startClientMsgId: started.id, reason: "user", final: .onTick)
        XCTAssertTrue(center.activeShares.isEmpty)
        center.tick(startClientMsgId: started.id)
        XCTAssertTrue(fx.frames.isEmpty, "no final frame is built for a start that was not acknowledged")
        XCTAssertNotNil(center.waitingForEcho[started.id], "the stop waits for the echo of the start")
        fx.echo(started)
        XCTAssertNil(center.waitingForEcho[started.id], "the echo releases the stop")
        XCTAssertEqual(fx.stopTargets(), [started.id])
        XCTAssertTrue(fx.frames.isEmpty)
    }

    func test_aSecondShareInTheSameConversationEndsTheFirst() throws {
        let first = try fx.startAcknowledgedShare()
        let second = try fx.startShare()
        XCTAssertEqual(center.activeShares.map { $0.id }, [second.id], "one share per conversation and device")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(fx.stopTargets(), [first.id], "the first share ended with its stop")
        XCTAssertNotEqual(first.sid, second.sid, "a fresh share id for every share")
        XCTAssertNotEqual(first.key, second.key, "a fresh key for every share")
    }

    // MARK: The gates

    func test_aShareIsRefusedWhileTheSwitchIsOffOrThePermissionIsMissing() {
        LocationShareCenter.featureOverride = false
        var dispatched = false
        let off = center.startLive(reading: fx.reading(), duration: 900, peerUserId: peerId, conversationId: UUID()) { _, _, _ in
            dispatched = true
        }
        if case .failure(.disabled) = off {} else { XCTFail("a share started with the switch off") }
        XCTAssertFalse(dispatched)

        LocationShareCenter.featureOverride = true
        center.authorizationOverride = false
        let denied = center.startLive(reading: fx.reading(), duration: 900, peerUserId: peerId, conversationId: UUID()) { _, _, _ in
            dispatched = true
        }
        if case .failure(.permission) = denied {} else { XCTFail("a share started without the permission") }
        XCTAssertFalse(dispatched)
        XCTAssertTrue(center.activeShares.isEmpty)
        XCTAssertNil(center.connectionToken)
    }

    func test_aFixThatIsTooOldIsRefusedAndNothingStarts() {
        var dispatched = false
        let result = center.startLive(reading: fx.reading(age: 300), duration: 900, peerUserId: peerId, conversationId: UUID()) { _, _, _ in
            dispatched = true
        }
        if case .failure(.refused(.age)) = result {} else { XCTFail("a stale fix was accepted") }
        XCTAssertFalse(dispatched)
        XCTAssertTrue(center.activeShares.isEmpty)
    }

    func test_theFlagShipsOffWithNoSeam() {
        LocationShareCenter.featureOverride = nil
        XCTAssertFalse(LocationShareCenter.isFeatureEnabled)
        LocationShareCenter.featureOverride = true
    }
}
