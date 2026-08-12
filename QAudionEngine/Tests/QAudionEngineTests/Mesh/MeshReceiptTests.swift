import XCTest
@testable import QAudionEngine

/// Pins the two things a mesh receipt must not get wrong: that a re-delivered
/// ack cannot walk a message's status backwards, and that the envelope round
/// trips byte for byte (Android parses it from the same JSON).
final class MeshReceiptTests: XCTestCase {

    func testStatusOnlyEverMovesForward() {
        XCTAssertEqual(meshReceiptStatusUpdate(current: .sent, kind: MeshReceipt.kindDelivered), .delivered)
        XCTAssertEqual(meshReceiptStatusUpdate(current: .delivered, kind: MeshReceipt.kindRead), .read)
        XCTAssertEqual(meshReceiptStatusUpdate(current: .sent, kind: MeshReceipt.kindRead), .read)
        // A flood mesh re-delivers packets out of order; a late "delivered"
        // must not take the blue ticks off a message already read.
        XCTAssertNil(meshReceiptStatusUpdate(current: .read, kind: MeshReceipt.kindDelivered))
        XCTAssertNil(meshReceiptStatusUpdate(current: .read, kind: MeshReceipt.kindRead))
        XCTAssertNil(meshReceiptStatusUpdate(current: .delivered, kind: MeshReceipt.kindDelivered))
    }

    func testAReceiptIsProofOfArrivalEvenForAFailedMessage() {
        XCTAssertEqual(meshReceiptStatusUpdate(current: .failed, kind: MeshReceipt.kindDelivered), .delivered)
        XCTAssertEqual(meshReceiptStatusUpdate(current: .sending, kind: MeshReceipt.kindRead), .read)
    }

    func testUnknownKindsChangeNothing() {
        XCTAssertNil(meshReceiptStatusUpdate(current: .sent, kind: "x"))
        XCTAssertNil(meshReceiptStatusUpdate(current: .sent, kind: ""))
    }

    func testRoundTripsThroughJson() {
        let receipt = MeshReceipt(
            senderUserId: "u-recipient", recipientUserId: "u-author",
            receiptId: "receipt-1", messageClientMsgId: "msg-1",
            kind: MeshReceipt.kindRead, atMs: 1_700_000_000_000,
            senderNodeHex: "aabbccddeeff0011", recipientNodeHex: "1100ffeeddccbbaa"
        )
        XCTAssertEqual(MeshReceipt.decode(receipt.encode()), receipt)
    }

    func testAReceiptWithAnUnusableKindOrVersionDoesNotParse() {
        let bogusKind = #"{"v":2,"s":"a","r":"b","c":"c","m":"m","k":"z","ts":1,"sn":"x","rn":"y"}"#
        XCTAssertNil(MeshReceipt.decode(Data(bogusKind.utf8)))
        let v1 = #"{"v":1,"s":"a","r":"b","c":"c","m":"m","k":"d","ts":1,"sn":"x","rn":"y"}"#
        XCTAssertNil(MeshReceipt.decode(Data(v1.utf8)))
    }

    func testTheReceiptPacketTypeHasItsOwnWireCode() {
        // Sharing DATA's code would make a receipt indistinguishable from a
        // message before decryption, and the type is bound into the AAD.
        XCTAssertEqual(MeshPacketType.receipt.rawValue, 0x05)
        XCTAssertEqual(MeshPacketType(rawValue: 0x05), .receipt)
    }
}
