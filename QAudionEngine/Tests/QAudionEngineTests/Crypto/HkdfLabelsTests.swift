import XCTest
@testable import QAudionEngine

final class HkdfLabelsTests: XCTestCase {

    func test_messageKey_isCanonicalString() {
        XCTAssertEqual(String(data: HkdfLabels.messageKey, encoding: .utf8), "q-audion-msg-key")
    }

    func test_hybridPqcSessionKey_isCanonicalString() {
        XCTAssertEqual(String(data: HkdfLabels.hybridPqcSessionKey, encoding: .utf8), "q-audion-session-key")
    }

    func test_nfcCollaborativePsk_isCanonicalString() {
        XCTAssertEqual(String(data: HkdfLabels.nfcCollaborativePsk, encoding: .utf8), "Q-Audion NFC Collaborative PSK v1")
    }

    func test_deviceLinkPsk_isCanonicalString() {
        XCTAssertEqual(String(data: HkdfLabels.deviceLinkPsk, encoding: .utf8), "qaudion-device-link-v1")
    }

    func test_frameChainAudio_isCanonicalString() {
        XCTAssertEqual(String(data: HkdfLabels.frameChainAudio, encoding: .utf8), "q-audion-frame-key")
    }

    func test_frameChainVideo_isCanonicalString() {
        XCTAssertEqual(String(data: HkdfLabels.frameChainVideo, encoding: .utf8), "q-audion-video-frame-key")
    }

    func test_fileKey_isCanonicalString() {
        XCTAssertEqual(String(data: HkdfLabels.fileKey, encoding: .utf8), "q-audion-file-key")
    }

    func test_recoveryAuth_isCanonicalString() {
        XCTAssertEqual(String(data: HkdfLabels.recoveryAuth, encoding: .utf8), "recovery-auth-v1")
    }

    func test_hybridPqcSaltV1_isCanonicalString() {
        XCTAssertEqual(String(data: HkdfLabels.hybridPqcSaltV1, encoding: .utf8), "q-audion-hybrid-pqc-v1")
    }

    func test_deviceLinkSalt_isCanonicalString() {
        XCTAssertEqual(String(data: HkdfLabels.deviceLinkSalt, encoding: .utf8), "qaudion-link-salt")
    }

    func test_symmetricKeyBytes_is32() {
        XCTAssertEqual(HkdfLabels.symmetricKeyBytes, 32)
    }

    func test_allLabels_roundTripUtf8() {
        XCTAssertTrue(HkdfLabels.verifyAllUtf8RoundTrip())
    }

    func test_messageKey_byteCountMatchesUtf8Length() {
        // "q-audion-msg-key" = 16 ASCII bytes
        XCTAssertEqual(HkdfLabels.messageKey.count, 16)
    }

    func test_nfcCollaborativePsk_byteCountIs33() {
        // "Q-Audion NFC Collaborative PSK v1" = 33 ASCII bytes
        XCTAssertEqual(HkdfLabels.nfcCollaborativePsk.count, 33)
    }
}
