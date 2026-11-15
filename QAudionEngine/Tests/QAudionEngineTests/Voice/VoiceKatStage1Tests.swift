import XCTest
import Foundation
@testable import QAudionEngine

/// Resampler against the reference outputs: every clip, every tap schedule, resets at their positions.
final class VoiceKatStage1Tests: XCTestCase {

    private func blocks(_ schedule: KatJSON, rate: Int, total: Int) -> [Int] {
        var lengths: [Int]
        if !schedule["block_ms"].isNull {
            let step = schedule["block_ms"].int * rate / 1000
            lengths = [Int](repeating: step, count: total / step)
        } else if !schedule["block_samples"].isNull {
            let step = schedule["block_samples"].int
            lengths = [Int](repeating: step, count: total / step)
        } else {
            lengths = schedule["block_samples_list"].ints
        }
        let used = lengths.reduce(0, +)
        XCTAssertLessThanOrEqual(used, total)
        if used < total {
            lengths.append(total - used)
        }
        return lengths
    }

    /// Pushes `samples` through a resampler in blocks, splitting a block at every reset position; returns all outputs of
    /// all segments, one after the other.
    private func run(
        samples: [Int16],
        rate: Int,
        constants: VoiceConstants,
        blockLengths: [Int],
        resets: [Int]
    ) throws -> [Float] {
        let resampler = try XCTUnwrap(VoiceResampler(rate: rate, constants: constants))
        var cuts = Set<Int>(resets)
        var end = 0
        for length in blockLengths {
            end += length
            cuts.insert(end)
        }
        XCTAssertEqual(end, samples.count)
        var out: [Float] = []
        out.reserveCapacity(samples.count)
        var previous = 0
        for position in cuts.sorted() {
            for index in previous..<position {
                if let value = resampler.push(samples[index]) {
                    out.append(value)
                }
            }
            if resets.contains(position) {
                resampler.reset()
            }
            previous = position
        }
        return out
    }

    func testEveryClipAndScheduleMatchesTheReference() throws {
        let bundle = try VoiceKat.bundle()
        let constants = bundle.constants
        let stage1 = try VoiceKat.json("stage1_resampler/stage1.json")
        let schedules = try VoiceKat.json("stage1_resampler/schedules.json")
        let names = ["10ms", "20ms", "60ms", "512smp", "rand"]
        XCTAssertEqual(stage1["clips"].count, 6)

        for clip in stage1["clips"].array {
            let name = clip["name"].string
            let rate = clip["rate"].int
            let audio = try VoiceKat.wav(clip["audio_file"].string)
            XCTAssertEqual(audio.rate, rate, "clip \(name)")
            XCTAssertEqual(audio.samples.count, clip["n_in"].int, "clip \(name)")
            let resets = clip["resets_at_input"].ints
            let total = audio.samples.count
            let expectedCount = clip["n_out"].int

            let reference: [Float]
            if clip["expected_file"].isNull {
                reference = VoiceKat.scaled(audio.samples)
            } else {
                reference = try VoiceKat.floats(clip["expected_file"].string)
            }
            XCTAssertEqual(reference.count, expectedCount, "clip \(name) expected length")

            var first: [Float] = []
            for scheduleName in names {
                let spec = schedules["clips"][name]["schedules"][scheduleName]
                let lengths = blocks(spec, rate: rate, total: total)
                let got = try run(
                    samples: audio.samples, rate: rate, constants: constants, blockLengths: lengths, resets: resets)
                XCTAssertEqual(got.count, expectedCount, "clip \(name) \(scheduleName) output count")
                guard got.count == reference.count else { continue }
                var worst: Float = 0
                for i in 0..<got.count {
                    worst = max(worst, abs(got[i] - reference[i]))
                }
                XCTAssertLessThanOrEqual(worst, 1e-5, "clip \(name) \(scheduleName) largest difference")
                if first.isEmpty {
                    first = got
                } else {
                    XCTAssertTrue(
                        first.elementsEqual(got) { $0.bitPattern == $1.bitPattern },
                        "clip \(name) \(scheduleName) differs from the first schedule")
                }
            }

            // Output count of every segment.
            var produced = 0
            for segment in clip["segments"].array {
                produced += segment["n_out"].int
            }
            XCTAssertEqual(produced, expectedCount, "clip \(name) segment output counts")
        }
    }

    func testRatesOtherThanTheSupportedOnesGetNoResampler() throws {
        let constants = try VoiceKat.bundle().constants
        XCTAssertNil(VoiceResampler(rate: 44_100, constants: constants))
        XCTAssertNil(VoiceResampler(rate: 8_000, constants: constants))
        for rate in VoiceResampler.supportedRates {
            XCTAssertNotNil(VoiceResampler(rate: rate, constants: constants), "\(rate)")
        }
    }
}
