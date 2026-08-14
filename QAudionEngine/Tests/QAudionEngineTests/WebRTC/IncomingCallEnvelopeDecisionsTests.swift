import XCTest
@testable import QAudionEngine

/// W-DCSTUCK (2026-08-13) — regression tests for the `call_incoming`
/// duplicate guard.
///
/// The bug these lock down: an iOS→iOS call ships two `call_offer` envelopes
/// under one `call_id` — a vestigial `sdp:""` one from `beginAndroidOutgoing`
/// that rings the callee, then the REAL SDP-bearing one from
/// `startOutgoingCall`. The server relays both as `call_incoming`. The W450
/// duplicate guard dropped the second one wholesale, SDP included, so the
/// callee never built a `webRtcController`, answered with an empty SDP, and the
/// caller's PeerConnection stayed in HAVE_LOCAL_OFFER for the whole call —
/// sealed-audio DataChannel stuck at `.connecting` (`dcmux tx dc=0 … st=0` on
/// every real call), 100% of the voice relayed through the VPS.
///
/// Pure decision, no WebRTC import: runs on CI without the WebRTC binary.
final class IncomingCallEnvelopeDecisionsTests: XCTestCase {

    private typealias Sut = IncomingCallEnvelopeDecisions

    /// Envelope 1 — first sighting of this call. Full provisioning path.
    func testFirstEnvelopeProvisionsNormally() {
        XCTAssertEqual(
            Sut.resolveDuplicateCallIncoming(
                sameCallProvisioned: false, differentCallActive: false,
                sdpLength: 0, hasWebRtcController: false),
            .provisionNormally)
    }

    /// Envelope 2 — THE REGRESSION. Same call, already provisioned, carries the
    /// WebRTC SDP, no controller built yet: the SDP must be consumed, not binned.
    func testSecondEnvelopeWithSdpIsRescued() {
        XCTAssertEqual(
            Sut.resolveDuplicateCallIncoming(
                sameCallProvisioned: true, differentCallActive: false,
                sdpLength: 1842, hasWebRtcController: false),
            .rescueWebRtcOffer)
    }

    /// Envelope 3+ — the SDP was already consumed (controller exists). Nothing
    /// new on the wire; the W450 drop still applies, or CallKit gets a second
    /// report and the controller is rebuilt mid-call.
    func testSdpDuplicateAfterControllerExistsIsDropped() {
        XCTAssertEqual(
            Sut.resolveDuplicateCallIncoming(
                sameCallProvisioned: true, differentCallActive: false,
                sdpLength: 1842, hasWebRtcController: true),
            .dropDuplicate)
    }

    /// A genuine duplicate of the vestigial offer carries nothing new.
    func testProvisionedDuplicateWithoutSdpIsDropped() {
        XCTAssertEqual(
            Sut.resolveDuplicateCallIncoming(
                sameCallProvisioned: true, differentCallActive: false,
                sdpLength: 0, hasWebRtcController: false),
            .dropDuplicate)
    }

    /// A DIFFERENT call already owns the device — adopting its SDP would point
    /// the live PeerConnection at the wrong peer. The rescue must never win
    /// over this, whatever the SDP says.
    func testDifferentCallActiveAlwaysDropsEvenWithSdp() {
        XCTAssertEqual(
            Sut.resolveDuplicateCallIncoming(
                sameCallProvisioned: false, differentCallActive: true,
                sdpLength: 1842, hasWebRtcController: false),
            .dropDuplicate)
    }

    /// PushKit woke us first: `activeCallKitId` is set but the responder
    /// integration is not built, so `sameCallProvisioned` is false. This is
    /// W450's case (B) — it must still reach the full provisioning path even
    /// when the envelope carries SDP.
    func testPushKitFirstStillProvisionsNormallyWithSdp() {
        XCTAssertEqual(
            Sut.resolveDuplicateCallIncoming(
                sameCallProvisioned: false, differentCallActive: false,
                sdpLength: 1842, hasWebRtcController: false),
            .provisionNormally)
    }
}
