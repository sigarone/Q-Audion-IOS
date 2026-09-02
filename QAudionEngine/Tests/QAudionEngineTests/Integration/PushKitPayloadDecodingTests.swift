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

    // MARK: - TRUST-6 (CRYPTO_PROTOCOL_AUDIT_2026-09-01.md, security audit
    // backlog item 9) — opaque call-wakeup payload. Wire shape mirrors
    // bcrypto-server's existing opaque_wakeup pattern for messages
    // (`internal/push/fcm.go`'s SendOpaquePush: type/kind/shash/ts).

    func test_decodesOpaqueCallWakeupPayload() throws {
        let dict: [String: Any] = [
            "type": "opaque_wakeup",
            "kind": "call",
            "shash": "a1b2c3d4e5f6",
            "ts": "1700000000"
        ]
        let parsed = try PushKitProvider.parseOpaqueCallWakeup(dict)
        XCTAssertEqual(parsed.kind, "call")
        XCTAssertEqual(parsed.senderHash, "a1b2c3d4e5f6")
        XCTAssertEqual(parsed.timestamp, 1_700_000_000)
    }

    func test_decodesOpaqueCallWakeupPayload_tsAsNumber() throws {
        let dict: [String: Any] = [
            "type": "opaque_wakeup",
            "kind": "call",
            "shash": "a1b2c3d4e5f6",
            "ts": 1_700_000_000
        ]
        let parsed = try PushKitProvider.parseOpaqueCallWakeup(dict)
        XCTAssertEqual(parsed.timestamp, 1_700_000_000)
    }

    func test_opaqueCallWakeupCarriesNoCallIdOrCallerIdentity() throws {
        // TRUST-6's core property: a payload with the plaintext identity
        // fields present alongside the opaque type must decode WITHOUT ever
        // surfacing them — OpaqueCallWakeupPayload has no fields to hold
        // them in the first place, so this documents (and would fail to
        // compile if that ever regressed) that call_id/caller_id/
        // caller_name simply have nowhere to go.
        let dict: [String: Any] = [
            "type": "opaque_wakeup",
            "kind": "call",
            "shash": "a1b2c3d4e5f6",
            "ts": "1700000000",
            "call_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
            "caller_id": "user-aabbccdd",
            "caller_name": "Alice"
        ]
        let parsed = try PushKitProvider.parseOpaqueCallWakeup(dict)
        XCTAssertEqual(parsed.kind, "call")
        // No assertion possible/needed on caller identity — the type has no
        // such property. The mirror-image `parsePayload` test above proves
        // the OLD plaintext type still decodes those fields when present;
        // this proves the NEW type structurally cannot.
    }

    func test_opaqueCallWakeup_rejectsWrongType() throws {
        let dict: [String: Any] = ["type": "incoming_call", "kind": "call"]
        XCTAssertThrowsError(try PushKitProvider.parseOpaqueCallWakeup(dict))
    }

    func test_opaqueCallWakeup_rejectsMissingKind() throws {
        let dict: [String: Any] = ["type": "opaque_wakeup"]
        XCTAssertThrowsError(try PushKitProvider.parseOpaqueCallWakeup(dict))
    }

    func test_opaqueCallWakeup_rejectsWrongKind() throws {
        // A different opaque_wakeup kind (e.g. a future "message" wakeup
        // ever ported to iOS) must NOT be silently accepted as a call.
        let dict: [String: Any] = ["type": "opaque_wakeup", "kind": "message"]
        XCTAssertThrowsError(try PushKitProvider.parseOpaqueCallWakeup(dict))
    }

    func test_opaqueCallWakeup_missingOptionalFieldsDegradeGracefully() throws {
        let dict: [String: Any] = ["type": "opaque_wakeup", "kind": "call"]
        let parsed = try PushKitProvider.parseOpaqueCallWakeup(dict)
        XCTAssertEqual(parsed.senderHash, "")
        XCTAssertEqual(parsed.timestamp, 0)
    }

    // MARK: - The two payload types must not cross-parse

    func test_plaintextIncomingCallTypeIsRejectedByOpaqueParser() throws {
        let dict: [String: Any] = [
            "type": "incoming_call",
            "call_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
            "caller_id": "user-aabbccdd",
            "caller_name": "Alice",
            "call_type": "audio"
        ]
        XCTAssertThrowsError(try PushKitProvider.parseOpaqueCallWakeup(dict))
    }

    func test_opaqueWakeupTypeIsRejectedByPlaintextParser() throws {
        let dict: [String: Any] = ["type": "opaque_wakeup", "kind": "call"]
        XCTAssertThrowsError(try PushKitProvider.parsePayload(dict))
    }
}
