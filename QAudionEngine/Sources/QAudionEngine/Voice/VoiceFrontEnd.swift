import Foundation

/// An event of the call that restarts parts of the front-end. `reset` is a discontinuity of the sample stream (a
/// dropped block); a change of the tap rate resets the same way on its own.
enum VoiceFrontEndEvent {
    case hold
    case resume
    case route
    case reset
}

/// The streaming front-end: tap blocks become 512-sample chunks at 16 kHz, each chunk is scored and labelled, its
/// stats flags are read once final, and accepted chunks are cut into windows.
///
/// RX blocks, stats snapshots, mute changes and events arrive in any interleaving. A chunk waits until both its label
/// and its stats flags are final; at `finish()` everything that is left becomes final. Single threaded: the caller
/// serialises all calls.
final class VoiceFrontEnd {
    private struct Pending {
        var chunk: VoiceChunk
        var epoch: Int
        var probability: Float
        var label: Int
    }

    /// Called for every chunk once its label and flags are final, in index order.
    var onChunk: ((VoiceChunkRecord) -> Void)?
    /// Called for every window, right after the chunk that completes it.
    var onWindow: ((VoiceWindowResult) -> Void)?

    private let chunker: VoiceChunker
    private let vad: VoiceVadModel
    private let labeller: VoiceLabeller
    private let stats: VoiceStatsStream
    private let assembler: VoiceWindowAssembler

    private var epoch = 0
    private var currentRate: Int?
    private var inactive = false
    private var unlabelled: [Pending] = []
    private var awaiting: [Pending] = []

    init(bundle: VoiceBundle, vad: VoiceVadModel) {
        let constants = bundle.constants
        self.chunker = VoiceChunker(constants: constants)
        self.vad = vad
        self.labeller = VoiceLabeller(config: constants.vad)
        self.stats = VoiceStatsStream(gates: constants.gates)
        self.assembler = VoiceWindowAssembler(
            constants: constants,
            fbank: VoiceFbank(tables: bundle.tables, constants: constants.fbank)
        )
    }

    /// True once a tap rate the resampler does not support was seen: nothing is learned for the rest of the call.
    var isInactive: Bool { inactive }

    /// Tap-clock time of the first sample of the call (known after the first block).
    var mediaStartNs: Int64? { chunker.mediaStartNs }

    /// Input samples consumed in the current tap segment (the position of a discontinuity).
    var inputPosition: Int { chunker.inputPosition }

    /// The stats track as of the inputs seen so far.
    var statsTrack: VoiceStatsTrack { stats.track }

    // MARK: inputs

    /// One RX block: registers it, then consumes its samples.
    func onRx(_ pcm: [Int16], rateHz: Int, tNs: Int64, tapTicks: Int64) throws {
        registerTapBlock(count: pcm.count, rateHz: rateHz, tNs: tNs, tapTicks: tapTicks)
        try push(pcm[...])
    }

    /// Registers a tap block (length, rate, clock reading of the callback, cumulative tap position after it) before
    /// its samples are pushed. A change of rate starts a new tap segment and resets the front-end.
    func registerTapBlock(count: Int, rateHz: Int, tNs: Int64, tapTicks: Int64) {
        if inactive {
            return
        }
        if currentRate != rateHz {
            if !VoiceResampler.supportedRates.contains(rateHz) {
                inactive = true
                return
            }
            if currentRate != nil {
                restartForRateChange()
            }
            if !chunker.startTapSegment(rateHz: rateHz) {
                inactive = true
                return
            }
            currentRate = rateHz
        }
        chunker.registerBlock(count: count, tNs: tNs)
        stats.addTapBlock(tNs: tNs, ticks: tapTicks)
        releaseFinalChunks()
    }

    /// Consumes samples of the block that was registered last (they may be pushed in pieces, with events in between).
    func push(_ samples: ArraySlice<Int16>) throws {
        if inactive {
            return
        }
        for sample in samples {
            if let chunk = chunker.push(sample) {
                try handle(chunk)
            }
        }
    }

    func onStats(_ snapshot: VoiceStatsSnapshot) {
        stats.addSnapshot(snapshot)
        releaseFinalChunks()
    }

    func onMute(tNs: Int64, muted: Bool) {
        stats.addMute(tNs: tNs, muted: muted)
        releaseFinalChunks()
    }

    /// A hold, resume, route change or discontinuity at the current position of the stream.
    func onEvent(_ event: VoiceFrontEndEvent) {
        let next = chunker.nextIndex
        if event == .hold || event == .reset {
            finalizeLabels(labeller.flush())
            labeller.resetState(nextIndex: next)
        }
        epoch += 1
        if event == .reset {
            chunker.reset()
            vad.reset()
        }
        releaseFinalChunks()
    }

    /// End of the call: remaining labels are decided, the tap and the stats track are closed, and every chunk that is
    /// left is released.
    func finish() {
        finalizeLabels(labeller.flush())
        stats.finish()
        releaseFinalChunks()
    }

    // MARK: pipeline

    private func restartForRateChange() {
        finalizeLabels(labeller.flush())
        labeller.resetState(nextIndex: chunker.nextIndex)
        epoch += 1
        vad.reset()
    }

    private func handle(_ chunk: VoiceChunk) throws {
        let p = try vad.step(chunk.samples)
        let outcome = labeller.push(index: chunk.index, probability: Double(p))
        unlabelled.append(Pending(chunk: chunk, epoch: epoch, probability: p, label: 0))
        finalizeLabels(outcome.finalized)
        releaseFinalChunks()
    }

    private func finalizeLabels(_ labels: [(index: Int, label: UInt8)]) {
        for entry in labels {
            if unlabelled.isEmpty {
                break
            }
            var pending = unlabelled.removeFirst()
            pending.label = Int(entry.label)
            awaiting.append(pending)
        }
    }

    private func releaseFinalChunks() {
        guard let mediaStart = chunker.mediaStartNs else { return }
        while let head = awaiting.first {
            if !stats.isConcealmentFinal(t1: head.chunk.t1Ns) || !stats.isTxFinal(t1: head.chunk.t1Ns) {
                break
            }
            awaiting.removeFirst()
            let record = makeRecord(head, mediaStart: mediaStart)
            onChunk?(record)
            if let window = assembler.push(record) {
                onWindow?(window)
            }
        }
    }

    private func makeRecord(_ pending: Pending, mediaStart: Int64) -> VoiceChunkRecord {
        let chunk = pending.chunk
        let track = stats.track
        let tx = track.txFlags(t0: chunk.t0Ns, t1: chunk.t1Ns, mediaStart: mediaStart)
        let conc = track.concFlags(t0: chunk.t0Ns, t1: chunk.t1Ns, mediaStart: mediaStart)
        let accepted = pending.label == 1 && !tx.excluded
        return VoiceChunkRecord(
            index: chunk.index,
            t0Ns: chunk.t0Ns,
            t1Ns: chunk.t1Ns,
            power: chunk.power,
            clip: chunk.clip,
            nin: chunk.nin,
            epoch: pending.epoch,
            probability: Double(pending.probability),
            label: pending.label,
            excluded: tx.excluded,
            txUnknown: tx.unknown,
            concUnknown: conc.unknown,
            touchConcealment: conc.concealment,
            touchStretch: conc.stretch,
            samples: chunk.samples,
            overlaps: accepted ? track.overlappingKnown(t0: chunk.t0Ns, t1: chunk.t1Ns) : []
        )
    }
}
