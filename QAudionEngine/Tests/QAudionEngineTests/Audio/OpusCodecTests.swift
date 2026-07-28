import XCTest
@testable import QAudionEngine

final class OpusCodecTests: XCTestCase {
    func testEncodeReturnsData() {
        let codec = OpusCodec()
        let pcm = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        let encoded = codec.encode(pcm)
        XCTAssertNotNil(encoded)
        // Safe: pcm is fixed-size (bytesPerFrame), so encode() always succeeds.
        // swiftlint:disable:next force_unwrapping
        XCTAssertFalse(encoded!.isEmpty)
    }

    func testEncodeWrongSizeReturnsNil() {
        let codec = OpusCodec()
        XCTAssertNil(codec.encode(Data(repeating: 0, count: 100)))
    }

    func testDecodeReturnsData() {
        let codec = OpusCodec()
        let pcm = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        // Safe: pcm is fixed-size (bytesPerFrame), so encode() always succeeds.
        // swiftlint:disable:next force_unwrapping
        let encoded = codec.encode(pcm)!
        let decoded = codec.decode(encoded)
        XCTAssertNotNil(decoded)
        // Safe: decoded from a valid non-empty encoded frame, so decode() always succeeds.
        // swiftlint:disable:next force_unwrapping
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
        // Safe: pcm is fixed-size (bytesPerFrame), so encode() always succeeds.
        // swiftlint:disable:next force_unwrapping
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

    // MARK: - W-IOSFECFLAG

    private func rms(_ d: Data) -> Double {
        let n = d.count / 2
        guard n > 0 else { return 0 }
        var sumSq = 0.0
        d.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<n {
                let v = Double(Int16(littleEndian: p[i]))
                sumSq += v * v
            }
        }
        return (sumSq / Double(n)).squareRoot()
    }

    private func tone(amplitude: Double = 0.35) -> Data {
        var d = Data(count: AudioConstants.bytesPerFrame)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<AudioConstants.samplesPerFrame {
                let t = Double(i) / Double(AudioConstants.sampleRate)
                p[i] = Int16(sin(2 * Double.pi * 440 * t) * amplitude * 32767)
            }
        }
        return d
    }

    /// THE test the suite was missing. `testDecodeReturnsData` above asserts only
    /// non-nil and byte count, so it passes when the decoder returns pure
    /// concealment — which is exactly what iOS did on every frame while
    /// `decode_fec` was 1, and why the defect survived for weeks.
    ///
    /// A steady tone is NOT a valid probe here: the LBRR copy of the previous
    /// frame of a steady tone also has energy. The signal has to CHANGE between
    /// frames so "the previous one" is distinguishable from "this one".
    func testDecodeRendersTheCurrentFrameAndNotThePreviousOne() {
        let codec = OpusCodec()
        let silence = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        let loud = tone()
        let inputRms = rms(loud)
        XCTAssertGreaterThan(inputRms, 1000, "the probe tone itself must be loud")

        // Alternate silence and tone so a frame-late decode is unmistakable.
        var decodedToneRms: [Double] = []
        for i in 0..<8 {
            let src = (i % 2 == 0) ? silence : loud
            guard let enc = codec.encode(src), let dec = codec.decode(enc) else {
                return XCTFail("encode/decode failed at frame \(i)")
            }
            if i % 2 == 1 { decodedToneRms.append(rms(dec)) }
        }
        // Skip the first pair: the encoder has lookahead and the decoder is cold.
        let settled = decodedToneRms.dropFirst()
        XCTAssertFalse(settled.isEmpty)
        for (k, r) in settled.enumerated() {
            XCTAssertGreaterThan(
                r, inputRms * 0.2,
                "tone frame \(k) decoded at RMS \(r) against an input of \(inputRms) — " +
                "that is concealment or the previous frame, not this one"
            )
        }
    }

    /// And the mirror: a silent frame must not come back loud. Catches the
    /// symmetric failure where the decoder renders a stale loud frame.
    func testASilentFrameDecodesQuiet() {
        let codec = OpusCodec()
        let loud = tone()
        let silence = Data(repeating: 0, count: AudioConstants.bytesPerFrame)
        // Safe: loud/silence are fixed-size tone()/Data buffers, so encode() always succeeds.
        // swiftlint:disable:next force_unwrapping
        for _ in 0..<4 { _ = codec.decode(codec.encode(loud)!) }
        var last = 0.0
        // Safe: encode() always succeeds on a fixed-size buffer, and decode() always
        // succeeds on the resulting non-empty encoded frame.
        // swiftlint:disable:next force_unwrapping
        for _ in 0..<4 { last = rms(codec.decode(codec.encode(silence)!)!) }
        XCTAssertLessThan(last, rms(loud) * 0.2, "silence decoded at RMS \(last)")
    }
}
