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

    /// W-GRPFALLBACKAUDIO-IOS regression — before this fix, `parseBinary`'s
    /// `.audioData` case returned the WHOLE multi-frame batch payload as a
    /// single opaque `Data`, silently corrupting every frame past the first
    /// (the 2-byte count header and each frame's own 2-byte length prefix
    /// stayed embedded in what callers would have tried to `open()` as raw
    /// ciphertext). This pins the real round trip: N frames in, the SAME N
    /// frames out, byte-for-byte, in order.
    func testCreateAndParseAudioDataSingleFrame() {
        let frame = Data(repeating: 0x42, count: 136) // 120B padded plaintext + 16B GCM tag, a realistic sealed-audio frame size
        let wire = QAudionCapabilityExchange.createAudioData(frames: [frame])
        guard let message = QAudionCapabilityExchange.parse(wire) else {
            XCTFail("Failed to parse AUDIO_DATA"); return
        }
        guard case .audioData(let frames) = message else {
            XCTFail("Expected .audioData"); return
        }
        XCTAssertEqual(frames, [frame])
    }

    func testCreateAndParseAudioDataMultiFrame() {
        let f0 = Data(repeating: 0x01, count: 136)
        let f1 = Data(repeating: 0x02, count: 90)
        let f2 = Data() // zero-length frame must round-trip too (the W-PADOVERFLOW sentinel is carried one layer up, inside the sealed ciphertext — this layer must not special-case an empty element)
        let wire = QAudionCapabilityExchange.createAudioData(frames: [f0, f1, f2])
        guard let message = QAudionCapabilityExchange.parse(wire),
              case .audioData(let frames) = message else {
            XCTFail("Failed to parse multi-frame AUDIO_DATA"); return
        }
        XCTAssertEqual(frames, [f0, f1, f2])
    }

    func testAudioDataEmptyBatch() {
        let wire = QAudionCapabilityExchange.createAudioData(frames: [])
        guard let message = QAudionCapabilityExchange.parse(wire),
              case .audioData(let frames) = message else {
            XCTFail("Failed to parse empty AUDIO_DATA batch"); return
        }
        XCTAssertEqual(frames, [])
    }

    func testIsQuadEnvelope() {
        let offer = QAudionCapabilityExchange.createOffer(publicKey: Data(repeating: 0xAA, count: 32))
        XCTAssertTrue(QAudionCapabilityExchange.isQuadEnvelope(offer))
        XCTAssertFalse(QAudionCapabilityExchange.isQuadEnvelope(Data(repeating: 0x99, count: 40)))
        XCTAssertFalse(QAudionCapabilityExchange.isQuadEnvelope(Data([0x51, 0x41, 0x55]))) // truncated magic
    }
}
