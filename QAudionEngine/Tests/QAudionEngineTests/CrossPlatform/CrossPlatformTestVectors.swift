import XCTest
@testable import QAudionEngine

final class CrossPlatformTestVectors: XCTestCase {

    func testPaddingVectors() {
        let padding = AdaptivePadding(targetFrameSize: 256)
        // Vector 1: small payload -> 256 bytes
        let payload1 = Data(repeating: 0x00, count: 10)
        let padded1 = padding.pad(encryptedPayload: payload1, confidenceScore: 1.0)
        XCTAssertEqual(padded1.count, 256)
        let high1 = Int(padded1[padded1.count - 2])
        let low1 = Int(padded1[padded1.count - 1])
        XCTAssertEqual((high1 << 8) | low1, 244)

        // Vector 2: large payload -> payload + 2
        let payload2 = Data(repeating: 0xFF, count: 255)
        let padded2 = padding.pad(encryptedPayload: payload2, confidenceScore: 1.0)
        XCTAssertEqual(padded2.count, 257)
        let high2 = Int(padded2[padded2.count - 2])
        let low2 = Int(padded2[padded2.count - 1])
        XCTAssertEqual((high2 << 8) | low2, 0)
    }

    func testFrameEncoderWireFormatMatch() {
        let frame = EncryptedFrame(
            flags: 0x00,
            sequenceNumber: 42,
            timestamp: 1234567890,
            nonce: Data(repeating: 0xAB, count: 12),
            payload: Data([0x01, 0x02, 0x03, 0x04, 0x05]),
            tag: Data(repeating: 0xCD, count: 16)
        )
        let wire = FrameEncoder.serialize(frame)

        // Verify byte positions (big-endian, must match Android)
        XCTAssertEqual(wire[0], 0x01)  // version
        XCTAssertEqual(wire[1], 0x00)  // flags
        // seqNum=42 -> 0x0000002A
        XCTAssertEqual(wire[2], 0x00)
        XCTAssertEqual(wire[3], 0x00)
        XCTAssertEqual(wire[4], 0x00)
        XCTAssertEqual(wire[5], 0x2A)
        // timestamp=1234567890 -> 0x00000000499602D2
        XCTAssertEqual(wire[6], 0x00)
        XCTAssertEqual(wire[7], 0x00)
        XCTAssertEqual(wire[8], 0x00)
        XCTAssertEqual(wire[9], 0x00)
        XCTAssertEqual(wire[10], 0x49)
        XCTAssertEqual(wire[11], 0x96)
        XCTAssertEqual(wire[12], 0x02)
        XCTAssertEqual(wire[13], 0xD2)
        // nonceLen=12
        XCTAssertEqual(wire[14], 0x0C)
        // payloadLen=5 -> 0x0005
        XCTAssertEqual(wire[27], 0x00)
        XCTAssertEqual(wire[28], 0x05)
    }

    func testDeterministicHkdf() throws {
        let secret = Data(repeating: 0xBE, count: 32)
        let sm1 = SessionManager()
        let state1 = try sm1.initSession(sharedSecret: Data(secret))
        let sm2 = SessionManager()
        let state2 = try sm2.initSession(sharedSecret: Data(secret))
        XCTAssertEqual(state1.rootKey, state2.rootKey, "Root keys must be deterministic")
        XCTAssertEqual(state1.chainKey, state2.chainKey, "Chain keys must be deterministic")
        let fk1 = try sm1.ratchet()
        let fk2 = try sm2.ratchet()
        XCTAssertEqual(fk1, fk2, "Frame keys must be deterministic")
    }
}
