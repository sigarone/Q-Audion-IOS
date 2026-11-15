import XCTest
@testable import QAudionEngine

/// One known-answer vector for `VoiceConfidenceAnnounceCipher`, shared byte for byte with Android's
/// `VoiceConfidenceAnnounceCipherKatTest`. The sealed string was computed outside both apps (plain JCA and Python
/// `cryptography`, HKDF-SHA256 extract with a zero salt then expand, AES-256-GCM, nonce 00..0b). Android builds up to
/// this change send the same bytes without the trailing `=`, so both spellings must open.
///
/// This code was written on a machine that cannot compile Swift for iOS: the macOS CI job is what runs it.
final class VoiceConfidenceAnnounceCipherKatTests: XCTestCase {

    private let sessionKey = Data(0..<32)
    private let callId = "3f2c9d1e-7a44-4c1b-9a0e-5d6f7a8b9c0d"
    private let announce = VoiceConfidenceAnnounceCipher.Announce(seq: 42, confidence: 0.125, atEpochMs: 1_700_000_000_999)
    private let sealed = "AAECAwQFBgcICQoLAY7ZpmUszUF61X/wkeVQWRr6n+XBvs47II0nzbo+UqI="

    func testOpensTheVectorWithAndWithoutPadding() {
        XCTAssertEqual(VoiceConfidenceAnnounceCipher.open(sessionKey: sessionKey, callId: callId, payload: sealed), announce)
        let unpadded = String(sealed.dropLast())
        XCTAssertEqual(VoiceConfidenceAnnounceCipher.open(sessionKey: sessionKey, callId: callId, payload: unpadded), announce)
    }

    func testSealsPaddedBase64ThatOpens() throws {
        let out = try XCTUnwrap(VoiceConfidenceAnnounceCipher.seal(sessionKey: sessionKey, callId: callId, announce: announce))
        XCTAssertEqual(out.count, sealed.count)
        XCTAssertEqual(VoiceConfidenceAnnounceCipher.open(sessionKey: sessionKey, callId: callId, payload: out), announce)
    }
}
