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
/// stats flags are released by the stats stream, and accepted chunks are cut into windows.
///
/// RX blocks, stats snapshots and mute changes are fed in the order of the stats stream (by tap-clock time, and at the same
/// time RX blocks, mute changes, deliveries; an input that arrives below the clock is late and the stream handles it), and
/// `finish` gives the tap-clock time of the end of the call. A chunk waits until its label is final (a look-ahead of 17
/// chunks) and its stats flags are released (final, or overdue); `finish` makes everything final. Single threaded: the
/// caller serialises all calls.
///
/// INACTIVE: a tap rate that is none of 16, 24, 32 and 48 kHz, a failed VAD call, or a VAD output that is not a finite
/// number makes the front-end inactive for the rest of the call. `isInactive` reads true, what it holds (the waiting chunks,
/// the accumulator, the labeller) is discarded, no further chunk or window is emitted and every later input is ignored.
/// Nothing is thrown at the caller; the engine reports that the voice cannot be verified.
final class VoiceFrontEnd {
    private struct Pending {
        var chunk: VoiceChunk
        var epoch: Int
        var probability: Float
        /// Nil until the label is final.
        var label: Int?
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
    private var ended = false
    private var pending: [Pending] = []

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

    /// True from the first unsupported tap rate, failed VAD call or non-finite VAD output to the end of the call: nothing
    /// is learned for the rest of it.
    var isInactive: Bool { inactive }

    /// Tap-clock time of the first sample of the call (known after the first block).
    var mediaStartNs: Int64? { chunker.mediaStartNs }

    /// Input samples consumed in the current tap segment (the position of a discontinuity).
    var inputPosition: Int { chunker.inputPosition }

    /// Index the next chunk will get; also the `at_chunk` of an event that happens now.
    var nextChunkIndex: Int { chunker.nextIndex }

    /// The stats stream, exposed to the tests of this module.
    var statsStream: VoiceStatsStream { stats }

    // MARK: inputs

    /// One RX block: registers it, then consumes its samples.
    func onRx(_ pcm: [Int16], rateHz: Int, tNs: Int64, tapTicks: Int64) {
        registerTapBlock(count: pcm.count, rateHz: rateHz, tNs: tNs, tapTicks: tapTicks)
        push(pcm[...])
    }

    /// Registers a tap block (length, rate, clock reading of the callback, cumulative tap position after it) before
    /// its samples are pushed. A change of rate starts a new tap segment and resets the front-end.
    func registerTapBlock(count: Int, rateHz: Int, tNs: Int64, tapTicks: Int64) {
        if ended || inactive {
            return
        }
        if currentRate != rateHz {
            if !VoiceResampler.supportedRates.contains(rateHz) {
                goInactive()
                return
            }
            if currentRate != nil {
                restartForRateChange()
            }
            if !chunker.startTapSegment(rateHz: rateHz) {
                goInactive()
                return
            }
            currentRate = rateHz
        }
        chunker.registerBlock(count: count, tNs: tNs)
        if let mediaStart = chunker.mediaStartNs {
            stats.setMediaStart(mediaStart)
        }
        stats.addTapBlock(tNs: tNs, ticks: tapTicks)
        releaseFinalChunks()
    }

    /// Consumes samples of the block that was registered last (they may be pushed in pieces, with events in between).
    func push(_ samples: ArraySlice<Int16>) {
        for sample in samples {
            if ended || inactive {
                return
            }
            if let chunk = chunker.push(sample) {
                handle(chunk)
            }
        }
    }

    /// One delivered stats report (at its arrival; one that comes below the clock is late and dropped by the stream).
    func onStats(_ snapshot: VoiceStatsSnapshot) {
        if ended || inactive {
            return
        }
        stats.addSnapshot(snapshot)
        releaseFinalChunks()
    }

    /// A change of the mute state at tap-clock time `tNs`. It moves the clock (the chunks that wait are released at it) and
    /// is kept at its own time when it is late. The changes must reach the front-end losslessly, never through a bounded
    /// queue that drops its oldest element; a caller that cannot guarantee that calls `onMuteLost` for an overflow.
    func onMute(tNs: Int64, muted: Bool) {
        if ended || inactive {
            return
        }
        stats.addMute(tNs: tNs, muted: muted)
        releaseFinalChunks()
    }

    /// A mute change was lost: `tNs` is the time of the change that was ahead of it in the queue (the media start when
    /// there is none).
    func onMuteLost(tNs: Int64) {
        if ended || inactive {
            return
        }
        stats.addLostMute(tNs: tNs)
    }

    /// A hold, resume, route change or discontinuity at the current position of the stream. Every event starts a new
    /// accumulator epoch for the chunks from its position on. Media start is the first RX block: an event before it is not
    /// an event of the call and does nothing, for every kind; one after it starts an epoch also when no chunk has completed yet.
    func onEvent(_ event: VoiceFrontEndEvent) {
        if ended || inactive || chunker.mediaStartNs == nil {
            return
        }
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

    /// End of the call at tap-clock time `endNs` (the time of the latest input when not given): remaining labels are
    /// decided, the stats stream is closed, and every chunk that is left is released.
    func finish(endNs: Int64? = nil) {
        if ended {
            return
        }
        if !inactive {
            finalizeLabels(labeller.flush())
            stats.finish(endNs: endNs)
            releaseFinalChunks()
        }
        ended = true
    }

    // MARK: pipeline

    /// The front-end stops for the rest of the call and discards what it holds.
    private func goInactive() {
        inactive = true
        pending.removeAll()
        assembler.discard()
        labeller.resetState(nextIndex: chunker.nextIndex)
    }

    private func restartForRateChange() {
        finalizeLabels(labeller.flush())
        labeller.resetState(nextIndex: chunker.nextIndex)
        epoch += 1
        vad.reset()
    }

    private func handle(_ chunk: VoiceChunk) {
        // A failed model call, or an output that is not a finite number, makes the front-end inactive: a chunk never gets
        // the label of its predecessor.
        let p: Float
        do {
            p = try vad.step(chunk.samples)
        } catch {
            goInactive()
            return
        }
        if !p.isFinite {
            goInactive()
            return
        }
        let outcome = labeller.push(index: chunk.index, probability: Double(p))
        pending.append(Pending(chunk: chunk, epoch: epoch, probability: p, label: nil))
        stats.addChunk(index: chunk.index, t0Ns: chunk.t0Ns, t1Ns: chunk.t1Ns)
        finalizeLabels(outcome.finalized)
        releaseFinalChunks()
    }

    /// Stores each final label on the chunk with that index; a label whose chunk is not waiting is dropped, never given to
    /// another chunk.
    private func finalizeLabels(_ labels: [(index: Int, label: UInt8)]) {
        for entry in labels {
            guard let base = pending.first?.chunk.index else { break }
            let offset = entry.index - base
            if offset >= 0, offset < pending.count, pending[offset].chunk.index == entry.index {
                pending[offset].label = Int(entry.label)
            } else if let at = pending.firstIndex(where: { $0.chunk.index == entry.index }) {
                pending[at].label = Int(entry.label)
            }
        }
    }

    private func releaseFinalChunks() {
        guard !inactive, chunker.mediaStartNs != nil else { return }
        while let head = pending.first, let label = head.label {
            guard let flags = stats.pollFinal() else { break }
            if flags.index != head.chunk.index {
                // The stats stream and the chunk queue are out of step: stop rather than pair a chunk with another's flags.
                goInactive()
                return
            }
            pending.removeFirst()
            let record = makeRecord(head, label: label, flags: flags)
            onChunk?(record)
            if let window = assembler.push(record) {
                onWindow?(window)
            }
        }
    }

    private func makeRecord(_ pending: Pending, label: Int, flags: VoiceChunkFlags) -> VoiceChunkRecord {
        let chunk = pending.chunk
        let accepted = label == 1 && !flags.excluded
        return VoiceChunkRecord(
            index: chunk.index,
            t0Ns: chunk.t0Ns,
            t1Ns: chunk.t1Ns,
            power: chunk.power,
            clip: chunk.clip,
            nin: chunk.nin,
            epoch: pending.epoch,
            probability: Double(pending.probability),
            label: label,
            excluded: flags.excluded,
            txUnknown: flags.txUnknown,
            concUnknown: flags.concUnknown,
            touchConcealment: flags.touchConcealment,
            touchStretch: flags.touchStretch,
            samples: chunk.samples,
            // A chunk released as overdue has no intervals; the others keep them only when they can enter a window.
            overlaps: accepted ? flags.overlaps : [],
            releaseNs: flags.releaseNs,
            overdue: flags.overdue
        )
    }
}
