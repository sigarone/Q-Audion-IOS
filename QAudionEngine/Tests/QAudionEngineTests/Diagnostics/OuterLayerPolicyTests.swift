import XCTest
@testable import QAudionEngine

/// What each leg of the sealed-audio path does with a frame, for every state of the call's outer layer. Pure decisions: the
/// matrices below are the whole contract (a frame of a sealed call is opened or held, never delivered raw; a call without the
/// outer layer uses the DataChannel only).
final class OuterLayerPolicyTests: XCTestCase {

    func testTxMatrix() {
        let cases: [(OuterLayerMode, Bool, OuterLayerPolicy.Tx)] = [
            (.sealed, true, .seal),
            (.sealed, false, .hold),
            (.unknown, true, .seal),
            (.unknown, false, .plainEitherLeg),
            (.noOuter, false, .plainDataChannelOnly),
            (.noOuter, true, .plainDataChannelOnly),
            (.offLocalInstall, false, .plainDataChannelOnly),
            (.offPeerInstall, true, .plainDataChannelOnly),
        ]
        for (mode, installed, expected) in cases {
            XCTAssertEqual(OuterLayerPolicy.tx(mode: mode, sealerInstalled: installed), expected, "\(mode) installed=\(installed)")
        }
    }

    func testRxMatrixOnBothLegs() {
        for leg in [OuterLayerLeg.dataChannel, .wsRelay] {
            XCTAssertEqual(OuterLayerPolicy.rx(mode: .sealed, leg: leg, recvSealerInstalled: true), .open)
            // Fail closed: the sealer is not there yet, so the frame is held and never passed through.
            XCTAssertEqual(OuterLayerPolicy.rx(mode: .sealed, leg: leg, recvSealerInstalled: false), .hold)
            XCTAssertEqual(OuterLayerPolicy.rx(mode: .unknown, leg: leg, recvSealerInstalled: true), .open)
            XCTAssertEqual(OuterLayerPolicy.rx(mode: .unknown, leg: leg, recvSealerInstalled: false), .passThrough)
        }
        for mode in [OuterLayerMode.noOuter, .offLocalInstall, .offPeerInstall] {
            XCTAssertEqual(OuterLayerPolicy.rx(mode: mode, leg: .dataChannel, recvSealerInstalled: false), .passThrough)
            XCTAssertEqual(OuterLayerPolicy.rx(mode: mode, leg: .wsRelay, recvSealerInstalled: false), .drop)
            XCTAssertEqual(OuterLayerPolicy.rx(mode: mode, leg: .wsRelay, recvSealerInstalled: true), .drop)
        }
    }

    func testOnlyTheOffModesCloseTheRelay() {
        XCTAssertFalse(OuterLayerMode.sealed.isOuterOff)
        XCTAssertFalse(OuterLayerMode.unknown.isOuterOff)
        XCTAssertTrue(OuterLayerMode.noOuter.isOuterOff)
        XCTAssertTrue(OuterLayerMode.offLocalInstall.isOuterOff)
        XCTAssertTrue(OuterLayerMode.offPeerInstall.isOuterOff)
    }

    func testTheOuterOffFrameIsExactlyTwoBytesFromTheDataChannel() {
        let frame = Data([0x03, 0x03])
        XCTAssertEqual(OuterLayerPolicy.outerOffFrame, frame)
        XCTAssertEqual(WireRelayFrameCodec.muxControl, 0x03)
        XCTAssertEqual(WireRelayFrameCodec.controlKindOuterOff, 0x03)
        XCTAssertTrue(OuterLayerPolicy.isOuterOffFromDataChannel(frame, leg: .dataChannel))
        // The same bytes on the relay are not the signal.
        XCTAssertFalse(OuterLayerPolicy.isOuterOffFromDataChannel(frame, leg: .wsRelay))
        // Nothing else is: shorter, longer, other kind, other mux byte, a hang-up or retransmit request frame.
        for other in [Data(), Data([0x03]), Data([0x03, 0x03, 0x00]), Data([0x03, 0x02]), Data([0x03, 0x01]), Data([0x01, 0x03])] {
            XCTAssertFalse(OuterLayerPolicy.isOuterOffFromDataChannel(other, leg: .dataChannel), "\(Array(other))")
        }
        // A slice that does not start at index 0 is judged by its bytes.
        let slice = Data([0xFF, 0x03, 0x03]).dropFirst()
        XCTAssertTrue(OuterLayerPolicy.isOuterOffFromDataChannel(Data(slice), leg: .dataChannel))
        // Shorter than any sealed frame by construction.
        XCTAssertLessThan(frame.count, OuterLayerPolicy.minSealedFrameLength)
    }

    func testTheTagIsAdvertised() {
        XCTAssertEqual(CallCapabilities.outerOffV1, "outer-off-v1")
        XCTAssertTrue(CallCapabilities.local.contains("outer-off-v1"))
    }

    func testTheRetransmitCacheIsZeroedAndForgottenAtASendSwitch() {
        let ring = NackRetransmitRing(capacity: 4)
        ring.record(seq: 1, envelope: Data([1, 2, 3]))
        ring.record(seq: 2, envelope: Data([4, 5, 6]))
        XCTAssertEqual(ring.lookup(seq: 1), Data([1, 2, 3]))
        ring.clear()
        XCTAssertNil(ring.lookup(seq: 1))
        XCTAssertNil(ring.lookup(seq: 2))
        // A resend is the cached bytes unchanged.
        ring.record(seq: 5, envelope: Data([9, 9]))
        XCTAssertEqual(ring.lookup(seq: 5), Data([9, 9]))
    }
}
