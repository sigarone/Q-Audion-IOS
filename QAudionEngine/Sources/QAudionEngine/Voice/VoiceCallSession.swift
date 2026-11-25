import Foundation

/// What one call binds the voice check to. Every field is captured by value when the session is created, from the state of
/// THIS call: a field that an earlier call may have left behind is never read later.
struct VoiceCallBinding {
    var callId: String
    var contactId: String
    /// The device that this call's handshake pinned (nil when the call pinned the bare contact id).
    var peerDeviceId: String?
    /// Unix time of the call's start, and the local UTC offset at that time.
    var tStartS: Int
    var utcOffsetS: Int
}

/// The outcome of one stats poll.
enum VoicePollResult {
    /// The two selector reports of the poll, as one snapshot.
    case snapshot(VoiceStatsSnapshot)
    /// The reports cannot be used: Cannot verify (audio).
    case fault(VoiceStatsFault)
    /// Nothing to ask yet (no live audio transceiver) or nothing came back: the interval is simply missing.
    case unavailable
}

/// Where the poll gets its reports. The implementation resolves the LIVE audio receiver and sender at every poll, on the queue
/// the connection belongs to, and never keeps one between polls.
protocol VoiceStatsSource: AnyObject {
    func pollOnce(_ deliver: @escaping (VoicePollResult) -> Void)
}

/// A source made of a closure (the call controller asks its current connection at every poll).
final class VoiceClosureStatsSource: VoiceStatsSource {
    private let poll: (@escaping (VoicePollResult) -> Void) -> Void

    init(_ poll: @escaping (@escaping (VoicePollResult) -> Void) -> Void) {
        self.poll = poll
    }

    func pollOnce(_ deliver: @escaping (VoicePollResult) -> Void) {
        poll(deliver)
    }
}

/// The 1 s tick of the poll.
protocol VoiceTicker: AnyObject {
    func start(everyMs: Int, queue: DispatchQueue, handler: @escaping () -> Void)
    func stop()
}

final class VoiceDispatchTicker: VoiceTicker {
    private var timer: DispatchSourceTimer?

    func start(everyMs: Int, queue: DispatchQueue, handler: @escaping () -> Void) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(everyMs), repeating: .milliseconds(everyMs), leeway: .milliseconds(50))
        t.setEventHandler(handler: handler)
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// Collects the two selector reports of one poll and delivers one result (exactly once).
final class VoicePollJoin: @unchecked Sendable {
    typealias Part = (rows: [VoiceStatRow], stamp: PeerConnectionStatsGate.Stamp, reportNs: Int64)

    private let lock = NSLock()
    private var receiver: Part?
    private var sender: Part?
    private var delivered = false
    private let deliver: (VoicePollResult) -> Void

    init(deliver: @escaping (VoicePollResult) -> Void) {
        self.deliver = deliver
    }

    func receiverArrived(_ part: Part) {
        lock.lock()
        receiver = part
        lock.unlock()
        finishIfComplete()
    }

    func senderArrived(_ part: Part) {
        lock.lock()
        sender = part
        lock.unlock()
        finishIfComplete()
    }

    private func finishIfComplete() {
        lock.lock()
        guard !delivered, let r = receiver, let s = sender else {
            lock.unlock()
            return
        }
        delivered = true
        lock.unlock()
        switch VoiceStatsReader.readReceiver(r.rows) {
        case .failure(let fault):
            deliver(.fault(fault))
        case .success(let inbound):
            let stamp = PeerConnectionStatsGate.combine(r.stamp, s.stamp)
            let snapshot = VoiceStatsReader.snapshot(
                stamp: stamp, reportNs: r.reportNs, inbound: inbound, sender: VoiceStatsReader.readSender(s.rows))
            deliver(.snapshot(snapshot))
        }
    }
}

/// What a call keeps for the voice check from the moment the call object exists, before the session does: a fallback to the data
/// channel can arrive before media start and must not be lost. The session, once it exists, is told of everything the latch
/// holds.
final class VoiceCallLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fallback = false
    private var session: VoiceCallSession?
    private var vconsBeforeSession: [(VoiceVcons, Int)] = []

    /// The peer's announcement: passed on to the session, or kept until the session exists (a few at most).
    func noteVcons(_ v: VoiceVcons, wallS: Int) {
        lock.lock()
        let s = session
        if s == nil, vconsBeforeSession.count < 8 { vconsBeforeSession.append((v, wallS)) }
        lock.unlock()
        s?.peerVcons(v, wallS: wallS)
    }

    /// The media left SRTP for the rest of the call.
    func noteFallback() {
        lock.lock()
        fallback = true
        let s = session
        lock.unlock()
        s?.pathFallback()
    }

    /// The session of this call exists now: replay what happened before.
    func attach(_ newSession: VoiceCallSession) {
        lock.lock()
        session = newSession
        let replay = fallback
        let held = vconsBeforeSession
        vconsBeforeSession = []
        lock.unlock()
        if replay { newSession.pathFallback() }
        for (v, wallS) in held { newSession.peerVcons(v, wallS: wallS) }
    }

    func detach() -> VoiceCallSession? {
        lock.lock()
        defer { lock.unlock() }
        let s = session
        session = nil
        return s
    }

    var currentSession: VoiceCallSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }
}

/// The background-task assertion of the post-call work of one call. It is ended exactly once: by the system's expiration, or by the
/// end of the post-call work, whichever comes first (the second one finds it ended and does nothing).
final class VoiceTaskHold: @unchecked Sendable {
    private let tasks: VoiceBackgroundTasks
    private let lock = NSLock()
    private var token: Int?
    private var ended = false

    init(tasks: VoiceBackgroundTasks) {
        self.tasks = tasks
    }

    /// The token that `begin` returned. When the assertion already expired, it is given back at once.
    func began(_ newToken: Int?) {
        guard let newToken else { return }
        lock.lock()
        if ended {
            lock.unlock()
            tasks.end(newToken)
            return
        }
        token = newToken
        lock.unlock()
    }

    /// Gives the assertion back, once. Callable from any thread, also from the expiration handler.
    func end() {
        lock.lock()
        let t = token
        token = nil
        ended = true
        lock.unlock()
        if let t { tasks.end(t) }
    }
}

/// An embedder for a call whose speaker model did not load: every window fails.
private final class UnavailableEmbedder: VoiceWindowEmbedder {
    func embed(window: VoiceWindowResult) throws -> VoiceEmbedding? { nil }
}

/// The voice check of ONE call: the producer of the RX tap, the one serial background queue that owns the engine, the 1 s stats
/// poll, and the end of the call. Everything that touches the engine, the models or the store runs on that queue, never on the
/// main thread; the entry points are cheap and may be called from any thread.
final class VoiceCallSession: @unchecked Sendable {
    let binding: VoiceCallBinding
    let queue: DispatchQueue
    /// The producer that `NativeAudioPcmTap` calls (see `VoiceRxTap`).
    private(set) var rxTap: VoiceRxTap!

    private let process: VoiceProcess
    private let rxQueue = VoiceRxQueue(capacity: 256)
    private let clock: () -> Int64
    private let makeTicker: () -> VoiceTicker
    private let governor: BackgroundCpuGovernor
    private let protectedData: ProtectedDataFlag
    /// The wipe epoch of the daily counters when the call began.
    private let dailyEpoch: Int

    // Shared with other threads.
    private let lock = NSLock()
    private var fallbackSeen = false
    /// The hold state of the call as last told (this side or the peer): the engine starts from it, whenever it is built.
    private var holdNow = false
    private var cancelRequested = false
    private var ended = false
    /// The result of this call must not be written: the voice was wiped or the contact was deleted while the call ran.
    private var resultDiscarded = false
    /// The engine and its post-call work are dropped (a wipe): nothing of the call goes on.
    private var engineDiscarded = false
    private var source: VoiceStatsSource?
    private var engineForCancel: VoiceEngine?

    // Confined to `queue`.
    private var engine: VoiceEngine?
    private var gaveUp = false
    private var prepared = false
    private var mediaStartNs: Int64 = 0
    private var lastAt: Int64 = 0
    private var ticker: VoiceTicker?
    private var pollsInFlight = 0
    private var lastHold = false
    private var lastTierInput: VoiceTierInput?
    private var engineRan = false
    private var releaseModels: (() -> Void)?
    /// The peer's announcements that arrived before the engine exists; replayed to it once it is built.
    private var pendingVcons: [(VoiceVcons, Int)] = []
    /// The owner setting was off at the start of the call: nothing is processed, nothing is read or written.
    private var offForCall = false

    /// Polls that the lock or the CPU governor held back, and RX blocks that went on to the engine (diagnostics and tests).
    private(set) var heldBackPolls = 0
    private(set) var fedBlocks = 0
    private(set) var heldBackBlocks = 0
    private(set) var holdEventsFed = 0

    init(binding: VoiceCallBinding, process: VoiceProcess, queue: DispatchQueue? = nil,
         clock: @escaping () -> Int64 = VoiceClock.nowNs, ticker: @escaping () -> VoiceTicker = { VoiceDispatchTicker() },
         governor: BackgroundCpuGovernor = BackgroundCpuGovernor(flag: .shared), protectedData: ProtectedDataFlag = .shared) {
        self.binding = binding
        self.process = process
        // One serial background queue for the whole voice work of the call; its priority is provisional until it is measured.
        self.queue = queue ?? DispatchQueue(label: "com.bcrypto.qaudion.voice.call", qos: .utility)
        self.clock = clock
        self.makeTicker = ticker
        self.governor = governor
        self.protectedData = protectedData
        self.dailyEpoch = process.daily.epoch
        self.rxTap = VoiceRxTap(queue: rxQueue, clock: clock, wake: { [weak self] in self?.scheduleDrain() })
    }

    // MARK: entry points (any thread)

    /// Where the 1 s poll gets its reports.
    func attachStatsSource(_ newSource: VoiceStatsSource) {
        lock.lock()
        source = newSource
        lock.unlock()
    }

    /// The call is genuinely accepted: the engine is built (models, record, device tag) and started.
    func mediaStart(held: Bool = false) {
        let now = clock()
        lock.lock()
        holdNow = held
        lock.unlock()
        queue.async { [self] in startEngine(now) }
    }

    /// The media left SRTP for the data channel: Cannot verify (path) for the rest of the call. Replayed at the start of the
    /// engine when it arrives before it.
    func pathFallback() {
        lock.lock()
        fallbackSeen = true
        lock.unlock()
        let now = clock()
        queue.async { [self] in
            guard engine != nil else { return }
            feed(.path(atNs: stamped(now), path: .dc))
        }
    }

    func muteChanged(_ muted: Bool) {
        let now = clock()
        queue.async { [self] in
            guard engine != nil else { return }
            feed(.mute(atNs: stamped(now), tNs: now, muted: muted))
        }
    }

    /// The call is put on hold (by this side or by the peer) or resumed. Only a change is passed on.
    func holdChanged(_ held: Bool) {
        let now = clock()
        lock.lock()
        holdNow = held
        lock.unlock()
        queue.async { [self] in
            guard engine != nil, held != lastHold else { return }
            lastHold = held
            holdEventsFed += 1
            feed(.hold(atNs: stamped(now), held: held))
        }
    }

    /// One moment of the trust inputs of the call. The engine keeps the lowest tier of every moment; an input equal to the one
    /// reported last is not passed again.
    func reportTier(_ input: VoiceTierInput) {
        let now = clock()
        queue.async { [self] in
            guard engine != nil, input != lastTierInput else { return }
            lastTierInput = input
            feed(.tier(atNs: stamped(now), input: input))
        }
    }

    /// The peer's announcement, opened and decoded. A withdrawal deletes the contact's record at once, also before the engine exists.
    func peerVcons(_ v: VoiceVcons, wallS: Int) {
        let now = clock()
        queue.async { [self] in
            // A withdrawal deletes the record of the contact whenever one exists, whatever the owner setting, the entitlement or the
            // state of the engine is, and the end of this call writes nothing back. It comes before every early return.
            if v.withdraw {
                discardResult()
                try? process.services.deleteRecord(contactId: binding.contactId, generation: process.services.generation)
            }
            if let e = engine, !isEnded {
                e.feed(.vcons(atNs: stamped(now), vcons: v, wallS: wallS))
                return
            }
            if offForCall || gaveUp || isEnded { return }
            if pendingVcons.count < 16 { pendingVcons.append((v, wallS)) }
        }
    }

    /// The owner chose "It was <name>" on the Differs sheet.
    func wasHimTapped() {
        let now = clock()
        queue.async { [self] in
            guard engine != nil else { return }
            feed(.wasHim(atNs: stamped(now)))
        }
    }

    /// The learning and verifying bits of this device's own announcement (0 while there is no engine).
    var announcedFlags: Int {
        lock.lock()
        let e = engineForCancel
        lock.unlock()
        return e?.announcedFlags ?? 0
    }

    /// The peer's announced route class (a consent message, later). Until then the class is unknown: the local audio route is
    /// never used.
    func peerRouteAnnounced(_ routeClass: Int) {
        let now = clock()
        queue.async { [self] in
            guard engine != nil else { return }
            feed(.route(atNs: stamped(now), routeClass: routeClass))
        }
    }

    /// Cancels the post-call work of this call: the embeddings that have not started are dropped, also those that would start
    /// after this call returns. Never resumed.
    func requestPostCancel() {
        lock.lock()
        cancelRequested = true
        let e = engineForCancel
        lock.unlock()
        e?.requestPostCancel()
    }

    /// The call is over: the producer stops, the engine gets the end of the call and runs its post-call work under a background
    /// task, then the call is flushed into the store and everything is let go.
    func callEnded() {
        lock.lock()
        if ended {
            lock.unlock()
            return
        }
        ended = true
        lock.unlock()
        rxTap.stop()
        let now = clock()
        // The assertion is taken here, on the caller's thread, while the app can still get the time.
        // The assertion is given back inside the expiration handler too (the system ends the app soon after it returns), and only once.
        let tasks = process.backgroundTasks
        let hold = VoiceTaskHold(tasks: tasks)
        let token = tasks.begin(name: "voice-post-call", onExpiration: { [weak self] in
            self?.requestPostCancel()
            hold.end()
        })
        hold.began(token)
        queue.async { [self] in finish(now, hold: hold) }
    }

    /// The result of this call is not written any more (the contact was deleted or blocked). The call itself goes on.
    func discardResult() {
        lock.lock()
        resultDiscarded = true
        lock.unlock()
    }

    private var isResultDiscarded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resultDiscarded || engineDiscarded
    }

    /// A wipe: the engine and its post-call work are stopped and dropped, nothing is flushed, nothing is written, and the models
    /// are given back. Callable from any thread; the work itself runs on the queue.
    func discardAll() {
        lock.lock()
        resultDiscarded = true
        engineDiscarded = true
        cancelRequested = true
        let e = engineForCancel
        let first = !ended
        ended = true
        lock.unlock()
        e?.requestPostCancel()
        rxTap.stop()
        if first {
            queue.async { [self] in finish(clock(), hold: nil) }
        }
    }

    /// Runs `body` on the queue of the session with its engine (tests).
    func withEngine<T>(_ body: (VoiceEngine?) -> T) -> T {
        queue.sync { body(engine) }
    }

    private var isEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    // MARK: on the queue

    private func scheduleDrain() {
        queue.async { [self] in drainRx() }
    }

    private func stamped(_ at: Int64) -> Int64 {
        lastAt = max(lastAt, at)
        return lastAt
    }

    private func feed(_ item: VoiceEngineItem) {
        engine?.feed(item)
    }

    private func startEngine(_ now: Int64) {
        let startedGeneration = process.services.generation
        guard engine == nil, !gaveUp, !isEnded, VoiceFeature.isEnabled else { return }
        // The owner setting (and the entitlement) is read once, here. Off: no model, no store, no key, nothing is created.
        guard process.ownerOn else {
            gaveUp = true
            offForCall = true
            process.showDisplay(.off)
            return
        }
        guard let ready = process.services.prepare() else {
            gaveUp = true
            return
        }
        prepared = true
        releaseModels = ready.release
        let services = process.services
        // The account of this call, taken once: the write at the end of the call goes to this account's store or nowhere.
        guard let startedAccount = services.currentAccount() else {
            gaveUp = true
            return
        }
        do {
            let cfg = ready.config
            let record = try services.loadRecord(contactId: binding.contactId, cfg: cfg.state, generation: startedGeneration)
            let deviceKnown = !(binding.peerDeviceId?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            // A device that is really unknown has no tag of its own and is never counted as a new one.
            var tag = 0
            if deviceKnown { tag = try services.deviceTag(deviceId: binding.peerDeviceId ?? "", generation: startedGeneration) }
            guard let budget = services.budget else {
                gaveUp = true
                return
            }
            let contactId = binding.contactId
            let finalizer: VoiceCallFinalizer = { [weak self] _, call in
                var before: TemplateRecord?
                var result: CallEnd?
                // The generation is checked inside the lock of the store, and so is this call's own flag: a wipe or a deletion that came
                // first leaves nothing for this call to write.
                try services.update(contactId: contactId, cfg: cfg.state, generation: startedGeneration, account: startedAccount) { loaded in
                    if self?.isResultDiscarded ?? true { throw VoiceStaleCall() }
                    before = loaded
                    let end = try VoiceTemplateState.endOfCall(loaded, call, cfg.state)
                    result = end
                    return end.record
                }
                guard let end = result else { throw VoiceStateError(message: "no result of the end of the call") }
                return VoiceFinish(before: before, end: end)
            }
            let info = VoiceCallInfo(
                callId: binding.callId, ownerOn: true, model: ready.model, record: record, tStartS: binding.tStartS,
                utcOffsetS: binding.utcOffsetS, deviceTag: tag, display: nil, ownerTemplate: Self.usableOwnerTemplate(process.ownerTemplate()),
                deviceKnown: deviceKnown)
            let listener = VoiceSessionEffectListener(
                contactId: contactId, services: services, process: process, generation: startedGeneration)
            let built = try VoiceEngine(
                config: cfg, call: info, vad: ready.vad, embedder: ready.embedder ?? UnavailableEmbedder(), budget: budget,
                finalizer: finalizer, listener: listener)
            mediaStartNs = now
            engine = built
            engineRan = true
            lock.lock()
            engineForCancel = built
            let cancel = cancelRequested
            let replayFallback = fallbackSeen
            let heldAtStart = holdNow
            lock.unlock()
            lastAt = now
            // Tier 0 until the trust inputs exist (`reportTier`, once the peer's key confirmation verified and the call has its
            // protection line): nothing is learned and nothing is shown as Matches.
            built.feed(.mediaStart(atNs: now, tNs: now, tierInput: nil))
            if replayFallback { built.feed(.path(atNs: stamped(now), path: .dc)) }
            // A call that is on hold when the engine starts begins as held (the hold hooks pass changes only).
            if heldAtStart {
                lastHold = true
                holdEventsFed += 1
                built.feed(.hold(atNs: stamped(now), held: true))
            }
            if cancel { built.requestPostCancel() }
            let early = pendingVcons
            pendingVcons = []
            for (v, wallS) in early { built.feed(.vcons(atNs: stamped(now), vcons: v, wallS: wallS)) }
            let t = makeTicker()
            ticker = t
            t.start(everyMs: 1000, queue: queue) { [weak self] in self?.pollTick() }
        } catch {
            gaveUp = true
        }
    }

    /// The owner template is read only for a diagnostic counter: a vector that is not a finite unit vector of the embedding size is
    /// not used at all.
    static func usableOwnerTemplate(_ t: [Float]?) -> [Float]? {
        guard let t, t.count == 512, t.allSatisfy({ $0.isFinite }) else { return nil }
        let norm = t.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return abs(norm - 1) <= 0.01 ? t : nil
    }

    private func drainRx() {
        let blocks = rxQueue.drain()
        guard engine != nil else { return }
        // While the protected data is unreadable (the phone is locked) the speech model is not run: the blocks are let go, and the
        // engine sees the gap in the tap position as dropped blocks.
        guard protectedData.isAvailable else {
            heldBackBlocks += blocks.count
            return
        }
        for b in blocks where b.tNs >= mediaStartNs {
            VoiceStatsTraceHook.tap(tNs: b.tNs, ticks: b.ticks)
            feed(.rx(atNs: stamped(b.tNs), tNs: b.tNs, rateHz: b.rateHz, ticks: b.ticks, pcm: b.pcm, dropped: b.dropped))
            fedBlocks += 1
        }
    }

    private func pollTick() {
        guard engine != nil, !isEnded else { return }
        guard protectedData.isAvailable, governor.decide().run else {
            heldBackPolls += 1
            return
        }
        guard pollsInFlight < 3 else { return }
        lock.lock()
        let s = source
        lock.unlock()
        guard let s else { return }
        pollsInFlight += 1
        s.pollOnce { [weak self] result in
            guard let self else { return }
            self.queue.async { self.pollArrived(result) }
        }
    }

    private func pollArrived(_ result: VoicePollResult) {
        pollsInFlight = max(0, pollsInFlight - 1)
        guard engine != nil else { return }
        drainRx()
        switch result {
        case .snapshot(let snapshot):
            VoiceStatsTraceHook.snapshot(snapshot)
            feed(.stats(atNs: stamped(snapshot.arriveNs), snapshot: snapshot))
        case .fault:
            feed(.audioFault(atNs: stamped(clock())))
        case .unavailable:
            break
        }
    }

    private func finish(_ now: Int64, hold: VoiceTaskHold?) {
        ticker?.stop()
        ticker = nil
        var summary: VoiceCallSummary?
        lock.lock()
        let dropped = engineDiscarded
        lock.unlock()
        if let e = engine, !dropped {
            drainRx()
            e.feed(.callEnd(atNs: stamped(now), tNs: now))
            e.close()
            summary = e.summary
        }
        hold?.end()
        lock.lock()
        engineForCancel = nil
        let keepResult = !(resultDiscarded || engineDiscarded)
        lock.unlock()
        engine = nil
        process.forget(self)
        process.showDisplay(nil)
        if prepared {
            prepared = false
            releaseModels?()
            releaseModels = nil
            process.services.callFinished()
        }
        // The id-free daily counters: what this call adds, and the lines of the days that are over and due.
        if let summary, keepResult {
            let nowS = Int(Date().timeIntervalSince1970)
            let offset = TimeZone.current.secondsFromGMT()
            process.daily.record(
                VoiceDailyCall(summary: summary, contactId: binding.contactId, endS: nowS, utcOffsetS: offset), ifEpoch: dailyEpoch)
        }
        if engineRan {
            let nowS = Int(Date().timeIntervalSince1970)
            for line in process.daily.dueLines(nowS: nowS, utcOffsetS: TimeZone.current.secondsFromGMT()) {
                process.emitDailyLine(line)
            }
        }
    }

}

/// The effect of the engine: the peer withdrew its consent and the record is deleted under the store's lock.
final class VoiceSessionEffectListener: VoiceEngineListener {
    private let contactId: String
    private let services: VoiceServices
    private let process: VoiceProcess?
    /// The wipe generation the call began with (nil: the one at the time of the effect).
    private let generation: Int?

    init(contactId: String, services: VoiceServices, process: VoiceProcess? = nil, generation: Int? = nil) {
        self.contactId = contactId
        self.services = services
        self.process = process
        self.generation = generation
    }

    /// A per-call line of the log: the process writes it only for an account that has the diagnostic flag.
    func onLine(_ tNs: Int64, _ line: String) {
        process?.emitCallLine(line)
    }

    /// The state of the voice card.
    func onTransition(_ transition: VoiceTransition) {
        process?.showDisplay(VoiceCheckDisplay(shown: transition.shown, detail: transition.detail))
    }

    func onEffect(_ tNs: Int64, _ effect: VoiceEffect) {
        switch effect {
        case .deleteRecord:
            try? services.deleteRecord(contactId: contactId, generation: generation ?? services.generation)
        }
    }
}
