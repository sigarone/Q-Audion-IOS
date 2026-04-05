import XCTest
@testable import QAudionEngine

final class CryptoConstantsTests: XCTestCase {

    func testKeySizes() {
        XCTAssertEqual(CryptoConstants.keySizeBits, 256)
        XCTAssertEqual(CryptoConstants.keySizeBytes, 32)
    }

    func testAeadParameters() {
        XCTAssertEqual(CryptoConstants.nonceSize, 12)
        XCTAssertEqual(CryptoConstants.tagSize, 16)
    }

    func testRatchetParameters() {
        XCTAssertEqual(CryptoConstants.ratchetIntervalFrames, 100)
        XCTAssertEqual(CryptoConstants.ratchetIntervalMs, 300_000)
    }

    func testAudioParameters() {
        XCTAssertEqual(CryptoConstants.frameDurationMs, 20)
        XCTAssertEqual(CryptoConstants.sampleRate, 48000)
        XCTAssertEqual(CryptoConstants.samplesPerFrame, 960)
    }

    func testHkdfInfoStrings() {
        XCTAssertEqual(CryptoConstants.hkdfInfoChain, Data("q-audion-frame-key".utf8))
        XCTAssertEqual(CryptoConstants.hkdfInfoRoot, Data("q-audion-root-ratchet".utf8))
        XCTAssertEqual(CryptoConstants.hkdfInfoPskMix, Data("q-audion-psk-mix".utf8))
        XCTAssertEqual(CryptoConstants.hkdfInfoNextChain, Data("q-audion-next-chain".utf8))
    }

    func testZeroize() {
        var data = Data([0x01, 0x02, 0x03, 0x04])
        CryptoConstants.zeroize(&data)
        XCTAssertEqual(data, Data([0x00, 0x00, 0x00, 0x00]))
    }

    func testConstantTimeEquals_identical() {
        let a = Data([0x01, 0x02, 0x03])
        let b = Data([0x01, 0x02, 0x03])
        XCTAssertTrue(CryptoConstants.constantTimeEquals(a, b))
    }

    func testConstantTimeEquals_different() {
        let a = Data([0x01, 0x02, 0x03])
        let b = Data([0x01, 0x02, 0x04])
        XCTAssertFalse(CryptoConstants.constantTimeEquals(a, b))
    }

    func testConstantTimeEquals_differentLength() {
        let a = Data([0x01, 0x02])
        let b = Data([0x01, 0x02, 0x03])
        XCTAssertFalse(CryptoConstants.constantTimeEquals(a, b))
    }
}
