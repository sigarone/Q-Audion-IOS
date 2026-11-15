import XCTest
import Foundation
@testable import QAudionEngine

/// Silero VAD through ONNX Runtime on the reference chunk streams: probabilities within the stage 2 tolerance, and the
/// hysteresis and labels that follow from them exactly.
final class VoiceKatSileroTests: XCTestCase {

    func testEveryClipAgreesWithTheStoredProbabilitiesAndLabels() throws {
        let bundle = try VoiceKat.bundle()
        let stage2 = try VoiceKat.json("stage2_vad/stage2.json")
        let stage1 = try VoiceKat.json("stage1_resampler/stage1.json")
        let runner = try SileroVadRunner(modelURL: bundle.vadModelURL)

        // The pass-through clip has no stage 1 file: its stream is the audio itself.
        var passThrough: [Int: [Float]] = [:]
        for clip in stage1["clips"].array where clip["expected_file"].isNull && clip["name"].string == "d" {
            passThrough[0] = VoiceKat.scaled(try VoiceKat.wav(clip["audio_file"].string).samples)
        }

        var worst: Float = 0
        for clip in stage2["clips"].array {
            let name = clip["name"].string
            let stream = try VoiceKat.chunkStream(clip["stream_segments"], passThrough: passThrough)
            let count = clip["n_chunks"].int
            XCTAssertEqual(stream.count, count * VoiceChunker.chunkLength, "clip \(name) stream length")
            let events = VoiceLabellerRun.events(clip["events"])
            let resets = Set(events.filter { $0.kind == "reset" }.map { $0.atChunk })
            let stored = try VoiceKat.floats("stage2_vad/clip_\(name).p.f32")

            runner.reset()
            var p: [Float] = []
            for index in 0..<count {
                if resets.contains(index) {
                    runner.reset()
                }
                let chunk = Array(stream[(index * VoiceChunker.chunkLength)..<((index + 1) * VoiceChunker.chunkLength)])
                p.append(try runner.step(chunk))
            }
            XCTAssertEqual(p.count, stored.count, "clip \(name)")
            for index in 0..<min(p.count, stored.count) {
                let difference = abs(p[index] - stored[index])
                worst = max(worst, difference)
                XCTAssertLessThanOrEqual(difference, 2e-3, "clip \(name) chunk \(index)")
            }

            let result = VoiceLabellerRun.run(
                probabilities: p.map { Double($0) }, events: events, config: bundle.constants.vad)
            XCTAssertEqual(result.h, try VoiceKat.bytes(clip["h_file"].string), "clip \(name) hysteresis")
            XCTAssertEqual(result.labels, try VoiceKat.bytes(clip["label_file"].string), "clip \(name) labels")
        }
        print("voice-kat silero largest probability difference \(worst)")
    }
}
