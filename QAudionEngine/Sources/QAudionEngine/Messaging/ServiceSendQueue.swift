import Foundation

/// 2026-09-19 service-message root fix — bounded, in-memory, per-peer FIFO of
/// service payloads that could not be sealed on the CONTROL channel yet.
///
/// A service payload is sealed on CONTROL or not at all: with no CONTROL
/// session for the peer (or a failed v5 seal) it is NEVER sealed on the CHAT
/// ladder (v4/v3/v2/v1) — that is how a `decrypt_nack`, a reaction or a
/// sender key used to surface on the peer as an undecryptable chat message.
/// It waits here instead, and ``ServiceSendCoordinator`` flushes it, in order,
/// once a CONTROL session exists and the socket is up.
///
/// Pure value type, no clock and no I/O: the caller passes `nowMs`, so every
/// bound (cap 64 per peer, TTL 10 minutes) is pinned by `ServiceSendQueueTests`.
public struct ServiceSendQueue: Equatable, Sendable {

    public struct Entry: Equatable, Sendable {
        /// Also the `client_msg_id` the frame ships under.
        public let id: UUID
        public let peerId: String
        public let plaintext: String
        /// Short human label for logs ("decrypt_nack", "reaction", …). Never the payload.
        public let label: String
        public let enqueuedAtMs: Int64

        public init(id: UUID, peerId: String, plaintext: String, label: String, enqueuedAtMs: Int64) {
            self.id = id
            self.peerId = peerId
            self.plaintext = plaintext
            self.label = label
            self.enqueuedAtMs = enqueuedAtMs
        }
    }

    /// Oldest entries are dropped past this many per peer.
    public static let capPerPeer: Int = 64
    /// An entry older than this is dropped instead of sent.
    public static let ttlMs: Int64 = 10 * 60 * 1000

    private var byPeer: [String: [Entry]] = [:]

    public init() {}

    public var totalCount: Int {
        byPeer.values.reduce(0) { $0 + $1.count }
    }

    public func count(peerId: String) -> Int {
        byPeer[peerId]?.count ?? 0
    }

    /// Peers with at least one held entry, in a stable (sorted) order.
    public func peerIds() -> [String] {
        byPeer.keys.sorted()
    }

    public func entries(peerId: String) -> [Entry] {
        byPeer[peerId] ?? []
    }

    public func first(peerId: String) -> Entry? {
        byPeer[peerId]?.first
    }

    public func contains(id: UUID) -> Bool {
        for list in byPeer.values where list.contains(where: { $0.id == id }) {
            return true
        }
        return false
    }

    /// Appends `entry` behind everything already held for its peer. Returns
    /// the entry that was dropped to honour the cap (the oldest), if any.
    /// Re-enqueueing an id that is already held is a no-op.
    @discardableResult
    public mutating func enqueue(_ entry: Entry) -> Entry? {
        var list = byPeer[entry.peerId] ?? []
        if list.contains(where: { $0.id == entry.id }) { return nil }
        list.append(entry)
        var dropped: Entry? = nil
        if list.count > Self.capPerPeer {
            dropped = list.removeFirst()
        }
        byPeer[entry.peerId] = list
        return dropped
    }

    public mutating func remove(peerId: String, id: UUID) {
        guard var list = byPeer[peerId] else { return }
        list.removeAll(where: { $0.id == id })
        if list.isEmpty {
            byPeer.removeValue(forKey: peerId)
        } else {
            byPeer[peerId] = list
        }
    }

    public mutating func removeAll(peerId: String) {
        byPeer.removeValue(forKey: peerId)
    }

    /// Removes and returns every entry whose age is at or past ``ttlMs``.
    @discardableResult
    public mutating func purgeExpired(nowMs: Int64) -> [Entry] {
        var expired: [Entry] = []
        for peerId in byPeer.keys.sorted() {
            guard let list = byPeer[peerId] else { continue }
            var kept: [Entry] = []
            for entry in list {
                if nowMs - entry.enqueuedAtMs >= Self.ttlMs {
                    expired.append(entry)
                } else {
                    kept.append(entry)
                }
            }
            if kept.isEmpty {
                byPeer.removeValue(forKey: peerId)
            } else {
                byPeer[peerId] = kept
            }
        }
        return expired
    }
}

// MARK: - Coordinator

/// Owns one ``ServiceSendQueue`` and the rules for draining it.
///
/// - `.hold` payloads (user-initiated operations: delete/edit/reaction/
///   ephemeral timer, sender-key init & rotate, decrypt_nack) are queued when
///   they cannot go out now; `.bestEffort` payloads (avatar re-announces, mesh
///   receipts) are simply dropped instead.
/// - Whenever something is held, the platform's ensure-session mechanism is
///   nudged at most every ``ensureIntervalMs`` (the mechanism throttles
///   itself further).
/// - The queue is flushed IN ORDER once the peer has a CONTROL session AND the
///   socket is connected; the first failed send stops the round and leaves the
///   rest for the next tick.
///
/// All state is main-actor; the platform plugs in through ``Hooks`` so the
/// logic is unit-testable without a socket or a ratchet.
@MainActor
public final class ServiceSendCoordinator {

    public enum Delivery: Equatable, Sendable {
        case hold
        case bestEffort
    }

    public enum SendResult: Equatable, Sendable {
        case sent
        case noControlSession
        case transportDown
        case failed
    }

    public enum Submission: Equatable, Sendable {
        case sent
        case held
        case dropped
    }

    public typealias NowProvider = @MainActor () -> Int64
    public typealias ControlSessionCheck = @MainActor (_ peerId: String) -> Bool
    public typealias SocketReadyCheck = @MainActor () -> Bool
    public typealias SessionEnsurer = @MainActor (_ peerId: String) -> Void
    public typealias Shipper = @MainActor (_ entry: ServiceSendQueue.Entry) async -> SendResult
    public typealias LogSink = @MainActor (_ line: String) -> Void

    public struct Hooks {
        public var nowMs: NowProvider
        public var hasControlSession: ControlSessionCheck
        public var isSocketReady: SocketReadyCheck
        public var ensureSession: SessionEnsurer
        public var sealAndSend: Shipper
        public var log: LogSink

        public init(nowMs: @escaping NowProvider,
                    hasControlSession: @escaping ControlSessionCheck,
                    isSocketReady: @escaping SocketReadyCheck,
                    ensureSession: @escaping SessionEnsurer,
                    sealAndSend: @escaping Shipper,
                    log: @escaping LogSink) {
            self.nowMs = nowMs
            self.hasControlSession = hasControlSession
            self.isSocketReady = isSocketReady
            self.ensureSession = ensureSession
            self.sealAndSend = sealAndSend
            self.log = log
        }
    }

    /// Minimum spacing between ensure-session nudges for one peer.
    public static let ensureIntervalMs: Int64 = 15_000
    /// Pause between a CONTROL install and the flush it triggers, so a
    /// pre-bootstrap that installed the session locally has time to reach the
    /// wire ahead of the frames sealed on it.
    static let flushGraceNanos: UInt64 = 2_000_000_000
    /// A head entry that comes back ``SendResult/failed`` this many times is
    /// dropped (see ``flush(peerId:)``).
    public static let poisonFailureLimit: Int = 3

    private var hooks: Hooks
    private let autoTick: Bool
    private var queue = ServiceSendQueue()
    private var lastEnsureMs: [String: Int64] = [:]
    private var flushing: Set<String> = []
    private var rerun: Set<String> = []
    private var tickTask: Task<Void, Never>?
    /// `.failed` results seen per held entry; an entry leaves this map whenever
    /// it leaves the queue.
    private var failedAttempts: [UUID: Int] = [:]

    public init(hooks: Hooks, autoTick: Bool = true) {
        self.hooks = hooks
        self.autoTick = autoTick
    }

    /// The platform rebuilds its hooks whenever the provider is rebuilt; the
    /// held queue survives that.
    public func replaceHooks(_ newHooks: Hooks) {
        hooks = newHooks
    }

    /// The account these payloads belong to is gone (logout, remote wipe,
    /// account deletion). What is held is plaintext (group sender-key seeds,
    /// nacks, edits) meant for that account's peers: it must not survive into
    /// the next login, where the tick would ensure a session under the NEW
    /// identity and flush it under that identity.
    ///
    /// `flushing` is deliberately kept: a flush that is suspended inside
    /// `sealAndSend` finishes and unregisters itself, and a second flusher for
    /// the same peer must not start meanwhile (it would double-send a head).
    /// That flush now finds the empty queue and simply ends.
    public func reset() {
        queue = ServiceSendQueue()
        lastEnsureMs.removeAll()
        rerun.removeAll()
        failedAttempts.removeAll()
        tickTask?.cancel()
        tickTask = nil
    }

    public var pendingCount: Int { queue.totalCount }

    public func heldCount(peerId: String) -> Int { queue.count(peerId: peerId) }

    public func pendingIds(peerId: String) -> [UUID] {
        queue.entries(peerId: peerId).map { $0.id }
    }

    // MARK: Submit

    /// Sends `plaintext` to `peerId` on CONTROL. `.sent` — it left; `.held` —
    /// queued behind anything already held and flushed later; `.dropped` — a
    /// best-effort payload that could not go now.
    public func submit(
        peerId: String,
        plaintext: String,
        label: String,
        delivery: Delivery,
        id: UUID = UUID()
    ) async -> Submission {
        let entry = ServiceSendQueue.Entry(
            id: id, peerId: peerId, plaintext: plaintext, label: label, enqueuedAtMs: hooks.nowMs())
        if delivery == .bestEffort {
            return await sendBestEffort(entry)
        }
        purgeExpired()
        if let dropped = queue.enqueue(entry) {
            failedAttempts.removeValue(forKey: dropped.id)
            hooks.log("service_queue cap=1 dropped_oldest label=\(dropped.label) peer=\(dropped.peerId.prefix(8))")
        }
        await flush(peerId: peerId)
        return queue.contains(id: id) ? .held : .sent
    }

    private func sendBestEffort(_ entry: ServiceSendQueue.Entry) async -> Submission {
        guard hooks.hasControlSession(entry.peerId) else {
            ensureIfDue(peerId: entry.peerId)
            hooks.log("service_send dropped=1 reason=nocontrol label=\(entry.label) peer=\(entry.peerId.prefix(8))")
            return .dropped
        }
        guard hooks.isSocketReady() else {
            hooks.log("service_send dropped=1 reason=socket label=\(entry.label) peer=\(entry.peerId.prefix(8))")
            return .dropped
        }
        let result = await hooks.sealAndSend(entry)
        if result == .sent { return .sent }
        if result == .noControlSession { ensureIfDue(peerId: entry.peerId) }
        hooks.log("service_send dropped=1 reason=failed label=\(entry.label) peer=\(entry.peerId.prefix(8))")
        return .dropped
    }

    // MARK: Flush

    /// Drains the queue for `peerId` in order. Single-flight per peer: a call
    /// that arrives while a flush runs asks it to go round once more.
    ///
    /// A head entry that keeps coming back ``SendResult/failed`` (a seal that
    /// can never succeed, e.g. `encryptV5Routed` returning nil) would block
    /// every later entry for the peer until its TTL, so after
    /// ``poisonFailureLimit`` such results it is dropped with a log line and the
    /// round moves on. ``SendResult/noControlSession`` and
    /// ``SendResult/transportDown`` are retryable conditions: they are neither
    /// counted nor reset.
    public func flush(peerId: String) async {
        if flushing.contains(peerId) {
            rerun.insert(peerId)
            return
        }
        flushing.insert(peerId)
        var again = true
        while again {
            again = false
            purgeExpired()
            while let head = queue.first(peerId: peerId) {
                guard hooks.hasControlSession(peerId) else {
                    ensureIfDue(peerId: peerId)
                    break
                }
                guard hooks.isSocketReady() else { break }
                let result = await hooks.sealAndSend(head)
                if result == .sent {
                    queue.remove(peerId: peerId, id: head.id)
                    failedAttempts.removeValue(forKey: head.id)
                    continue
                }
                if result == .noControlSession { ensureIfDue(peerId: peerId) }
                if result == .failed {
                    let failures = (failedAttempts[head.id] ?? 0) + 1
                    if failures >= Self.poisonFailureLimit {
                        queue.remove(peerId: peerId, id: head.id)
                        failedAttempts.removeValue(forKey: head.id)
                        hooks.log("service_send dropped=1 reason=poison label=\(head.label) peer=\(head.peerId.prefix(8))")
                        continue
                    }
                    failedAttempts[head.id] = failures
                }
                break
            }
            if rerun.remove(peerId) != nil { again = true }
        }
        flushing.remove(peerId)
        scheduleTickIfNeeded()
    }

    /// A CONTROL session was just installed for `peerId`: flush after a short
    /// grace period (see ``flushGraceNanos``).
    public func controlSessionInstalled(peerId: String) {
        guard queue.count(peerId: peerId) > 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: ServiceSendCoordinator.flushGraceNanos)
            await self?.flush(peerId: peerId)
        }
    }

    /// The socket just authenticated: try every peer with held entries.
    public func socketBecameReady() {
        for peerId in queue.peerIds() {
            Task { [weak self] in
                await self?.flush(peerId: peerId)
            }
        }
    }

    // MARK: Tick

    /// One retry round over every held peer. `true` while anything is still held.
    @discardableResult
    public func tick() async -> Bool {
        purgeExpired()
        for peerId in queue.peerIds() {
            if !hooks.hasControlSession(peerId) { ensureIfDue(peerId: peerId) }
            await flush(peerId: peerId)
        }
        return queue.totalCount > 0
    }

    private func scheduleTickIfNeeded() {
        guard autoTick, tickTask == nil, queue.totalCount > 0 else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                // One second past the ensure interval: the sleep is monotonic, ensureIfDue reads the wall
                // clock, and a tick landing a hair early would skip the nudge for a whole extra round.
                let interval = UInt64(ServiceSendCoordinator.ensureIntervalMs + 1_000) * 1_000_000
                try? await Task.sleep(nanoseconds: interval)
                // A cancelled task (``reset()``) must end without touching `tickTask`: a
                // newer task may already own it.
                if Task.isCancelled { return }
                guard let coordinator = self else { return }
                let more = await coordinator.tick()
                if !more {
                    coordinator.tickTask = nil
                    return
                }
            }
        }
    }

    // MARK: Helpers

    private func purgeExpired() {
        let expired = queue.purgeExpired(nowMs: hooks.nowMs())
        for entry in expired {
            failedAttempts.removeValue(forKey: entry.id)
            hooks.log("service_queue ttl=1 expired label=\(entry.label) peer=\(entry.peerId.prefix(8))")
        }
    }

    private func ensureIfDue(peerId: String) {
        let now = hooks.nowMs()
        if let last = lastEnsureMs[peerId], now - last < Self.ensureIntervalMs { return }
        lastEnsureMs[peerId] = now
        hooks.ensureSession(peerId)
    }
}
