import XCTest
@testable import QAudionEngine

/// W-MEDIAATACCEPT (option b) — pure-function coverage for
/// `RingSignalingDecisions`. No locks, no timers, no `Date()` — every case
/// is a plain input/output assertion.
final class RingSignalingDecisionsTests: XCTestCase {

    // MARK: - offerUpdate (W-BLANKRERINGSDP parity)

    func testOfferUpdateKeepsNonEmptyIncoming() {
        XCTAssertEqual(
            RingSignalingDecisions.offerUpdate(existingSdp: nil, incomingSdp: "v=0..."),
            .keepIncoming
        )
    }

    func testOfferUpdateIgnoresEmptyOverNonEmpty() {
        XCTAssertEqual(
            RingSignalingDecisions.offerUpdate(existingSdp: "v=0...", incomingSdp: ""),
            .keepExisting
        )
    }

    func testOfferUpdateSequenceEmptyThenSdpThenEmptyKeepsTheSdp() {
        // "vuota poi SDP poi vuota → si tiene l'SDP"
        var stashed: String?
        func apply(_ incoming: String) {
            switch RingSignalingDecisions.offerUpdate(existingSdp: stashed, incomingSdp: incoming) {
            case .keepIncoming: stashed = incoming
            case .keepExisting: break
            }
        }
        apply("")
        XCTAssertNil(stashed)
        apply("v=0...real-sdp...")
        XCTAssertEqual(stashed, "v=0...real-sdp...")
        apply("")
        XCTAssertEqual(stashed, "v=0...real-sdp...", "a blank replay must never blank out a stashed offer")
    }

    func testOfferUpdateKeepsLastNonEmptySdp() {
        var stashed: String?
        func apply(_ incoming: String) {
            switch RingSignalingDecisions.offerUpdate(existingSdp: stashed, incomingSdp: incoming) {
            case .keepIncoming: stashed = incoming
            case .keepExisting: break
            }
        }
        apply("v=0...first...")
        apply("v=0...second...")
        XCTAssertEqual(stashed, "v=0...second...", "the peer's latest non-empty OFFER always wins")
    }

    // MARK: - shouldStartMediaPlane

    func testShouldStartMediaPlaneFalseWhenLegacyMode() {
        XCTAssertFalse(RingSignalingDecisions.shouldStartMediaPlane(
            mode: 0, accepted: true, hasSdp: true, state: .none
        ))
    }

    func testShouldStartMediaPlaneFalseBeforeAccept() {
        XCTAssertFalse(RingSignalingDecisions.shouldStartMediaPlane(
            mode: 1, accepted: false, hasSdp: true, state: .none
        ))
    }

    func testShouldStartMediaPlaneWaitsForSdpAfterAccept() {
        // ACCEPTED without SDP (cold-start PushKit/FCM race, §2.1) — not
        // yet startable, but not a failure either; the 2s timer decides.
        XCTAssertFalse(RingSignalingDecisions.shouldStartMediaPlane(
            mode: 1, accepted: true, hasSdp: false, state: .awaitingSdp
        ))
    }

    func testShouldStartMediaPlaneTrueOnceAcceptedAndSdpPresent() {
        XCTAssertTrue(RingSignalingDecisions.shouldStartMediaPlane(
            mode: 1, accepted: true, hasSdp: true, state: .none
        ))
        XCTAssertTrue(RingSignalingDecisions.shouldStartMediaPlane(
            mode: 1, accepted: true, hasSdp: true, state: .awaitingSdp
        ))
    }

    func testShouldStartMediaPlaneIdempotentOnceBuildingOrDone() {
        for state: RingSignalingRegistry.MediaPlaneState in [.building, .ready, .failed] {
            XCTAssertFalse(RingSignalingDecisions.shouldStartMediaPlane(
                mode: 1, accepted: true, hasSdp: true, state: state
            ), "state \(state) must never re-trigger a build")
        }
    }

    // MARK: - shouldHoldAccept (I11)

    func testShouldHoldAcceptFalseWhenLegacyMode() {
        XCTAssertFalse(RingSignalingDecisions.shouldHoldAccept(
            mode: 0, acceptedAtMs: nil, answerSent: false, released: false, nowMs: 1_000
        ))
    }

    func testShouldHoldAcceptTrueBeforeHumanAccept() {
        XCTAssertTrue(RingSignalingDecisions.shouldHoldAccept(
            mode: 1, acceptedAtMs: nil, answerSent: false, released: false, nowMs: 1_000
        ))
    }

    func testShouldHoldAcceptFalseOnceAnswerSent() {
        XCTAssertFalse(RingSignalingDecisions.shouldHoldAccept(
            mode: 1, acceptedAtMs: 1_000, answerSent: true, released: false, nowMs: 1_100
        ))
    }

    func testShouldHoldAcceptTrueWithinReserveWindowWithoutAnswer() {
        XCTAssertTrue(RingSignalingDecisions.shouldHoldAccept(
            mode: 1, acceptedAtMs: 1_000, answerSent: false, released: false, nowMs: 1_000 + 4_999
        ))
    }

    func testShouldHoldAcceptFalseAfterFiveSecondReserveElapsed() {
        XCTAssertFalse(RingSignalingDecisions.shouldHoldAccept(
            mode: 1, acceptedAtMs: 1_000, answerSent: false, released: false, nowMs: 1_000 + 5_000
        ))
    }

    func testShouldHoldAcceptFalseOnceAlreadyReleased() {
        XCTAssertFalse(RingSignalingDecisions.shouldHoldAccept(
            mode: 1, acceptedAtMs: nil, answerSent: false, released: true, nowMs: 1_000
        ))
    }

    // MARK: - audioIOGate

    func testAudioIOGateProceedsWhenNotSignalingOnlyMode() {
        XCTAssertEqual(
            RingSignalingDecisions.audioIOGate(mode: 0, mediaPlane: .building, predictedNative: true),
            .proceed
        )
    }

    func testAudioIOGateProceedsWhenPredictedNonNative() {
        // A call that will use the custom (non-native) audio path never
        // needs to wait on the PeerConnection.
        XCTAssertEqual(
            RingSignalingDecisions.audioIOGate(mode: 1, mediaPlane: .building, predictedNative: false),
            .proceed
        )
    }

    func testAudioIOGateDefersWhilePcIsBuilding() {
        for state: RingSignalingRegistry.MediaPlaneState in [.none, .awaitingSdp, .building] {
            XCTAssertEqual(
                RingSignalingDecisions.audioIOGate(mode: 1, mediaPlane: state, predictedNative: true),
                .deferGate5,
                "state \(state) must defer when native is predicted"
            )
        }
    }

    func testAudioIOGateProceedsOncePcIsReadyOrFailed() {
        for state: RingSignalingRegistry.MediaPlaneState in [.ready, .failed] {
            XCTAssertEqual(
                RingSignalingDecisions.audioIOGate(mode: 1, mediaPlane: state, predictedNative: true),
                .proceed
            )
        }
    }

    // MARK: - iceAdmit

    func testIceAdmitDropsDifferentCallId() {
        XCTAssertEqual(
            RingSignalingDecisions.iceAdmit(envelopeCallId: "aaa", boundCallId: "bbb", count: 0),
            .drop
        )
    }

    func testIceAdmitDropsWhenNoBoundCall() {
        XCTAssertEqual(
            RingSignalingDecisions.iceAdmit(envelopeCallId: "aaa", boundCallId: "", count: 0),
            .drop
        )
    }

    func testIceAdmitIsCaseInsensitiveOnCallId() {
        XCTAssertEqual(
            RingSignalingDecisions.iceAdmit(envelopeCallId: "AAA-Call", boundCallId: "aaa-call", count: 0),
            .queue
        )
    }

    func testIceAdmitEnforcesCapAtOneHundred() {
        XCTAssertEqual(
            RingSignalingDecisions.iceAdmit(envelopeCallId: "aaa", boundCallId: "aaa", count: 99),
            .queue
        )
        XCTAssertEqual(
            RingSignalingDecisions.iceAdmit(envelopeCallId: "aaa", boundCallId: "aaa", count: 100),
            .drop
        )
    }
}
