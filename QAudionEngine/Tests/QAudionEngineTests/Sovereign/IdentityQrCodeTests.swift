import XCTest
@testable import QAudionEngine

final class IdentityQrCodeTests: XCTestCase {

    private let pub32 = Data((0..<32).map { UInt8($0) })

    /// Deliberately pinned to the literal current version rather than
    /// interpolating `IdentityQrCode.version` — a version bump changes what
    /// every other client must parse, so it should break this line and be
    /// updated by hand, not silently follow the constant.
    ///
    /// 2026-08-02: the pin said `QAUDION:1:` while `encode` has emitted v2
    /// since the M-29 8-byte-checksum change. The pin did exactly its job
    /// and went red; nobody saw it, because this whole class was excluded
    /// from CI on 2026-06-19. Correcting the pin, not the encoder — the
    /// sibling round-trip and wrong-length cases pass, so the format itself
    /// is sound.
    func test_encode_producesQaudionPrefixedString() throws {
        let id = IdentityQrCode.Identity(userId: "user-aabbcc", pubkey: pub32)
        let s = try IdentityQrCode.encode(identity: id)
        XCTAssertTrue(s.hasPrefix("QAUDION:2:"), "unexpected prefix: \(s.prefix(16))")
    }

    func test_encodeDecode_roundTrip() throws {
        let id = IdentityQrCode.Identity(userId: "user-aabbcc", pubkey: pub32)
        let s = try IdentityQrCode.encode(identity: id)
        let decoded = try IdentityQrCode.decode(string: s)
        XCTAssertEqual(decoded, id)
    }

    func test_encode_rejectsWrongPubkeyLength() {
        let id = IdentityQrCode.Identity(userId: "u", pubkey: Data([0x00]))
        XCTAssertThrowsError(try IdentityQrCode.encode(identity: id))
    }

    func test_encode_rejectsColonInUserId() {
        let id = IdentityQrCode.Identity(userId: "bad:userid", pubkey: pub32)
        XCTAssertThrowsError(try IdentityQrCode.encode(identity: id)) { err in
            guard case IdentityQrCode.Error.userIdContainsColon = err else {
                XCTFail("Expected .userIdContainsColon, got \(err)"); return
            }
        }
    }

    func test_decode_rejectsWrongPrefix() {
        XCTAssertThrowsError(try IdentityQrCode.decode(string: "OTHER:1:u:abc:def"))
    }

    func test_decode_rejectsUnsupportedVersion() {
        // Build a v99 string with a valid checksum-shape (random base64 bytes).
        let s = "QAUDION:99:u:\(pub32.base64EncodedString()):AAAAAA=="
        XCTAssertThrowsError(try IdentityQrCode.decode(string: s)) { err in
            guard case IdentityQrCode.Error.unsupportedVersion(let v) = err else {
                XCTFail("Expected .unsupportedVersion, got \(err)"); return
            }
            XCTAssertEqual(v, 99)
        }
    }

    func test_decode_rejectsTamperedChecksum() throws {
        let id = IdentityQrCode.Identity(userId: "u", pubkey: pub32)
        var s = try IdentityQrCode.encode(identity: id)
        // Tamper with the userId in the encoded string — checksum should now mismatch.
        s = s.replacingOccurrences(of: ":u:", with: ":U:")
        XCTAssertThrowsError(try IdentityQrCode.decode(string: s)) { err in
            guard case IdentityQrCode.Error.checksumMismatch = err else {
                XCTFail("Expected .checksumMismatch, got \(err)"); return
            }
        }
    }

    func test_decode_rejectsTooFewSegments() {
        XCTAssertThrowsError(try IdentityQrCode.decode(string: "QAUDION:1:u"))
    }

    func test_decode_rejectsBadBase64() {
        let s = "QAUDION:1:u:not_base64_!@#:AAAAAA=="
        XCTAssertThrowsError(try IdentityQrCode.decode(string: s))
    }

    func test_encodeDecode_userIdWithSpacesAndDashes() throws {
        let id = IdentityQrCode.Identity(userId: "user-aabbcc 1122 3344", pubkey: pub32)
        let s = try IdentityQrCode.encode(identity: id)
        let decoded = try IdentityQrCode.decode(string: s)
        XCTAssertEqual(decoded.userId, "user-aabbcc 1122 3344")
    }
}
