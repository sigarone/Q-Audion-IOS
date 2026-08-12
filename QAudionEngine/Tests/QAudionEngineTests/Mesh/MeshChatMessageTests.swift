import XCTest
@testable import QAudionEngine

/// Wire v2 rules for the mesh envelope and the shell it travels in.
///
/// v1 encrypted only the body and shipped senderUserId, recipientUserId,
/// conversationId, clientMsgId and a timestamp in cleartext around it — real
/// user UUIDs, broadcast to whoever was within Bluetooth range. v2 seals the
/// whole envelope, and the shell outside it carries one field: the message id,
/// which the ratchet needs to rebuild its own associated data before it can
/// decrypt anything.
///
/// Field names are pinned deliberately. The Android sibling encodes the same
/// short keys, and a rename on one side would show up only as "nothing decodes
/// between an iPhone and an Android phone".
final class MeshChatMessageTests: XCTestCase {

    private func envelope(body: String = "ci vediamo alle 8") -> MeshChatMessage {
        MeshChatMessage(
            senderUserId: "user-a",
            recipientUserId: "user-b",
            clientMsgId: "11111111-1111-1111-1111-111111111111",
            conversationId: "conv-1",
            body: body,
            sentAtMs: 1_700_000_000_000,
            senderNodeHex: "aaaaaaaaaaaaaaaa",
            recipientNodeHex: "bbbbbbbbbbbbbbbb"
        )
    }

    func testEncodeDecodeRoundTrip() {
        XCTAssertEqual(MeshChatMessage.decode(envelope().encode()), envelope())
    }

    func testDecodeNeverThrowsOnGarbageBytes() {
        XCTAssertNil(MeshChatMessage.decode(Data([0x00, 0x01])))
        XCTAssertNil(MeshChatMessage.decode(Data()))
    }

    func testV1EnvelopeIsRejectedRatherThanAcceptedAsADowngrade() throws {
        // v1 is refused on version alone: accepting it would keep a path open
        // back to the cleartext-metadata layout.
        let v1 = Data(#"{"v":1,"s":"a","r":"b","c":"c","conv":"d","ct":"ZQ==","ts":1}"#.utf8)
        XCTAssertNil(MeshChatMessage.decode(v1))
    }

    func testEveryUserIdentifierAndTheBodyLiveInsideTheSealedEnvelope() throws {
        // Guards against a field being added back OUTSIDE the seal: anything a
        // listener must not learn has to serialise as part of this blob.
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: envelope().encode()) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), Set(["v", "s", "r", "c", "conv", "b", "ts", "sn", "rn"]))
        XCTAssertEqual(json["b"] as? String, "ci vediamo alle 8")
    }

    func testShellCarriesOnlyTheMessageIdAndTheSealedBlob() throws {
        let shell = MeshSealedShell(clientMsgId: "msg-1", sealedB64: "AQIDBAUGBwgJCg==")
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: shell.encode()) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), Set(["c", "e"]))
        XCTAssertEqual(MeshSealedShell.decode(shell.encode()), shell)
    }

    func testShellNeverParsesWhatItCarries() {
        // The shell is opaque about its payload: any string round-trips
        // unchanged, whether or not it is real base64 ciphertext.
        let shell = MeshSealedShell(clientMsgId: "c", sealedB64: "not-real-base64!!")
        XCTAssertEqual(MeshSealedShell.decode(shell.encode())?.sealedB64, "not-real-base64!!")
    }

    func testAadIsByteExactSoAndroidDerivesTheSameString() throws {
        // Pinned literally against the Android sibling's own test, which
        // asserts this exact string.
        let aad = meshPacketAad(
            version: 1,
            typeWireCode: MeshPacketType.data.rawValue,
            senderId: try MeshNodeId(hex: "aaaaaaaaaaaaaaaa"),
            recipientId: try MeshNodeId(hex: "bbbbbbbbbbbbbbbb")
        )
        XCTAssertEqual(
            String(data: aad, encoding: .utf8),
            "mesh:v1:1:aaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbb"
        )
    }

    func testAadRendersAHighPacketTypeUnsigned() throws {
        // Kotlin's Byte is signed and Swift's UInt8 is not: 0x80 must be "128"
        // on both sides, not "-128" on one of them.
        let aad = meshPacketAad(
            version: 1,
            typeWireCode: 0x80,
            senderId: try MeshNodeId(hex: "aaaaaaaaaaaaaaaa"),
            recipientId: try MeshNodeId(hex: "bbbbbbbbbbbbbbbb")
        )
        XCTAssertEqual(
            String(data: aad, encoding: .utf8),
            "mesh:v1:128:aaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbb"
        )
    }
}
