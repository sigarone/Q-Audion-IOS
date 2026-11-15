import XCTest
import Foundation
@testable import QAudionEngine

/// The labeller against the reference: the synthetic vector, and the clips' stored probabilities.
enum VoiceLabellerRun {
    /// Runs the hysteresis and the streaming labeller over probabilities, with events positioned before chunk
    /// `atChunk`; `reset` and `hold` restart the labeller. Returns the hysteresis and the final label of every chunk.
    static func run(
        probabilities: [Double],
        events: [(kind: String, atChunk: Int)],
        config: VoiceConstants.Vad
    ) -> (h: [UInt8], labels: [UInt8]) {
        let labeller = VoiceLabeller(config: config)
        var h = [UInt8](repeating: 0, count: probabilities.count)
        var labels = [UInt8](repeating: 0, count: probabilities.count)
        let ordered = events.enumerated().sorted { a, b in
            a.element.atChunk != b.element.atChunk ? a.element.atChunk < b.element.atChunk : a.offset < b.offset
        }.map { $0.element }
        var next = 0
        for index in 0..<probabilities.count {
            while next < ordered.count && ordered[next].atChunk <= index {
                if ordered[next].kind == "reset" || ordered[next].kind == "hold" {
                    for entry in labeller.flush() {
                        labels[entry.index] = entry.label
                    }
                    labeller.resetState(nextIndex: index)
                }
                next += 1
            }
            let outcome = labeller.push(index: index, probability: probabilities[index])
            h[index] = outcome.hysteresis
            for entry in outcome.finalized {
                labels[entry.index] = entry.label
            }
        }
        for entry in labeller.flush() {
            labels[entry.index] = entry.label
        }
        return (h: h, labels: labels)
    }

    static func events(_ json: KatJSON) -> [(kind: String, atChunk: Int)] {
        json.array.map { (kind: $0["kind"].string, atChunk: $0["at_chunk"].int) }
    }
}

final class VoiceKatStage2Tests: XCTestCase {

    func testLabellerVector() throws {
        let config = try VoiceKat.bundle().constants.vad
        let vector = try VoiceKat.json("stage2_vad/labeller.json")
        XCTAssertEqual(vector["cases"].count, 10)
        for testCase in vector["cases"].array {
            let name = testCase["name"].string
            var p: [Double] = []
            for run in testCase["p_runs"].array {
                p.append(contentsOf: [Double](repeating: run[0].double, count: run[1].int))
            }
            XCTAssertEqual(p.count, testCase["n_chunks"].int, name)
            let result = VoiceLabellerRun.run(
                probabilities: p, events: VoiceLabellerRun.events(testCase["events"]), config: config)
            XCTAssertEqual(result.h.map { Int($0) }, testCase["h"].ints, "\(name) hysteresis")
            XCTAssertEqual(result.labels.map { Int($0) }, testCase["labels"].ints, "\(name) labels")
        }
    }

    /// The stored probabilities and events of every clip give the stored hysteresis and labels.
    func testClipLabelsFromStoredProbabilities() throws {
        let config = try VoiceKat.bundle().constants.vad
        let stage2 = try VoiceKat.json("stage2_vad/stage2.json")
        XCTAssertEqual(stage2["clips"].count, 7)
        for clip in stage2["clips"].array {
            let name = clip["name"].string
            let p = try VoiceKat.floats("stage2_vad/clip_\(name).p.f32").map { Double($0) }
            XCTAssertEqual(p.count, clip["n_chunks"].int, name)
            let result = VoiceLabellerRun.run(
                probabilities: p, events: VoiceLabellerRun.events(clip["events"]), config: config)
            XCTAssertEqual(result.h, try VoiceKat.bytes(clip["h_file"].string), "clip \(name) hysteresis")
            XCTAssertEqual(result.labels, try VoiceKat.bytes(clip["label_file"].string), "clip \(name) labels")
        }
    }
}
