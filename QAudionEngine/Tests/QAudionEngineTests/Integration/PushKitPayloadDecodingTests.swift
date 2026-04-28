import XCTest
@testable import QAudionEngine

final class PushKitPayloadDecodingTests: XCTestCase {

    func test_decodesIncomingCallPayload() throws {
        let dict: [String: Any] = [
            "type": "incoming_call",
            "call_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
            "caller_id": "user-aabbccdd",
            "caller_name": "Alice",
            "call_type": "audio"
        ]
        let parsed = try PushKitProvider.parsePayload(dict)
        XCTAssertEqual(parsed.callId.uuidString.lowercased(), "f47ac10b-58cc-4372-a567-0e02b2c3d479")
        XCTAssertEqual(parsed.callerId, "user-aabbccdd")
        XCTAssertEqual(parsed.callerName, "Alice")
        XCTAssertEqual(parsed.hasVideo, false)
    }

    func test_decodesVideoCall() throws {
        let dict: [String: Any] = [
            "type": "incoming_call",
            "call_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
            "caller_id": "user-x",
            "caller_name": "Bob",
            "call_type": "video"
        ]
        let parsed = try PushKitProvider.parsePayload(dict)
        XCTAssertTrue(parsed.hasVideo)
    }

    func test_rejectsWrongType() throws {
        let dict: [String: Any] = ["type": "regular_message"]
        XCTAssertThrowsError(try PushKitProvider.parsePayload(dict))
    }

    func test_rejectsMissingCallId() throws {
        let dict: [String: Any] = [
            "type": "incoming_call",
            "caller_id": "user-x",
            "caller_name": "Bob",
            "call_type": "audio"
        ]
        XCTAssertThrowsError(try PushKitProvider.parsePayload(dict))
    }

    func test_rejectsBadUUID() throws {
        let dict: [String: Any] = [
            "type": "incoming_call",
            "call_id": "not-a-uuid",
            "caller_id": "user-x",
            "caller_name": "Bob",
            "call_type": "audio"
        ]
        XCTAssertThrowsError(try PushKitProvider.parsePayload(dict))
    }
}
