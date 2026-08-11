import XCTest
@testable import QAudionEngine

final class MeshChatMessageTests: XCTestCase {

    func testEncodeDecodeRoundTrip() {
        let msg = MeshChatMessage(
            senderUserId: "user-a",
            recipientUserId: "user-b",
            clientMsgId: "11111111-1111-1111-1111-111111111111",
            conversationId: "conv-1",
            ciphertextB64: "AQIDBAUGBwgJCg==",
            sentAtMs: 1_700_000_000_000
        )
        let decoded = MeshChatMessage.decode(msg.encode())
        XCTAssertEqual(decoded, msg)
    }

    func testDecodeNeverThrowsOnGarbageBytes() {
        XCTAssertNil(MeshChatMessage.decode(Data([0x00, 0x01])))
        XCTAssertNil(MeshChatMessage.decode(Data()))
    }

    func testCiphertextFieldNeverParsedHereJustCarried() {
        // MeshChatMessage is an opaque envelope: any base64-looking string
        // round-trips unchanged, whether or not it is real ciphertext. This
        // type must never attempt to decode/validate it — that would
        // violate the "mesh never sees plaintext" invariant.
        let msg = MeshChatMessage(
            senderUserId: "a", recipientUserId: "b", clientMsgId: "c",
            conversationId: "d", ciphertextB64: "not-real-base64!!", sentAtMs: 0
        )
        let decoded = MeshChatMessage.decode(msg.encode())
        XCTAssertEqual(decoded?.ciphertextB64, "not-real-base64!!")
    }

    func testWireUsesShortFieldNames() throws {
        let msg = MeshChatMessage(
            senderUserId: "a", recipientUserId: "b", clientMsgId: "c",
            conversationId: "d", ciphertextB64: "e", sentAtMs: 0
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: msg.encode()) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["v", "s", "r", "c", "conv", "ct", "ts"]))
    }
}
