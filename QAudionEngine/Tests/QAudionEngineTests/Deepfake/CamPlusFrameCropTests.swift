import XCTest
@testable import QAudionEngine

/// The fbank frames `CamPlusSpeakerEmbedder` gives the model: a multiple of 200, mean-normalized over the frames kept.
final class CamPlusFrameCropTests: XCTestCase {

    private func frames(_ count: Int, _ value: (Int) -> Float) -> [[Float]] {
        (0..<count).map { t in [Float](repeating: value(t), count: KaldiFbankExtractor.numMelBins) }
    }

    func testTheModelGetsAMultipleOf200FramesMeanNormalizedOverThoseFrames() throws {
        // Frames 0..<200 hold 1 and the rest 100: the mean of all 300 frames is 34, the mean of the 200 kept is 1.
        let input = frames(300) { $0 < 200 ? 1 : 100 }
        let kept = try XCTUnwrap(CamPlusSpeakerEmbedder.modelFrames(from: input))
        XCTAssertEqual(kept.count, 200)
        XCTAssertTrue(kept.allSatisfy { row in row.allSatisfy { abs($0) < 1e-5 } })
        XCTAssertEqual(input.count, 300, "the input is not modified")

        let four = try XCTUnwrap(CamPlusSpeakerEmbedder.modelFrames(from: frames(400) { Float($0 % 5) }))
        XCTAssertEqual(four.count, 400)
        XCTAssertEqual(four.reduce(0) { $0 + $1[0] } / Float(four.count), 0, accuracy: 1e-5)

        XCTAssertEqual(CamPlusSpeakerEmbedder.modelFrames(from: frames(906) { Float($0 % 5) })?.count, 800)
        XCTAssertEqual(CamPlusSpeakerEmbedder.modelFrames(from: frames(200) { Float($0) })?.count, 200)
        XCTAssertNil(CamPlusSpeakerEmbedder.modelFrames(from: frames(199) { Float($0) }), "under 2 s there is no embedding")
        XCTAssertNil(CamPlusSpeakerEmbedder.modelFrames(from: []))
    }

    /// The owner window (4 s at 16 kHz) is 400 frames from the real extractor and the model sees all of them; a 3 s
    /// window is 300 frames and the model sees the first 200.
    func testTheOwnerWindowIsFourHundredFramesAndAllOfItIsKept() throws {
        let window = (0..<64_000).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / 16_000)) }
        let extractor = KaldiFbankExtractor()

        let all = extractor.extract(window)
        XCTAssertEqual(all.count, 400)
        XCTAssertEqual(CamPlusSpeakerEmbedder.modelFrames(from: all)?.count, 400)

        let three = extractor.extract(Array(window.prefix(48_000)))
        XCTAssertEqual(three.count, 300)
        XCTAssertEqual(CamPlusSpeakerEmbedder.modelFrames(from: three)?.count, 200)
    }
}
