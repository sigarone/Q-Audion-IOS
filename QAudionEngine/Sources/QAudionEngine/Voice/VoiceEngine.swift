import Foundation

/// The orchestration of ONE call of the contact-voice check. It composes the front-end (resampler, chunker, VAD, labeller,
/// windows; the stats stream is fed by the engine), the scoring, the evidence machine and the state functions, and adds what none
/// of them has: the feed order of the stats stream with its hold, the epochs and what they reset, the process-wide budget and the
/// pending windows, the post-call work, the call-local reference, consent, tier, hold, route, path and mute events, the summary of
/// the call that goes to the state functions, and the log lines.
///
/// Pure: no clock, no file, no thread. Every input is an item with the instant at which it reaches the worker
/// (`VoiceEngineItem`); the worker is serial, so an item is processed at `now = max(atNs, workerFree)` where `workerFree` is the
/// end of the last embedding that it started. Nothing else advances time. Items are fed in non-decreasing `atNs`; at the same
/// instant the RX blocks come first. An item before the first `mediaStart` is ignored; after the call ends only `postCancel` has
/// an effect.
///
/// THREADING: one engine is driven from ONE thread (a serial background queue, never the main thread); every callback of the
/// listener, the VAD, the embedder and the finalizer runs on it. Only `requestPostCancel` and the shared `VoiceCpuBudget` may be
/// touched from other threads. One `VoiceCpuBudget` serves the whole process (the engines of successive calls and the monitors
/// that report to it).
final class VoiceEngine {
    private static let ns: Int64 = 1_000_000_000
    private static let ms: Int64 = 1_000_000
    private static let chunkMs: Int64 = 32
    /// The hold of the stats feed: inputs younger than this are kept back so that they can be put in time order.
    private static let holdNs: Int64 = 100 * 1_000_000
    /// The tap line of the log is written this long after media start.
    private static let tapLineNs: Int64 = 2 * 1_000_000_000
    private static let rankRx = 0
    private static let rankMute = 1
    private static let rankDelivery = 2
    private static let routeNames = [0: "unk", 1: "ear", 2: "spk", 3: "bt", 4: "wired", 5: "car"]

    private enum EpochKind {
        case reset
        case hold
        case resume
        case route
    }

    private enum HeldPayload {
        case tap(ticks: Int64)
        case mute(muted: Bool)
        case delivery(VoiceStatsSnapshot)
    }

    private struct Held {
        let tNs: Int64
        let rank: Int
        let seq: Int
        let payload: HeldPayload
    }

    private final class PendingWindow {
        var window: VoiceWindowResult
        let rec: VoiceWindowRecord
        let rf: Int
        let ep: Int
        let tCutNs: Int64

        init(window: VoiceWindowResult, rec: VoiceWindowRecord, rf: Int, ep: Int, tCutNs: Int64) {
            self.window = window
            self.rec = rec
            self.rf = rf
            self.ep = ep
            self.tCutNs = tCutNs
        }

        var n: Int { window.n }
        var disjoint: Bool { window.disjoint }
    }

    private final class Inflight {
        let done: Int64
        let seq: Int
        let w: PendingWindow
        let raw: RawEmbedding
        let start: Int64
        let cost: Int64

        init(done: Int64, seq: Int, w: PendingWindow, raw: RawEmbedding, start: Int64 = -1, cost: Int64 = 0) {
            self.done = done
            self.seq = seq
            self.w = w
            self.raw = raw
            self.start = start
            self.cost = cost
        }

        var post: Bool { start >= 0 }
    }

    private struct DoneWindow {
        let n: Int
        let emb: [Float]
        let ranges: [[Int]]
        let nb: Bool
        let enroll: Bool
        let disjoint: Bool
        let lCons: Double?
    }

    private struct Due {
        let t: Int64
        let order: Int
        let c: Inflight?
    }

    private struct PostPlan {
        let plan: [Inflight]
        let deadline: Int64
        let deadlineHit: Bool
        let cancelledEarly: Bool
    }

    private struct Template {
        let unit: [Float]
        let speechS: Double
        let xcond: Bool
        let key: String
    }

    /// The VAD of the call: the busy time of every inference goes to the budget as `[now, now + cost)` (it does not advance the
    /// worker's clock).
    private final class CostVad: VoiceVadModel {
        private let inner: TimedVadModel
        var onCost: ((Int64) -> Void)?

        init(_ inner: TimedVadModel) {
            self.inner = inner
        }

        func reset() {
            inner.reset()
        }

        func step(_ chunk: [Float]) throws -> Float {
            let p = try inner.step(chunk)
            onCost?(inner.lastCostNs)
            return p
        }
    }

    private let config: VoiceEngineConfig
    private let call: VoiceCallInfo
    private let embedder: VoiceWindowEmbedder
    private let budget: VoiceCpuBudget
    private let finalizer: VoiceCallFinalizer
    private let listener: VoiceEngineListener?
    private let costVad: CostVad
    private let verifyScorer: VoiceScorer
    private let callLocalScorer: VoiceScorer

    // the call (it survives a repeated media start: what holds "for the rest of the call")
    private var tMedia: Int64 = 0
    private var started = false
    private var callStarted = false
    private var workerFree: Int64 = 0
    private var curT: Int64 = 0
    private var curNow: Int64 = 0
    private var ended = false
    private var flushed = false
    private var rec: TemplateRecord?
    private var path = VoicePath.srtp
    private var pathEverDc = false
    private var tiers: [Int] = []
    private(set) var tier = 0
    private var blockedCall = false
    private var withdrawn = false
    private var consentS = 0

    // the media epoch (reset at every media start)
    private var inactiveReason: VoiceFault?
    private var offEngine: Bool
    private var fault: VoiceFault?
    private var modelOk: Bool
    private var vseq: Int?
    private var peerRoute = 0
    private var mode = VoiceCheckMode.callLocal
    private var fe: VoiceFrontEnd!
    private var machine: VoiceCallMachine!
    private var lastRecord: VoiceRecord!
    private var curCtx: VoiceCallContext?
    private var disp = VoiceScoringConstants.Display(differs: false, change: false)

    // the stats feed and its hold
    private var held: [Held] = []
    private var seqs = [0, 0, 0]
    private var lastTicks: Int64?
    private var curRate = 0
    private var startedRx = false
    private var rf = 0
    private var firstRate: Int?
    private var tapEmitted = false
    private var cb: [Int] = []

    // chunk tags (by chunk index): the accumulator epoch, the count of reference resets and the peer's route class when it was made
    private var tagEpoch: [Int] = []
    private var tagRf: [Int] = []
    private var tagRt: [Int] = []

    // labels and flags
    private var speechT1: [Int64] = []
    private var speechChunks = 0
    private var exclSpeech = 0

    // windows, the budget, the pending list
    private var pending: [PendingWindow] = []
    private var inflight: [Inflight] = []
    private var doneWindows: [DoneWindow] = []
    private var startedLog: [Int64] = []
    private var overflowLog: [Int64] = []
    private var embedCosts: [Int64] = []
    private var vadCosts: [Int64] = []
    private var skipsBlocks = 0
    private var skipsOverflow = 0
    private var tickK: Int64 = 1

    // evidence
    private var refRf = 0
    private var refEmbs: [[Float]] = []
    private var refPrepared: PreparedTemplate?
    private var prepared: [String: PreparedTemplate] = [:]
    private var nScored = 0
    private var nUnc = 0
    private var rown = 0
    private var matchWindows = 0
    private var matched = false
    private var lastCand: VoiceCandidate?
    private var scoredLc: [Double] = []
    private var gateWindows = 0
    private var everShadow = false
    private var lastShadow = false
    private var wasHim = false
    /// The windows that failed their first enrollment gate: mix, snr, clip, concealment, narrowband.
    private var rej = [0, 0, 0, 0, 0]

    // the end of the call
    private var post: PostPlan?
    private var tEnd: Int64 = 0

    private let cancelLock = NSLock()
    private var cancelRequested = false

    /// The state of the display at the end of the call (read when the call ended, before the post-call work), or nil before.
    private(set) var finalState: VoiceFinalState?

    /// How the call went into the state functions, once it has been flushed.
    private(set) var result: VoiceFlushResult?

    /// What the call adds to the daily counters, set at the flush.
    private(set) var summary: VoiceCallSummary?

    /// Dropped blocks, and windows dropped by the pending rule (the skip count of the end line).
    var skipCounts: (blocks: Int, overflow: Int) { (skipsBlocks, skipsOverflow) }

    /// How many inputs reached the stats stream late or never: late RX, late mute, late delivery, lost mute, snapshots dropped by the cap.
    var lateCounts: [Int] {
        guard let s = fe?.statsStream else { return [0, 0, 0, 0, 0] }
        return [s.lateRxCount, s.lateMuteCount, s.lateDeliveryCount, s.lostMuteCount, s.capDroppedCount]
    }

    /// True once the call has been flushed into the state functions: the engine takes no more input.
    var isFlushed: Bool { flushed }

    /// The engine holds `listener` for its whole life: a listener must not hold the engine back.
    init(config: VoiceEngineConfig, call: VoiceCallInfo, vad: TimedVadModel, embedder: VoiceWindowEmbedder, budget: VoiceCpuBudget,
         finalizer: @escaping VoiceCallFinalizer, listener: VoiceEngineListener? = nil) throws {
        self.config = config
        self.call = call
        self.embedder = embedder
        self.budget = budget
        self.finalizer = finalizer
        self.listener = listener
        self.costVad = CostVad(vad)
        let topN = config.scoring.cohort.topN
        self.verifyScorer = try VoiceScorer(cohort: config.cohort, topN: topN, qmf: config.scoring.qmf.constants)
        self.callLocalScorer = try VoiceScorer(cohort: config.cohort, topN: topN, qmf: config.scoring.callLocal.qmf)
        self.rec = call.record
        self.offEngine = !call.ownerOn
        self.modelOk = call.model == .ok
        costVad.onCost = { [unowned self] cost in
            self.vadCosts.append(cost)
            self.budget.add(who: "vad", startNs: self.curNow, endNs: self.curNow + cost)
        }
    }

    /// Cancels the post-call work of this call (a call, incoming or outgoing, starts): callable from any thread. The embeddings of
    /// the pending windows that have not started are dropped (`dropped_cancelled`), whatever the worker is doing. The same effect
    /// as a `postCancel` item at the instant it reaches the worker.
    func requestPostCancel() {
        cancelLock.lock()
        cancelRequested = true
        cancelLock.unlock()
    }

    /// True once `requestPostCancel` was called (tests).
    var postCancelRequested: Bool { isCancelRequested() }

    private func isCancelRequested() -> Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelRequested
    }

    // MARK: small helpers

    private func line(_ t: Int64, _ text: String) {
        listener?.onLine(t, text)
    }

    private func callTag() -> String {
        String(call.callId.prefix(8))
    }

    private func secs(_ t: Int64) -> Int64 {
        max(0, (t - tMedia) / Self.ns)
    }

    // MARK: the entry point

    /// Feeds one item. Not thread safe: see the class comment.
    func feed(_ item: VoiceEngineItem) {
        if flushed { return }
        var isStart = false
        if case .mediaStart = item { isStart = true }
        if !started && !isStart { return } // nothing before media start is an input of the call
        let now = max(item.atNs, workerFree)
        curT = now
        curNow = now
        if !isStart && !ended { runDue(now) }
        switch item {
        case .mediaStart(_, let tNs, let tierInput):
            onMediaStart(tNs: tNs, tierInput: tierInput, now: now)
        case .rx(_, let tNs, let rateHz, let ticks, let pcm, let dropped):
            onRx(tNs: tNs, rateHz: rateHz, ticks: ticks, pcm: pcm, droppedIn: dropped, now: now)
        case .stats(_, let snapshot):
            if !ended && !offEngine { holdAdd(Self.rankDelivery, snapshot.arriveNs, .delivery(snapshot)) }
        case .mute(_, let tNs, let muted):
            if !ended && !offEngine { holdAdd(Self.rankMute, tNs, .mute(muted: muted)) }
        case .vcons(_, let v, let wallS):
            onVcons(v, wallS: wallS, now: now)
        case .route(_, let routeClass):
            if !ended && !offEngine {
                curT = now
                if routeClass != peerRoute { route(routeClass, now) }
            }
        case .hold(_, let isHeld):
            if !ended && !offEngine {
                curT = now
                epochEvent(isHeld ? .hold : .resume, now)
            }
        case .path(_, let newPath):
            onPath(newPath, now: now)
        case .tier(_, let input):
            if !ended && !offEngine {
                tiers.append(VoiceTier.tier(input))
                tier = tiers.min() ?? 0
                setCtx(now) { $0.tier = self.tier }
            }
        case .busy(_, let who, let startNs, let endNs):
            budget.add(who: who, startNs: startNs, endNs: endNs)
        case .wasHim:
            wasHim = true
        case .audioFault:
            if !ended && !offEngine && inactiveReason == nil { inactive(.audio) }
        case .callEnd(_, let tNs):
            onCallEnd(tEndItem: tNs, now: now)
        case .postCancel(let atNs):
            if ended && !flushed { finishPost(cancelAt: atNs, cancelled: true) }
        }
        if !ended && !isStart {
            flushHeld(now, everything: false)
            runDue(now)
        }
    }

    /// The end of the script: the post-call work that is left runs to its end and the call is flushed. A call that never ended is not flushed.
    func close() {
        if !started || flushed || !ended { return }
        finishPost(cancelAt: nil, cancelled: false)
    }

    // MARK: media start (every state is reset)

    private func onMediaStart(tNs: Int64, tierInput: VoiceTierInput?, now: Int64) {
        tMedia = tNs
        started = true
        workerFree = max(workerFree, now)
        if !callStarted { // the state of the CALL is set once: a repeated media start is the same call
            callStarted = true
            rec = call.record
            path = .srtp
            pathEverDc = false
            tiers = []
            tier = 0
            blockedCall = false
            withdrawn = false
            consentS = 0
        }
        ended = false
        inactiveReason = nil
        offEngine = !call.ownerOn
        fault = nil
        modelOk = call.model == .ok
        if call.model == .fail { fault = .model }
        vseq = nil
        peerRoute = 0
        wasHim = false
        let r0 = rec
        if let r = r0, r.state == TemplateState.enrolled || r.state == TemplateState.needsRefresh {
            mode = .verify
        } else {
            mode = .callLocal
        }
        // the front-end and the stats stream
        let frontEnd = VoiceFrontEnd(constants: config.constants, tables: config.tables, vad: costVad, externalStats: true)
        frontEnd.onChunkCreated = { [unowned self] idx, _, epoch in self.chunkCreated(idx, epoch) }
        frontEnd.onLabel = { [unowned self] _, t1Ns, label in self.labelFinal(t1Ns, label) }
        frontEnd.onChunk = { [unowned self] record in
            if record.label == 1 && record.excluded { self.exclSpeech += 1 }
        }
        frontEnd.onWindow = { [unowned self] window in self.windowCut(window, self.curNow) }
        frontEnd.statsStream.setMediaStart(tMedia)
        fe = frontEnd
        costVad.reset()
        held = []
        seqs = [0, 0, 0]
        lastTicks = nil
        curRate = 0
        startedRx = false
        rf = 0
        speechT1 = []
        speechChunks = 0
        exclSpeech = 0
        tagEpoch = []
        tagRf = []
        tagRt = []
        firstRate = nil
        tapEmitted = false
        cb = []
        tickK = 1
        // windows, the budget, the pending list
        pending = []
        inflight = []
        doneWindows = []
        startedLog = []
        overflowLog = []
        embedCosts = []
        vadCosts = []
        refRf = 0
        refEmbs = []
        refPrepared = nil
        prepared = [:]
        nScored = 0
        nUnc = 0
        rown = 0
        matchWindows = 0
        matched = false
        lastCand = nil
        scoredLc = []
        gateWindows = 0
        everShadow = false
        lastShadow = false
        rej = [0, 0, 0, 0, 0]
        post = nil
        finalState = nil
        // the machine
        let m = VoiceCallMachine(constants: config.scoring, mode: mode)
        machine = m
        lastRecord = m.mediaStart(tMedia)
        curCtx = nil
        disp = call.display ?? config.scoring.display
        if let input = tierInput {
            tiers.append(VoiceTier.tier(input))
            tier = tiers.min() ?? 0
        }
        line(tMedia, "QA-VOICE v=1 ev=start call=\(callTag()) own=\(call.ownerOn ? 1 : 0) peer=- tier=\(tier) path=srtp model=\(call.model.rawValue)")
        if !offEngine {
            let st = rec.map { Self.cstateCode($0.state) } ?? "lrn"
            line(tMedia, "QA-VOICE v=1 ev=cstate call=\(callTag()) st=\(st)")
        }
        let contact: VoiceContactState
        if let r = r0, r.state == TemplateState.needsRefresh {
            contact = .needsRefresh
        } else if mode == .verify {
            contact = .enrolled
        } else {
            contact = .learning
        }
        let consent = !(offEngine || blockedCall)
        let faultNow = faultStatic()
        let tierNow = tier
        let display = disp
        setCtx(tMedia) {
            $0.consent = consent
            $0.fault = faultNow
            $0.tier = tierNow
            $0.routeCovered = true
            $0.deviceCovered = true
            $0.contact = contact
            $0.displayDiffers = display.differs
            $0.displayChange = display.change
        }
        coverageCtx(tMedia, 0)
    }

    // MARK: the machine

    /// What the machine answered at `t`: the displayed change and the shadow flag are logged, nothing after the end of the call.
    @discardableResult
    private func afterStep(_ t: Int64, _ r: VoiceRecord) -> VoiceRecord {
        let prevShown = lastRecord.shown
        lastRecord = r
        if ended { return r } // after the end the machine still takes the windows that the post-call work embeds (the blocks decide what is learned); the display is gone
        if r.changed {
            listener?.onTransition(VoiceTransition(tNs: t, from: prevShown, shown: r.shown, detail: r.detail, cand: r.cand, b: r.b))
            line(t, "QA-VOICE v=1 ev=state call=\(callTag()) from=\(Self.shownCode(prevShown)) to=\(Self.shownCode(r.shown)) t=\(secs(t)) nw=\(nScored) blk=\(r.b) shown=1")
            if r.shown == .matches { matched = true }
        }
        if r.shadow != lastShadow {
            line(t, "QA-VOICE v=1 ev=state call=\(callTag()) from=\(r.shadow ? "chk" : "diff") to=\(r.shadow ? "diff" : "chk") t=\(secs(t)) nw=\(nScored) blk=\(r.b) shown=0")
            lastShadow = r.shadow
        }
        everShadow = everShadow || r.shadow
        return r
    }

    private func setCtx(_ t: Int64, _ update: (inout VoiceCallContext) -> Void) {
        let old = curCtx
        var new = old ?? VoiceCallContext()
        update(&new)
        if let old = old, new == old { return }
        curCtx = new
        let target = new
        afterStep(t, machine.setContext(t) { $0 = target })
    }

    private func coverage(_ routeClass: Int) -> VoiceTemplateState.Cov {
        guard let r = rec, r.state == TemplateState.enrolled || r.state == TemplateState.needsRefresh else {
            return VoiceTemplateState.Cov(route: false, device: false, slot: nil)
        }
        return VoiceTemplateState.coverage(r, routeClass: routeClass, deviceTag: call.deviceTag, config.state)
    }

    private func coverageCtx(_ t: Int64, _ routeClass: Int) {
        let c = coverage(routeClass)
        if mode == .verify {
            setCtx(t) {
                $0.routeCovered = c.route
                $0.deviceCovered = c.device
            }
        }
    }

    // MARK: the next due thing (ticks, the tap line, completions)

    private func earlier(_ t: Int64, _ order: Int, than best: Due?) -> Bool {
        guard let b = best else { return true }
        return t < b.t || (t == b.t && order < b.order)
    }

    private func nextDue(_ upto: Int64) -> Due? {
        if offEngine { return nil } // the owner setting is off: nothing is processed, nothing is timed
        var best: Due?
        var first: Inflight?
        for c in inflight {
            if let f = first {
                if c.done < f.done || (c.done == f.done && c.seq < f.seq) { first = c }
            } else {
                first = c
            }
        }
        if let c = first, c.done <= upto { best = Due(t: c.done, order: 0, c: c) }
        if !tapEmitted {
            let t = tMedia + Self.tapLineNs
            if t <= upto && earlier(t, 1, than: best) { best = Due(t: t, order: 1, c: nil) }
        }
        let tt = tMedia + tickK * Int64(config.constants.gates.stats.pollMs) * Self.ms
        if tt <= upto && earlier(tt, 2, than: best) { best = Due(t: tt, order: 2, c: nil) }
        return best
    }

    private func runDue(_ upto: Int64) {
        while true {
            if let due = nextDue(upto) {
                switch due.order {
                case 0:
                    if let c = due.c {
                        if let i = inflight.firstIndex(where: { $0 === c }) { inflight.remove(at: i) }
                        complete(c, due.t)
                        tryStart(due.t)
                    }
                case 1:
                    tapLine(due.t)
                default:
                    tick(due.t)
                    tickK += 1
                    tryStart(due.t)
                }
                continue
            }
            if tryStart(upto) { continue }
            break
        }
    }

    private func tapLine(_ t: Int64) {
        tapEmitted = true
        let hz: String
        if let r = firstRate, VoiceResampler.supportedRates.contains(r) { hz = String(r) } else { hz = "other" }
        if let lo = cb.min(), let hi = cb.max() {
            line(t, "QA-VOICE v=1 ev=tap call=\(callTag()) src=rx hz=\(hz) cbmin=\(lo) cbmax=\(hi) n=\(cb.count)")
        } else {
            line(t, "QA-VOICE v=1 ev=tap call=\(callTag()) src=rx hz=\(hz) cbmin=0 cbmax=0 n=0")
        }
    }

    /// Final VAD speech in the last 30 s of tap time at `t`: the chunks with final label 1 whose end is in (t - 30 s, t].
    private func speechMs30s(_ t: Int64) -> Int64 {
        let lo = t - config.scoring.evidence.noverLookbackMs * Self.ms
        var n: Int64 = 0
        var i = speechT1.count - 1
        while i >= 0 {
            let t1 = speechT1[i]
            if t1 > t {
                i -= 1
                continue
            }
            if t1 <= lo { break }
            n += 1
            i -= 1
        }
        return n * Self.chunkMs
    }

    private func tick(_ t: Int64) {
        let speech = speechMs30s(t)
        let f = faultAt(t, speech)
        setCtx(t) { $0.fault = f }
        afterStep(t, machine.tick(t, speechMs30s: speech))
    }

    /// The reason of Cannot verify at `t`. Cannot verify (cpu): final speech of at least the minimum in the last 30 s, a window
    /// skipped, and none started. A window is skipped when the pending rule dropped it in the last 30 s, or when it was cut in
    /// the last 30 s, is still waiting and the budget has no room (it never started because the budget was closed).
    private func faultAt(_ t: Int64, _ speechIn: Int64? = nil) -> VoiceFault? {
        if let f = faultStatic() { return f }
        let speech = speechIn ?? speechMs30s(t)
        let ev = config.scoring.evidence
        let lo = t - ev.noverLookbackMs * Self.ms
        let dropped = overflowLog.contains { $0 > lo && $0 <= t }
        let skipped = dropped || (!budget.room(t) && pending.contains { $0.tCutNs > lo && $0.tCutNs <= t })
        let startedIn = startedLog.contains { $0 > lo && $0 <= t }
        return (speech >= ev.noverMinVadMs && skipped && !startedIn) ? .cpu : nil
    }

    /// The reason of Cannot verify that does not depend on the clock: the path, the model, an inactive front-end.
    private func faultStatic() -> VoiceFault? {
        pathEverDc ? .path : fault
    }

    // MARK: RX blocks, chunks, epochs

    private func onRx(tNs: Int64, rateHz: Int, ticks: Int64, pcm: [Int16], droppedIn: Int, now: Int64) {
        if ended || offEngine { return }
        if path == .dc { return }
        let n = pcm.count
        if !tapEmitted { cb.append(n) }
        if firstRate == nil { firstRate = rateHz }
        let supported = VoiceResampler.supportedRates.contains(rateHz)
        if inactiveReason == nil && !supported { inactive(.audio) }
        // the stats stream gets (t, ticks) of every block, merged by time (the hold)
        holdAdd(Self.rankRx, tNs, .tap(ticks: ticks))
        let per: Int64? = supported ? Int64(96_000 / rateHz) : nil
        if inactiveReason != nil {
            lastTicks = ticks
            return
        }
        var dropped = droppedIn // the blocks that the worker queue dropped just before this one
        if let lt = lastTicks, let p = per, dropped == 0, ticks > lt + Int64(n) * p {
            dropped = 1 // a gap in the tap position that the queue did not report: one drop
        }
        lastTicks = ticks
        let newSegment = curRate != 0 && rateHz != curRate
        if curRate == 0 {
            curRate = rateHz
        } else if newSegment {
            curRate = rateHz
            epochEvent(.reset, now) // the front-end starts its new segment (resampler, time map, clip counts) and resets itself in registerTapBlock
        } else if dropped != 0 {
            skipsBlocks += dropped
            fe.onEvent(.reset)
            epochEvent(.reset, now)
        }
        startedRx = true
        fe.registerTapBlock(count: n, rateHz: rateHz, tNs: tNs, tapTicks: ticks)
        if !fe.isInactive { fe.push(pcm[...]) }
        if fe.isInactive && inactiveReason == nil { inactive(.audio) } // a VAD call failed
    }

    /// The front-end is inactive for the rest of the call and discards what it holds; the engine reports Cannot verify (audio).
    private func inactive(_ why: VoiceFault) {
        inactiveReason = why
        fault = why
        fe.deactivate()
        for w in pending { w.rec.fate = .droppedInactive }
        pending = []
        let f = faultStatic()
        setCtx(curT) { $0.fault = f }
    }

    /// An event of the call: reset (a dropped block or a rate change), hold, resume, route. It starts an epoch for the chunks from
    /// the next one on and discards the partial evidence block at once. The front-end part of a dropped block is the caller's
    /// (`fe.onEvent`), the one of a rate change is in `registerTapBlock`.
    private func epochEvent(_ kind: EpochKind, _ now: Int64) {
        if !startedRx && kind != .reset { return }
        afterStep(now, machine.reset(now))
        if kind != .reset { rf += 1 }
        switch kind {
        case .hold: fe.onEvent(.hold)
        case .resume: fe.onEvent(.resume)
        case .route: fe.onEvent(.route)
        case .reset: break
        }
    }

    // MARK: the feed of the stats stream (the hold)

    private func holdAdd(_ rank: Int, _ t: Int64, _ payload: HeldPayload) {
        held.append(Held(tNs: t, rank: rank, seq: seqs[rank], payload: payload))
        seqs[rank] += 1
    }

    /// Feeds the inputs of the stats stream whose time is below `now - hold` (all of them at the end of the call), by (time, kind,
    /// order of arrival).
    private func flushHeld(_ now: Int64, everything: Bool) {
        let cut = now - Self.holdNs
        if !held.isEmpty {
            let ready = held.filter { everything || $0.tNs < cut }.sorted {
                ($0.tNs, $0.rank, $0.seq) < ($1.tNs, $1.rank, $1.seq)
            }
            if !ready.isEmpty {
                held = held.filter { !(everything || $0.tNs < cut) }
                let stream = fe.statsStream
                for h in ready {
                    switch h.payload {
                    case .tap(let ticks): stream.addTapBlock(tNs: h.tNs, ticks: ticks)
                    case .mute(let muted): stream.addMute(tNs: h.tNs, muted: muted)
                    case .delivery(let snapshot): stream.addSnapshot(snapshot)
                    }
                }
            }
        }
        collect()
    }

    /// Takes the chunks that the stats stream released; every chunk whose label and flags are both final goes on to the windows, in order.
    private func collect() {
        if inactiveReason != nil || offEngine { return }
        fe.drainReleased()
        if fe.isInactive && inactiveReason == nil { inactive(.audio) }
    }

    // MARK: what the front-end reports

    private func chunkCreated(_ idx: Int, _ epoch: Int) {
        while tagEpoch.count <= idx {
            tagEpoch.append(0)
            tagRf.append(0)
            tagRt.append(0)
        }
        tagEpoch[idx] = epoch
        tagRf[idx] = rf
        tagRt[idx] = peerRoute
    }

    private func labelFinal(_ t1Ns: Int64, _ label: Int) {
        if label != 1 { return }
        speechT1.append(t1Ns)
        speechChunks += 1
    }

    // MARK: windows, the pending list, the budget

    /// Which windows are embedded: the scoring-eligible disjoint ones (verification and the call-local check), and, for a contact
    /// that is not Enrolled (learning), also every enrollment-eligible one. Nothing when the call is blocked for the contact, the
    /// model failed, the path left SRTP or the front-end is inactive.
    private func needed(_ w: VoiceWindowResult) -> Bool {
        if offEngine || blockedCall || !modelOk || pathEverDc || inactiveReason != nil { return false }
        if w.disjoint && w.score { return true }
        return mode == .callLocal && w.enroll
    }

    private func windowCut(_ w: VoiceWindowResult, _ now: Int64) {
        let first = w.first
        let routeClass = first < tagRt.count ? tagRt[first] : peerRoute
        let record = VoiceWindowRecord(window: w, tCutNs: now, routeClass: routeClass)
        let pw = PendingWindow(
            window: w, rec: record, rf: first < tagRf.count ? tagRf[first] : rf,
            ep: first < tagEpoch.count ? tagEpoch[first] : fe.currentEpoch, tCutNs: now)
        listener?.onWindow(record)
        // the first failed ENROLLMENT gate of the window (the counters of the end line)
        let en = config.constants.gates.enroll
        if w.meanP < en.meanPMin {
            rej[0] += 1
        } else if w.snrDb < en.snrDbMin {
            rej[1] += 1
        } else if !(w.clipFrac < en.clipFracMax) {
            rej[2] += 1
        } else if w.plcEvents > en.plcEventsMax || w.stretchEvents > en.stretchEventsMax || w.concUnknown {
            rej[3] += 1
        } else if en.wbOnly && w.narrowband {
            rej[4] += 1
        }
        if !needed(w) {
            record.fate = .notNeeded
            return
        }
        pending.append(pw)
        if pending.count > config.engine.cpu.maxPending {
            let victim = pending.first(where: { !$0.disjoint }) ?? pending[0]
            if let i = pending.firstIndex(where: { $0 === victim }) { pending.remove(at: i) }
            victim.rec.fate = .droppedPending
            skipsOverflow += 1
            overflowLog.append(now)
        } else {
            record.fate = .pending
        }
    }

    private func pick() -> PendingWindow? {
        pending.first(where: { $0.disjoint }) ?? pending.first
    }

    @discardableResult
    private func tryStart(_ t: Int64) -> Bool {
        if ended || offEngine || pending.isEmpty || workerFree > t || !budget.room(t) { return false }
        guard let w = pick() else { return false }
        if let i = pending.firstIndex(where: { $0 === w }) { pending.remove(at: i) }
        return start(w, t)
    }

    /// The audio of a window is not kept once the model has seen it.
    private func wipeSamples(_ w: PendingWindow) {
        VoiceWipe.floats(&w.window.samples)
        w.window.samples = []
    }

    private func embedOf(_ w: PendingWindow) -> VoiceEmbedding? {
        do {
            return try embedder.embed(window: w.window)
        } catch {
            return nil
        }
    }

    private func start(_ w: PendingWindow, _ t: Int64) -> Bool {
        let embedded = embedOf(w)
        wipeSamples(w)
        guard let e = embedded, let raw = VoiceMath.rawEmbedding(e.raw) else {
            w.rec.fate = .embedFailed
            return true
        }
        let done = t + e.costNs
        workerFree = done
        budget.add(who: "contact", startNs: t, endNs: done)
        startedLog.append(t)
        embedCosts.append(e.costNs)
        w.rec.fate = .embedded
        w.rec.embedStartNs = t
        w.rec.embedDoneNs = done
        inflight.append(Inflight(done: done, seq: w.n, w: w, raw: raw))
        return true
    }

    // MARK: scoring of an embedded window

    /// The template, the enrolled speech in seconds, xcond and the cache key for scoring a window of this route class against the
    /// contact's record.
    private func template(_ routeClass: Int) -> Template? {
        guard let r = rec else { return nil }
        let c = coverage(routeClass)
        guard let slot = c.slot else {
            guard let unit = r.adaptive else { return nil }
            return Template(unit: unit, speechS: Double(r.consensusSpeechMs) / 1000.0, xcond: !c.route, key: "B")
        }
        let sl = r.slots[slot]
        guard let unit = sl.centroid else { return nil }
        return Template(unit: unit, speechS: Double(sl.speechMs) / 1000.0, xcond: false, key: "S\(slot)")
    }

    private func prepare(_ key: String, _ v: [Float]) -> PreparedTemplate? {
        if let p = prepared[key] { return p }
        guard let p = try? verifyScorer.prepare(v) else { return nil }
        prepared[key] = p
        return p
    }

    private func complete(_ c: Inflight, _ t: Int64) {
        let w = c.w
        curT = t
        let e = c.raw.unit()
        let norm = c.raw.norm
        let out = w.rec
        var lCons: Double?
        // a learning window is scored against the consensus template, when the record has one
        if mode == .callLocal, w.window.enroll, let r = rec, let anchor = r.anchor {
            let covered = r.sessions.isEmpty
                ? false
                : VoiceTemplateState.coverage(r, routeClass: out.routeClass, deviceTag: call.deviceTag, config.state).route
            if let tpl = prepare("A", anchor),
               let s = try? verifyScorer.score(
                   e: e, rawNorm: norm, snrDb: w.window.snrDb, plc: w.window.plc, nb: w.window.narrowband,
                   enrollSpeechS: Double(r.consensusSpeechMs) / 1000.0, xcond: !covered, template: tpl) {
                lCons = s.lClipped
            }
        }
        doneWindows.append(DoneWindow(
            n: w.n, emb: e, ranges: w.window.ranges, nb: w.window.narrowband, enroll: w.window.enroll,
            disjoint: w.window.disjoint, lCons: lCons))
        out.embedMs = (c.done - (out.embedStartNs ?? c.done)) / Self.ms
        // the evidence, in the order of the chunk epochs
        if w.window.disjoint && w.window.score { evidence(w, e, norm, t, out) }
    }

    private func evidence(_ w: PendingWindow, _ e: [Float], _ norm: Double, _ t: Int64, _ out: VoiceWindowRecord) {
        let win = w.window
        if w.ep < fe.currentEpoch {
            // A window cut from chunks that came before a reset (a chunk is final about 3 s after its end) keeps its own epoch. It
            // is still embedded and given to learning, but it never enters the evidence of the new epoch, never moves the display
            // and never joins the call-local reference.
            out.stale = true
            return
        }
        let cfg = config.scoring
        let lC: Double
        if mode == .verify {
            guard let tpl = template(out.routeClass) else { return }
            let cov = coverage(out.routeClass)
            setCtx(t) {
                $0.routeCovered = cov.route
                $0.deviceCovered = cov.device
            }
            guard let prep = prepare(tpl.key, tpl.unit),
                  let res = try? verifyScorer.score(
                      e: e, rawNorm: norm, snrDb: win.snrDb, plc: win.plc, nb: win.narrowband, enrollSpeechS: tpl.speechS,
                      xcond: tpl.xcond, template: prep) else { return }
            leak(e, tpl.unit)
            lC = res.lClipped
        } else {
            if w.rf > refRf {
                refRf = w.rf
                refEmbs = []
                refPrepared = nil
            }
            guard let ref = refPrepared else {
                if win.certain {
                    refEmbs.append(e)
                    out.ref = true
                    if refEmbs.count == cfg.callLocal.refWindows {
                        if let centroid = try? VoiceCentroid.of(refEmbs) {
                            refPrepared = try? verifyScorer.prepare(centroid)
                        }
                        refEmbs = []
                    }
                } else {
                    out.ref = false
                }
                return
            }
            guard let res = try? callLocalScorer.score(
                e: e, rawNorm: norm, snrDb: win.snrDb, plc: win.plc, nb: win.narrowband, enrollSpeechS: cfg.callLocal.refSpeechS,
                xcond: false, template: ref) else { return }
            leak(e, ref.unit)
            lC = res.lClipped
        }
        guard lC.isFinite else { return }
        out.lC = lC
        nScored += 1
        if !win.certain { nUnc += 1 }
        let stepped: VoiceRecord
        do {
            stepped = try machine.window(t, x: lC, certain: win.certain)
        } catch {
            return
        }
        let cand = afterStep(t, stepped).cand
        out.cand = cand
        lastCand = cand
        if mode == .verify && cand == .matches { matchWindows += 1 }
        if win.certain {
            scoredLc.append(lC)
            let en = config.constants.gates.enroll
            if win.snrDb >= en.snrDbMin && win.meanP >= en.meanPMin { gateWindows += 1 }
        }
    }

    /// The leak counter (diagnostic only): a scored window whose embedding is closer to the owner's template than to the template it was scored against.
    private func leak(_ e: [Float], _ tpl: [Float]) {
        guard let ot = call.ownerTemplate else { return }
        if VoiceScorer.dot32(e, 0, ot, 0) > VoiceScorer.dot32(e, 0, tpl, 0) { rown += 1 }
    }

    // MARK: the other inputs

    private func onVcons(_ v: VoiceVcons, wallS: Int, now: Int64) {
        if ended || offEngine { return }
        curT = now
        if !v.allow || v.withdraw { blockedCall = true }
        if v.withdraw && !withdrawn {
            withdrawn = true
            if rec != nil { // a record that exists is deleted at once; with none there is nothing to delete and nothing is logged
                rec = nil
                listener?.onEffect(now, .deleteRecord)
                line(now, "QA-VOICE v=1 ev=store call=\(callTag()) op=delete res=ok why=contact")
            }
        }
        if v.allow && !v.withdraw { consentS = wallS }
        if vseq == nil || v.seq > vseq! {
            vseq = v.seq
            if v.routeClass != peerRoute { route(v.routeClass, now) }
        }
        let consent = !(offEngine || blockedCall)
        setCtx(now) { $0.consent = consent }
        if blockedCall {
            for w in pending { w.rec.fate = .droppedBlocked }
            pending = []
        }
    }

    private func route(_ cls: Int, _ now: Int64) {
        peerRoute = cls
        epochEvent(.route, now)
    }

    private func onPath(_ newPath: VoicePath, now: Int64) {
        if ended || offEngine { return }
        curT = now
        path = newPath
        if path == .dc {
            pathEverDc = true
            for w in pending { w.rec.fate = .droppedPath }
            pending = []
            let f = faultStatic()
            setCtx(now) { $0.fault = f }
        }
    }

    // MARK: the end of the call, the post-call work, the flush

    private func onCallEnd(tEndItem: Int64, now: Int64) {
        if ended { return }
        runDue(min(now, tEndItem))
        curT = tEndItem
        // the end of the stats stream: every held input is fed, chunks that end after the end are never released
        let clock = fe.statsStream.clockTime ?? 0
        let endNs = max(tEndItem, clock)
        flushHeld(now, everything: true)
        if inactiveReason == nil && !offEngine {
            fe.finish(endNs: endNs)
            if fe.isInactive && inactiveReason == nil { inactive(.audio) }
        }
        if !offEngine { // Cannot verify (cpu) is judged once more at the end of the call, with the windows that still wait
            let f = faultAt(tEndItem)
            setCtx(tEndItem) { $0.fault = f }
        }
        tEnd = tEndItem
        finalState = displaySnapshot()
        ended = true
        // the in-flight embeddings finish, then the pending windows are embedded within post_call_max_s of the end of the call
        let cpu = config.engine.cpu
        var plan: [Inflight] = []
        var cur = max(tEnd, workerFree)
        let deadline = tEnd + Int64(cpu.postCallMaxS) * Self.ns
        plan.append(contentsOf: inflight.sorted { ($0.done, $0.seq) < ($1.done, $1.seq) })
        if let latest = inflight.map({ $0.done }).max() { cur = max(cur, latest) }
        inflight = []
        var rest = pending
        pending = []
        var deadlineHit = false
        var early = false
        while !rest.isEmpty {
            if isCancelRequested() { // a call started: what has not started is dropped (the app's cancel; never resumed)
                for y in rest { y.rec.fate = .droppedCancelled }
                rest = []
                early = true
                break
            }
            let w = rest.first(where: { $0.disjoint }) ?? rest[0]
            if let i = rest.firstIndex(where: { $0 === w }) { rest.remove(at: i) }
            let embedded = embedOf(w)
            wipeSamples(w)
            guard let e = embedded, let raw = VoiceMath.rawEmbedding(e.raw) else {
                w.rec.fate = .embedFailed
                continue
            }
            if cur + e.costNs > deadline {
                w.rec.fate = .droppedPostCall
                for y in rest { y.rec.fate = .droppedPostCall }
                rest = []
                deadlineHit = true
                break
            }
            plan.append(Inflight(done: cur + e.costNs, seq: w.n, w: w, raw: raw, start: cur, cost: e.costNs))
            cur += e.costNs
        }
        post = PostPlan(plan: plan, deadline: deadline, deadlineHit: deadlineHit, cancelledEarly: early)
        for c in plan where c.post { c.w.rec.fate = .postPlanned }
        workerFree = max(workerFree, cur)
    }

    private func displaySnapshot() -> VoiceFinalState {
        let ctx = curCtx ?? VoiceCallContext()
        let r: VoiceRecord = lastRecord
        return VoiceFinalState(
            shown: r.shown, detail: r.detail, cand: r.cand, b: r.b, worst: r.worst, blockN: r.blockN, differed: r.differed,
            scored: nScored, unc: nUnc, speechMs: Int64(speechChunks) * Self.chunkMs, routeCovered: ctx.routeCovered,
            deviceCovered: ctx.deviceCovered)
    }

    private func finishPost(cancelAt: Int64?, cancelled: Bool) {
        guard let p = post else { return }
        var tFlush = tEnd
        for c in p.plan {
            if let at = cancelAt, c.done > at {
                c.w.rec.fate = .droppedCancelled
                tFlush = max(tFlush, at)
                continue
            }
            if c.post {
                c.w.rec.embedStartNs = c.start
                c.w.rec.embedDoneNs = c.done
                c.w.rec.fate = .embeddedPostCall
                budget.add(who: "contact", startNs: c.start, endNs: c.done)
                embedCosts.append(c.cost)
            }
            complete(c, c.done)
            tFlush = max(tFlush, c.done)
        }
        // the work that did not finish is cut off at the deadline
        if p.deadlineHit && (cancelAt == nil || cancelAt! >= p.deadline) { tFlush = max(tFlush, p.deadline) }
        flush(tFlush, cancelled || p.cancelledEarly)
    }

    /// The summary of the call goes to the state functions; the lines of the end.
    private func flush(_ t: Int64, _ cancelled: Bool) {
        flushed = true
        let cid = callTag()
        let recIn = rec
        let windows = doneWindows.sorted { $0.n < $1.n }
        var recOut = recIn
        var info: CallResult?
        var beforeRec = recIn
        var failed = false
        let ran = !offEngine && !pathEverDc
        if ran {
            do {
                let fin = try finalizer(recIn, callDict(windows))
                beforeRec = fin.before
                recOut = fin.end.record
                info = fin.end.result
            } catch {
                failed = true
            }
        }
        rec = recOut
        if ran, let i = info {
            learnLines(t, cid, beforeRec.map { Self.cstateCode($0.state) } ?? "none", beforeRec, recOut, i)
        }
        endLine(t, cid)
        result = VoiceFlushResult(flushNs: t, cancelled: cancelled, ran: ran, failed: failed, info: info, record: recOut)
    }

    private func callDict(_ windows: [DoneWindow]) -> StateCall {
        let tStartS = call.tStartS
        let tEndS = tStartS + Int(max(0, (tEnd - tMedia) / Self.ns))
        let ev = machine.evidence
        let learnBlocked = ev.everDiffersCandidate || ev.everWeakBlock
        let usable = modelOk && inactiveReason == nil
        let enr = windows.filter { $0.enroll }
        func stateWindow(_ d: DoneWindow, _ lC: Double?) -> StateWindow {
            StateWindow(emb: d.emb, chunks: d.ranges.map { $0[0]..<$0[1] }, lC: lC, nb: d.nb)
        }
        if mode == .callLocal {
            let list: [StateWindow]? = usable ? enr.map { stateWindow($0, $0.lCons) } : nil
            return StateCall(
                tStartS: tStartS, tEndS: tEndS, utcOffsetS: call.utcOffsetS, routeClass: peerRoute, deviceTag: call.deviceTag,
                consent: !blockedCall, consentS: consentS, tier: tier, learnBlocked: learnBlocked, windows: list)
        }
        // Enrolled or Needs refresh: the outcome of the call and the windows of a slot entry
        let disj = enr.filter { $0.disjoint }
        let capChunks = config.engine.updateMaxSpeechMs / Int(Self.chunkMs)
        let taken = VoiceTemplateState.takeWithin(disj.map { stateWindow($0, nil) }, free: capChunks).taken
        let u: [Float]? = taken.isEmpty ? nil : StateVec.sum(taken.map { $0.emb })
        let outcome = StateOutcome(
            u: u, lC: scoredLc, gateWindows: gateWindows, matched: matched, finalMatches: lastCand == .matches,
            differsCandidate: ev.everDiffersCandidate, blocked: ev.blocked, matchWindows: matchWindows, scoredWindows: nScored,
            eligWindows: disj.count, authenticityElevated: false, wasHim: wasHim)
        let list: [StateWindow]? = usable ? enr.map { stateWindow($0, nil) } : nil
        return StateCall(
            tStartS: tStartS, tEndS: tEndS, utcOffsetS: call.utcOffsetS, routeClass: peerRoute, deviceTag: call.deviceTag,
            consent: !blockedCall, consentS: consentS, tier: tier, learnBlocked: learnBlocked, windows: list, outcome: outcome)
    }

    private func learnLines(_ t: Int64, _ cid: String, _ before: String, _ recIn: TemplateRecord?, _ recOut: TemplateRecord?, _ info: CallResult) {
        let after = recOut.map { Self.cstateCode($0.state) } ?? "none"
        if info.why == "no_consent" { // blocked for this contact in this call: the state functions changed nothing
            if let r = recIn, r.state == TemplateState.enrolled || r.state == TemplateState.needsRefresh {
                line(t, "QA-VOICE v=1 ev=upd call=\(cid) res=skip_off")
            }
            return
        }
        let path = info.path
        if path == "learning" && info.why != "tier" && info.why != "blocked" {
            var why: String?
            if info.why == "short" || info.why == "mixed" || info.why == "no_session" {
                why = info.why != "no_session" ? info.why : nil
            } else if let rcmp = info.recompute {
                if rcmp.state == TemplateState.enrolled {
                    why = "enrolled"
                } else if info.evicted != nil {
                    why = "evict"
                } else if rcmp.why == "conflict" {
                    why = "conflict"
                } else if rcmp.why == "loo" {
                    why = "loo"
                } else if info.session == "merged" {
                    why = "merged"
                } else {
                    why = "added"
                }
            }
            if let why = why {
                let ns = recOut?.sessions.count ?? 0
                let sp = recOut.map { $0.consensusSpeechMs / 1000 } ?? 0
                let days = recOut?.nDaysConsensus ?? 0
                line(t, "QA-VOICE v=1 ev=learn call=\(cid) from=\(before) to=\(after) ns=\(ns) sp=\(min(sp, 9999)) days=\(min(days, 9)) why=\(why)")
            }
        } else if path == "enrolled" || path == "refresh" {
            let sl = info.slot
            if let s = sl, s.entered, let out = recOut {
                line(
                    t,
                    "QA-VOICE v=1 ev=learn call=\(cid) from=\(before) to=\(after) ns=\(out.sessions.count) sp=\(min(out.consensusSpeechMs / 1000, 9999)) "
                        + "days=\(min(out.nDaysConsensus, 9)) why=\(s.activated == true ? "slota" : "slotq")")
            }
            var res = "skip_state"
            if info.why == "tier" {
                res = "skip_tier"
            } else if info.why == "no_consent" {
                res = "skip_off"
            } else if let up = info.update {
                if up.updated {
                    res = "applied"
                } else if up.why == "bound" || up.why == "theta" {
                    res = "bound"
                } else if up.why == "rate" {
                    res = "rate"
                } else if up.why == "windows" {
                    res = "skip_short"
                } else {
                    res = "skip_cond"
                }
            } else if sl != nil {
                res = "skip_cond"
            }
            line(t, "QA-VOICE v=1 ev=upd call=\(cid) res=\(res)")
        }
    }

    private func endLine(_ t: Int64, _ cid: String) {
        guard let f = finalState else { return }
        let shown = Self.shownCode(f.shown)
        var res = ["match", "chk", "diff", "nover", "chg", "off"].contains(shown) ? shown : "na"
        if offEngine { res = "off" }
        let shadow: String
        if everShadow {
            shadow = "diff"
        } else if res == "na" && nScored > 0 {
            switch lastCand {
            case .matches?: shadow = "match"
            case .checking?: shadow = "chk"
            default: shadow = "diff"
            }
        } else {
            shadow = "na"
        }
        let rdt = speechChunks > 0 ? (1000 * exclSpeech) / speechChunks : 0
        let worst = lastRecord.worst // the evidence at the flush: the windows of the post-call work count (the display of `res` is that of the end of the call)
        let margin = worst < 0.25 ? 0 : worst < 0.5 ? 1 : worst < 0.75 ? 2 : worst < 1.0 ? 3 : 4
        let c = coverage(peerRoute)
        let covered = (mode == .verify && c.route) ? 1 : 0
        let newdev = (mode == .verify && !c.device) ? 1 : 0
        let emb = embedCosts.map { $0 / Self.ms }.sorted()
        let vadUs = vadCosts.map { $0 / 1000 }.sorted()
        let dur = max(0, (tEnd - tMedia) / Self.ns)
        let speechS = f.speechMs / 1000
        summary = VoiceCallSummary(
            res: res, verifyMode: mode == .verify, shadow: everShadow, speechS: speechS, margin: margin, routeClass: peerRoute,
            newDevice: newdev == 1)
        let skipped = min(skipsBlocks + skipsOverflow, 9999)
        let routeName = Self.routeNames[peerRoute] ?? "unk"
        line(
            t,
            "QA-VOICE v=1 ev=end call=\(cid) res=\(res) shadow=\(shadow) dur=\(min(dur, 99_999)) vsp=\(min(speechS, 99_999)) acc=\(min(nScored, 9999)) "
                + "unc=\(min(nUnc, 9999)) blk=\(min(lastRecord.b, 999)) rsnr=\(rej[1]) rclip=\(rej[2]) rplc=\(rej[3]) rdt=\(min(rdt, 9999)) rnb=\(rej[4]) rmix=\(rej[0]) "
                + "rskip=\(skipped) rown=\(rown) margin=\(margin) sc=- cov=\(covered) newdev=\(newdev) "
                + "emb50=\(min(Self.percentile(emb, 0.5), 9999)) emb95=\(min(Self.percentile(emb, 0.95), 9999)) "
                + "vad95=\(min(Self.percentile(vadUs, 0.95), 999)) route=\(routeName)")
    }

    // MARK: codes

    /// The element `floor(q (n - 1))` of the sorted values; 0 when there is none.
    private static func percentile(_ sorted: [Int64], _ q: Double) -> Int64 {
        if sorted.isEmpty { return 0 }
        return sorted[Int((q * Double(sorted.count - 1)).rounded(.down))]
    }

    private static func shownCode(_ s: VoiceShown) -> String {
        switch s {
        case .matches: return "match"
        case .checking: return "chk"
        case .differs: return "diff"
        case .cannotVerify: return "nover"
        case .learning: return "lrn"
        case .changed: return "chg"
        case .off: return "off"
        }
    }

    private static func cstateCode(_ state: Int) -> String {
        switch state {
        case TemplateState.learning: return "lrn"
        case TemplateState.provisional: return "prov"
        case TemplateState.enrolled: return "enr"
        default: return "ref"
        }
    }
}
