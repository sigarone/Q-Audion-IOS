import XCTest
@testable import QAudionEngine

/// W-GRPFALLBACKAUDIO-IOS — unit coverage for the seal/open roundtrip the
/// group-call SFU-outage fallback-audio receive path unseals real Opus
/// frames with. Ungated from `canImport(WebRTC)` (unlike
/// `PqcRtpFrameSealerTests`): `GroupFallbackAudioSealer`'s own dependencies
/// (`AeadCipher`, `FrameEncoder`, `CryptoKit`) have nothing to do with the
/// WebRTC target — see that class's own kdoc.
final class GroupFallbackAudioSealerTests: XCTestCase {

    private let key32 = Data(repeating: 0x37, count: 32)

    func testRoundTripTypicalOpusFrame() throws {
        let tx = GroupFallbackAudioSealer()
        let rx = GroupFallbackAudioSealer()
        // A realistic 20ms Opus frame at the standard 40kbps operating
        // point is well under the 118-byte (120 - 2 header) budget.
        let opus = Data((0..<80).map { UInt8($0 & 0xFF) })
        let wire = try tx.sealAudio(opus: opus, sessionKey: key32)
        let opened = try rx.openAudio(wire: wire, sessionKey: key32)
        XCTAssertEqual(opened.opus, opus)
    }

    func testMultipleFramesRoundTripInOrder() throws {
        let tx = GroupFallbackAudioSealer()
        let rx = GroupFallbackAudioSealer()
        let frames = (0..<5).map { i in Data(repeating: UInt8(i), count: 40 + i) }
        for f in frames {
            let wire = try tx.sealAudio(opus: f, sessionKey: key32)
            let opened = try rx.openAudio(wire: wire, sessionKey: key32)
            XCTAssertEqual(opened.opus, f)
        }
    }

    /// W-PADOVERFLOW parity — an Opus frame too large for the standard
    /// 120-byte block (budget = 118 bytes after the 2-byte length header)
    /// must NOT throw and must NOT change the wire size: it degrades to a
    /// declared-length-zero packet, which `openAudio` surfaces as
    /// `OpenResult(opus: nil)` — the caller's PLC-concealment sentinel —
    /// rather than corrupting or truncating the oversized frame.
    func testOversizedFrameDegradesToSilenceSentinelNotError() throws {
        let tx = GroupFallbackAudioSealer()
        let rx = GroupFallbackAudioSealer()
        let tooLarge = Data(repeating: 0xAB, count: 200) // > 118-byte budget
        let wire = try tx.sealAudio(opus: tooLarge, sessionKey: key32)
        let opened = try rx.openAudio(wire: wire, sessionKey: key32)
        XCTAssertNil(opened.opus, "oversized frame must degrade to the silence sentinel, not leak/truncate the real audio")
    }

    func testWireSizeIsConstantRegardlessOfOpusLength() throws {
        let tx = GroupFallbackAudioSealer()
        let short = try tx.sealAudio(opus: Data([0x01, 0x02]), sessionKey: key32)
        let long = try tx.sealAudio(opus: Data(repeating: 0x03, count: 100), sessionKey: key32)
        // Anti-traffic-analysis property: every sealed frame is the same
        // size on the wire regardless of the real Opus payload length.
        XCTAssertEqual(short.count, long.count)
    }

    func testWrongKeyFailsToOpen() throws {
        let tx = GroupFallbackAudioSealer()
        let rx = GroupFallbackAudioSealer()
        let wire = try tx.sealAudio(opus: Data([0x01, 0x02, 0x03]), sessionKey: key32)
        let wrongKey = Data(repeating: 0x99, count: 32)
        XCTAssertThrowsError(try rx.openAudio(wire: wire, sessionKey: wrongKey))
    }

    func testTamperedCiphertextFailsToOpen() throws {
        let tx = GroupFallbackAudioSealer()
        let rx = GroupFallbackAudioSealer()
        var wire = try tx.sealAudio(opus: Data([0x0A, 0x0B]), sessionKey: key32)
        let last = wire.endIndex - 1
        wire[last] ^= 0xFF
        XCTAssertThrowsError(try rx.openAudio(wire: wire, sessionKey: key32))
    }

    func testRejectsWrongKeyLengthOnSeal() {
        let tx = GroupFallbackAudioSealer()
        XCTAssertThrowsError(try tx.sealAudio(opus: Data([0x01]), sessionKey: Data(repeating: 0x01, count: 16)))
    }

    func testRejectsWrongKeyLengthOnOpen() throws {
        let tx = GroupFallbackAudioSealer()
        let wire = try tx.sealAudio(opus: Data([0x01]), sessionKey: key32)
        XCTAssertThrowsError(try tx.openAudio(wire: wire, sessionKey: Data(repeating: 0x01, count: 16)))
    }

    func testTwoSealersDifferentKeysDontInterop() throws {
        let tx = GroupFallbackAudioSealer()
        let rxWrongKey = GroupFallbackAudioSealer()
        let wire = try tx.sealAudio(opus: Data([0x01, 0x02]), sessionKey: key32)
        let otherKey = Data(repeating: 0x77, count: 32)
        XCTAssertThrowsError(try rxWrongKey.openAudio(wire: wire, sessionKey: otherKey))
    }

    /// Interop sanity: the AUDIO_DATA envelope batches N sealed wire frames
    /// (`QAudionCapabilityExchange.createAudioData`/`parseAudioDataBatch`).
    /// This exercises exactly that combination — seal locally, batch, wrap,
    /// unwrap, unseal — the same path `GroupCallController.
    /// handleFallbackAudioData` runs against a real inbound envelope.
    func testRoundTripThroughAudioDataEnvelope() throws {
        let tx = GroupFallbackAudioSealer()
        let rx = GroupFallbackAudioSealer()
        let opusFrames = [Data([0x01, 0x02, 0x03]), Data([0x04, 0x05])]
        let wireFrames = try opusFrames.map { try tx.sealAudio(opus: $0, sessionKey: key32) }
        let envelope = QAudionCapabilityExchange.createAudioData(frames: wireFrames)
        guard let message = QAudionCapabilityExchange.parse(envelope),
              case .audioData(let parsedFrames) = message else {
            XCTFail("failed to parse AUDIO_DATA envelope")
            return
        }
        XCTAssertEqual(parsedFrames.count, opusFrames.count)
        for (wire, expectedOpus) in zip(parsedFrames, opusFrames) {
            let opened = try rx.openAudio(wire: wire, sessionKey: key32)
            XCTAssertEqual(opened.opus, expectedOpus)
        }
    }
}
