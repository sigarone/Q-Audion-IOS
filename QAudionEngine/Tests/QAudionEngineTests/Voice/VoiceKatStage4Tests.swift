import XCTest
import Foundation
@testable import QAudionEngine

/// The table-driven filter bank on the stored windows: the samples of each window are the chunks of its ranges from the
/// clip's reference chunk stream.
final class VoiceKatStage4Tests: XCTestCase {

    func testEveryStoredWindow() throws {
        let bundle = try VoiceKat.bundle()
        let fbank = VoiceFbank(tables: bundle.tables, constants: bundle.constants.fbank)
        let stage4 = try VoiceKat.json("stage4_fbank/stage4.json")
        XCTAssertEqual(stage4["shape"].ints, [VoiceFbank.frames, VoiceFbankTables.numMel])
        XCTAssertEqual(stage4["windows"].count, 9)

        var streams: [String: [Float]] = [:]
        var worstOverall: Float = 0
        for entry in stage4["windows"].array {
            let clip = entry["clip"].string
            let inputs = try VoiceKat.json("stage3_measure/clip_\(clip).inputs.json")
            if streams[clip] == nil {
                var passThrough: [Int: [Float]] = [:]
                for (j, seg) in inputs["tap_segments"].array.enumerated() {
                    let first = seg["first_sample"].int
                    let wav = try VoiceKat.wav(seg["audio_file"].string)
                    passThrough[j] = VoiceKat.scaled(Array(wav.samples[first..<(first + seg["n_samples"].int)]))
                }
                streams[clip] = try VoiceKat.chunkStream(inputs["stream_segments"], passThrough: passThrough)
            }
            let stream = streams[clip] ?? []

            let expected = try VoiceKat.json("stage3_measure/clip_\(clip).expected.json")
            let window = expected["windows"][entry["window"].int]
            XCTAssertEqual(window["first"].int, entry["first_chunk"].int, "clip \(clip) window")
            XCTAssertEqual(window["last"].int, entry["last_chunk"].int, "clip \(clip) window")

            var samples: [Float] = []
            for range in window["ranges"].array {
                let first = range[0].int
                let end = range[1].int
                samples.append(contentsOf: stream[(first * VoiceChunker.chunkLength)..<(end * VoiceChunker.chunkLength)])
            }
            XCTAssertEqual(samples.count, VoiceFbank.windowSamples, "clip \(clip) window samples")
            guard samples.count == VoiceFbank.windowSamples else { continue }

            let got = fbank.fbank(samples)
            let want = try VoiceKat.floats(entry["file"].string)
            XCTAssertEqual(got.count, want.count, entry["file"].string)
            guard got.count == want.count else { continue }
            var worst: Float = 0
            for i in 0..<got.count {
                worst = max(worst, abs(got[i] - want[i]))
            }
            worstOverall = max(worstOverall, worst)
            XCTAssertLessThanOrEqual(worst, 5e-3, "\(entry["file"].string) largest difference")
        }
        print("voice-kat fbank largest difference \(worstOverall)")
    }
}
