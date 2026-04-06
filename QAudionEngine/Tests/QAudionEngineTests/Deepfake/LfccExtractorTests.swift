import XCTest
@testable import QAudionEngine

final class LfccExtractorTests: XCTestCase {
    func testExtractProducesFeatures() {
        let extractor = LfccExtractor()
        // Generate 48000 samples = 1 second of 48kHz audio
        var pcm = Data(count: 48000 * 2)
        pcm.withUnsafeMutableBytes { buf in
            let ptr = buf.bindMemory(to: Int16.self)
            for i in 0..<48000 { ptr[i] = Int16(sin(Double(i) * 440.0 * 2 * .pi / 48000.0) * 16000) }
        }
        let features = extractor.extract(pcmData: pcm)
        XCTAssertFalse(features.isEmpty)
        // Features should be multiple of 60 (20 coeffs * 3 = coeffs + delta + delta-delta)
        XCTAssertEqual(features.count % LfccExtractor.totalFeatures, 0)
    }

    func testEmptyInput() {
        XCTAssertTrue(LfccExtractor().extract(pcmData: Data()).isEmpty)
    }

    func testParameters() {
        XCTAssertEqual(LfccExtractor.sampleRate, 48000)
        XCTAssertEqual(LfccExtractor.numCoeffs, 20)
        XCTAssertEqual(LfccExtractor.totalFeatures, 60)
    }
}
