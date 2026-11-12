import XCTest
@testable import QAudionEngine

/// An OFFER of another call arriving while a call is live must leave the live call as it is.
final class LiveCallOfferRoutingTests: XCTestCase {

    private let liveId = "aaaaaaaa-1111-2222-3333-444444444444"
    private let otherId = "bbbbbbbb-1111-2222-3333-444444444444"

    private func offer(callId: String, round: Int = 1) -> AndroidHandshakeBundle {
        AndroidHandshakeBundle(
            kind: .offer, callId: callId,
            pqcPublicKey: Data(repeating: 0xA1, count: 1568).base64EncodedString(),
            x25519PublicKey: Data(repeating: 0xA2, count: 32).base64EncodedString(),
            sasCommit: nil,
            rekeyNonce: V6TestFixtures.rekeyNonce.base64EncodedString(), rekeyRound: round)
    }

    private struct Seen {
        var processing: [String] = []
        var fatals: [String] = []
        var sent = 0
        var keyInstalls = 0
        var relayReady = 0
    }

    private func receive(_ integ: QAudionCallIntegration, _ bundle: AndroidHandshakeBundle, callId: String) async -> Seen {
        var seen = Seen()
        integ.sendCallProcessing = { cid, _ in seen.processing.append(cid) }
        integ.onHandshakeFatal = { _, reason in seen.fatals.append(reason) }
        integ.onPqcSessionKeyEstablished = { _ in seen.keyInstalls += 1 }
        integ.onRelaySessionReady = { _, _, _ in seen.relayReady += 1 }
        _ = try? await integ.onAndroidBundleReceived(
            bundle: bundle, callId: callId, callerId: "peer-1", capsBind: CapsBind.analyze(bundle: bundle),
            sendOpaqueRaw: { _ in seen.sent += 1 })
        return seen
    }

    func testPolicy() {
        XCTAssertTrue(QAudionCallIntegration.isOfferForOtherLiveCall(
            offerCallId: otherId, sessionCallIds: [liveId], isLive: true))
        XCTAssertFalse(QAudionCallIntegration.isOfferForOtherLiveCall(
            offerCallId: liveId.uppercased(), sessionCallIds: [liveId], isLive: true), "the live call's own OFFER")
        XCTAssertFalse(QAudionCallIntegration.isOfferForOtherLiveCall(
            offerCallId: otherId, sessionCallIds: [liveId], isLive: false), "no live call")
        XCTAssertFalse(QAudionCallIntegration.isOfferForOtherLiveCall(
            offerCallId: otherId, sessionCallIds: [], isLive: true), "no session held")
    }

    /// A round-1 OFFER of another call, with a call live: nothing happens for it, the live call keeps its session.
    func testRoundOneOfferOfAnotherCallLeavesTheLiveCallAlone() async {
        let integ = QAudionCallIntegration()
        integ.configureLiveCallForTesting(callId: liveId)
        let seen = await receive(integ, offer(callId: otherId), callId: otherId)
        XCTAssertTrue(seen.processing.isEmpty, "the OFFER was not taken up")
        XCTAssertTrue(seen.fatals.isEmpty)
        XCTAssertEqual(seen.sent, 0)
        XCTAssertEqual(seen.keyInstalls, 0)
        XCTAssertEqual(seen.relayReady, 0)
        XCTAssertTrue(integ.hasProcessedOffer(callId: liveId))
        XCTAssertFalse(integ.hasProcessedOffer(callId: otherId))
    }

    /// Any other round of another call is dropped the same way, without ending the live call.
    func testRoundTwoOfferOfAnotherCallDoesNotEndTheLiveCall() async {
        let integ = QAudionCallIntegration()
        integ.configureLiveCallForTesting(callId: liveId)
        let seen = await receive(integ, offer(callId: otherId, round: 2), callId: otherId)
        XCTAssertTrue(seen.fatals.isEmpty)
        XCTAssertTrue(seen.processing.isEmpty)
        XCTAssertTrue(integ.hasProcessedOffer(callId: liveId))
    }

    /// Controls: the live call's own OFFER and an OFFER with no live call are taken up as before.
    func testOwnOfferAndOfferWithoutLiveCallAreTakenUp() async {
        let live = QAudionCallIntegration()
        live.configureLiveCallForTesting(callId: liveId)
        let own = await receive(live, offer(callId: liveId, round: 2), callId: liveId)
        XCTAssertEqual(own.processing, [liveId])

        let idle = QAudionCallIntegration()
        let first = await receive(idle, offer(callId: otherId), callId: otherId)
        XCTAssertEqual(first.processing, [otherId])
    }
}
