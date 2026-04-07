import XCTest
@testable import QAudionEngine

final class OpusCodecTests: XCTestCase {
    func testEncodeReturnsData() {
        let codec = OpusCodec()
        let pcm = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        let encoded = codec.encode(pcm)
        XCTAssertNotNil(encoded)
        XCTAssertFalse(encoded!.isEmpty)
    }

    func testEncodeWrongSizeReturnsNil() {
        let codec = OpusCodec()
        XCTAssertNil(codec.encode(Data(repeating: 0, count: 100)))
    }

    func testDecodeReturnsData() {
        let codec = OpusCodec()
        let pcm = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        let encoded = codec.encode(pcm)!
        let decoded = codec.decode(encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.count, AudioConstants.bytesPerFrame)
    }

    func testDecodePLC() {
        let codec = OpusCodec()
        let plc = codec.decodePLC()
        XCTAssertEqual(plc.count, AudioConstants.bytesPerFrame)
    }

    func testStats() {
        let codec = OpusCodec()
        let pcm = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        _ = codec.encode(pcm)
        _ = codec.encode(pcm)
        let encoded = codec.encode(pcm)!
        _ = codec.decode(encoded)
        let stats = codec.getStats()
        XCTAssertEqual(stats.encoded, 3)
        XCTAssertEqual(stats.decoded, 1)
    }

    func testReconfigure() {
        let codec = OpusCodec()
        codec.reconfigure(.highQuality())
        let pcm = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        XCTAssertNotNil(codec.encode(pcm))
    }
}
