import XCTest
@testable import QAudionEngine

/// GAP-3 fix (2026-07-07 cross-platform matrix audit) — tests for the pure
/// SDP transform `preserveDtlsRoleInUpgradeAnswer`. Mirrors the Desktop
/// (PeerConnectionManager.ts) and Android (PeerConnectionHolder.kt) suites
/// for the identical function.
///
/// No WebRTC import needed: the transform is deliberately RTC-type-free so
/// it runs on the macOS CI runner (`swift test`) without the WebRTC binary.
final class PreserveDtlsRoleInUpgradeAnswerTests: XCTestCase {

    private let sampleAnswerActPass = """
    v=0
    o=- 1 1 IN IP4 127.0.0.1
    s=-
    t=0 0
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=setup:actpass
    m=video 9 UDP/TLS/RTP/SAVPF 96
    a=setup:actpass
    """

    // No established local SDP (nil) — the very first negotiation of the
    // call, no committed role to preserve yet. Must be a no-op.
    func testNilEstablishedSdpIsNoOp() {
        let result = preserveDtlsRoleInUpgradeAnswer(answerSdp: sampleAnswerActPass, establishedLocalSdp: nil)
        XCTAssertEqual(result, sampleAnswerActPass)
    }

    // Established local SDP carries no a=setup line at all (malformed /
    // pre-DTLS state) — must be a no-op, never crash on a missing match.
    func testEstablishedSdpWithNoSetupLineIsNoOp() {
        let established = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"
        let result = preserveDtlsRoleInUpgradeAnswer(answerSdp: sampleAnswerActPass, establishedLocalSdp: established)
        XCTAssertEqual(result, sampleAnswerActPass)
    }

    // We committed "active" locally → the peer's answer MUST be pinned to
    // "passive" on every m-section (both audio and video), regardless of
    // whether the answer proposed actpass, active, or passive.
    func testEstablishedActiveRolePinsAnswerToPassive() {
        let established = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=setup:active\r\n"
        let result = preserveDtlsRoleInUpgradeAnswer(answerSdp: sampleAnswerActPass, establishedLocalSdp: established)
        XCTAssertFalse(result.contains("a=setup:actpass"))
        XCTAssertFalse(result.contains("a=setup:active"))
        let passiveCount = result.components(separatedBy: "a=setup:passive").count - 1
        XCTAssertEqual(passiveCount, 2, "both m-sections must be pinned to passive")
    }

    // Symmetric: established "passive" → answer pinned to "active".
    func testEstablishedPassiveRolePinsAnswerToActive() {
        let established = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=setup:passive\r\n"
        let result = preserveDtlsRoleInUpgradeAnswer(answerSdp: sampleAnswerActPass, establishedLocalSdp: established)
        XCTAssertFalse(result.contains("a=setup:actpass"))
        XCTAssertFalse(result.contains("a=setup:passive"))
        let activeCount = result.components(separatedBy: "a=setup:active").count - 1
        XCTAssertEqual(activeCount, 2, "both m-sections must be pinned to active")
    }

    // A pre-existing "active"/"passive" in the answer (not actpass) must
    // ALSO be overridden if it disagrees with the established complement —
    // the pin is unconditional on every recognized setup line, not just
    // actpass ones (mirrors the Desktop/Android regex which matches all
    // three values).
    func testDisagreeingConcreteAnswerRoleIsOverridden() {
        let established = "a=setup:active\r\n"
        let answer = "m=video 9 UDP/TLS/RTP/SAVPF 96\r\na=setup:active\r\n"
        let result = preserveDtlsRoleInUpgradeAnswer(answerSdp: answer, establishedLocalSdp: established)
        XCTAssertTrue(result.contains("a=setup:passive"))
        XCTAssertFalse(result.contains("a=setup:active"))
    }
}
