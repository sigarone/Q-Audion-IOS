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
        lock.unlock()
        if replay { newSession.pathFallback() }
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

    // Shared with other threads.
    private let lock = NSLock()
    private var fallbackSeen = false
    private var cancelRequested = false
    private var ended = false
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

    /// Polls that the lock or the CPU governor held back, and RX blocks that went on to the engine (diagnostics and tests).
    private(set) var heldBackPolls = 0
    private(set) var fedBlocks = 0
    private(set) var heldBackBlocks = 0

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
    func mediaStart() {
        let now = clock()
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

    func holdChanged(_ held: Bool) {
        let now = clock()
        queue.async { [self] in
            guard engine != nil else { return }
            feed(.hold(atNs: stamped(now), held: held))
        }
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
        let token = process.backgroundTasks.begin(name: "voice-post-call", onExpiration: { [weak self] in self?.requestPostCancel() })
        queue.async { [self] in finish(now, token: token) }
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
        guard engine == nil, !gaveUp, !isEnded, VoiceFeature.isEnabled else { return }
        guard let ready = process.services.prepare() else {
            gaveUp = true
            return
        }
        prepared = true
        let services = process.services
        do {
            let cfg = ready.config
            let record = try services.loadRecord(contactId: binding.contactId, cfg: cfg.state)
            let tag = try services.deviceTag(deviceId: binding.peerDeviceId ?? "")
            guard let budget = services.budget else {
                gaveUp = true
                return
            }
            let contactId = binding.contactId
            let finalizer: VoiceCallFinalizer = { _, call in
                var before: TemplateRecord?
                var result: CallEnd?
                try services.update(contactId: contactId, cfg: cfg.state) { loaded in
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
                utcOffsetS: binding.utcOffsetS, deviceTag: tag, display: nil, ownerTemplate: nil)
            let listener = VoiceSessionEffectListener(contactId: contactId, services: services)
            let built = try VoiceEngine(
                config: cfg, call: info, vad: ready.vad, embedder: ready.embedder ?? UnavailableEmbedder(), budget: budget,
                finalizer: finalizer, listener: listener)
            mediaStartNs = now
            engine = built
            lock.lock()
            engineForCancel = built
            let cancel = cancelRequested
            let replayFallback = fallbackSeen
            lock.unlock()
            lastAt = now
            // Tier 0 until the trust inputs exist: nothing is learned and nothing is shown as Matches.
            built.feed(.mediaStart(atNs: now, tNs: now, tierInput: nil))
            if replayFallback { built.feed(.path(atNs: stamped(now), path: .dc)) }
            if cancel { built.requestPostCancel() }
            let t = makeTicker()
            ticker = t
            t.start(everyMs: 1000, queue: queue) { [weak self] in self?.pollTick() }
        } catch {
            gaveUp = true
        }
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

    private func finish(_ now: Int64, token: Int?) {
        ticker?.stop()
        ticker = nil
        if let e = engine {
            drainRx()
            e.feed(.callEnd(atNs: stamped(now), tNs: now))
            e.close()
        }
        if let token { process.backgroundTasks.end(token) }
        lock.lock()
        engineForCancel = nil
        lock.unlock()
        engine = nil
        process.forget(self)
        if prepared {
            prepared = false
            process.services.callFinished()
        }
    }

}

/// The effect of the engine: the peer withdrew its consent and the record is deleted under the store's lock.
final class VoiceSessionEffectListener: VoiceEngineListener {
    private let contactId: String
    private let services: VoiceServices

    init(contactId: String, services: VoiceServices) {
        self.contactId = contactId
        self.services = services
    }

    func onEffect(_ tNs: Int64, _ effect: VoiceEffect) {
        switch effect {
        case .deleteRecord:
            try? services.deleteRecord(contactId: contactId)
        }
    }
}
