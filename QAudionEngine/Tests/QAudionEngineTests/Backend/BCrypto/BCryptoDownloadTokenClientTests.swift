import XCTest
@testable import QAudionEngine

/// Pure-codec tests for ``IssuedDownloadToken``. Network round-trip
/// against a real bcrypto-server is exercised in the integration
/// tests run on Codemagic with a staging endpoint.
final class BCryptoDownloadTokenClientTests: XCTestCase {

    func test_decode_validResponse() throws {
        let json = """
        {
          "file_id": "01940000-0000-7000-8000-aaaabbbbcccc",
          "recipient_user_id": "00000000-0000-0000-0000-cccccccccccc",
          "expires_at_ms": 1700604800000,
          "max_uses": 10,
          "token_hex": "deadbeef00000000000000000000000000000000000000000000000000000000"
        }
        """
        // .utf8 encoding of a Swift String literal never fails.
        // swiftlint:disable:next force_unwrapping
        let data = json.data(using: .utf8)!
        let issued = try IssuedDownloadToken.decode(data)
        XCTAssertEqual(issued.fileId, "01940000-0000-7000-8000-aaaabbbbcccc")
        XCTAssertEqual(issued.recipientUserId, "00000000-0000-0000-0000-cccccccccccc")
        XCTAssertEqual(issued.expiresAtMs, 1700604800000)
        XCTAssertEqual(issued.maxUses, 10)
        XCTAssertEqual(issued.tokenHex.count, 64)  // SHA-256 hex
    }

    func test_decode_rejectsMissingFileId() {
        let json = """
        {"recipient_user_id":"r","expires_at_ms":1,"max_uses":1,"token_hex":"a"}
        """
        // .utf8 encoding of a Swift String literal never fails.
        // swiftlint:disable:next force_unwrapping
        XCTAssertThrowsError(try IssuedDownloadToken.decode(json.data(using: .utf8)!))
    }

    func test_decode_rejectsMissingTokenHex() {
        let json = """
        {"file_id":"f","recipient_user_id":"r","expires_at_ms":1,"max_uses":1}
        """
        // .utf8 encoding of a Swift String literal never fails.
        // swiftlint:disable:next force_unwrapping
        XCTAssertThrowsError(try IssuedDownloadToken.decode(json.data(using: .utf8)!))
    }

    func test_claim_dropsRecipientUserId() {
        let issued = IssuedDownloadToken(
            fileId: "f1", recipientUserId: "r1",
            expiresAtMs: 1700000000000, maxUses: 5,
            tokenHex: "abc"
        )
        let claim = issued.claim
        XCTAssertEqual(claim.fileId, "f1")
        XCTAssertEqual(claim.expiresAtMs, 1700000000000)
        XCTAssertEqual(claim.maxUses, 5)
        XCTAssertEqual(claim.tokenHex, "abc")
        // Verify (visually): claim has no recipient_user_id field —
        // server re-derives it from the JWT bearer.
    }
}
