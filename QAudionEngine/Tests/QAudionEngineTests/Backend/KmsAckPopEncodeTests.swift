import XCTest
@testable import QAudionEngine

/// §3.6 + §3.0 freeze: the ack-pop `epoch` is a DECIMAL STRING in BOTH
/// the request body AND the response (uint64 exceeds JS safe-integer
/// range; cross-platform parity). The prior iOS draft used numeric
/// UInt64 — this test pins the corrected String shape.
final class KmsAckPopEncodeTests: XCTestCase {
    func testAckPopBodyShape() throws {
        let body = try BCryptoKmsClient.encodeAckPopBody(
            keyId: "11111111-1111-1111-1111-111111111111",
            deviceId: "33333333-3333-3333-3333-333333333333",
            epoch: 42,
            txnId: "44444444-4444-4444-4444-444444444444",
            popB64: "AAEC")
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(obj["key_id"] as? String, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(obj["device_id"] as? String, "33333333-3333-3333-3333-333333333333")
        // FROZEN: epoch is a decimal STRING, not a number.
        XCTAssertEqual(obj["epoch"] as? String, "42")
        XCTAssertNil(obj["epoch"] as? NSNumber, "epoch must NOT serialize as a JSON number")
        XCTAssertEqual(obj["txn_id"] as? String, "44444444-4444-4444-4444-444444444444")
        XCTAssertEqual(obj["pop"] as? String, "AAEC")
    }

    func testAckPopResponseDecode() throws {
        // Server returns epoch as a decimal STRING too.
        let json = Data(#"{"verified":true,"commit":true,"epoch":"42"}"#.utf8)
        let r = try JSONDecoder().decode(BCryptoKmsClient.AckPopResponse.self, from: json)
        XCTAssertTrue(r.verified); XCTAssertTrue(r.commit)
        XCTAssertEqual(r.epoch, "42")
        XCTAssertEqual(UInt64(r.epoch), 42)
    }
}
