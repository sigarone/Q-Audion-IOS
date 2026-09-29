import XCTest
@testable import QAudionEngine

/// TRACK B (2026-09-29, "phone always DTLS server when answering") — tests
/// for the pure SDP transform `forcePassiveRoleForFreshAnswer`. Mirrors the
/// Android suite for the identical function
/// (`PeerConnectionHolderForcePassiveRoleTest` in `PeerConnectionHolderTest.kt`).
///
/// Unlike `pinOwnAnswerToEstablishedDtlsRole` / `preserveDtlsRoleInUpgradeAnswer`
/// (renegotiation, keyed off an already-established local SDP), this is the
/// FIRST-negotiation path: it looks at the REMOTE OFFER's `a=setup` value
/// instead, and only ever rewrites `active` -> `passive`, never producing
/// `actpass` in an answer (forbidden by RFC 8842 §5.5).
///
/// No WebRTC import needed: the transform is deliberately RTC-type-free so
/// it runs on the macOS CI runner (`swift test`) without the WebRTC binary.
final class ForcePassiveRoleForFreshAnswerTests: XCTestCase {

    func testOfferActpassForcesAnswerSetupFromActiveToPassive() {
        let offer = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=setup:actpass\r\n"
        let answer = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=setup:active\r\n"

        let result = forcePassiveRoleForFreshAnswer(answerSdp: answer, remoteOfferSdp: offer, killSwitchActive: false)

        XCTAssertEqual(result, "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=setup:passive\r\n")
    }

    func testMultipleMSectionsAndBundleAllGetRewrittenConsistently() {
        let offer = "v=0\r\n"
            + "a=group:BUNDLE 0 1\r\n"
            + "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
            + "a=mid:0\r\n"
            + "a=setup:actpass\r\n"
            + "m=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
            + "a=mid:1\r\n"
        let answer = "v=0\r\n"
            + "a=group:BUNDLE 0 1\r\n"
            + "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
            + "a=mid:0\r\n"
            + "a=setup:active\r\n"
            + "m=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
            + "a=mid:1\r\n"
            + "a=setup:active\r\n"

        let result = forcePassiveRoleForFreshAnswer(answerSdp: answer, remoteOfferSdp: offer, killSwitchActive: false)

        let passiveCount = result.components(separatedBy: "a=setup:passive").count - 1
        XCTAssertEqual(passiveCount, 2, "both m-sections must be forced to passive")
        XCTAssertFalse(result.contains("a=setup:active"))
    }

    func testLfOnlySdpIsStillRewritten() {
        let offer = "v=0\na=setup:actpass\n"
        let answer = "v=0\nm=audio 9 UDP/TLS/RTP/SAVPF 111\na=setup:active\n"

        let result = forcePassiveRoleForFreshAnswer(answerSdp: answer, remoteOfferSdp: offer, killSwitchActive: false)

        XCTAssertEqual(result, "v=0\nm=audio 9 UDP/TLS/RTP/SAVPF 111\na=setup:passive\n")
    }

    func testAlreadyPassiveAnswerIsLeftUnchanged() {
        let offer = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=setup:actpass\r\n"
        let answer = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=setup:passive\r\n"

        let result = forcePassiveRoleForFreshAnswer(answerSdp: answer, remoteOfferSdp: offer, killSwitchActive: false)

        XCTAssertEqual(result, answer)
    }

    func testNeverProducesActpassInTheAnswer() {
        // Pathological input: answer somehow still has actpass. Not a valid
        // answer per RFC 8842, but the function must not "fix" it into
        // something equally wrong — it only ever targets a concrete `active`
        // line, so an actpass line is left exactly as-is.
        let offer = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=setup:actpass\r\n"
        let answer = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=setup:actpass\r\n"

        let result = forcePassiveRoleForFreshAnswer(answerSdp: answer, remoteOfferSdp: offer, killSwitchActive: false)

        XCTAssertEqual(result, answer)
        XCTAssertFalse(result.contains("a=setup:active\r"))
    }

    func testOfferNotActpassLeavesAnswerUnchanged() {
        // Defensive only — libwebrtc's NegotiateDtlsRole hard-rejects a
        // non-actpass offer before this code ever runs.
        let offer = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=setup:active\r\n"
        let answer = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=setup:passive\r\n"

        let result = forcePassiveRoleForFreshAnswer(answerSdp: answer, remoteOfferSdp: offer, killSwitchActive: false)

        XCTAssertEqual(result, answer)
    }

    func testNilRemoteOfferLeavesAnswerUnchanged() {
        let answer = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=setup:active\r\n"

        let result = forcePassiveRoleForFreshAnswer(answerSdp: answer, remoteOfferSdp: nil, killSwitchActive: false)

        XCTAssertEqual(result, answer)
    }

    func testKillSwitchActiveLeavesAnswerUnchangedEvenForActpassOffer() {
        let offer = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=setup:actpass\r\n"
        let answer = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=setup:active\r\n"

        let result = forcePassiveRoleForFreshAnswer(answerSdp: answer, remoteOfferSdp: offer, killSwitchActive: true)

        XCTAssertEqual(result, answer)
    }
}
