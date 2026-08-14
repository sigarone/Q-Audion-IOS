import XCTest
@testable import QAudionEngine

/// W-ACCEPTGATE-SDP (2026-08-14) — regression tests for WIRE_SPEC §3.5's
/// caller-side latch.
///
/// The bug: rescuing the SDP-bearing `call_incoming` (W-DCSTUCK) made the callee
/// answer with SDP at RING time instead of at accept time. That armed the 7 s
/// rollout-safety countdown while the callee was still ringing, so the caller
/// flipped itself to connected on its own — "uno sembra connesso, l'altro ancora
/// in connessione".
///
/// Pure decision, no WebRTC import: runs on CI without the WebRTC binary.
final class AcceptGateDecisionsTests: XCTestCase {

    private typealias Sut = AcceptGateDecisions

    /// THE REGRESSION. SDP answer at ring time must NOT start a countdown that
    /// can declare the call connected without the peer's `call_accepted`.
    func testSdpBearingAnswerDoesNotArmTheFallback() {
        XCTAssertEqual(
            Sut.resolve(peerAlreadyAccepted: false, answerCarriedSdp: true),
            .waitForAcceptOnly)
    }

    /// A bare answer IS the peer saying a human accepted — the pre-W-DCSTUCK
    /// iOS↔iOS shape, and the case the safety net was written for. Unchanged.
    func testBareAnswerStillArmsTheFallback() {
        XCTAssertEqual(
            Sut.resolve(peerAlreadyAccepted: false, answerCarriedSdp: false),
            .waitForAcceptWithFallback)
    }

    /// `call_accepted` can land BEFORE the answer (the callee's accept and its
    /// handshake race). Both flags in hand → finalize, whatever the answer was.
    func testAcceptAlreadyArrivedFinalizesRegardlessOfSdp() {
        for sdp in [true, false] {
            XCTAssertEqual(
                Sut.resolve(peerAlreadyAccepted: true, answerCarriedSdp: sdp),
                .finalizeNow,
                "accept already latched must win (answerCarriedSdp=\(sdp))")
        }
    }

    /// Whatever the branch, the local handshake flag is always recorded — only
    /// the countdown is conditional. Encoded here as: no input combination is
    /// allowed to drop the call on the floor.
    func testEveryOutcomeIsActionable() {
        for accepted in [true, false] {
            for sdp in [true, false] {
                let action = Sut.resolve(peerAlreadyAccepted: accepted, answerCarriedSdp: sdp)
                XCTAssertTrue(
                    action == .finalizeNow
                        || action == .waitForAcceptWithFallback
                        || action == .waitForAcceptOnly)
            }
        }
    }
}
