import XCTest
@testable import QAudionEngine

// MARK: - MessageSendEnvelope tests

final class MessageSendEnvelopeTests: XCTestCase {

    private let messageId = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
    private let recipientId = "user-aabbccdd-1122-3344-5566-778899aabbcc"
    private let ciphertext = Data((0..<32).map { UInt8($0 & 0xFF) })
    private let clientTs: Int64 = 1_745_000_000_000

    func test_encode_producesCanonicalJson() throws {
        let env = MessageSendEnvelope(
            messageId: messageId,
            recipientId: recipientId,
            ciphertext: ciphertext,
            clientTs: clientTs
        )
        let json = try env.encodeAsJsonString()
        XCTAssertTrue(json.contains("\"type\":\"msg_send\""))
        XCTAssertTrue(json.contains("\"message_id\":\"12345678-1234-1234-1234-123456789abc\""))
        XCTAssertTrue(json.contains("\"recipient_id\":\"\(recipientId)\""))
        XCTAssertTrue(json.contains("\"ciphertext\":\"\(ciphertext.base64EncodedString())\""))
        XCTAssertTrue(json.contains("\"client_ts\":1745000000000"))
        // No top-level id field (lite-server contract)
        XCTAssertFalse(json.contains("\"id\""))
    }

    func test_decode_roundTrip() throws {
        let original = MessageSendEnvelope(
            messageId: messageId,
            recipientId: recipientId,
            ciphertext: ciphertext,
            clientTs: clientTs
        )
        let json = try original.encodeAsJsonString()
        let decoded = try MessageSendEnvelope.decode(jsonString: json)
        XCTAssertEqual(decoded, original)
    }

    func test_decode_rejectsWrongType() {
        let badJson = """
        {"type":"msg_delivered","data":{"message_id":"12345678-1234-1234-1234-123456789abc","recipient_id":"x","ciphertext":"AAAA","client_ts":0}}
        """
        XCTAssertThrowsError(try MessageSendEnvelope.decode(jsonString: badJson)) { err in
            guard case MessageSendEnvelope.Error.wrongType = err else {
                XCTFail("Expected .wrongType, got \(err)"); return
            }
        }
    }

    func test_decode_rejectsMissingField_messageId() {
        let badJson = """
        {"type":"msg_send","data":{"recipient_id":"x","ciphertext":"AAAA","client_ts":0}}
        """
        XCTAssertThrowsError(try MessageSendEnvelope.decode(jsonString: badJson)) { err in
            guard case MessageSendEnvelope.Error.missingField(let f) = err else {
                XCTFail("Expected .missingField, got \(err)"); return
            }
            XCTAssertEqual(f, "message_id")
        }
    }

    func test_decode_rejectsInvalidBase64() {
        let badJson = """
        {"type":"msg_send","data":{"message_id":"12345678-1234-1234-1234-123456789abc","recipient_id":"x","ciphertext":"not_base64_!@#","client_ts":0}}
        """
        XCTAssertThrowsError(try MessageSendEnvelope.decode(jsonString: badJson)) { err in
            guard case MessageSendEnvelope.Error.invalidBase64 = err else {
                XCTFail("Expected .invalidBase64, got \(err)"); return
            }
        }
    }

    func test_decode_toleratesExtraFields() throws {
        let json = """
        {"type":"msg_send","data":{"message_id":"12345678-1234-1234-1234-123456789abc","recipient_id":"\(recipientId)","ciphertext":"\(ciphertext.base64EncodedString())","client_ts":1745000000000,"server_ts":1745000000500,"unknown_future":true}}
        """
        let decoded = try MessageSendEnvelope.decode(jsonString: json)
        XCTAssertEqual(decoded.messageId, messageId)
        XCTAssertEqual(decoded.recipientId, recipientId)
        XCTAssertEqual(decoded.clientTs, clientTs)
    }
}

// MARK: - MessageDeliveredEnvelope tests

final class MessageDeliveredEnvelopeTests: XCTestCase {

    private let messageId = UUID(uuidString: "aaaabbbb-cccc-dddd-eeee-ffffffffffff")!
    private let deliveredTo = "user-11223344-5566-7788-99aa-bbccddeeff00"
    private let deliveredTs: Int64 = 1_745_100_000_000

    func test_encode_producesCanonicalJson() throws {
        let env = MessageDeliveredEnvelope(
            messageId: messageId,
            deliveredTo: deliveredTo,
            deliveredTs: deliveredTs
        )
        let json = try env.encodeAsJsonString()
        XCTAssertTrue(json.contains("\"type\":\"msg_delivered\""))
        XCTAssertTrue(json.contains("\"message_id\":\"aaaabbbb-cccc-dddd-eeee-ffffffffffff\""))
        XCTAssertTrue(json.contains("\"delivered_to\":\"\(deliveredTo)\""))
        XCTAssertTrue(json.contains("\"delivered_ts\":1745100000000"))
        XCTAssertFalse(json.contains("\"id\""))
    }

    func test_decode_roundTrip() throws {
        let original = MessageDeliveredEnvelope(
            messageId: messageId,
            deliveredTo: deliveredTo,
            deliveredTs: deliveredTs
        )
        let json = try original.encodeAsJsonString()
        let decoded = try MessageDeliveredEnvelope.decode(jsonString: json)
        XCTAssertEqual(decoded, original)
    }

    func test_decode_rejectsWrongType() {
        let badJson = """
        {"type":"msg_send","data":{"message_id":"aaaabbbb-cccc-dddd-eeee-ffffffffffff","delivered_to":"x","delivered_ts":0}}
        """
        XCTAssertThrowsError(try MessageDeliveredEnvelope.decode(jsonString: badJson)) { err in
            guard case MessageDeliveredEnvelope.Error.wrongType = err else {
                XCTFail("Expected .wrongType, got \(err)"); return
            }
        }
    }

    func test_decode_rejectsMissingField_deliveredTo() {
        let badJson = """
        {"type":"msg_delivered","data":{"message_id":"aaaabbbb-cccc-dddd-eeee-ffffffffffff","delivered_ts":0}}
        """
        XCTAssertThrowsError(try MessageDeliveredEnvelope.decode(jsonString: badJson)) { err in
            guard case MessageDeliveredEnvelope.Error.missingField(let f) = err else {
                XCTFail("Expected .missingField, got \(err)"); return
            }
            XCTAssertEqual(f, "delivered_to")
        }
    }

    func test_decode_toleratesExtraFields() throws {
        let json = """
        {"type":"msg_delivered","data":{"message_id":"aaaabbbb-cccc-dddd-eeee-ffffffffffff","delivered_to":"\(deliveredTo)","delivered_ts":1745100000000,"push_notified":false}}
        """
        let decoded = try MessageDeliveredEnvelope.decode(jsonString: json)
        XCTAssertEqual(decoded.deliveredTo, deliveredTo)
        XCTAssertEqual(decoded.deliveredTs, deliveredTs)
    }
}

// MARK: - MessageReadEnvelope tests

final class MessageReadEnvelopeTests: XCTestCase {

    private let messageId = UUID(uuidString: "deadbeef-dead-beef-dead-beefdeadbeef")!
    private let readerId = "user-cafebabe-cafe-babe-cafe-babecafebabe"
    private let readTs: Int64 = 1_745_200_000_000

    func test_encode_producesCanonicalJson() throws {
        let env = MessageReadEnvelope(
            messageId: messageId,
            readerId: readerId,
            readTs: readTs
        )
        let json = try env.encodeAsJsonString()
        XCTAssertTrue(json.contains("\"type\":\"msg_read\""))
        XCTAssertTrue(json.contains("\"message_id\":\"deadbeef-dead-beef-dead-beefdeadbeef\""))
        XCTAssertTrue(json.contains("\"reader_id\":\"\(readerId)\""))
        XCTAssertTrue(json.contains("\"read_ts\":1745200000000"))
        XCTAssertFalse(json.contains("\"id\""))
    }

    func test_decode_roundTrip() throws {
        let original = MessageReadEnvelope(
            messageId: messageId,
            readerId: readerId,
            readTs: readTs
        )
        let json = try original.encodeAsJsonString()
        let decoded = try MessageReadEnvelope.decode(jsonString: json)
        XCTAssertEqual(decoded, original)
    }

    func test_decode_rejectsWrongType() {
        let badJson = """
        {"type":"msg_typing","data":{"message_id":"deadbeef-dead-beef-dead-beefdeadbeef","reader_id":"x","read_ts":0}}
        """
        XCTAssertThrowsError(try MessageReadEnvelope.decode(jsonString: badJson)) { err in
            guard case MessageReadEnvelope.Error.wrongType = err else {
                XCTFail("Expected .wrongType, got \(err)"); return
            }
        }
    }

    func test_decode_rejectsMissingField_readTs() {
        let badJson = """
        {"type":"msg_read","data":{"message_id":"deadbeef-dead-beef-dead-beefdeadbeef","reader_id":"x"}}
        """
        XCTAssertThrowsError(try MessageReadEnvelope.decode(jsonString: badJson)) { err in
            guard case MessageReadEnvelope.Error.missingField(let f) = err else {
                XCTFail("Expected .missingField, got \(err)"); return
            }
            XCTAssertEqual(f, "read_ts")
        }
    }

    func test_decode_toleratesExtraFields() throws {
        let json = """
        {"type":"msg_read","data":{"message_id":"deadbeef-dead-beef-dead-beefdeadbeef","reader_id":"\(readerId)","read_ts":1745200000000,"delivery_hop_ms":12}}
        """
        let decoded = try MessageReadEnvelope.decode(jsonString: json)
        XCTAssertEqual(decoded.messageId, messageId)
        XCTAssertEqual(decoded.readerId, readerId)
    }
}

// MARK: - MessageTypingEnvelope tests

final class MessageTypingEnvelopeTests: XCTestCase {

    private let recipientId = "user-00112233-4455-6677-8899-aabbccddeeff"

    func test_encode_producesCanonicalJson_typingTrue() throws {
        let env = MessageTypingEnvelope(recipientId: recipientId, isTyping: true)
        let json = try env.encodeAsJsonString()
        XCTAssertTrue(json.contains("\"type\":\"msg_typing\""))
        XCTAssertTrue(json.contains("\"recipient_id\":\"\(recipientId)\""))
        XCTAssertTrue(json.contains("\"is_typing\":true"))
        // No message_id, no ts, no top-level id
        XCTAssertFalse(json.contains("\"message_id\""))
        XCTAssertFalse(json.contains("\"id\""))
    }

    func test_encode_producesCanonicalJson_typingFalse() throws {
        let env = MessageTypingEnvelope(recipientId: recipientId, isTyping: false)
        let json = try env.encodeAsJsonString()
        XCTAssertTrue(json.contains("\"is_typing\":false"))
    }

    func test_decode_roundTrip_true() throws {
        let original = MessageTypingEnvelope(recipientId: recipientId, isTyping: true)
        let json = try original.encodeAsJsonString()
        let decoded = try MessageTypingEnvelope.decode(jsonString: json)
        XCTAssertEqual(decoded, original)
    }

    func test_decode_roundTrip_false() throws {
        let original = MessageTypingEnvelope(recipientId: recipientId, isTyping: false)
        let json = try original.encodeAsJsonString()
        let decoded = try MessageTypingEnvelope.decode(jsonString: json)
        XCTAssertEqual(decoded, original)
    }

    func test_decode_rejectsWrongType() {
        let badJson = """
        {"type":"msg_read","data":{"recipient_id":"x","is_typing":true}}
        """
        XCTAssertThrowsError(try MessageTypingEnvelope.decode(jsonString: badJson)) { err in
            guard case MessageTypingEnvelope.Error.wrongType = err else {
                XCTFail("Expected .wrongType, got \(err)"); return
            }
        }
    }

    func test_decode_rejectsMissingField_isTyping() {
        let badJson = """
        {"type":"msg_typing","data":{"recipient_id":"x"}}
        """
        XCTAssertThrowsError(try MessageTypingEnvelope.decode(jsonString: badJson)) { err in
            guard case MessageTypingEnvelope.Error.missingField(let f) = err else {
                XCTFail("Expected .missingField, got \(err)"); return
            }
            XCTAssertEqual(f, "is_typing")
        }
    }

    func test_decode_toleratesExtraFields() throws {
        let json = """
        {"type":"msg_typing","data":{"recipient_id":"\(recipientId)","is_typing":true,"composing_since_ms":200}}
        """
        let decoded = try MessageTypingEnvelope.decode(jsonString: json)
        XCTAssertEqual(decoded.recipientId, recipientId)
        XCTAssertTrue(decoded.isTyping)
    }
}
