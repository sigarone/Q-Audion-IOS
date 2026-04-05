import XCTest
@testable import QAudionEngine

final class AdaptivePaddingTests: XCTestCase {
    func testPadToTargetSize() {
        let p = AdaptivePadding()
        let padded = p.pad(encryptedPayload: Data(repeating: 0xAA, count: 100), confidenceScore: 1.0)
        XCTAssertEqual(padded.count, 256)
    }
    func testUnpadRecoverPayload() {
        let p = AdaptivePadding()
        let payload = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let padded = p.pad(encryptedPayload: payload, confidenceScore: 0.5)
        let recovered = try! p.unpad(paddedFrame: padded)
        XCTAssertEqual(recovered, payload)
    }
    func testLargePayloadExceedsTarget() {
        let p = AdaptivePadding()
        let payload = Data(repeating: 0xFF, count: 255)
        let padded = p.pad(encryptedPayload: payload, confidenceScore: 1.0)
        XCTAssertEqual(padded.count, 257)
        XCTAssertEqual(try! p.unpad(paddedFrame: padded), payload)
    }
    func testPaddingLengthEncoding() {
        let p = AdaptivePadding()
        let padded = p.pad(encryptedPayload: Data(repeating: 0x00, count: 10), confidenceScore: 1.0)
        let paddingLength = (Int(padded[padded.count - 2]) << 8) | Int(padded[padded.count - 1])
        XCTAssertEqual(paddingLength, 244)
    }
    func testRoundTripMultipleSizes() {
        let p = AdaptivePadding()
        for size in [0, 1, 50, 100, 200, 253, 254, 255, 300] {
            let payload = Data(repeating: UInt8(size % 256), count: size)
            XCTAssertEqual(try! p.unpad(paddedFrame: p.pad(encryptedPayload: payload, confidenceScore: 0.7)), payload, "Failed for size \(size)")
        }
    }
    func testStatistics() {
        let p = AdaptivePadding()
        _ = p.pad(encryptedPayload: Data(repeating: 0, count: 50), confidenceScore: 0.5)
        _ = p.pad(encryptedPayload: Data(repeating: 0, count: 50), confidenceScore: 0.5)
        XCTAssertEqual(p.statistics.totalFramesPadded, 2)
    }
}
