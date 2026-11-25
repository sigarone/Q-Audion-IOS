import XCTest
import AVFoundation
@testable import QAudionEngine

/// The producer in the render callback: the tap position is counted before the queue, a full queue drops and counts, and
/// nothing in it waits.
final class VoiceRxTapTests: XCTestCase {
    private final class Counter {
        var wakes = 0
    }

    private func makeTap(capacity: Int, counter: Counter, now: @escaping () -> Int64 = { 1 }) -> (VoiceRxTap, VoiceRxQueue) {
        let queue = VoiceRxQueue(capacity: capacity)
        let tap = VoiceRxTap(queue: queue, clock: now, wake: { counter.wakes += 1 })
        return (tap, queue)
    }

    func testTheTapPositionIsFramesTimes96000OverTheRateOfTheBuffer() {
        let counter = Counter()
        let (tap, queue) = makeTap(capacity: 16, counter: counter)
        tap.ingest(samples: [Int16](repeating: 1, count: 480), frames: 480, rateHz: 48_000)
        tap.ingest(samples: [Int16](repeating: 1, count: 240), frames: 240, rateHz: 24_000)
        tap.ingest(samples: [Int16](repeating: 1, count: 160), frames: 160, rateHz: 16_000)
        tap.ingest(samples: [Int16](repeating: 1, count: 320), frames: 320, rateHz: 32_000)
        let blocks = queue.drain()
        XCTAssertEqual(blocks.map { $0.ticks }, [960, 960 + 960, 960 + 960 + 960, 960 + 960 + 960 + 960])
        XCTAssertEqual(blocks.map { $0.rateHz }, [48_000, 24_000, 16_000, 32_000])
    }

    func testABlockThatTheQueueRefusesStillAdvancesThePositionAndIsCounted() {
        let counter = Counter()
        let (tap, queue) = makeTap(capacity: 2, counter: counter)
        for _ in 0..<5 {
            tap.ingest(samples: [Int16](repeating: 0, count: 480), frames: 480, rateHz: 48_000)
        }
        XCTAssertEqual(tap.droppedBlocks, 3)
        XCTAssertEqual(queue.count, 2)
        let first = queue.drain()
        XCTAssertEqual(first.map { $0.ticks }, [960, 1920])
        XCTAssertEqual(first.map { $0.dropped }, [0, 0])
        // After the consumer has made room, the next block carries what was refused and its position includes it.
        tap.ingest(samples: [Int16](repeating: 0, count: 480), frames: 480, rateHz: 48_000)
        let next = queue.drain()
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].dropped, 3)
        XCTAssertEqual(next[0].ticks, 6 * 960)
    }

    func testTheWorkerIsWokenOnlyWhenABlockEntersAnEmptyQueue() {
        let counter = Counter()
        let (tap, queue) = makeTap(capacity: 8, counter: counter)
        for _ in 0..<4 { tap.ingest(samples: [0, 0], frames: 2, rateHz: 48_000) }
        XCTAssertEqual(counter.wakes, 1)
        _ = queue.drain()
        tap.ingest(samples: [0, 0], frames: 2, rateHz: 48_000)
        XCTAssertEqual(counter.wakes, 2)
    }

    func testAStoppedTapQueuesNothing() {
        let counter = Counter()
        let (tap, queue) = makeTap(capacity: 8, counter: counter)
        tap.stop()
        tap.ingest(samples: [0, 0], frames: 2, rateHz: 48_000)
        XCTAssertEqual(queue.count, 0)
        XCTAssertEqual(counter.wakes, 0)
    }

    func testSamplesThatAreNotSixteenBitIntegersAdvanceThePositionAndQueueNothing() {
        let counter = Counter()
        let (tap, queue) = makeTap(capacity: 8, counter: counter)
        tap.ingest(samples: nil, frames: 480, rateHz: 48_000)
        tap.ingest(samples: [Int16](repeating: 0, count: 480), frames: 480, rateHz: 48_000)
        let blocks = queue.drain()
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].ticks, 1920)
    }

    func testTheBlockCarriesTheClockOfTheCallback() {
        let counter = Counter()
        var t: Int64 = 1_000
        let (tap, queue) = makeTap(capacity: 8, counter: counter, now: {
            t += 10
            return t
        })
        tap.ingest(samples: [1], frames: 1, rateHz: 48_000)
        tap.ingest(samples: [1], frames: 1, rateHz: 48_000)
        XCTAssertEqual(queue.drain().map { $0.tNs }, [1_010, 1_020])
    }

    /// The real buffer: the first channel of an interleaved stereo buffer, at the rate of the buffer, before any conversion.
    func testABufferIsTakenAsItIsAtItsOwnRate() throws {
        let counter = Counter()
        let (tap, queue) = makeTap(capacity: 8, counter: counter)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let channels = try XCTUnwrap(buffer.int16ChannelData)
        let interleaved: [Int16] = [10, -1, 20, -2, 30, -3, 40, -4]
        for (i, v) in interleaved.enumerated() { channels[0][i] = v }
        tap.render(buffer: buffer)
        let blocks = queue.drain()
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].pcm, [10, 20, 30, 40])
        XCTAssertEqual(blocks[0].rateHz, 24_000)
        XCTAssertEqual(blocks[0].ticks, 4 * 4)
    }

    func testAFullQueueRefusesWithoutWaiting() {
        let queue = VoiceRxQueue(capacity: 1)
        let block = VoiceRxBlock(tNs: 1, rateHz: 48_000, ticks: 1, pcm: [0], dropped: 0)
        XCTAssertTrue(queue.offer(block).queued)
        let refused = queue.offer(block)
        XCTAssertFalse(refused.queued)
        XCTAssertFalse(refused.wasEmpty)
        XCTAssertEqual(queue.count, 1)
    }
}
