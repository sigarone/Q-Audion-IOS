import XCTest
@testable import QAudionEngine

/// The per-round inner seal of a call: round slots, one counter and one replay window for the whole call, the send pointer that
/// moves only at the peer's confirmation, the 30 s grace of a previous round, and what the call's key state does around it (the
/// read-only check before an ACCEPT, the abandon of a failed round, the wipe at the end).
final class InnerSealV2SessionTests: XCTestCase {

    private let callIdL = "call-s9"
    private let block = Data(repeating: 0x55, count: 256)

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var now: Int { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Int) { lock.lock(); value = newValue; lock.unlock() }
    }

    private final class SwitchBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [InnerSendMove] = []
        func add(_ from: Int32, _ to: Int32) { lock.lock(); stored.append(InnerSendMove(from: from, to: to)); lock.unlock() }
        var moves: [InnerSendMove] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private func key(_ seed: Int) -> Data {
        Data(repeating: UInt8(truncatingIfNeeded: seed + 1), count: 32)
    }

    private func features() -> LiveCallCrypto.Features {
        LiveCallCrypto.Features(
            ext: true, rekeyChainV1: false, frameKeyV6: false, innerSealV2: true,
            ownCapabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true), ownTag: true, peerTag: true, selfIsCaller: true)
    }

    private func makePair(_ clock: TestClock) throws -> (caller: InnerSealV2Session, callee: InnerSealV2Session) {
        let caller = InnerSealV2Session(callIdL: callIdL, role: .offerer, nowMs: { clock.now })
        let callee = InnerSealV2Session(callIdL: callIdL, role: .acceptor, nowMs: { clock.now })
        XCTAssertTrue(caller.stageRound0(sessionKey: key(0)))
        XCTAssertTrue(callee.stageRound0(sessionKey: key(0)))
        return (caller, callee)
    }

    private func stage(_ session: InnerSealV2Session, epoch: Int32, seed: Int) throws {
        let prepared = try XCTUnwrap(session.prepare(sessionKey: key(seed)))
        XCTAssertNil(session.install(epoch: epoch, prepared: prepared))
    }

    private struct SealRefused: Error {}

    private func sealed(_ session: InnerSealV2Session) throws -> (wire: Data, ctr: UInt64, epochByte: UInt8) {
        guard case .sealed(let wire, let ctr, let epochByte) = session.sealAudio(block: block) else {
            XCTFail("the seal was refused")
            throw SealRefused()
        }
        return (wire, ctr, epochByte)
    }

    // MARK: - Test 1: slots, counter and window across rekeys

    func testOneCounterAndOneWindowSurviveEveryRekeyAndAPreviousRoundIsErasedThirtySecondsAfterTheNextOne() throws {
        let clock = TestClock()
        let (caller, callee) = try makePair(clock)
        var counters: [UInt64] = []

        // Round 0 seals from install: the first frame carries counter 1 and envelope byte 0, and the peer opens it.
        let first = try sealed(caller)
        XCTAssertEqual(first.ctr, 1)
        XCTAssertEqual(first.epochByte, 0)
        XCTAssertEqual(callee.openAudio(wire: first.wire), .opened(block: block, ctr: 1))
        counters.append(first.ctr)
        // Two more frames of round 0 are kept back, to arrive late.
        let late1 = try sealed(caller)
        let late2 = try sealed(caller)
        counters.append(contentsOf: [late1.ctr, late2.ctr])
        // The confirmation of round 0 moves nothing: it is already the send round.
        XCTAssertNil(caller.peerKcmac(epoch: 0))
        XCTAssertNil(callee.peerKcmac(epoch: 0))

        // Round 1 is staged on both sides: nobody sends under it yet.
        try stage(caller, epoch: 1, seed: 1)
        try stage(callee, epoch: 1, seed: 1)
        let beforeSwitch = try sealed(caller)
        XCTAssertEqual(beforeSwitch.epochByte, 0)
        counters.append(beforeSwitch.ctr)
        XCTAssertEqual(caller.sendEpoch, 0)

        // The caller verifies the callee's confirmation: the pointer moves once, forward, and the counter goes on.
        clock.set(1000)
        XCTAssertEqual(caller.peerKcmac(epoch: 1), InnerSendMove(from: 0, to: 1))
        XCTAssertNil(caller.peerKcmac(epoch: 1), "a repeated confirmation moves nothing")
        let afterSwitch = try sealed(caller)
        XCTAssertEqual(afterSwitch.epochByte, 1)
        counters.append(afterSwitch.ctr)
        // A frame of a round the receiver has staged but not yet confirmed opens.
        XCTAssertEqual(callee.openAudio(wire: afterSwitch.wire), .opened(block: block, ctr: afterSwitch.ctr))
        XCTAssertEqual(callee.snapshot().verified, [0])

        // The callee verifies the caller's confirmation of round 1 at t = 1000: round 0 is receive-only until t = 31000.
        XCTAssertEqual(callee.peerKcmac(epoch: 1), InnerSendMove(from: 0, to: 1))
        clock.set(30_999)
        XCTAssertEqual(callee.openAudio(wire: late1.wire), .opened(block: block, ctr: late1.ctr), "a previous round opens inside the grace")
        XCTAssertEqual(callee.openAudio(wire: late1.wire), .dropped(.replay), "and only once")
        clock.set(31_000)
        XCTAssertEqual(callee.openAudio(wire: late2.wire), .dropped(.noSlot), "erased at exactly verification + 30 s")
        XCTAssertEqual(callee.snapshot().epochs, [1])

        // A round that is never confirmed keeps its slot, and the send pointer stays where it was.
        try stage(caller, epoch: 2, seed: 2)
        clock.set(200_000)
        let whileUndecided = try sealed(caller)
        XCTAssertEqual(whileUndecided.epochByte, 1)
        counters.append(whileUndecided.ctr)
        XCTAssertEqual(caller.snapshot().epochs, [1, 2], "round 0 is gone, the staged round has no deadline")
        caller.abandon(epoch: 1)
        caller.abandon(epoch: 0)
        XCTAssertEqual(caller.snapshot().epochs, [1, 2], "a verified round and round 0 are never abandoned")
        caller.abandon(epoch: 2)
        XCTAssertEqual(caller.snapshot().epochs, [1])

        // A late confirmation of an older round never moves the pointer back.
        try stage(caller, epoch: 2, seed: 2)
        try stage(caller, epoch: 3, seed: 3)
        XCTAssertEqual(caller.peerKcmac(epoch: 3), InnerSendMove(from: 1, to: 3))
        XCTAssertNil(caller.peerKcmac(epoch: 2))
        XCTAssertEqual(caller.sendEpoch, 3)
        let last = try sealed(caller)
        XCTAssertEqual(last.epochByte, 3)
        counters.append(last.ctr)

        // The counter never went back and never repeated.
        XCTAssertEqual(counters, counters.sorted())
        XCTAssertEqual(Set(counters).count, counters.count)
        XCTAssertEqual(caller.snapshot().txCtr, counters.last)
    }

    // MARK: - Test 4: the key state around the slots

    func testTheSwitchFiresOnlyAtTheConfirmationAndTheCheckBeforeAnAcceptReadsOnly() throws {
        let integration = QAudionCallIntegration()
        let switches = SwitchBox()
        integration.onInnerSendSwitch = { from, to in switches.add(from, to) }
        let object = try XCTUnwrap(integration.adoptLiveForTesting(
            callId: "call-s9-a", role: .offerer, features: features(), sessionKey: key(0)))
        XCTAssertNotNil(object.innerPort)
        XCTAssertEqual(object.innerSendEpoch, 0)

        XCTAssertEqual(integration.liveStage(object, epoch: 1, sessionKey: key(1), ours: true, handle: nil), .staged)
        XCTAssertTrue(switches.moves.isEmpty, "the stage moves nothing")
        XCTAssertEqual(object.innerSendEpoch, 0)

        // The check before an ACCEPT changes nothing, whatever it answers.
        let rounds = object.snapshot()
        let inner = object.innerSnapshotForTesting()
        XCTAssertEqual(object.precheckInnerStage(epoch: 257), .slotCollision, "round 257 shares its envelope byte with round 1")
        XCTAssertEqual(object.precheckInnerStage(epoch: 1), .duplicate)
        XCTAssertNil(object.precheckInnerStage(epoch: 2))
        XCTAssertEqual(object.snapshot(), rounds)
        XCTAssertEqual(object.innerSnapshotForTesting(), inner)

        // A colliding round is refused with nothing written, and the refusal is recorded.
        XCTAssertEqual(integration.liveStage(object, epoch: 257, sessionKey: key(2), ours: true, handle: nil), .slotCollision)
        XCTAssertEqual(object.snapshot().rounds, rounds.rounds)
        XCTAssertEqual(object.lastRefusalEpoch, 257)

        // The confirmation of round 2 of the call (epoch 1) moves the pointer once.
        integration.liveConfirm(gen: object.gen, round: 2)
        XCTAssertEqual(switches.moves, [InnerSendMove(from: 0, to: 1)])
        integration.liveConfirm(gen: object.gen, round: 2)
        XCTAssertEqual(switches.moves.count, 1)
        XCTAssertEqual(object.innerSendEpoch, 1)

        // A round that failed loses its staged slot.
        XCTAssertEqual(integration.liveStage(object, epoch: 2, sessionKey: key(3), ours: true, handle: nil), .staged)
        XCTAssertEqual(object.innerSnapshotForTesting()?.epochs.contains(2), true)
        integration.liveFail(gen: object.gen, round: 3)
        XCTAssertEqual(object.innerSnapshotForTesting()?.epochs.contains(2), false)
    }

    // MARK: - Test 5: the end of the call

    func testACloseWipesEveryKeyAndRefusesAndANewCallStartsAtCounterOne() throws {
        let integration = QAudionCallIntegration()
        let object = try XCTUnwrap(integration.adoptLiveForTesting(
            callId: "call-s9-b", role: .offerer, features: features(), sessionKey: key(0)))
        let port = try XCTUnwrap(object.innerPort)
        guard case .sealed(_, let firstCtr, _) = port.sealAudio(block: block) else { return XCTFail("seal") }
        XCTAssertEqual(firstCtr, 1)
        _ = port.sealAudio(block: block)
        let buffers = object.innerKeyBuffersForTesting()
        XCTAssertEqual(buffers.count, 2)
        XCTAssertTrue(buffers.allSatisfy { !$0.isWipedForTesting })

        integration.liveCloseDetached(object, why: 3)
        XCTAssertEqual(port.sealAudio(block: block), .refused(.closed))
        XCTAssertEqual(port.openAudio(wire: Data([0x04])), .dropped(.closed))
        XCTAssertTrue(buffers.allSatisfy { $0.isWipedForTesting }, "every key buffer is wiped")
        XCTAssertNil(object.innerPort)
        XCTAssertNil(object.innerSendEpoch)

        // The next call on the same integration: a new object, counter 1, an empty window.
        let second = try XCTUnwrap(integration.adoptLiveForTesting(
            callId: "call-s9-c", role: .offerer, features: features(), sessionKey: key(0)))
        XCTAssertNotEqual(second.gen, object.gen)
        let secondPort = try XCTUnwrap(second.innerPort)
        guard case .sealed(_, let secondCtr, _) = secondPort.sealAudio(block: block) else { return XCTFail("seal") }
        XCTAssertEqual(secondCtr, 1)
        let peer = InnerSealV2Session(callIdL: second.callIdL, role: .acceptor, nowMs: { 0 })
        XCTAssertTrue(peer.stageRound0(sessionKey: key(0)))
        guard case .sealed(let wire, _, _) = peer.sealAudio(block: block) else { return XCTFail("seal") }
        XCTAssertEqual(secondPort.openAudio(wire: wire), .opened(block: block, ctr: 1))
    }
}
