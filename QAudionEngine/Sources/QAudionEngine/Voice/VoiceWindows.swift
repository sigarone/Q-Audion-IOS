import Foundation

/// A chunk whose label and stats flags are final, as the window assembler takes it.
struct VoiceChunkRecord {
    var index: Int
    var t0Ns: Int64
    var t1Ns: Int64
    var power: Double
    var clip: Int
    var nin: Int
    /// Accumulator epoch: every event of the call starts a new one.
    var epoch: Int
    var probability: Double
    var label: Int
    var excluded: Bool
    var txUnknown: Bool
    var concUnknown: Bool
    var touchConcealment: Bool
    var touchStretch: Bool
    var samples: [Float]
    /// Known intervals whose widened span overlaps the chunk (kept for chunks that can enter a window).
    var overlaps: [VoiceIntervalRef]
}

/// One 128-chunk window with its measurements and flags.
struct VoiceWindowResult {
    var n: Int
    var epoch: Int
    var w: Int
    var disjoint: Bool
    /// Half-open runs [first, end) of chunk indices.
    var ranges: [[Int]]
    var first: Int
    var last: Int
    var meanP: Double
    var noiseP: Double
    var speechP: Double
    var snrDb: Double
    var clipFrac: Double
    var plc: Double
    var plcEvents: Int
    var stretchEvents: Int
    var concUnknown: Bool
    var txUnknown: Bool
    var bw: Double
    var narrowband: Bool
    var enroll: Bool
    var score: Bool
    var certain: Bool
    /// The window's 65,536 samples.
    var samples: [Float]
}

/// Collects accepted chunks (final speech label, not excluded) and cuts a window every `hop` chunks once `chunks` are
/// available, with the measurements and quality flags of each window.
final class VoiceWindowAssembler {
    private struct Recent {
        var index: Int
        var power: Double
        var label: Int
        var probability: Double
    }

    private let constants: VoiceConstants
    private let fbank: VoiceFbank
    private let chunksPerWindow: Int
    private let hop: Int
    private let maxSpanNs: Int64

    private var accepted: [VoiceChunkRecord] = []
    private var acceptedBase = 0
    private var cut = 0
    private var currentEpoch: Int?
    private var resets = 0
    private var windowCount = 0
    private var noisePower = 1e-9
    private var recent: [Recent] = []

    init(constants: VoiceConstants, fbank: VoiceFbank) {
        self.constants = constants
        self.fbank = fbank
        self.chunksPerWindow = constants.window.chunks
        self.hop = constants.window.hopChunks
        self.maxSpanNs = Int64(constants.window.maxSpanMs) * 1_000_000
    }

    /// Feeds the next chunk record (all chunks, in index order). Returns the window it completes, if any.
    func push(_ record: VoiceChunkRecord) -> VoiceWindowResult? {
        if currentEpoch == nil {
            currentEpoch = record.epoch
        }
        if record.epoch != currentEpoch {
            clearAccumulator()
            currentEpoch = record.epoch
            resets += 1
        }
        remember(record)
        if record.label != 1 || record.excluded {
            return nil
        }
        let pending = hop * cut
        if accepted.count + acceptedBase > pending {
            let oldest = accepted[pending - acceptedBase]
            if record.t0Ns - oldest.t0Ns > maxSpanNs {
                clearAccumulator()
                resets += 1
            }
        }
        accepted.append(record)
        let count = accepted.count + acceptedBase
        guard count >= chunksPerWindow, (count - chunksPerWindow) % hop == 0 else { return nil }
        let w = (count - chunksPerWindow) / hop
        let first = hop * w - acceptedBase
        let members = Array(accepted[first..<(first + chunksPerWindow)])
        cut = w + 1
        let result = makeWindow(members: members, w: w)
        // Chunks before the start of the next window are not needed again.
        let release = hop * cut - acceptedBase
        if release > 0 && release <= accepted.count {
            accepted.removeFirst(release)
            acceptedBase += release
        }
        return result
    }

    private func clearAccumulator() {
        accepted.removeAll()
        acceptedBase = 0
        cut = 0
    }

    private func remember(_ record: VoiceChunkRecord) {
        recent.append(Recent(
            index: record.index, power: record.power, label: record.label, probability: record.probability))
        let keep = constants.gates.snr.poolChunks
        if recent.count > 2 * keep {
            recent.removeFirst(recent.count - keep)
        }
    }

    private func makeWindow(members: [VoiceChunkRecord], w: Int) -> VoiceWindowResult {
        let gates = constants.gates
        let snr = gates.snr
        let last = members[members.count - 1].index

        // Noise power: a low percentile of the non-speech chunks among the last `poolChunks` chunk indices.
        var pool: [Double] = []
        for r in recent where r.index > last - snr.poolChunks && r.index <= last {
            if r.label == 0 && r.probability < constants.vad.noiseP {
                pool.append(r.power)
            }
        }
        if pool.count >= snr.minPool {
            pool.sort()
            let at = Int((snr.percentile * Double(pool.count - 1)).rounded(.down))
            noisePower = pool[at]
        }
        var powerSum = 0.0
        for r in members {
            powerSum += r.power
        }
        let speechPower = powerSum / Double(members.count)
        var snrDb = 10.0 * log10(max(speechPower - noisePower, 1e-12) / max(noisePower, 1e-9))
        snrDb = min(max(snrDb, snr.clip[0]), snr.clip[1])

        var clipped = 0
        var inputs = 0
        var probabilitySum = 0.0
        var concUnknown = false
        var txUnknown = false
        var distinct: [Int64: VoiceIntervalRef] = [:]
        for r in members {
            clipped += r.clip
            inputs += r.nin
            probabilitySum += r.probability
            concUnknown = concUnknown || r.concUnknown
            txUnknown = txUnknown || r.txUnknown
            for ref in r.overlaps {
                distinct[ref.key] = ref
            }
        }
        let clipFrac = Double(clipped) / Double(inputs)
        let meanP = probabilitySum / Double(members.count)

        var audible: Int64 = 0
        var total: Int64 = 0
        var plcEvents = 0
        var stretchEvents = 0
        for ref in distinct.values {
            audible += ref.audible
            total += ref.total
            if ref.conc {
                plcEvents += 1
            }
            if ref.stretch > 0 {
                stretchEvents += 1
            }
        }
        let plc = total > 0 ? Double(audible) / Double(total) : 0.0

        var samples: [Float] = []
        samples.reserveCapacity(members.count * VoiceChunker.chunkLength)
        for r in members {
            samples.append(contentsOf: r.samples)
        }
        let bandwidth = VoiceFbank.bandwidth(
            fbank.logMel(samples), high: constants.fbank.nbHiBins, low: constants.fbank.nbLoBins)
        let narrowband = bandwidth < gates.betaNb

        let enrollGate = gates.enroll
        let scoreGate = gates.score
        let certainGate = gates.certain
        let score = meanP >= scoreGate.meanPMin
            && snrDb >= scoreGate.snrDbMin
            && clipFrac < scoreGate.clipFracMax
            && plc < scoreGate.plcFracMax
        let enroll = meanP >= enrollGate.meanPMin
            && snrDb >= enrollGate.snrDbMin
            && clipFrac < enrollGate.clipFracMax
            && plcEvents <= enrollGate.plcEventsMax
            && stretchEvents <= enrollGate.stretchEventsMax
            && !concUnknown
            && (enrollGate.wbOnly ? !narrowband : true)
            && !txUnknown
        let certain = score && plc < certainGate.plcFracMax && !concUnknown && !txUnknown

        let number = windowCount
        windowCount += 1
        return VoiceWindowResult(
            n: number,
            epoch: resets,
            w: w,
            disjoint: w % 2 == 0,
            ranges: Self.ranges(of: members.map { $0.index }),
            first: members[0].index,
            last: last,
            meanP: meanP,
            noiseP: noisePower,
            speechP: speechPower,
            snrDb: snrDb,
            clipFrac: clipFrac,
            plc: plc,
            plcEvents: plcEvents,
            stretchEvents: stretchEvents,
            concUnknown: concUnknown,
            txUnknown: txUnknown,
            bw: bandwidth,
            narrowband: narrowband,
            enroll: enroll,
            score: score,
            certain: certain,
            samples: samples
        )
    }

    private static func ranges(of indices: [Int]) -> [[Int]] {
        var out: [[Int]] = []
        var start = indices[0]
        var previous = indices[0]
        for i in indices.dropFirst() {
            if i == previous + 1 {
                previous = i
                continue
            }
            out.append([start, previous + 1])
            start = i
            previous = i
        }
        out.append([start, previous + 1])
        return out
    }
}
