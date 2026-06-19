import XCTest
@testable import QAudionEngine

final class QAudionCapabilityExchangeTests: XCTestCase {
    func testCreateAndParseOffer() {
        let pk = Data(repeating: 0xAA, count: 1568)
        let fps = ["abc123", "def456"]
        let data = QAudionCapabilityExchange.createOffer(publicKey: pk, pskFingerprints: fps)
        XCTAssertFalse(data.isEmpty)

        guard let message = QAudionCapabilityExchange.parse(data) else {
            XCTFail("Failed to parse offer"); return
        }
        if case .offer(let parsedPk, _, let parsedFps) = message {
            XCTAssertEqual(parsedPk, pk)
            XCTAssertEqual(parsedFps, fps)
        } else { XCTFail("Expected offer") }
    }

    func testCreateAndParseAccept() {
        let ct = Data(repeating: 0xBB, count: 1088)
        let data = QAudionCapabilityExchange.createAccept(ciphertext: ct, pskFingerprint: "fp123")
        guard let message = QAudionCapabilityExchange.parse(data) else {
            XCTFail("Failed to parse accept"); return
        }
        if case .accept(let parsedCt, let parsedFp) = message {
            XCTAssertEqual(parsedCt, ct)
            XCTAssertEqual(parsedFp, "fp123")
        } else { XCTFail("Expected accept") }
    }

    func testParseInvalidData() {
        XCTAssertNil(QAudionCapabilityExchange.parse(Data([0x00])))
        XCTAssertNil(QAudionCapabilityExchange.parse(Data("invalid".utf8)))
    }
}
