import XCTest
@testable import QAudionEngine

final class OpaqueMessageEnvelopeTests: XCTestCase {

    private let recipient = "user-aabbccdd-1122-3344-5566-778899aabbcc"
    private let ciphertext = Data((0..<48).map { UInt8($0 & 0xFF) })  // 48 random bytes

    func test_encode_producesCanonicalJson() throws {
        let envelope = OpaqueMessageEnvelope.makeOutbound(recipientId: recipient, ciphertext: ciphertext)
        let json = try envelope.encodeAsJsonString()
        XCTAssertTrue(json.contains("\"type\":\"opaque_message\""))
        XCTAssertTrue(json.contains("\"recipient_id\":\"\(recipient)\""))
        // Wire key is "data" to match Android WsCodec.kt OpaqueMessage encoder.
        XCTAssertTrue(json.contains("\"data\":\"\(ciphertext.base64EncodedString())\""))
        // Must NOT use the old "ciphertext" key.
        XCTAssertFalse(json.contains("\"ciphertext\""))
        // No id field at top level (lite-server contract).
        XCTAssertFalse(json.contains("\"id\""))
    }

    func test_decode_inboundEnvelope_roundTrip() throws {
        let outbound = OpaqueMessageEnvelope.makeOutbound(recipientId: recipient, ciphertext: ciphertext)
        let json = try outbound.encodeAsJsonString()
        let decoded = try OpaqueMessageEnvelope.decode(jsonString: json)
        XCTAssertEqual(decoded.recipientId, recipient)
        XCTAssertEqual(decoded.ciphertext, ciphertext)
        XCTAssertEqual(decoded.type, "opaque_message")
    }

    func test_decode_rejectsWrongType() {
        let badJson = """
        {"type":"audio_frame","data":{"recipient_id":"x","data":"AAAA"}}
        """
        XCTAssertThrowsError(try OpaqueMessageEnvelope.decode(jsonString: badJson)) { err in
            guard case OpaqueMessageEnvelope.Error.wrongType = err else {
                XCTFail("Expected .wrongType, got \(err)"); return
            }
        }
    }

    func test_decode_rejectsMissingRecipient() {
        let badJson = """
        {"type":"opaque_message","data":{"data":"AAAA"}}
        """
        XCTAssertThrowsError(try OpaqueMessageEnvelope.decode(jsonString: badJson))
    }

    func test_decode_rejectsBadBase64() {
        let badJson = """
        {"type":"opaque_message","data":{"recipient_id":"x","data":"not_base64_!@#"}}
        """
        XCTAssertThrowsError(try OpaqueMessageEnvelope.decode(jsonString: badJson)) { err in
            guard case OpaqueMessageEnvelope.Error.invalidBase64 = err else {
                XCTFail("Expected .invalidBase64, got \(err)"); return
            }
        }
    }

    func test_decode_toleratesExtraFields() throws {
        let json = """
        {"type":"opaque_message","data":{"recipient_id":"\(recipient)","data":"\(ciphertext.base64EncodedString())","server_ts":1745000000,"unknown_future_field":42}}
        """
        let decoded = try OpaqueMessageEnvelope.decode(jsonString: json)
        XCTAssertEqual(decoded.recipientId, recipient)
    }

    func test_encode_emptyCiphertextIsAllowed() throws {
        let envelope = OpaqueMessageEnvelope.makeOutbound(recipientId: recipient, ciphertext: Data())
        let json = try envelope.encodeAsJsonString()
        XCTAssertTrue(json.contains("\"data\":\"\""))
    }
}
