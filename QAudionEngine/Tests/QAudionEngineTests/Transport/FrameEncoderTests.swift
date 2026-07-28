import XCTest
@testable import QAudionEngine

final class FrameEncoderTests: XCTestCase {
    func testSerializeDeserializeRoundTrip() throws {
        let frame = EncryptedFrame(flags: 0x00, sequenceNumber: 42, timestamp: 1234567890,
            nonce: Data(repeating: 0xAB, count: 12), payload: Data([0x01, 0x02, 0x03, 0x04, 0x05]),
            tag: Data(repeating: 0xCD, count: 16))
        let wire = FrameEncoder.serialize(frame)
        let decoded = try FrameEncoder.deserialize(wire)
        XCTAssertEqual(decoded.version, frame.version)
        XCTAssertEqual(decoded.flags, frame.flags)
        XCTAssertEqual(decoded.sequenceNumber, frame.sequenceNumber)
        XCTAssertEqual(decoded.timestamp, frame.timestamp)
        XCTAssertEqual(decoded.nonce, frame.nonce)
        XCTAssertEqual(decoded.payload, frame.payload)
        XCTAssertEqual(decoded.tag, frame.tag)
        XCTAssertNil(decoded.deepfakeScore)
    }
    func testSerializeWithDeepfakeScore() throws {
        let frame = EncryptedFrame(flags: TransportConstants.flagHasDeepfakeScore,
            sequenceNumber: 100, timestamp: 9999999999,
            nonce: Data(repeating: 0x11, count: 12), payload: Data([0xFF]),
            tag: Data(repeating: 0x22, count: 16), deepfakeScore: 0.85)
        let wire = FrameEncoder.serialize(frame)
        let decoded = try FrameEncoder.deserialize(wire)
        // Safe: this frame is serialized above with flagHasDeepfakeScore set and a literal
        // 0.85 score — deserialize is guaranteed (and this test verifies) to round-trip it non-nil.
        // swiftlint:disable:next force_unwrapping
        XCTAssertEqual(decoded.deepfakeScore!, 0.85, accuracy: 0.001)
    }
    func testWireFormatLayout() {
        let frame = EncryptedFrame(flags: 0x00, sequenceNumber: 1, timestamp: 0,
            nonce: Data(repeating: 0x00, count: 12), payload: Data([0xDE, 0xAD]),
            tag: Data(repeating: 0x00, count: 16))
        let wire = FrameEncoder.serialize(frame)
        XCTAssertEqual(wire[0], 0x01) // version
        XCTAssertEqual(wire[1], 0x00) // flags
        XCTAssertEqual(wire[5], 0x01) // seqNum=1 last byte
        XCTAssertEqual(wire[14], 12) // nonceLen
        XCTAssertEqual(wire[27], 0x00); XCTAssertEqual(wire[28], 0x02) // payloadLen=2
        XCTAssertEqual(wire[29], 0xDE); XCTAssertEqual(wire[30], 0xAD) // payload
        XCTAssertEqual(wire.count, 47)
    }
    func testEmptyPayload() throws {
        let frame = EncryptedFrame(sequenceNumber: 0, timestamp: 0,
            nonce: Data(repeating: 0, count: 12), payload: Data(), tag: Data(repeating: 0, count: 16))
        let wire = FrameEncoder.serialize(frame)
        XCTAssertEqual(wire.count, TransportConstants.headerSize + TransportConstants.tagSize)
        let decoded = try FrameEncoder.deserialize(wire)
        XCTAssertEqual(decoded.payload.count, 0)
    }
    func testIsValid() {
        let valid = FrameEncoder.serialize(EncryptedFrame(sequenceNumber: 1, timestamp: 100,
            nonce: Data(repeating: 0, count: 12), payload: Data([0x01]), tag: Data(repeating: 0, count: 16)))
        XCTAssertTrue(FrameEncoder.isValid(valid))
        XCTAssertFalse(FrameEncoder.isValid(Data([0x00])))
        XCTAssertFalse(FrameEncoder.isValid(Data(repeating: 0xFF, count: 45)))
    }
    func testExtractSequenceNumber() {
        let frame = EncryptedFrame(sequenceNumber: 0xDEADBEEF, timestamp: 0,
            nonce: Data(repeating: 0, count: 12), payload: Data(), tag: Data(repeating: 0, count: 16))
        let wire = FrameEncoder.serialize(frame)
        XCTAssertEqual(FrameEncoder.extractSequenceNumber(wire), 0xDEADBEEF)
    }
}
