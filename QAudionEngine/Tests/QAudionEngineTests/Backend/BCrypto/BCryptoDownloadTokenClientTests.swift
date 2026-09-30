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

    // MARK: - Item A-iOS (2026-09-30 file-transfer plan): computeMaxUses KAT

    func test_computeMaxUses_nonPositiveChunkCount_returnsNil() {
        // Matches Android leaving max_uses unset when the size is unknown
        // — the server then applies its own default.
        XCTAssertNil(BCryptoDownloadTokenClient.computeMaxUses(totalChunks: 0))
        XCTAssertNil(BCryptoDownloadTokenClient.computeMaxUses(totalChunks: -1))
    }

    func test_computeMaxUses_smallFile_hitsTheFloor() {
        // 1 chunk (64 KiB): restarts=1, desired=4, floored to the server's
        // own default-intent floor of 10.
        XCTAssertEqual(BCryptoDownloadTokenClient.computeMaxUses(totalChunks: 1), 10)
        // Still under the 64-chunk (4 MiB) threshold for a first extra
        // restart — same floor.
        XCTAssertEqual(BCryptoDownloadTokenClient.computeMaxUses(totalChunks: 63), 10)
    }

    func test_computeMaxUses_scalesWithChunkCount() {
        // 64 chunks -> 1 extra restart -> restarts=2, desired=8 -> still
        // floored to 10 (8 < 10).
        XCTAssertEqual(BCryptoDownloadTokenClient.computeMaxUses(totalChunks: 64), 10)
        // 128 chunks -> 2 extra restarts -> restarts=3, desired=12 -> above
        // the floor, so the actual scaled value is returned.
        XCTAssertEqual(BCryptoDownloadTokenClient.computeMaxUses(totalChunks: 128), 12)
        // 192 chunks -> 3 extra restarts -> restarts=4, desired=16.
        XCTAssertEqual(BCryptoDownloadTokenClient.computeMaxUses(totalChunks: 192), 16)
        // Monotonically non-decreasing in the chunk count.
        var previous: Int32 = 0
        for chunks in stride(from: 1, through: 2000, by: 37) {
            let value = BCryptoDownloadTokenClient.computeMaxUses(totalChunks: chunks) ?? 0
            XCTAssertGreaterThanOrEqual(value, previous, "must not decrease as chunks grow (chunks=\(chunks))")
            previous = value
        }
    }

    func test_computeMaxUses_largestAllowedFile_wellUnderTheCeiling() {
        // 5 GiB / 64 KiB = 81 920 chunks (ChatFileAttachmentReceiver's own
        // DoS guard). Pinned exact value so the formula's real-world output
        // is on record, not just its shape.
        let maxRealisticChunks = 81_920
        let result = BCryptoDownloadTokenClient.computeMaxUses(totalChunks: maxRealisticChunks)
        XCTAssertEqual(result, 5_124)
        XCTAssertLessThan(result ?? .max, BCryptoDownloadTokenClient.maxDownloadTokenMaxUses,
                           "the largest legitimate file must never be clamped by the safety ceiling")
    }

    func test_computeMaxUses_pathologicalChunkCount_isClampedToTheCeiling() {
        // A corrupted/absurd chunk count must never overflow into a
        // negative Int32 or an unbounded value sent to the server.
        let result = BCryptoDownloadTokenClient.computeMaxUses(totalChunks: Int.max / 2)
        XCTAssertEqual(result, BCryptoDownloadTokenClient.maxDownloadTokenMaxUses)
    }
}
