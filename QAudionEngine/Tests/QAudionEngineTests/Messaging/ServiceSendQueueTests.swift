import XCTest
@testable import QAudionEngine

/// 2026-09-19 service-message root fix — pins the bounded per-peer hold queue
/// (cap, TTL, order) and the coordinator rules around it (hold vs best-effort,
/// flush in order, stop the round on failure, ensure-session throttle).
final class ServiceSendQueueTests: XCTestCase {

    private func entry(_ peer: String = "peerA", label: String = "x", at ms: Int64 = 0) -> ServiceSendQueue.Entry {
        ServiceSendQueue.Entry(id: UUID(), peerId: peer, plaintext: "{\"qa_ctl\":1}", label: label, enqueuedAtMs: ms)
    }

    func test_constants_matchTheContract() {
        XCTAssertEqual(ServiceSendQueue.capPerPeer, 64)
        XCTAssertEqual(ServiceSendQueue.ttlMs, 10 * 60 * 1000)
    }

    func test_enqueue_keepsFifoOrderPerPeer() {
        var q = ServiceSendQueue()
        let a = entry(), b = entry(), c = entry()
        q.enqueue(a); q.enqueue(b); q.enqueue(c)
        XCTAssertEqual(q.entries(peerId: "peerA").map { $0.id }, [a.id, b.id, c.id])
        XCTAssertEqual(q.first(peerId: "peerA")?.id, a.id)
        XCTAssertEqual(q.totalCount, 3)
    }

    func test_peersAreIsolated_andListedSorted() {
        var q = ServiceSendQueue()
        q.enqueue(entry("zed")); q.enqueue(entry("alpha")); q.enqueue(entry("alpha"))
        XCTAssertEqual(q.peerIds(), ["alpha", "zed"])
        XCTAssertEqual(q.count(peerId: "alpha"), 2)
        XCTAssertEqual(q.count(peerId: "zed"), 1)
        XCTAssertEqual(q.count(peerId: "nobody"), 0)
    }

    func test_cap_dropsTheOldest_andReportsIt() {
        var q = ServiceSendQueue()
        let first = entry()
        XCTAssertNil(q.enqueue(first))
        for _ in 1..<ServiceSendQueue.capPerPeer {
            XCTAssertNil(q.enqueue(entry()))
        }
        XCTAssertEqual(q.count(peerId: "peerA"), 64)
        let overflow = entry()
        let dropped = q.enqueue(overflow)
        XCTAssertEqual(dropped?.id, first.id)
        XCTAssertEqual(q.count(peerId: "peerA"), 64)
        XCTAssertFalse(q.contains(id: first.id))
        XCTAssertEqual(q.entries(peerId: "peerA").last?.id, overflow.id)
    }

    func test_cap_isPerPeer() {
        var q = ServiceSendQueue()
        for _ in 0..<ServiceSendQueue.capPerPeer { q.enqueue(entry("a")) }
        XCTAssertNil(q.enqueue(entry("b")))
        XCTAssertEqual(q.count(peerId: "a"), 64)
        XCTAssertEqual(q.count(peerId: "b"), 1)
    }

    func test_ttl_dropsAtExactlyTheBoundary_notBefore() {
        var q = ServiceSendQueue()
        let old = entry(at: 1_000)
        q.enqueue(old)
        XCTAssertTrue(q.purgeExpired(nowMs: 1_000 + ServiceSendQueue.ttlMs - 1).isEmpty)
        XCTAssertEqual(q.totalCount, 1)
        let expired = q.purgeExpired(nowMs: 1_000 + ServiceSendQueue.ttlMs)
        XCTAssertEqual(expired.map { $0.id }, [old.id])
        XCTAssertEqual(q.totalCount, 0)
        XCTAssertTrue(q.peerIds().isEmpty)
    }

    func test_ttl_keepsTheFreshOnes() {
        var q = ServiceSendQueue()
        let old = entry(at: 0)
        let fresh = entry(at: ServiceSendQueue.ttlMs)
        q.enqueue(old); q.enqueue(fresh)
        let expired = q.purgeExpired(nowMs: ServiceSendQueue.ttlMs + 5)
        XCTAssertEqual(expired.map { $0.id }, [old.id])
        XCTAssertEqual(q.entries(peerId: "peerA").map { $0.id }, [fresh.id])
    }

    func test_remove_andRemoveAll() {
        var q = ServiceSendQueue()
        let a = entry(), b = entry()
        q.enqueue(a); q.enqueue(b)
        q.remove(peerId: "peerA", id: a.id)
        XCTAssertEqual(q.entries(peerId: "peerA").map { $0.id }, [b.id])
        q.removeAll(peerId: "peerA")
        XCTAssertEqual(q.totalCount, 0)
    }

    func test_enqueue_sameIdTwice_isIdempotent() {
        var q = ServiceSendQueue()
        let a = entry()
        q.enqueue(a)
        XCTAssertNil(q.enqueue(a))
        XCTAssertEqual(q.count(peerId: "peerA"), 1)
    }
}

/// The coordinator on fakes: no socket, no ratchet, no clock.
@MainActor
final class ServiceSendCoordinatorTests: XCTestCase {

    /// Mutable world the hooks read and write.
    private final class World {
        var now: Int64 = 1_000_000
        var hasControl = false
        var socketReady = true
        var result: ServiceSendCoordinator.SendResult = .sent
        /// Per-plaintext override of `result`, so one entry can fail while the rest go out.
        var resultFor: [String: ServiceSendCoordinator.SendResult] = [:]
        var ensureCalls: [String] = []
        var shipped: [ServiceSendQueue.Entry] = []
        var attempts = 0
        var logs: [String] = []
    }

    private func make(_ world: World) -> ServiceSendCoordinator {
        let hooks = ServiceSendCoordinator.Hooks(
            nowMs: { world.now },
            hasControlSession: { _ in world.hasControl },
            isSocketReady: { world.socketReady },
            ensureSession: { peer in world.ensureCalls.append(peer) },
            sealAndSend: { entry in
                world.attempts += 1
                let result = world.resultFor[entry.plaintext] ?? world.result
                if result == .sent { world.shipped.append(entry) }
                return result
            },
            log: { line in world.logs.append(line) }
        )
        return ServiceSendCoordinator(hooks: hooks, autoTick: false)
    }

    func test_holdWithoutControlSession_holdsAndNudgesEnsure() async {
        let w = World()
        let c = make(w)
        let s = await c.submit(peerId: "p", plaintext: "a", label: "l", delivery: .hold)
        XCTAssertEqual(s, .held)
        XCTAssertEqual(c.pendingCount, 1)
        XCTAssertEqual(w.ensureCalls, ["p"])
        XCTAssertEqual(w.attempts, 0, "nothing may be sealed without a CONTROL session")
    }

    func test_holdWithControlAndSocket_sendsImmediately() async {
        let w = World()
        w.hasControl = true
        let c = make(w)
        let s = await c.submit(peerId: "p", plaintext: "a", label: "l", delivery: .hold)
        XCTAssertEqual(s, .sent)
        XCTAssertEqual(c.pendingCount, 0)
        XCTAssertEqual(w.shipped.map { $0.plaintext }, ["a"])
    }

    func test_flushAfterControlInstall_shipsInSubmissionOrder() async {
        let w = World()
        let c = make(w)
        for text in ["1", "2", "3"] {
            _ = await c.submit(peerId: "p", plaintext: text, label: "l", delivery: .hold)
        }
        XCTAssertEqual(c.pendingCount, 3)
        w.hasControl = true
        await c.flush(peerId: "p")
        XCTAssertEqual(w.shipped.map { $0.plaintext }, ["1", "2", "3"])
        XCTAssertEqual(c.pendingCount, 0)
    }

    func test_newSubmissionQueuesBehindHeldOnes_orderIsPreserved() async {
        let w = World()
        let c = make(w)
        _ = await c.submit(peerId: "p", plaintext: "old", label: "l", delivery: .hold)
        w.hasControl = true
        let s = await c.submit(peerId: "p", plaintext: "new", label: "l", delivery: .hold)
        XCTAssertEqual(s, .sent)
        XCTAssertEqual(w.shipped.map { $0.plaintext }, ["old", "new"])
    }

    func test_socketDown_holdsWithoutSealing() async {
        let w = World()
        w.hasControl = true
        w.socketReady = false
        let c = make(w)
        let s = await c.submit(peerId: "p", plaintext: "a", label: "l", delivery: .hold)
        XCTAssertEqual(s, .held)
        XCTAssertEqual(w.attempts, 0, "a ratchet step must not be burned with no socket")
        w.socketReady = true
        await c.flush(peerId: "p")
        XCTAssertEqual(w.shipped.map { $0.plaintext }, ["a"])
    }

    func test_failedSend_stopsTheRound_andKeepsTheRestInOrder() async {
        let w = World()
        w.hasControl = true
        w.result = .transportDown
        let c = make(w)
        _ = await c.submit(peerId: "p", plaintext: "A", label: "l", delivery: .hold)
        _ = await c.submit(peerId: "p", plaintext: "B", label: "l", delivery: .hold)
        XCTAssertEqual(w.attempts, 2, "one attempt per submit, and B never overtakes A")
        XCTAssertEqual(c.pendingCount, 2)
        w.attempts = 0
        w.result = .sent
        await c.flush(peerId: "p")
        XCTAssertEqual(w.shipped.map { $0.plaintext }, ["A", "B"])
        XCTAssertEqual(c.pendingCount, 0)
    }

    func test_oneFailedSendInARound_doesNotAttemptTheNextEntry() async {
        let w = World()
        let c = make(w)
        for text in ["A", "B", "C"] {
            _ = await c.submit(peerId: "p", plaintext: text, label: "l", delivery: .hold)
        }
        w.hasControl = true
        w.result = .failed
        w.attempts = 0
        await c.flush(peerId: "p")
        XCTAssertEqual(w.attempts, 1)
        XCTAssertEqual(c.pendingCount, 3)
    }

    func test_expiredEntry_isDroppedWithAWarning_andNeverSent() async {
        let w = World()
        let c = make(w)
        _ = await c.submit(peerId: "p", plaintext: "a", label: "reaction", delivery: .hold)
        w.now += ServiceSendQueue.ttlMs
        w.hasControl = true
        await c.flush(peerId: "p")
        XCTAssertEqual(w.attempts, 0)
        XCTAssertEqual(c.pendingCount, 0)
        XCTAssertTrue(w.logs.contains { $0.contains("ttl=1") && $0.contains("reaction") })
    }

    func test_capOverflow_dropsTheOldestWithAWarning() async {
        let w = World()
        let c = make(w)
        for i in 0...ServiceSendQueue.capPerPeer {
            _ = await c.submit(peerId: "p", plaintext: "m\(i)", label: "l", delivery: .hold)
        }
        XCTAssertEqual(c.heldCount(peerId: "p"), ServiceSendQueue.capPerPeer)
        XCTAssertEqual(w.logs.filter { $0.contains("cap=1") }.count, 1)
        w.hasControl = true
        await c.flush(peerId: "p")
        XCTAssertEqual(w.shipped.first?.plaintext, "m1", "m0 was the oldest and was dropped")
        XCTAssertEqual(w.shipped.count, ServiceSendQueue.capPerPeer)
    }

    func test_bestEffort_isDroppedNotHeld_whenThereIsNoControlSession() async {
        let w = World()
        let c = make(w)
        let s = await c.submit(peerId: "p", plaintext: "a", label: "mesh_receipt", delivery: .bestEffort)
        XCTAssertEqual(s, .dropped)
        XCTAssertEqual(c.pendingCount, 0)
        XCTAssertEqual(w.attempts, 0)
        XCTAssertEqual(w.ensureCalls, ["p"], "the session is still nudged so the next one can go")
    }

    func test_bestEffort_sendsWhenPossible_andDropsOnFailure() async {
        let w = World()
        w.hasControl = true
        let c = make(w)
        let ok = await c.submit(peerId: "p", plaintext: "a", label: "l", delivery: .bestEffort)
        XCTAssertEqual(ok, .sent)
        w.result = .failed
        let failed = await c.submit(peerId: "p", plaintext: "b", label: "l", delivery: .bestEffort)
        XCTAssertEqual(failed, .dropped)
        XCTAssertEqual(c.pendingCount, 0)
    }

    func test_ensureSession_isNudgedAtMostEvery15Seconds() async {
        let w = World()
        let c = make(w)
        _ = await c.submit(peerId: "p", plaintext: "1", label: "l", delivery: .hold)
        _ = await c.submit(peerId: "p", plaintext: "2", label: "l", delivery: .hold)
        XCTAssertEqual(w.ensureCalls.count, 1)
        w.now += ServiceSendCoordinator.ensureIntervalMs - 1
        _ = await c.submit(peerId: "p", plaintext: "3", label: "l", delivery: .hold)
        XCTAssertEqual(w.ensureCalls.count, 1)
        w.now += 1
        _ = await c.submit(peerId: "p", plaintext: "4", label: "l", delivery: .hold)
        XCTAssertEqual(w.ensureCalls.count, 2)
    }

    func test_peersAreFlushedIndependently() async {
        let w = World()
        let c = make(w)
        _ = await c.submit(peerId: "a", plaintext: "for-a", label: "l", delivery: .hold)
        _ = await c.submit(peerId: "b", plaintext: "for-b", label: "l", delivery: .hold)
        w.hasControl = true
        await c.flush(peerId: "b")
        XCTAssertEqual(w.shipped.map { $0.plaintext }, ["for-b"])
        XCTAssertEqual(c.heldCount(peerId: "a"), 1)
    }

    func test_tick_flushesEverythingAndReportsWhatRemains() async {
        let w = World()
        let c = make(w)
        _ = await c.submit(peerId: "a", plaintext: "1", label: "l", delivery: .hold)
        _ = await c.submit(peerId: "b", plaintext: "2", label: "l", delivery: .hold)
        var more = await c.tick()
        XCTAssertTrue(more, "no CONTROL session yet: still held")
        w.hasControl = true
        more = await c.tick()
        XCTAssertFalse(more)
        XCTAssertEqual(Set(w.shipped.map { $0.plaintext }), ["1", "2"])
    }

    func test_replaceHooks_keepsTheHeldQueue() async {
        let w = World()
        let c = make(w)
        _ = await c.submit(peerId: "p", plaintext: "a", label: "l", delivery: .hold)
        let w2 = World()
        w2.hasControl = true
        c.replaceHooks(ServiceSendCoordinator.Hooks(
            nowMs: { w2.now },
            hasControlSession: { _ in w2.hasControl },
            isSocketReady: { w2.socketReady },
            ensureSession: { _ in },
            sealAndSend: { entry in
                w2.shipped.append(entry)
                return .sent
            },
            log: { _ in }
        ))
        await c.flush(peerId: "p")
        XCTAssertEqual(w2.shipped.map { $0.plaintext }, ["a"])
    }

    // MARK: - reset (logout / wipe / account switch)

    func test_reset_dropsEverythingHeld_soNothingFlushesUnderTheNextAccount() async {
        let w = World()
        let c = make(w)
        _ = await c.submit(peerId: "p", plaintext: "seed", label: "group_ctl", delivery: .hold)
        _ = await c.submit(peerId: "q", plaintext: "nack", label: "decrypt_nack", delivery: .hold)
        XCTAssertEqual(c.pendingCount, 2)
        c.reset()
        XCTAssertEqual(c.pendingCount, 0)
        w.hasControl = true
        await c.flush(peerId: "p")
        await c.flush(peerId: "q")
        _ = await c.tick()
        XCTAssertTrue(w.shipped.isEmpty, "a payload of the previous account is never sent under the next one")
        XCTAssertEqual(w.attempts, 0)
    }

    func test_reset_forgetsTheEnsureThrottle() async {
        let w = World()
        let c = make(w)
        _ = await c.submit(peerId: "p", plaintext: "a", label: "l", delivery: .hold)
        XCTAssertEqual(w.ensureCalls.count, 1)
        c.reset()
        _ = await c.submit(peerId: "p", plaintext: "b", label: "l", delivery: .hold)
        XCTAssertEqual(w.ensureCalls.count, 2, "the clock did not move: only reset() can have cleared the 15 s throttle")
    }

    func test_reset_leavesTheCoordinatorUsable() async {
        let w = World()
        w.hasControl = true
        let c = make(w)
        c.reset()
        let s = await c.submit(peerId: "p", plaintext: "fresh", label: "l", delivery: .hold)
        XCTAssertEqual(s, .sent)
        XCTAssertEqual(w.shipped.map { $0.plaintext }, ["fresh"])
    }

    // MARK: - poison head

    func test_poisonHead_isDroppedAfterThreeFailures_andTheNextEntryGoesOut() async {
        let w = World()
        w.hasControl = true
        w.resultFor["poison"] = .failed
        let c = make(w)
        _ = await c.submit(peerId: "p", plaintext: "poison", label: "reaction", delivery: .hold)
        _ = await c.submit(peerId: "p", plaintext: "next", label: "l", delivery: .hold)
        XCTAssertEqual(c.pendingCount, 2)
        XCTAssertTrue(w.shipped.isEmpty, "while it is still counted the failing head blocks the entry behind it")
        XCTAssertEqual(w.attempts, 2)
        await c.flush(peerId: "p")
        XCTAssertEqual(w.shipped.map { $0.plaintext }, ["next"])
        XCTAssertEqual(c.pendingCount, 0)
        XCTAssertTrue(w.logs.contains { $0.contains("reason=poison") && $0.contains("reaction") })
    }

    func test_transportDownAndNoControlSession_neverCountAsPoison() async {
        let w = World()
        w.hasControl = true
        w.result = .transportDown
        let c = make(w)
        _ = await c.submit(peerId: "p", plaintext: "a", label: "l", delivery: .hold)
        for _ in 0..<(ServiceSendCoordinator.poisonFailureLimit + 2) {
            await c.flush(peerId: "p")
        }
        XCTAssertEqual(c.pendingCount, 1, "transportDown is retryable, never poison")
        w.result = .noControlSession
        for _ in 0..<(ServiceSendCoordinator.poisonFailureLimit + 2) {
            await c.flush(peerId: "p")
        }
        XCTAssertEqual(c.pendingCount, 1, "noControlSession is retryable, never poison")
        XCTAssertFalse(w.logs.contains { $0.contains("reason=poison") })
        w.result = .sent
        await c.flush(peerId: "p")
        XCTAssertEqual(w.shipped.map { $0.plaintext }, ["a"])
    }

    func test_aTransportDownBetweenFailures_neitherCountsNorResets() async {
        let w = World()
        w.hasControl = true
        w.result = .failed
        let c = make(w)
        _ = await c.submit(peerId: "p", plaintext: "a", label: "l", delivery: .hold)
        await c.flush(peerId: "p")
        w.result = .transportDown
        await c.flush(peerId: "p")
        XCTAssertEqual(c.pendingCount, 1)
        w.result = .failed
        await c.flush(peerId: "p")
        XCTAssertEqual(c.pendingCount, 0, "the third .failed drops it: the transportDown in between changed nothing")
        XCTAssertTrue(w.logs.contains { $0.contains("reason=poison") })
    }

    func test_failureCounter_isPerEntry_andGoneOnceTheEntryIsSent() async {
        let w = World()
        w.hasControl = true
        w.result = .failed
        let c = make(w)
        _ = await c.submit(peerId: "p", plaintext: "a", label: "l", delivery: .hold)
        await c.flush(peerId: "p")
        w.result = .sent
        await c.flush(peerId: "p")
        XCTAssertEqual(w.shipped.map { $0.plaintext }, ["a"])
        // A different entry starts from zero: two failures are below the limit.
        w.result = .failed
        _ = await c.submit(peerId: "p", plaintext: "b", label: "l", delivery: .hold)
        await c.flush(peerId: "p")
        XCTAssertEqual(c.pendingCount, 1)
        XCTAssertFalse(w.logs.contains { $0.contains("reason=poison") })
    }
}
