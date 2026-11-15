import Foundation

/// One 512-sample chunk of the 16 kHz stream with its time span and the counts attributed to it.
struct VoiceChunk {
    var index: Int
    /// Tap-clock span [t0, t1) in nanoseconds.
    var t0Ns: Int64
    var t1Ns: Int64
    /// Mean square of the 512 samples.
    var power: Double
    /// Input samples with a magnitude at or above the clip level, and all input samples, attributed to the chunk.
    var clip: Int
    var nin: Int
    var samples: [Float]
}

/// Maps input positions of one tap segment to the tap clock. Each registered block carries the clock reading of its
/// callback, which is the time of the position just after its last sample.
final class VoiceTimeMap {
    let rate: Int
    private var ends: [Int] = []
    private var clock: [Int64] = []
    private var head = 0

    init(rate: Int) {
        self.rate = rate
    }

    var isEmpty: Bool { head >= ends.count }

    func append(count: Int, tNs: Int64) {
        ends.append((ends.last ?? 0) + count)
        clock.append(tNs)
    }

    /// Time of the input position num/den (a position before the first block uses the first block, one after the last
    /// uses the last).
    func tNs(num: Int, den: Int) -> Int64 {
        let block = blockIndex(num: num, den: den)
        let ahead = Int64(ends[block] * den - num) * 1_000_000_000
        let delta = Self.roundedQuotient(ahead, Int64(den) * Int64(rate))
        return clock[block] - delta
    }

    /// Drops the blocks that no position at or after num/den can refer to.
    func trim(before num: Int, den: Int) {
        let keep = blockIndex(num: num, den: den)
        if keep > head {
            head = keep
        }
        if head >= 4_096 {
            ends.removeFirst(head)
            clock.removeFirst(head)
            head = 0
        }
    }

    private func blockIndex(num: Int, den: Int) -> Int {
        let need = num > 0 ? (num + den - 1) / den : 0
        var low = head
        var high = ends.count
        while low < high {
            let mid = (low + high) / 2
            if ends[mid] < need {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return min(low, ends.count - 1)
    }

    private static func roundedQuotient(_ a: Int64, _ b: Int64) -> Int64 {
        floorQuotient(2 * a + b, 2 * b)
    }

    private static func floorQuotient(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}

/// Turns the sample stream of the calls's tap into chunks: runs the resampler, cuts 512 outputs, times the chunk from
/// the tap blocks and counts clipped and input samples per chunk.
final class VoiceChunker {
    static let chunkLength = 512

    private let constants: VoiceConstants
    private let clipLevel: Int
    private var resampler: VoiceResampler?
    private var timeMap: VoiceTimeMap?
    /// Input position (in the current tap segment) at which the current resampler run began, and the index of its first chunk.
    private var runStart = 0
    private var runFirstChunk = 0
    private var position = 0
    private var buffer: [Float] = []
    private var clipRun = 0
    private var inputRun = 0

    /// Index of the next chunk to be produced; it keeps counting across resets and rate changes.
    private(set) var nextIndex = 0
    /// Tap-clock time of input position 0 of the first tap segment, known once its first block is registered.
    private(set) var mediaStartNs: Int64?

    init(constants: VoiceConstants) {
        self.constants = constants
        self.clipLevel = constants.gates.clipLevel
        buffer.reserveCapacity(Self.chunkLength)
    }

    /// Input samples consumed in the current tap segment.
    var inputPosition: Int { position }

    /// Starts a new tap segment at `rateHz` (input positions count from 0 again). Returns false for a rate the
    /// resampler does not support.
    func startTapSegment(rateHz: Int) -> Bool {
        guard let next = VoiceResampler(rate: rateHz, constants: constants) else { return false }
        resampler = next
        timeMap = VoiceTimeMap(rate: rateHz)
        runStart = 0
        runFirstChunk = nextIndex
        position = 0
        clearRun()
        return true
    }

    /// Registers one tap block of the current segment (its length in samples and the clock reading of its callback).
    func registerBlock(count: Int, tNs: Int64) {
        guard let map = timeMap else { return }
        map.append(count: count, tNs: tNs)
        if mediaStartNs == nil {
            mediaStartNs = map.tNs(num: 0, den: 1)
        }
    }

    /// A discontinuity: the history is zeroed, the phase restarts and the partial chunk is discarded.
    func reset() {
        guard let current = resampler else { return }
        current.reset()
        runStart = position
        runFirstChunk = nextIndex
        clearRun()
    }

    /// Consumes one input sample; returns the chunk it completes, if any.
    func push(_ sample: Int16) -> VoiceChunk? {
        guard let current = resampler, let map = timeMap, !map.isEmpty else { return nil }
        position += 1
        inputRun += 1
        if abs(Int(sample)) >= clipLevel {
            clipRun += 1
        }
        guard let output = current.push(sample) else { return nil }
        buffer.append(output)
        if buffer.count < Self.chunkLength {
            return nil
        }

        let k = nextIndex - runFirstChunk
        let up = current.upFactor
        let down = current.downFactor
        let length = current.prototypeLength
        let den = 2 * up
        let base = 2 * up * runStart - (length - 1)
        let first = base + 2 * (Self.chunkLength * k) * down
        let following = base + 2 * (Self.chunkLength * (k + 1)) * down
        let t0 = map.tNs(num: first, den: den)
        let t1 = map.tNs(num: following, den: den)
        var energy = 0.0
        for value in buffer {
            let v = Double(value)
            energy += v * v
        }
        let chunk = VoiceChunk(
            index: nextIndex,
            t0Ns: t0,
            t1Ns: t1,
            power: energy / Double(Self.chunkLength),
            clip: clipRun,
            nin: inputRun,
            samples: buffer
        )
        nextIndex += 1
        clearRun()
        // The first chunk after a reset reaches back by the filter delay, so keep the blocks that far behind.
        map.trim(before: following - 2 * den * length, den: den)
        return chunk
    }

    private func clearRun() {
        buffer.removeAll(keepingCapacity: true)
        clipRun = 0
        inputRun = 0
    }
}
