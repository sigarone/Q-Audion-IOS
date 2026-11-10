import XCTest
@testable import QAudionEngine

/// WIRE_SPEC section 16: the frame bodies byte for byte, the serial arithmetic, the receiver (de-duplication, expiry,
/// lost-RESUMED clearing), the sender (six sends, legs, re-send events), the leg policy, the capability gate, the hint,
/// the silence gate, the tone and the iOS audio triggers. Time is virtual (`ManualHoldClock`).
final class CallHoldTests: XCTestCase {

    // MARK: - Wire

    func testHoldFrameIsByteForByteTheSpecVector() {
        // 03 04 01 01 01 00 07: HELD, cause system call, seq 7.
        let frame = CallHoldWire.holdFrame(state: CallHoldWire.stateHeld, cause: CallHoldWire.causeSystemCall, seq: 7)
        XCTAssertEqual([UInt8](frame), [0x03, 0x04, 0x01, 0x01, 0x01, 0x00, 0x07])
        let ack = CallHoldWire.ackFrame(seq: 7)
        XCTAssertEqual([UInt8](ack), [0x03, 0x05, 0x01, 0x00, 0x07])
    }

    func testBodiesRoundTripThroughTheControlCodec() throws {
        let frame = CallHoldWire.holdFrame(state: CallHoldWire.stateResumed, cause: CallHoldWire.causeAudioInterruption, seq: 0xABCD)
        let (kind, body) = try WireRelayFrameCodec.decodeControl(frame)
        XCTAssertEqual(kind, WireRelayFrameCodec.controlKindCallHold)
        let hold = try XCTUnwrap(CallHoldWire.decodeHold(body))
        XCTAssertEqual(hold, CallHoldWire.Hold(state: 2, cause: 2, seq: 0xABCD))
        XCTAssertFalse(hold.held)
        let (ackKind, ackBody) = try WireRelayFrameCodec.decodeControl(CallHoldWire.ackFrame(seq: 0xABCD))
        XCTAssertEqual(ackKind, WireRelayFrameCodec.controlKindCallHoldAck)
        XCTAssertEqual(CallHoldWire.decodeAck(ackBody), 0xABCD)
    }

    func testKindsAreNotReused() {
        XCTAssertEqual(WireRelayFrameCodec.controlKindHangup, 0x01)
        XCTAssertEqual(WireRelayFrameCodec.controlKindNackRequest, 0x02)
        XCTAssertEqual(WireRelayFrameCodec.controlKindOuterOff, 0x03)
        XCTAssertEqual(WireRelayFrameCodec.controlKindCallHold, 0x04)
        XCTAssertEqual(WireRelayFrameCodec.controlKindCallHoldAck, 0x05)
    }

    func testOuterOffFrameIsNeverReadAsAHoldFrame() throws {
        let (kind, body) = try WireRelayFrameCodec.decodeControl(OuterLayerPolicy.outerOffFrame)
        XCTAssertEqual(kind, WireRelayFrameCodec.controlKindOuterOff)
        XCTAssertNotEqual(kind, WireRelayFrameCodec.controlKindCallHold)
        XCTAssertNil(CallHoldWire.decodeHold(body))
        XCTAssertNil(CallHoldWire.decodeAck(body))
    }

    func testDecodeDropsWrongVerWrongStateAndShortBodies() {
        XCTAssertNil(CallHoldWire.decodeHold(Data([0x02, 0x01, 0x01, 0x00, 0x07])), "wrong ver")
        XCTAssertNil(CallHoldWire.decodeHold(Data([0x01, 0x00, 0x01, 0x00, 0x07])), "state 0")
        XCTAssertNil(CallHoldWire.decodeHold(Data([0x01, 0x03, 0x01, 0x00, 0x07])), "state 3")
        XCTAssertNil(CallHoldWire.decodeHold(Data([0x01, 0x01, 0x01, 0x00])), "short")
        XCTAssertNil(CallHoldWire.decodeHold(Data()))
        XCTAssertNil(CallHoldWire.decodeAck(Data([0x02, 0x00, 0x07])), "ack wrong ver")
        XCTAssertNil(CallHoldWire.decodeAck(Data([0x01, 0x00])), "ack short")
    }

    func testTrailingBytesAreIgnoredAndUnknownCauseReadsAsUnspecified() throws {
        let hold = try XCTUnwrap(CallHoldWire.decodeHold(Data([0x01, 0x01, 0x7F, 0x00, 0x09, 0xAA, 0xBB])))
        XCTAssertEqual(hold.cause, CallHoldWire.causeUnspecified)
        XCTAssertEqual(hold.seq, 9)
        XCTAssertEqual(CallHoldWire.decodeAck(Data([0x01, 0x00, 0x09, 0xFF])), 9)
    }

    func testDecodeWorksOnASliceWithANonZeroStartIndex() {
        let big = Data([0xEE, 0xEE, 0x01, 0x01, 0x03, 0x01, 0x02])
        let slice = big.subdata(in: 2..<7)
        XCTAssertEqual(CallHoldWire.decodeHold(slice)?.seq, 0x0102)
        let view = big[2...]
        XCTAssertEqual(CallHoldWire.decodeHold(view)?.cause, CallHoldWire.causeUser)
    }

    func testSeqSerialArithmeticWrapsAndRejectsOld() {
        XCTAssertTrue(CallHoldWire.isNewer(1, than: 0))
        XCTAssertTrue(CallHoldWire.isNewer(0, than: 65535), "wrap from 65535 to 0")
        XCTAssertTrue(CallHoldWire.isNewer(5, than: 65530))
        XCTAssertTrue(CallHoldWire.isNewer(32768, than: 1), "difference 32767")
        XCTAssertFalse(CallHoldWire.isNewer(32769, than: 1), "difference 32768 is old")
        XCTAssertFalse(CallHoldWire.isNewer(7, than: 7), "equal")
        XCTAssertFalse(CallHoldWire.isNewer(3, than: 9), "old")
    }

    // MARK: - Receiver

    func testFirstFrameIsAlwaysAppliedAndADuplicateIsAppliedOnce() {
        let r = CallHoldReceiver()
        let held = CallHoldWire.Hold(state: 1, cause: 1, seq: 40000)
        XCTAssertEqual(r.onFrame(held, nowMs: 1000), .init(applied: true, changed: true))
        XCTAssertTrue(r.held)
        XCTAssertEqual(r.onFrame(held, nowMs: 2000), .init(applied: false, changed: false), "duplicate")
        XCTAssertEqual(r.heldSinceMs, 1000)
    }

    func testResumedEndsHoldAndAnOldSeqIsIgnored() {
        let r = CallHoldReceiver()
        _ = r.onFrame(.init(state: 1, cause: 1, seq: 5), nowMs: 0)
        XCTAssertEqual(r.onFrame(.init(state: 2, cause: 1, seq: 6), nowMs: 10), .init(applied: true, changed: true))
        XCTAssertFalse(r.held)
        XCTAssertEqual(r.onFrame(.init(state: 1, cause: 1, seq: 5), nowMs: 20), .init(applied: false, changed: false))
        XCTAssertFalse(r.held, "a late old HELD does not hold again")
    }

    func testSeqWrapAppliesAcrossZero() {
        let r = CallHoldReceiver()
        _ = r.onFrame(.init(state: 1, cause: 0, seq: 65535), nowMs: 0)
        XCTAssertEqual(r.onFrame(.init(state: 2, cause: 0, seq: 0), nowMs: 5), .init(applied: true, changed: true))
        XCTAssertFalse(r.held)
    }

    func testExpiryIsAnchoredToTheFirstHeldAndNotExtended() {
        let r = CallHoldReceiver()
        _ = r.onFrame(.init(state: 1, cause: 1, seq: 1), nowMs: 1_000)
        // a repeated HELD with a newer seq and another cause does not move the anchor
        XCTAssertEqual(r.onFrame(.init(state: 1, cause: 2, seq: 2), nowMs: 600_000), .init(applied: true, changed: false))
        XCTAssertEqual(r.heldSinceMs, 1_000)
        XCTAssertFalse(r.expireIfDue(nowMs: 1_000 + CallHoldReceiver.expiryMs - 1))
        XCTAssertTrue(r.held)
        XCTAssertTrue(r.expireIfDue(nowMs: 1_000 + CallHoldReceiver.expiryMs))
        XCTAssertFalse(r.held)
    }

    func testANewHoldAfterResumedStartsANewThirtyMinutes() {
        let r = CallHoldReceiver()
        _ = r.onFrame(.init(state: 1, cause: 1, seq: 1), nowMs: 0)
        _ = r.onFrame(.init(state: 2, cause: 1, seq: 2), nowMs: 1_000)
        _ = r.onFrame(.init(state: 1, cause: 1, seq: 3), nowMs: 2_000_000)
        XCTAssertEqual(r.heldSinceMs, 2_000_000)
        XCTAssertFalse(r.expireIfDue(nowMs: 2_000_000 + 1_000))
    }

    func testThreeSecondsOfRealAudioClearAHoldOnASealedFrameCall() {
        let r = CallHoldReceiver()
        _ = r.onFrame(.init(state: 1, cause: 1, seq: 1), nowMs: 10_000)
        // audio seen in the second [10_000, 11_000), then [11_000, 12_000), then [12_000, 13_000)
        XCTAssertFalse(r.observeDecode(nowMs: 10_500, lastDecodeAtMs: 10_400, sealedFrameCall: true))
        XCTAssertFalse(r.observeDecode(nowMs: 11_500, lastDecodeAtMs: 11_400, sealedFrameCall: true))
        XCTAssertTrue(r.observeDecode(nowMs: 12_500, lastDecodeAtMs: 12_400, sealedFrameCall: true))
        XCTAssertFalse(r.held)
    }

    func testAGapBetweenAudioSecondsRestartsTheCount() {
        let r = CallHoldReceiver()
        _ = r.onFrame(.init(state: 1, cause: 1, seq: 1), nowMs: 0)
        XCTAssertFalse(r.observeDecode(nowMs: 500, lastDecodeAtMs: 400, sealedFrameCall: true))
        XCTAssertFalse(r.observeDecode(nowMs: 2_500, lastDecodeAtMs: 2_400, sealedFrameCall: true), "second 1 skipped")
        XCTAssertFalse(r.observeDecode(nowMs: 3_500, lastDecodeAtMs: 3_400, sealedFrameCall: true))
        XCTAssertTrue(r.observeDecode(nowMs: 4_500, lastDecodeAtMs: 4_400, sealedFrameCall: true))
    }

    func testAStaleDecodeStampDoesNotCountAndSrtpNeverAutoClears() {
        let r = CallHoldReceiver()
        _ = r.onFrame(.init(state: 1, cause: 1, seq: 1), nowMs: 0)
        XCTAssertFalse(r.observeDecode(nowMs: 5_000, lastDecodeAtMs: 100, sealedFrameCall: true), "stamp older than 1 s")
        for second in 0..<10 {
            let t = Int64(second) * 1000 + 400
            XCTAssertFalse(r.observeDecode(nowMs: t + 100, lastDecodeAtMs: t, sealedFrameCall: false))
        }
        XCTAssertTrue(r.held, "on SRTP only RESUMED or expiry ends HELD")
    }

    func testResetStartsAResumedCallWithNoSeqSeen() {
        let r = CallHoldReceiver()
        _ = r.onFrame(.init(state: 1, cause: 1, seq: 9), nowMs: 0)
        r.reset()
        XCTAssertFalse(r.held)
        XCTAssertEqual(r.onFrame(.init(state: 1, cause: 1, seq: 2), nowMs: 5), .init(applied: true, changed: true),
                       "the first frame of a call is always applied, whatever its seq")
    }

    // MARK: - Sender

    private func makeSender(clock: ManualHoldClock, hasTag: @escaping () -> Bool = { true },
                            log: SendLog) -> CallHoldSender {
        CallHoldSender(
            peerHasTag: hasTag,
            send: { kind, body, route in
                log.entries.append(.init(atMs: clock.nowMs, kind: kind, body: body, route: route))
                return true
            },
            schedule: clock.schedule,
            onStateChange: { held, cause, seq in log.changes.append("\(held ? 1 : 0)/\(cause)/\(seq)") },
            onNeverAcked: { seq in log.neverAcked.append(seq) })
    }

    func testAMissingAckGivesExactlySixSendsAtTheSpecTimesAndStops() {
        let clock = ManualHoldClock()
        let log = SendLog()
        let s = makeSender(clock: clock, log: log)
        XCTAssertTrue(s.addCause(CallHoldWire.causeSystemCall))
        clock.advance(by: 60_000)
        XCTAssertEqual(log.entries.map { $0.atMs }, [0, 400, 1000, 2000, 4000, 8000])
        XCTAssertEqual(log.entries.map { $0.route }, [.first, .both, .both, .both, .both, .both])
        XCTAssertTrue(log.entries.allSatisfy { $0.kind == 0x04 })
        XCTAssertEqual(log.neverAcked, [1], "one never-acknowledged event, after the grace")
        XCTAssertFalse(s.acknowledged)
    }

    func testTheAckStopsTheRetries() {
        let clock = ManualHoldClock()
        let log = SendLog()
        let s = makeSender(clock: clock, log: log)
        s.addCause(CallHoldWire.causeSystemCall)
        clock.advance(by: 500)
        XCTAssertEqual(log.entries.count, 2)
        XCTAssertFalse(s.onAck(99), "an ack for a seq never sent is ignored")
        XCTAssertTrue(s.onAck(1))
        clock.advance(by: 60_000)
        XCTAssertEqual(log.entries.count, 2)
        XCTAssertTrue(log.neverAcked.isEmpty)
        XCTAssertTrue(s.acknowledged)
        XCTAssertFalse(s.onAck(1), "a second ack for the same seq changes nothing")
    }

    func testAddingAnotherCauseWhileHeldSendsNothingAndTheLastRemovalResumes() {
        let clock = ManualHoldClock()
        let log = SendLog()
        let s = makeSender(clock: clock, log: log)
        XCTAssertTrue(s.addCause(CallHoldWire.causeSystemCall))
        XCTAssertFalse(s.addCause(CallHoldWire.causeAudioInterruption), "same state: no change")
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(s.currentSeq, 1)
        XCTAssertFalse(s.removeCause(CallHoldWire.causeSystemCall), "a cause is still active")
        XCTAssertTrue(s.held)
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertTrue(s.removeCause(CallHoldWire.causeAudioInterruption))
        XCTAssertFalse(s.held)
        XCTAssertEqual(s.currentSeq, 2)
        XCTAssertEqual(log.changes, ["1/1/1", "0/2/2"])
    }

    func testResumedIsWrittenBeforeRemoveCauseReturnsAndSupersedesTheHeldRetries() throws {
        let clock = ManualHoldClock()
        let log = SendLog()
        let s = makeSender(clock: clock, log: log)
        s.addCause(CallHoldWire.causeSystemCall)
        clock.advance(by: 100)
        XCTAssertEqual(log.entries.count, 1)
        s.removeCause(CallHoldWire.causeSystemCall)
        // synchronously, before any time passes: the RESUMED frame is out
        XCTAssertEqual(log.entries.count, 2)
        let resumed = try XCTUnwrap(CallHoldWire.decodeHold(log.entries[1].body))
        XCTAssertEqual(resumed.state, CallHoldWire.stateResumed)
        XCTAssertEqual(resumed.seq, 2)
        XCTAssertEqual(log.entries[1].route, .first)
        // the HELD schedule is dead, the RESUMED one runs: 0.4 s later the next copy, on both legs, with the new seq
        clock.advance(by: 400)
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(CallHoldWire.decodeHold(log.entries[2].body)?.seq, 2)
        XCTAssertEqual(log.entries[2].route, .both)
        s.onAck(2)
        clock.advance(by: 60_000)
        XCTAssertEqual(log.entries.count, 3)
    }

    func testResumedHasSixSendsInAllToo() {
        let clock = ManualHoldClock()
        let log = SendLog()
        let s = makeSender(clock: clock, log: log)
        s.addCause(1)
        s.onAck(1)
        let before = log.entries.count
        s.removeCause(1)
        clock.advance(by: 60_000)
        XCTAssertEqual(log.entries.count - before, 6)
    }

    func testSeqWrapsModuloSixtyFiveThousandFiveHundredThirtySix() {
        let clock = ManualHoldClock()
        let log = SendLog()
        let s = makeSender(clock: clock, log: log)
        for _ in 0..<32768 {
            s.addCause(1)
            s.removeCause(1)
        }
        XCTAssertEqual(s.currentSeq, 0, "65536 changes wrap to 0")
        s.addCause(1)
        XCTAssertEqual(s.currentSeq, 1)
    }

    func testNothingIsSentWithoutThePeerTagAndItGoesOutWhenTheTagIsKnown() {
        let clock = ManualHoldClock()
        let log = SendLog()
        var tag = false
        let s = makeSender(clock: clock, hasTag: { tag }, log: log)
        s.addCause(1)
        clock.advance(by: 30_000)
        XCTAssertTrue(log.entries.isEmpty, "gated on call-hold-v1: no frame at all")
        tag = true
        s.resendAfter("tag")
        XCTAssertEqual(log.entries.count, 1, "remembered and sent as soon as the tag is known")
        XCTAssertEqual(log.entries[0].route, .first)
        clock.advance(by: 60_000)
        XCTAssertEqual(log.entries.count, 6)
    }

    func testResendAfterAnEventSendsOnceMoreOnBothLegsOnlyWhileUnacknowledged() {
        let clock = ManualHoldClock()
        let log = SendLog()
        let s = makeSender(clock: clock, log: log)
        s.addCause(1)
        clock.advance(by: 60_000)
        XCTAssertEqual(log.entries.count, 6)
        s.resendAfter("leg")
        XCTAssertEqual(log.entries.count, 7)
        XCTAssertEqual(log.entries[6].route, .both)
        XCTAssertEqual(CallHoldWire.decodeHold(log.entries[6].body)?.seq, 1, "same state, same seq")
        s.onAck(1)
        s.resendAfter("rekey")
        XCTAssertEqual(log.entries.count, 7, "acknowledged: nothing to re-send")
    }

    func testCloseStopsEverything() {
        let clock = ManualHoldClock()
        let log = SendLog()
        let s = makeSender(clock: clock, log: log)
        s.addCause(1)
        s.close()
        clock.advance(by: 60_000)
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertFalse(s.addCause(2))
        s.resendAfter("leg")
        XCTAssertEqual(log.entries.count, 1)
    }

    // MARK: - Legs

    func testFirstSendGoesOnTheDataChannelWhenOpenAndOnTheRelayWhenNot() {
        XCTAssertEqual(HoldLegPolicy.select(route: .first, dcOpenCarrying: true, relayAllowed: true, outer: .sealed), [.dc])
        XCTAssertEqual(HoldLegPolicy.select(route: .first, dcOpenCarrying: false, relayAllowed: true, outer: .sealed), [.relay])
        XCTAssertEqual(HoldLegPolicy.select(route: .first, dcOpenCarrying: false, relayAllowed: false, outer: .sealed), [.dc],
                       "no relay leg: the DataChannel is all there is")
    }

    func testRetriesGoOnBothLegsWhenTheRelayIsAllowed() {
        XCTAssertEqual(HoldLegPolicy.select(route: .both, dcOpenCarrying: true, relayAllowed: true, outer: .sealed), [.dc, .relay])
        XCTAssertEqual(HoldLegPolicy.select(route: .both, dcOpenCarrying: false, relayAllowed: true, outer: .sealed), [.dc, .relay])
        XCTAssertEqual(HoldLegPolicy.select(route: .both, dcOpenCarrying: true, relayAllowed: false, outer: .sealed), [.dc])
    }

    func testInOffNothingIsEverWrittenToTheRelay() {
        for route in [HoldRoute.first, .both, .replyDc, .replyRelay] {
            for dc in [true, false] {
                let legs = HoldLegPolicy.select(route: route, dcOpenCarrying: dc, relayAllowed: true, outer: .off)
                XCTAssertFalse(legs.contains(.relay), "OFF never reaches the relay: \(route) dc=\(dc)")
            }
        }
        XCTAssertEqual(HoldLegPolicy.select(route: .first, dcOpenCarrying: false, relayAllowed: true, outer: .off), [.dc])
        XCTAssertEqual(HoldLegPolicy.select(route: .both, dcOpenCarrying: true, relayAllowed: true, outer: .off), [.dc])
    }

    func testUndecidedWritesNothingOnAnyLeg() {
        for route in [HoldRoute.first, .both, .replyDc, .replyRelay] {
            XCTAssertEqual(HoldLegPolicy.select(route: route, dcOpenCarrying: true, relayAllowed: true, outer: .undecided), [])
        }
    }

    func testAnAckFollowsTheLegTheFrameArrivedOn() {
        XCTAssertEqual(HoldLegPolicy.select(route: .replyDc, dcOpenCarrying: false, relayAllowed: true, outer: .sealed), [.dc])
        XCTAssertEqual(HoldLegPolicy.select(route: .replyRelay, dcOpenCarrying: true, relayAllowed: true, outer: .sealed), [.relay])
        XCTAssertEqual(HoldLegPolicy.select(route: .replyRelay, dcOpenCarrying: true, relayAllowed: false, outer: .sealed), [])
    }

    func testOuterStateMapping() {
        XCTAssertEqual(HoldOuterState.from(mode: .sealed, sealerInstalled: true), .sealed)
        XCTAssertEqual(HoldOuterState.from(mode: .sealed, sealerInstalled: false), .undecided)
        XCTAssertEqual(HoldOuterState.from(mode: .unknown, sealerInstalled: false), .undecided)
        XCTAssertEqual(HoldOuterState.from(mode: .unknown, sealerInstalled: true), .sealed)
        XCTAssertEqual(HoldOuterState.from(mode: .noOuter, sealerInstalled: false), .off)
        XCTAssertEqual(HoldOuterState.from(mode: .offLocalInstall, sealerInstalled: true), .off)
        XCTAssertEqual(HoldOuterState.from(mode: .offPeerInstall, sealerInstalled: true), .off)
    }

    // MARK: - Capability gate

    func testHoldKindsAreGatedOnCallHoldAndNeverOnDcHangup() {
        XCTAssertEqual(HoldLegPolicy.requiredTag(kind: 0x04), "call-hold-v1")
        XCTAssertEqual(HoldLegPolicy.requiredTag(kind: 0x05), "call-hold-v1")
        XCTAssertEqual(HoldLegPolicy.requiredTag(kind: 0x01), "dc-hangup-v1")
        XCTAssertEqual(HoldLegPolicy.requiredTag(kind: 0x02), "audio-nack-v1")
        XCTAssertEqual(CallCapabilities.callHoldV1, "call-hold-v1")
        XCTAssertTrue(CallCapabilities.local.contains(CallCapabilities.callHoldV1))
        XCTAssertNotEqual(HoldLegPolicy.requiredTag(kind: 0x04), CallCapabilities.dcHangupV1)
    }

    // MARK: - Hint

    func testTheHintAppearsAfterTenSecondsOfSilenceAndClearsOnAudio() {
        let h = PeerAudibleHint()
        XCTAssertFalse(h.evaluate(nowMs: 60_000, suppressed: false), "never before the first inbound audio of the call")
        h.onEvidence(nowMs: 1_000)
        XCTAssertFalse(h.evaluate(nowMs: 11_000, suppressed: false), "exactly 10 s is not more than 10 s")
        XCTAssertTrue(h.evaluate(nowMs: 11_001, suppressed: false))
        h.onEvidence(nowMs: 12_000)
        XCTAssertFalse(h.shown)
        XCTAssertFalse(h.evaluate(nowMs: 13_000, suppressed: false))
    }

    func testTheHintIsSuppressedWhileHeldAndRestartsTheCountWhenSuppressionEnds() {
        let h = PeerAudibleHint()
        h.onEvidence(nowMs: 0)
        XCTAssertFalse(h.evaluate(nowMs: 20_000, suppressed: true))
        XCTAssertFalse(h.evaluate(nowMs: 25_000, suppressed: false), "counted from zero at the last suppressed poll")
        XCTAssertTrue(h.evaluate(nowMs: 35_001, suppressed: false))
    }

    func testPacketCountGrowthIsEvidenceAndANoGrowthIsNot() {
        let h = PeerAudibleHint()
        h.onPacketCount(nowMs: 0, packetsReceived: nil)
        XCTAssertFalse(h.evaluate(nowMs: 30_000, suppressed: false), "no count yet: not heard")
        h.onPacketCount(nowMs: 1_000, packetsReceived: 100)
        h.onPacketCount(nowMs: 2_000, packetsReceived: 150)
        XCTAssertFalse(h.evaluate(nowMs: 11_000, suppressed: false))
        h.onPacketCount(nowMs: 12_000, packetsReceived: 150)
        XCTAssertTrue(h.evaluate(nowMs: 12_001, suppressed: false), "no growth for more than 10 s")
        h.onPacketCount(nowMs: 13_000, packetsReceived: 151)
        XCTAssertFalse(h.evaluate(nowMs: 13_001, suppressed: false))
    }

    // MARK: - Silence gate

    func testSilenceGateSkipsWhileHeldRestartsOnceAfterAndThenEvaluates() {
        let g = HoldSilenceGate()
        XCTAssertEqual(g.step(peerHeld: false), .evaluate)
        XCTAssertEqual(g.step(peerHeld: true), .skip)
        XCTAssertEqual(g.step(peerHeld: true), .skip)
        XCTAssertEqual(g.step(peerHeld: false), .restart)
        XCTAssertEqual(g.step(peerHeld: false), .evaluate)
        g.reset()
        XCTAssertEqual(g.step(peerHeld: false), .evaluate)
    }

    // MARK: - Tone

    func testToneIsAFourHundredTwentyFiveHertzBeepOfThreeHundredFiftyMilliseconds() {
        let pcm = HoldToneSynth.samples(sampleRate: 48_000)
        XCTAssertEqual(pcm.count, 16_800)
        XCTAssertEqual(pcm.first, 0)
        XCTAssertEqual(pcm.last, 0, "faded out")
        let peak = pcm.map { abs(Int($0)) }.max() ?? 0
        // about 24 dB below full scale: 32767 * 10^(-24/20) = 2067
        XCTAssertGreaterThan(peak, 1_900)
        XCTAssertLessThan(peak, 2_100)
        // zero crossings: 425 Hz over 0.35 s is about 148.75 cycles, so about 297 crossings
        var crossings = 0
        for i in 1..<pcm.count where (pcm[i - 1] < 0) != (pcm[i] < 0) { crossings += 1 }
        XCTAssertGreaterThan(crossings, 280)
        XCTAssertLessThan(crossings, 315)
        // the 10 ms fade-in is below the plateau
        XCTAssertLessThan(abs(Int(pcm[100])), peak)
    }

    func testToneWavIsAWellFormedMonoSixteenBitFile() {
        let wav = [UInt8](HoldToneSynth.wavData(sampleRate: 16_000))
        XCTAssertEqual(String(bytes: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(bytes: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(bytes: wav[36..<40], encoding: .ascii), "data")
        let dataLen = Int(wav[40]) | Int(wav[41]) << 8 | Int(wav[42]) << 16 | Int(wav[43]) << 24
        XCTAssertEqual(dataLen, 16_000 * 350 / 1000 * 2)
        XCTAssertEqual(wav.count, 44 + dataLen)
        XCTAssertEqual(Int(wav[22]), 1, "mono")
        XCTAssertEqual(Int(wav[34]), 16, "16 bit")
    }

    func testToneIsDueAtTimeZeroThenEveryFourSecondsAndNeverWhenLocalHeldOrNotHeld() {
        let never = HoldToneSynth.never
        XCTAssertTrue(HoldToneSynth.due(peerHeld: true, localHeld: false, nowMs: 0, lastBeepAtMs: never))
        XCTAssertFalse(HoldToneSynth.due(peerHeld: true, localHeld: false, nowMs: 3_999, lastBeepAtMs: 0))
        XCTAssertTrue(HoldToneSynth.due(peerHeld: true, localHeld: false, nowMs: 4_000, lastBeepAtMs: 0))
        XCTAssertFalse(HoldToneSynth.due(peerHeld: true, localHeld: true, nowMs: 0, lastBeepAtMs: never), "both held: no tone (16.5)")
        XCTAssertFalse(HoldToneSynth.due(peerHeld: false, localHeld: false, nowMs: 0, lastBeepAtMs: never))
    }

    // MARK: - iOS audio triggers

    func testInterruptionBeganAddsTheCauseAndEndedRemovesIt() {
        var t = AudioHoldTriggerState()
        XCTAssertEqual(t.interruptionBegan(), .add)
        XCTAssertEqual(t.interruptionBegan(), .none, "already applied")
        XCTAssertEqual(t.interruptionEnded(), .remove)
        XCTAssertEqual(t.interruptionEnded(), .none)
    }

    func testADeactivationOnlyCountsAfterTheDebounceAndANearImmediateReactivationNeverHolds() {
        var t = AudioHoldTriggerState()
        XCTAssertEqual(t.sessionDeactivated(), .armTimer)
        XCTAssertEqual(t.sessionDeactivated(), .none, "one timer")
        XCTAssertEqual(t.sessionActivated(), .cancelTimer, "back before the timer: no hold, no frame")
        XCTAssertEqual(t.deactivationTimerFired(), .none, "a stale fire does nothing")
    }

    func testADeactivationThatLastsHoldsAndTheNextActivationEndsIt() {
        var t = AudioHoldTriggerState()
        XCTAssertEqual(t.sessionDeactivated(), .armTimer)
        XCTAssertEqual(t.deactivationTimerFired(), .add)
        XCTAssertEqual(t.sessionDeactivated(), .none)
        XCTAssertEqual(t.sessionActivated(), .remove)
    }

    func testActivationClearsAnInterruptionWhoseEndedWasLost() {
        var t = AudioHoldTriggerState()
        XCTAssertEqual(t.interruptionBegan(), .add)
        XCTAssertEqual(t.sessionDeactivated(), .armTimer)
        XCTAssertEqual(t.deactivationTimerFired(), .none, "already held by the interruption")
        XCTAssertEqual(t.sessionActivated(), .remove, "the system activated the session again: the interruption is over")
        XCTAssertFalse(t.interruptionPending, "no stuck flag")
        XCTAssertEqual(t.interruptionEnded(), .none, "a late ended changes nothing")
    }

    func testAnInterruptionWithNoEndedIsClearedByTheNextActivationAndHasAThirtyMinuteCap() {
        var t = AudioHoldTriggerState()
        XCTAssertEqual(t.interruptionBegan(), .add)
        XCTAssertEqual(t.sessionActivated(), .remove)
        XCTAssertEqual(t.interruptionBegan(), .add, "a later interruption starts a new hold")
        XCTAssertEqual(AudioHoldTriggerState.maxHoldSeconds, 1800)
    }

    // MARK: - Hold causes and video (any cause pauses, the last one restores)

    /// Replays a sequence of cause changes the way `CallService` does and applies `CallHoldPolicy` on every state change.
    private func videoTrace(_ steps: [(add: Bool, cause: UInt8)], videoCall: Bool = true, userPaused: Bool = false) -> [String] {
        let s = CallHoldSender(peerHasTag: { false }, send: { _, _, _ in false }, schedule: { _, _ in {} })
        var pausedByHold = false
        var trace: [String] = []
        for step in steps {
            let changed = step.add ? s.addCause(step.cause) : s.removeCause(step.cause)
            guard changed else { trace.append("-"); continue }
            let a = CallHoldPolicy.videoAction(isOnHold: s.held, isGroupCall: false, isVideoCall: videoCall,
                                               localVideoAlreadyPaused: userPaused, videoPausedByPriorHold: pausedByHold)
            if a.pauseLocalVideo { pausedByHold = true }
            trace.append(a.pauseLocalVideo ? "pause" : (a.resumeLocalVideo ? "resume" : "none"))
            if !s.held { pausedByHold = false }
        }
        return trace
    }

    func testAnyFirstCausePausesVideoAndOnlyTheLastRemovalRestoresIt() {
        // audio interruption alone
        XCTAssertEqual(videoTrace([(true, 2), (false, 2)]), ["pause", "resume"])
        // CallKit hold, then an interruption: nothing more to do; unhold of CallKit leaves video paused, the end restores
        XCTAssertEqual(videoTrace([(true, 1), (true, 2), (false, 1), (false, 2)]), ["pause", "-", "-", "resume"])
        XCTAssertEqual(videoTrace([(true, 2), (true, 1), (false, 2), (false, 1)]), ["pause", "-", "-", "resume"])
    }

    func testVideoIsNotRestoredIfTheUserHadPausedItOrThereWasNoVideo() {
        XCTAssertEqual(videoTrace([(true, 1), (false, 1)], userPaused: true), ["none", "none"])
        XCTAssertEqual(videoTrace([(true, 1), (false, 1)], videoCall: false), ["none", "none"])
    }

    // MARK: - Outbound video while held

    func testFramesAreDroppedWhileHeldEvenIfAPathUnpaused() {
        // setVideoPaused(false) was called (paused == false) and the call is held: the frame is still dropped
        XCTAssertTrue(OutboundVideoGate.drops(paused: false, locallyHeld: true))
        XCTAssertTrue(OutboundVideoGate.drops(paused: true, locallyHeld: true))
        XCTAssertTrue(OutboundVideoGate.drops(paused: true, locallyHeld: false))
        XCTAssertFalse(OutboundVideoGate.drops(paused: false, locallyHeld: false), "restored after release")
    }

    func testCameraAndScreenShareAreRefusedWhileHeld() {
        XCTAssertFalse(OutboundVideoGate.mayEnableCamera(locallyHeld: true))
        XCTAssertTrue(OutboundVideoGate.mayEnableCamera(locallyHeld: false))
        XCTAssertFalse(OutboundVideoGate.mayStartScreenShare(locallyHeld: true))
        XCTAssertTrue(OutboundVideoGate.mayStartScreenShare(locallyHeld: false))
    }

    func testAnUnpauseWhileHeldIsDeferredAndAppliedOnceOnRelease() {
        var d = VideoUnpauseDeferral()
        // consent, initial video, finalise, promotion, screen share: every one of them asks through `request`
        for _ in 0..<5 { XCTAssertFalse(d.request(locallyHeld: true)) }
        XCTAssertTrue(d.deferred)
        XCTAssertTrue(d.released(), "applied on the last cause removed")
        XCTAssertFalse(d.released(), "and only once")
        XCTAssertTrue(d.request(locallyHeld: false), "not held: applied at once")
        XCTAssertFalse(d.released(), "nothing was deferred")
        _ = d.request(locallyHeld: true)
        d.reset()
        XCTAssertFalse(d.released())
    }

    // MARK: - Receive trust

    func testAHoldFrameActsOnlyWhenTheSealWasOpenedOrItCameOverDtlsInOff() {
        // SEALED call, recv sealer installed: the frame was opened, either leg
        XCTAssertTrue(HoldRxTrust.accept(mode: .sealed, leg: .wsRelay, recvSealerInstalled: true, peerHasTag: true))
        XCTAssertTrue(HoldRxTrust.accept(mode: .sealed, leg: .dataChannel, recvSealerInstalled: true, peerHasTag: true))
        // sealed call but no recv sealer yet: held, never acted on raw
        XCTAssertFalse(HoldRxTrust.accept(mode: .sealed, leg: .wsRelay, recvSealerInstalled: false, peerHasTag: true))
        // unknown outer state, no sealer: it would pass through unopened, so a relay frame is dropped, and so is DC
        XCTAssertFalse(HoldRxTrust.accept(mode: .unknown, leg: .wsRelay, recvSealerInstalled: false, peerHasTag: true))
        XCTAssertFalse(HoldRxTrust.accept(mode: .unknown, leg: .dataChannel, recvSealerInstalled: false, peerHasTag: true))
        // OFF: only the DTLS DataChannel; the relay is closed
        for mode in [OuterLayerMode.noOuter, .offLocalInstall, .offPeerInstall] {
            XCTAssertTrue(HoldRxTrust.accept(mode: mode, leg: .dataChannel, recvSealerInstalled: false, peerHasTag: true))
            XCTAssertFalse(HoldRxTrust.accept(mode: mode, leg: .wsRelay, recvSealerInstalled: false, peerHasTag: true))
        }
    }

    func testTrustIsTakenFromTheDecisionMadeForTheFrameNotFromLaterState() {
        // a frame that passed through unopened stays untrusted even if a sealer exists by the time it is looked at
        XCTAssertFalse(HoldRxTrust.frameIsAuthenticated(rx: .passThrough, mode: .unknown, leg: .wsRelay))
        XCTAssertFalse(HoldRxTrust.frameIsAuthenticated(rx: .passThrough, mode: .unknown, leg: .dataChannel))
        XCTAssertFalse(HoldRxTrust.frameIsAuthenticated(rx: .passThrough, mode: .sealed, leg: .dataChannel))
        XCTAssertTrue(HoldRxTrust.frameIsAuthenticated(rx: .passThrough, mode: .noOuter, leg: .dataChannel))
        XCTAssertFalse(HoldRxTrust.frameIsAuthenticated(rx: .passThrough, mode: .noOuter, leg: .wsRelay))
        XCTAssertTrue(HoldRxTrust.frameIsAuthenticated(rx: .open, mode: .sealed, leg: .wsRelay))
        XCTAssertFalse(HoldRxTrust.frameIsAuthenticated(rx: .hold, mode: .sealed, leg: .wsRelay))
        XCTAssertFalse(HoldRxTrust.frameIsAuthenticated(rx: .drop, mode: .noOuter, leg: .wsRelay))
    }

    func testAHoldFrameIsIgnoredWhenTheTagWasNotNegotiated() {
        XCTAssertFalse(HoldRxTrust.accept(mode: .sealed, leg: .dataChannel, recvSealerInstalled: true, peerHasTag: false))
        XCTAssertFalse(HoldRxTrust.accept(mode: .noOuter, leg: .dataChannel, recvSealerInstalled: false, peerHasTag: false))
    }

    // MARK: - Stale deactivation

    func testALateDeactivationOfThePreviousCallIsNotOurs() {
        XCTAssertEqual(NativeAudioUnitGateDecisions.callKitDeactivationOwner(pairedActivationGeneration: 4, currentGeneration: 5),
                       .endedCall)
        XCTAssertEqual(NativeAudioUnitGateDecisions.callKitDeactivationOwner(pairedActivationGeneration: 5, currentGeneration: 5),
                       .currentCall)
    }

    func testInterruptionEndedWhileStillDeactivatedKeepsTheHoldUntilActivation() {
        var t = AudioHoldTriggerState()
        _ = t.sessionDeactivated()
        XCTAssertEqual(t.deactivationTimerFired(), .add)
        XCTAssertEqual(t.interruptionBegan(), .none)
        XCTAssertEqual(t.interruptionEnded(), .none, "the session is still deactivated")
        XCTAssertEqual(t.sessionActivated(), .remove)
    }

    func testResetForgetsEverything() {
        var t = AudioHoldTriggerState()
        _ = t.interruptionBegan()
        t.reset()
        XCTAssertEqual(t, AudioHoldTriggerState())
        XCTAssertEqual(t.interruptionBegan(), .add)
    }
}

// MARK: - Test doubles

/// A virtual clock: `schedule` queues work, `advance` runs it in time order, `nowMs` is the virtual time.
final class ManualHoldClock {
    private(set) var nowMs: Int64 = 0
    private struct Item { let due: Int64; let work: () -> Void; var cancelled = false }
    private var items: [Int: Item] = [:]
    private var nextId = 0

    var schedule: HoldSchedule {
        return { [self] delay, work in
            nextId += 1
            let id = nextId
            items[id] = Item(due: nowMs + Int64((delay * 1000).rounded()), work: work)
            return { [self] in items[id]?.cancelled = true }
        }
    }

    func advance(by ms: Int64) {
        let target = nowMs + ms
        while true {
            var best: (id: Int, due: Int64)?
            for (id, item) in items where !item.cancelled && item.due <= target {
                if best == nil || (item.due, id) < (best!.due, best!.id) { best = (id, item.due) }
            }
            guard let next = best, let item = items[next.id] else { break }
            nowMs = next.due
            items[next.id]?.cancelled = true
            item.work()
        }
        nowMs = target
        items = items.filter { !$0.value.cancelled }
    }
}

final class SendLog {
    struct Entry { let atMs: Int64; let kind: UInt8; let body: Data; let route: HoldRoute }
    var entries: [Entry] = []
    var changes: [String] = []
    var neverAcked: [UInt16] = []
}
