import XCTest
@testable import QAudionEngine

final class DeviceLinkBinaryQRTests: XCTestCase {

    private let pub32 = Data((0..<32).map { UInt8($0) })  // 0x00..0x1F
    private let auth16 = Data((0..<16).map { UInt8(0xA0 + $0) })  // 0xA0..0xAF
    private let userId = "user-aabbccdd-1122-3344-5566-778899aabbcc"

    func test_encode_producesQaudionLinkUrl() throws {
        let url = try DeviceLinkBinaryQR.encode(pubkey: pub32, userId: userId, authCode: auth16)
        XCTAssertTrue(url.absoluteString.hasPrefix("qaudion://link/"))
    }

    func test_encode_blobLengthMatchesLayout() throws {
        let blob = try DeviceLinkBinaryQR.encodeBlob(pubkey: pub32, userId: userId, authCode: auth16)
        let userIdLen = userId.utf8.count
        // 32B pubkey + 4B length + N userId + 16B auth
        XCTAssertEqual(blob.count, 32 + 4 + userIdLen + 16)
    }

    func test_encodeBlob_layoutIsPubkeyLengthUserIdAuth() throws {
        let blob = try DeviceLinkBinaryQR.encodeBlob(pubkey: pub32, userId: userId, authCode: auth16)
        // First 32 = pubkey
        XCTAssertEqual(blob.prefix(32), pub32)
        // Next 4 = big-endian length
        let lengthBytes = blob.subdata(in: 32..<36)
        let length = (UInt32(lengthBytes[0]) << 24) |
                     (UInt32(lengthBytes[1]) << 16) |
                     (UInt32(lengthBytes[2]) << 8)  |
                      UInt32(lengthBytes[3])
        XCTAssertEqual(Int(length), userId.utf8.count)
        // Last 16 = auth code
        XCTAssertEqual(blob.suffix(16), auth16)
    }

    func test_decode_roundTrip() throws {
        let url = try DeviceLinkBinaryQR.encode(pubkey: pub32, userId: userId, authCode: auth16)
        let decoded = try DeviceLinkBinaryQR.decode(url: url)
        XCTAssertEqual(decoded.pubkey, pub32)
        XCTAssertEqual(decoded.userId, userId)
        XCTAssertEqual(decoded.authCode, auth16)
    }

    func test_decode_rejectsWrongScheme() {
        // Hardcoded well-formed URL literal — always parses.
        // swiftlint:disable:next force_unwrapping
        let url = URL(string: "https://example.com/link/abc")!
        XCTAssertThrowsError(try DeviceLinkBinaryQR.decode(url: url)) { err in
            guard case DeviceLinkBinaryQR.Error.invalidUrl = err else {
                XCTFail("Expected .invalidUrl, got \(err)")
                return
            }
        }
    }

    func test_decode_rejectsWrongHost() {
        // Hardcoded well-formed URL literal — always parses.
        // swiftlint:disable:next force_unwrapping
        let url = URL(string: "qaudion://other/abc")!
        XCTAssertThrowsError(try DeviceLinkBinaryQR.decode(url: url)) { err in
            guard case DeviceLinkBinaryQR.Error.invalidUrl = err else {
                XCTFail("Expected .invalidUrl, got \(err)")
                return
            }
        }
    }

    func test_decode_rejectsTruncatedBlob() {
        // Manually craft a truncated qaudion://link/<base64url> URL.
        let truncated = Data((0..<10).map { UInt8($0) })  // 10 bytes — too short
        let b64 = truncated.base64UrlEncodedNoPadding()
        // b64 is base64url alphabet only (no +, /, =) — always a valid URL path component.
        // swiftlint:disable:next force_unwrapping
        let url = URL(string: "qaudion://link/\(b64)")!
        XCTAssertThrowsError(try DeviceLinkBinaryQR.decode(url: url)) { err in
            guard case DeviceLinkBinaryQR.Error.tooShort = err else {
                XCTFail("Expected .tooShort, got \(err)")
                return
            }
        }
    }

    func test_encode_rejectsWrongSizedPubkey() {
        XCTAssertThrowsError(
            try DeviceLinkBinaryQR.encodeBlob(pubkey: Data([0x00]), userId: userId, authCode: auth16)
        )
    }

    func test_encode_rejectsWrongSizedAuthCode() {
        XCTAssertThrowsError(
            try DeviceLinkBinaryQR.encodeBlob(pubkey: pub32, userId: userId, authCode: Data([0x00]))
        )
    }

    func test_base64UrlNoPadding() {
        // Verify the encoding produces no padding `=` chars.
        let blob = Data((0..<32).map { UInt8($0) })
        let s = blob.base64UrlEncodedNoPadding()
        XCTAssertFalse(s.contains("="))
        XCTAssertFalse(s.contains("+"))
        XCTAssertFalse(s.contains("/"))
    }
}

private extension Data {
    func base64UrlEncodedNoPadding() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
