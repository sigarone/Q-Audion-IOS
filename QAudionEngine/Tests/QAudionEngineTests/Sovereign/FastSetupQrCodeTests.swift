import XCTest
@testable import QAudionEngine

final class FastSetupQrCodeTests: XCTestCase {

    func test_encodeDecode_roundTrip() throws {
        let payload = FastSetupQrCode.Payload(
            version: 1,
            userId: "user-aabbccdd-1122-3344-5566-778899aabbcc",
            dialExtension: "4242",
            initialPsk: Data((0..<32).map { UInt8($0) }),
            expiresAtUnixMs: 9_999_999_999_000,
            serverUrl: URL(string: "https://qaudion.example.com")!
        )
        let url = try FastSetupQrCode.encode(payload: payload)
        let decoded = try FastSetupQrCode.decode(url: url)
        XCTAssertEqual(decoded.version, payload.version)
        XCTAssertEqual(decoded.userId, payload.userId)
        XCTAssertEqual(decoded.dialExtension, payload.dialExtension)
        XCTAssertEqual(decoded.initialPsk, payload.initialPsk)
        XCTAssertEqual(decoded.expiresAtUnixMs, payload.expiresAtUnixMs)
        XCTAssertEqual(decoded.serverUrl, payload.serverUrl)
    }

    func test_encode_producesQaudionSetupUrl() throws {
        let payload = sampleMockPayload()
        let url = try FastSetupQrCode.encode(payload: payload)
        XCTAssertTrue(url.absoluteString.hasPrefix("qaudion://setup/"))
    }

    func test_decode_rejectsWrongScheme() {
        let url = URL(string: "https://example.com/setup/abc")!
        XCTAssertThrowsError(try FastSetupQrCode.decode(url: url))
    }

    func test_decode_rejectsWrongHost() {
        let url = URL(string: "qaudion://link/abc")!  // wrong host (link, not setup)
        XCTAssertThrowsError(try FastSetupQrCode.decode(url: url))
    }

    func test_decode_rejectsUnknownVersion() throws {
        let payload = sampleMockPayload(version: 99)
        let url = try FastSetupQrCode.encode(payload: payload)
        XCTAssertThrowsError(try FastSetupQrCode.decode(url: url)) { err in
            guard case FastSetupQrCode.Error.unsupportedVersion(let v) = err else {
                XCTFail("Expected .unsupportedVersion, got \(err)"); return
            }
            XCTAssertEqual(v, 99)
        }
    }

    func test_decode_rejectsExpiredPayload() throws {
        let pastMs = Int64(Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        let payload = sampleMockPayload(expiresAt: pastMs)
        let url = try FastSetupQrCode.encode(payload: payload)
        XCTAssertThrowsError(try FastSetupQrCode.decode(url: url)) { err in
            guard case FastSetupQrCode.Error.expired = err else {
                XCTFail("Expected .expired, got \(err)"); return
            }
        }
    }

    func test_decode_rejectsMalformedPsk() throws {
        // 31-byte PSK — must be exactly 32B per spec
        let payload = FastSetupQrCode.Payload(
            version: 1,
            userId: "u",
            dialExtension: nil,
            initialPsk: Data((0..<31).map { UInt8($0) }),
            expiresAtUnixMs: futureMs,
            serverUrl: URL(string: "https://test")!
        )
        XCTAssertThrowsError(try FastSetupQrCode.encode(payload: payload)) { err in
            guard case FastSetupQrCode.Error.wrongPskLength = err else {
                XCTFail("Expected .wrongPskLength, got \(err)"); return
            }
        }
    }

    func test_decode_optionalDialExtensionIsNil() throws {
        let payload = sampleMockPayload(dialExt: nil)
        let url = try FastSetupQrCode.encode(payload: payload)
        let decoded = try FastSetupQrCode.decode(url: url)
        XCTAssertNil(decoded.dialExtension)
    }

    // MARK: - Helpers

    private var futureMs: Int64 {
        return Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
    }

    private func sampleMockPayload(version: Int = 1,
                                   dialExt: String? = "4242",
                                   expiresAt: Int64? = nil) -> FastSetupQrCode.Payload {
        return FastSetupQrCode.Payload(
            version: version,
            userId: "user-aabbccdd-1122-3344-5566-778899aabbcc",
            dialExtension: dialExt,
            initialPsk: Data((0..<32).map { UInt8($0) }),
            expiresAtUnixMs: expiresAt ?? futureMs,
            serverUrl: URL(string: "https://qaudion.example.com")!
        )
    }
}
