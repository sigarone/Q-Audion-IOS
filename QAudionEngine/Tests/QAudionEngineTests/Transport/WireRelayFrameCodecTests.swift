import XCTest
@testable import QAudionEngine

/// Cross-platform parity tests against Android's
/// `feature/feature-call/.../domain/FrameRelayTransport.kt`.
/// The byte sequences encoded here MUST match what Android emits with the
/// same nonce / seq / ciphertext.
final class WireRelayFrameCodecTests: XCTestCase {

    // MARK: - Audio

    func testAudioWireLayoutMatchesAndroid() {
        let nonce = Data(repeating: 0xAA, count: 12)
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let tag = Data(repeating: 0xCC, count: 16)
        let frame = EncryptedFrame(
            sequenceNumber: 0x12345678,
            timestamp: 0, // not on the wire
            nonce: nonce,
            payload: payload,
            tag: tag
        )
        let wire = WireRelayFrameCodec.encodeAudio(frame)

        // Layout: 1 + 12 + 8 + 2 + (4+16) = 43 bytes
        XCTAssertEqual(wire.count, 1 + 12 + 8 + 2 + payload.count + tag.count)
        XCTAssertEqual(wire[0], 0x01)                // mux = AUDIO
        XCTAssertEqual(wire.subdata(in: 1..<13), nonce)

        // seq = 0x0000000012345678 (BE)
        XCTAssertEqual(wire[13], 0x00)
        XCTAssertEqual(wire[14], 0x00)
        XCTAssertEqual(wire[15], 0x00)
        XCTAssertEqual(wire[16], 0x00)
        XCTAssertEqual(wire[17], 0x12)
        XCTAssertEqual(wire[18], 0x34)
        XCTAssertEqual(wire[19], 0x56)
        XCTAssertEqual(wire[20], 0x78)

        // ct_len = payload(4) + tag(16) = 20 (BE)
        XCTAssertEqual(wire[21], 0x00)
        XCTAssertEqual(wire[22], 0x14)

        // ciphertext bytes
        XCTAssertEqual(wire.subdata(in: 23..<27), payload)
        XCTAssertEqual(wire.subdata(in: 27..<43), tag)
    }

    func testAudioRoundTrip() throws {
        let frame = EncryptedFrame(
            sequenceNumber: 9999,
            timestamp: 0,
            nonce: Data(repeating: 0x42, count: 12),
            payload: Data([0x01, 0x02, 0x03]),
            tag: Data(repeating: 0xEE, count: 16)
        )
        let wire = WireRelayFrameCodec.encodeAudio(frame)
        let decoded = try WireRelayFrameCodec.decode(wire)

        switch decoded.kind {
        case .audio: break
        case .video: XCTFail("expected audio")
        }
        XCTAssertEqual(decoded.frame.sequenceNumber, frame.sequenceNumber)
        XCTAssertEqual(decoded.frame.nonce, frame.nonce)
        XCTAssertEqual(decoded.frame.payload, frame.payload)
        XCTAssertEqual(decoded.frame.tag, frame.tag)
        XCTAssertEqual(decoded.frame.timestamp, 0) // synthesized
    }

    // MARK: - Video

    func testVideoWireLayoutMatchesAndroid() {
        let nonce = Data(repeating: 0x55, count: 12)
        let payload = Data([0x10, 0x20])
        let tag = Data(repeating: 0xBB, count: 16)
        let frame = EncryptedFrame(
            sequenceNumber: 1,
            timestamp: 0,
            nonce: nonce,
            payload: payload,
            tag: tag
        )
        let wire = WireRelayFrameCodec.encodeVideo(frame, fragIdx: 7, totalFrags: 11, isKey: true)

        XCTAssertEqual(wire.count, 1 + 2 + 2 + 1 + 12 + 8 + 2 + payload.count + tag.count)
        XCTAssertEqual(wire[0], 0x02)                // mux = VIDEO
        XCTAssertEqual(wire[1], 0x00); XCTAssertEqual(wire[2], 0x07) // fragIdx = 7
        XCTAssertEqual(wire[3], 0x00); XCTAssertEqual(wire[4], 0x0B) // totalFrags = 11
        XCTAssertEqual(wire[5], 0x01)                // isKey = true
        XCTAssertEqual(wire.subdata(in: 6..<18), nonce)
    }

    func testVideoRoundTrip() throws {
        let frame = EncryptedFrame(
            sequenceNumber: 0xCAFEBABE,
            timestamp: 0,
            nonce: Data(repeating: 0x33, count: 12),
            payload: Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE]),
            tag: Data(repeating: 0x77, count: 16)
        )
        let wire = WireRelayFrameCodec.encodeVideo(frame, fragIdx: 3, totalFrags: 9, isKey: false)
        let decoded = try WireRelayFrameCodec.decode(wire)

        switch decoded.kind {
        case .audio:
            XCTFail("expected video")
        case .video(let fragIdx, let totalFrags, let isKey):
            XCTAssertEqual(fragIdx, 3)
            XCTAssertEqual(totalFrags, 9)
            XCTAssertFalse(isKey)
        }
        XCTAssertEqual(decoded.frame.sequenceNumber, frame.sequenceNumber)
        XCTAssertEqual(decoded.frame.nonce, frame.nonce)
        XCTAssertEqual(decoded.frame.payload, frame.payload)
        XCTAssertEqual(decoded.frame.tag, frame.tag)
    }

    // MARK: - Edge cases

    func testEmptyPayloadDecodes() throws {
        // ctLen = 16 (just the tag, no payload). Mirrors Android comfort-noise
        // / heartbeat frames.
        let frame = EncryptedFrame(
            sequenceNumber: 1,
            timestamp: 0,
            nonce: Data(repeating: 0x01, count: 12),
            payload: Data(),
            tag: Data(repeating: 0x02, count: 16)
        )
        let wire = WireRelayFrameCodec.encodeAudio(frame)
        let decoded = try WireRelayFrameCodec.decode(wire)
        XCTAssertEqual(decoded.frame.payload, Data())
        XCTAssertEqual(decoded.frame.tag, frame.tag)
    }

    func testTruncatedFrameThrows() {
        let bad = Data([0x01, 0x00, 0x00]) // mux byte + 2 random bytes
        XCTAssertThrowsError(try WireRelayFrameCodec.decode(bad))
    }

    func testCiphertextSmallerThanTagThrows() {
        // mux + 12 nonce + 8 seq + ct_len(0x000F) + 15 bytes of "ciphertext"
        var data = Data([0x01])
        data.append(Data(repeating: 0xAA, count: 12))
        data.append(Data(repeating: 0x00, count: 8))
        data.append(0x00); data.append(0x0F) // ct_len = 15 (< 16)
        data.append(Data(repeating: 0xCC, count: 15))
        XCTAssertThrowsError(try WireRelayFrameCodec.decode(data)) { err in
            guard case WireRelayFrameCodec.CodecError.ciphertextTooSmall(let n) = err else {
                XCTFail("expected ciphertextTooSmall, got \(err)"); return
            }
            XCTAssertEqual(n, 15)
        }
    }

    func testEmptyDataThrowsEmpty() {
        XCTAssertThrowsError(try WireRelayFrameCodec.decode(Data())) { err in
            guard case WireRelayFrameCodec.CodecError.empty = err else {
                XCTFail("expected .empty, got \(err)"); return
            }
        }
    }

    func testLegacyUntaggedAudioFallback() throws {
        // No mux byte at start (an unknown leading byte != 0x01 / 0x02).
        // Per the Android spec we treat it as legacy untagged audio.
        let nonce = Data(repeating: 0x77, count: 12)
        let payload = Data([0x99])
        let tag = Data(repeating: 0x88, count: 16)
        var data = Data([0xFE]) // unknown mux
        data.append(nonce)
        data.append(Data(repeating: 0, count: 7)); data.append(0x05) // seq = 5 (BE)
        data.append(0x00); data.append(0x11) // ct_len = 17 (1 payload + 16 tag)
        data.append(payload)
        data.append(tag)
        // The codec should reject this because 0xFE is not mux=AUDIO and not
        // mux=VIDEO. The transport-level fallback (legacy iOS FrameEncoder)
        // is invoked separately; here we just verify the codec doesn't lie.
        // BUT: we still have the legacy untagged audio code path inside the
        // codec itself (header_size = 0). Let's construct one without any
        // mux byte at all — the input starts with a NONCE byte.
        // This is documented in the codec as "legacy pre-mux Android builds"
        // → we exercise that here.
        var legacy = Data()
        legacy.append(nonce)
        legacy.append(Data(repeating: 0, count: 7)); legacy.append(0x05)
        legacy.append(0x00); legacy.append(0x11)
        legacy.append(payload)
        legacy.append(tag)
        // First byte is 0x77 (nonce[0]); not a known mux → legacy path.
        let decoded = try WireRelayFrameCodec.decode(legacy)
        switch decoded.kind {
        case .audio: break
        case .video: XCTFail("legacy must decode as audio")
        }
        XCTAssertEqual(decoded.frame.sequenceNumber, 5)
        XCTAssertEqual(decoded.frame.payload, payload)
        XCTAssertEqual(decoded.frame.tag, tag)
    }
}
