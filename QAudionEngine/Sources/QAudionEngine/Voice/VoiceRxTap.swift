import Foundation
import AVFoundation

/// One RX block as the tap saw it, before any conversion.
struct VoiceRxBlock {
    /// The clock at the callback (`VoiceClock`).
    var tNs: Int64
    var rateHz: Int
    /// The cumulative tap position after this block, in ticks of 1/96,000 s. Counted in the callback before the block is queued,
    /// so a block that the queue drops still advances the position of the next one.
    var ticks: Int64
    var pcm: [Int16]
    /// The blocks that the queue refused just before this one.
    var dropped: Int
}

/// A bounded queue between the render thread and the voice worker. The producer never waits: when the queue is full, or when the
/// consumer holds the lock at that moment, the block is refused and the caller counts it.
final class VoiceRxQueue: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var blocks: [VoiceRxBlock] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        blocks.reserveCapacity(self.capacity)
    }

    /// `queued`: the block is in the queue; `wasEmpty`: the queue was empty before it, so the worker has to be told that there is
    /// something to drain.
    struct Offer {
        var queued: Bool
        var wasEmpty: Bool
    }

    /// Never blocks: a lock that is busy is a refusal.
    func offer(_ block: VoiceRxBlock) -> Offer {
        guard lock.try() else { return Offer(queued: false, wasEmpty: false) }
        defer { lock.unlock() }
        guard blocks.count < capacity else { return Offer(queued: false, wasEmpty: false) }
        let empty = blocks.isEmpty
        blocks.append(block)
        return Offer(queued: true, wasEmpty: empty)
    }

    /// Everything that is queued, in order. Called on the worker.
    func drain() -> [VoiceRxBlock] {
        lock.lock()
        let out = blocks
        blocks.removeAll(keepingCapacity: true)
        lock.unlock()
        return out
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return blocks.count
    }
}

/// The producer side of the RX tap: it sits in `NativeAudioPcmTap.render`, before the conversion that the other consumers use,
/// takes the clock, counts the tap position and queues a copy of the samples. It does no work that can wait: no lock that
/// another thread holds for long, no I/O, no model.
///
/// Its own state (`ticks`, `pendingDrops`) is touched only from the render callback, which the tap calls one buffer at a time.
final class VoiceRxTap: @unchecked Sendable {
    private let queue: VoiceRxQueue
    private let clock: () -> Int64
    private let wake: () -> Void
    private var ticks: Int64 = 0
    private var pendingDrops = 0
    private var stopped = false
    private let stopLock = NSLock()

    /// Buffers that were refused by the queue since the start (read from any thread).
    private(set) var droppedBlocks = 0

    /// `wake` is called when a block went into an empty queue: it only schedules the drain (a non-blocking `async`).
    init(queue: VoiceRxQueue, clock: @escaping () -> Int64 = VoiceClock.nowNs, wake: @escaping () -> Void) {
        self.queue = queue
        self.clock = clock
        self.wake = wake
    }

    /// After this the tap ignores every buffer (the call ended).
    func stop() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
    }

    private var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    /// One buffer of the tap, as the renderer hands it over: any layout. Samples that are not 16-bit integers advance the
    /// position and queue nothing (the engine sees the gap as a dropped block).
    func render(buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let rate = Int(buffer.format.sampleRate)
        guard frames > 0, rate > 0 else { return }
        guard buffer.format.commonFormat == .pcmFormatInt16, let channels = buffer.int16ChannelData else {
            ingest(samples: nil, frames: frames, rateHz: rate)
            return
        }
        let stride = buffer.format.isInterleaved ? max(1, Int(buffer.format.channelCount)) : 1
        let first = channels[0]
        var pcm = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            pcm[i] = first[i * stride]
        }
        ingest(samples: pcm, frames: frames, rateHz: rate)
    }

    /// The same for samples that are already mono 16-bit (and for the tests).
    func ingest(samples: [Int16]?, frames: Int, rateHz: Int) {
        if isStopped { return }
        let now = clock()
        ticks += Int64(frames) * 96_000 / Int64(rateHz)
        guard let pcm = samples else { return }
        let block = VoiceRxBlock(tNs: now, rateHz: rateHz, ticks: ticks, pcm: pcm, dropped: pendingDrops)
        let offer = queue.offer(block)
        if offer.queued {
            pendingDrops = 0
            if offer.wasEmpty { wake() }
        } else {
            pendingDrops += 1
            droppedBlocks += 1
        }
    }
}
