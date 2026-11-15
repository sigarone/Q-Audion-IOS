import Foundation

/// A voice-activity model that scores one 512-sample chunk at a time.
protocol VoiceVadModel: AnyObject {
    /// Clears the model state and the context of the previous chunk.
    func reset()
    /// Speech probability of the next chunk (512 samples).
    func step(_ chunk: [Float]) throws -> Float
}

/// Turns chunk probabilities into speech labels: a hysteresis per chunk, then a short fixed lookahead that applies the
/// gap filling and the minimum run length of the offline rule at every position.
final class VoiceLabeller {
    private let on: Double
    private let off: Double
    private let fillGap: Int
    private let minRun: Int
    private let lookahead: Int
    private let skipStart: Int

    private var hysteresisValues: [UInt8] = []
    private var base = 0
    private var runStart = 0
    private var inSpeech = false
    private var nextFinal = 0
    private var lastPushed = -1

    init(config: VoiceConstants.Vad) {
        on = config.on
        off = config.off
        fillGap = config.fillGapChunks
        minRun = config.minSpeechChunks
        lookahead = config.lookaheadChunks
        skipStart = config.skipStartChunks
    }

    /// The offline rule on a finite 0/1 sequence: a run of zeros no longer than `fillGap` with ones on both sides
    /// becomes ones, then a run of ones shorter than `minRun` becomes zeros.
    static func offlineRule(_ values: [UInt8], fillGap: Int, minRun: Int) -> [UInt8] {
        var s = values
        let n = s.count
        var i = 0
        while i < n {
            if s[i] == 1 {
                i += 1
                continue
            }
            var j = i
            while j < n && s[j] == 0 {
                j += 1
            }
            if i > 0 && j < n && (j - i) <= fillGap {
                for t in i..<j {
                    s[t] = 1
                }
            }
            i = j
        }
        i = 0
        while i < n {
            if s[i] == 0 {
                i += 1
                continue
            }
            var j = i
            while j < n && s[j] == 1 {
                j += 1
            }
            if (j - i) < minRun {
                for t in i..<j {
                    s[t] = 0
                }
            }
            i = j
        }
        return s
    }

    /// Starts a new labelling run at chunk `nextIndex` (media start is chunk 0).
    func resetState(nextIndex: Int) {
        hysteresisValues.removeAll(keepingCapacity: true)
        base = nextIndex
        runStart = nextIndex
        inSpeech = false
        nextFinal = nextIndex
        lastPushed = nextIndex - 1
    }

    /// Feeds the probability of chunk `index` (consecutive from the start of the run). Returns the hysteresis value of
    /// the chunk and the labels that became final.
    func push(index: Int, probability: Double) -> (hysteresis: UInt8, finalized: [(index: Int, label: UInt8)]) {
        let value = hysteresis(index: index, probability: probability)
        hysteresisValues.append(value)
        lastPushed = index
        var done: [(index: Int, label: UInt8)] = []
        while nextFinal + lookahead <= lastPushed {
            done.append((index: nextFinal, label: label(at: nextFinal)))
            nextFinal += 1
        }
        trim()
        return (hysteresis: value, finalized: done)
    }

    /// Labels every chunk not yet final; positions after the last pushed chunk count as non-speech.
    func flush() -> [(index: Int, label: UInt8)] {
        var done: [(index: Int, label: UInt8)] = []
        while nextFinal <= lastPushed {
            done.append((index: nextFinal, label: label(at: nextFinal)))
            nextFinal += 1
        }
        trim()
        return done
    }

    private func hysteresis(index: Int, probability: Double) -> UInt8 {
        if index < skipStart {
            inSpeech = false
            return 0
        }
        if !inSpeech {
            if probability >= on {
                inSpeech = true
            }
        } else if probability < off {
            inSpeech = false
        }
        return inSpeech ? 1 : 0
    }

    private func value(at index: Int) -> UInt8 {
        let offset = index - base
        if offset < 0 || offset >= hysteresisValues.count {
            return 0
        }
        return hysteresisValues[offset]
    }

    private func label(at index: Int) -> UInt8 {
        let low = max(runStart, index - lookahead)
        let high = index + lookahead
        var sequence: [UInt8] = []
        sequence.reserveCapacity(high - low + 1)
        for j in low...high {
            sequence.append(j <= lastPushed ? value(at: j) : 0)
        }
        return Self.offlineRule(sequence, fillGap: fillGap, minRun: minRun)[index - low]
    }

    private func trim() {
        let keepFrom = max(runStart, nextFinal - lookahead)
        let drop = keepFrom - base
        if drop >= 64 {
            hysteresisValues.removeFirst(drop)
            base += drop
        }
    }
}
