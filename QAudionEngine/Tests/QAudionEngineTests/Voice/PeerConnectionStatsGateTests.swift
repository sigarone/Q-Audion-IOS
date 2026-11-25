import XCTest
import Foundation
@testable import QAudionEngine

/// The registry of the statistics calls of one connection: the stamps of a request, `oldestNs` when callers overlap, and the
/// rules of the registration (released by the native callback only; dropped by `close`). The native call is faked: the test
/// holds its callback and decides when it comes, so no test waits for time.
final class PeerConnectionStatsGateTests: XCTestCase {
    /// A clock that moves only when the test says so, one value per reading.
    private final class Clock {
        private let lock = NSLock()
        private var now: Int64 = 0

        func set(_ t: Int64) {
            lock.lock()
            now = t
            lock.unlock()
        }

        func read() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            return now
        }
    }

    /// The native side of one fake request: its callback, to be called when the test wants the answer.
    private final class Pending {
        var answer: ((Int) -> Void)?
    }

    private func ask(_ gate: PeerConnectionStatsGate, _ pending: Pending,
                     into stamps: @escaping (PeerConnectionStatsGate.Stamp) -> Void) {
        gate.request(native: { (done: @escaping (Int) -> Void) in
            pending.answer = done
        }, completion: { _, stamp in stamps(stamp) })
    }

    func testAloneARequestIsItsOwnOldest() {
        let clock = Clock()
        let gate = PeerConnectionStatsGate(clock: clock.read)
        let a = Pending()
        var got: PeerConnectionStatsGate.Stamp?
        clock.set(1_000)
        ask(gate, a) { got = $0 }
        XCTAssertEqual(gate.outstandingCount, 1)
        clock.set(1_400)
        a.answer?(7)
        XCTAssertEqual(got, PeerConnectionStatsGate.Stamp(reqNs: 1_000, arriveNs: 1_400, oldestNs: 1_000))
        XCTAssertEqual(gate.outstandingCount, 0)
    }

    func testTwoCallersThatOverlapSeeTheOldestOutstandingRequest() {
        let clock = Clock()
        let gate = PeerConnectionStatsGate(clock: clock.read)
        let a = Pending()
        let b = Pending()
        let c = Pending()
        var sa: PeerConnectionStatsGate.Stamp?
        var sb: PeerConnectionStatsGate.Stamp?
        var sc: PeerConnectionStatsGate.Stamp?
        clock.set(100)
        ask(gate, a) { sa = $0 }
        clock.set(250)
        ask(gate, b) { sb = $0 } // A is still outstanding: B's oldest is A's request
        clock.set(300)
        a.answer?(1)
        clock.set(320)
        ask(gate, c) { sc = $0 } // A is answered, B is not: C's oldest is B's request
        clock.set(400)
        b.answer?(2)
        clock.set(450)
        c.answer?(3)
        XCTAssertEqual(sa, PeerConnectionStatsGate.Stamp(reqNs: 100, arriveNs: 300, oldestNs: 100))
        XCTAssertEqual(sb, PeerConnectionStatsGate.Stamp(reqNs: 250, arriveNs: 400, oldestNs: 100))
        XCTAssertEqual(sc, PeerConnectionStatsGate.Stamp(reqNs: 320, arriveNs: 450, oldestNs: 250))
        XCTAssertEqual(gate.outstandingCount, 0)
    }

    func testARequestThatIsNeverAnsweredStaysRegisteredAndKeepsOldestOld() {
        let clock = Clock()
        let gate = PeerConnectionStatsGate(clock: clock.read)
        let lost = Pending()
        let next = Pending()
        var stamp: PeerConnectionStatsGate.Stamp?
        clock.set(10)
        ask(gate, lost) { _ in XCTFail("the lost request is never answered") }
        clock.set(5_000_000_000)
        ask(gate, next) { stamp = $0 }
        next.answer?(1)
        // No timeout releases the registration: oldest stays at the lost request, so the interval is unknown, never wrong.
        XCTAssertEqual(stamp?.oldestNs, 10)
        XCTAssertEqual(gate.outstandingCount, 1)
    }

    func testTheRequestStampIsTakenInsideTheLockBeforeTheNativeCall() {
        let clock = Clock()
        let gate = PeerConnectionStatsGate(clock: clock.read)
        var registeredWhenTheNativeCallRan = -1
        clock.set(42)
        gate.request(native: { (done: @escaping (Int) -> Void) in
            registeredWhenTheNativeCallRan = gate.outstandingCount
            clock.set(99)
            done(0)
        }, completion: { _, stamp in
            XCTAssertEqual(stamp.reqNs, 42)
            XCTAssertEqual(stamp.arriveNs, 99)
            XCTAssertEqual(stamp.oldestNs, 42)
        })
        XCTAssertEqual(registeredWhenTheNativeCallRan, 1, "the request is registered before the native call is issued")
    }

    func testTheAnswerIsDeliveredOnTheThreadOfTheNativeCallback() {
        let gate = PeerConnectionStatsGate()
        let delivered = expectation(description: "delivered")
        let native = DispatchQueue(label: "test.native.callback")
        var nativeLabel = ""
        var deliveredLabel = ""
        gate.request(native: { (done: @escaping (Int) -> Void) in
            native.async {
                nativeLabel = String(cString: __dispatch_queue_get_label(nil))
                done(1)
            }
        }, completion: { _, _ in
            deliveredLabel = String(cString: __dispatch_queue_get_label(nil))
            delivered.fulfill()
        })
        wait(for: [delivered], timeout: 10)
        XCTAssertEqual(deliveredLabel, nativeLabel, "the gate adds no hop")
        XCTAssertEqual(nativeLabel, "test.native.callback")
    }

    func testACloseDropsTheRegistryAndALateAnswerStillArrives() {
        let clock = Clock()
        let gate = PeerConnectionStatsGate(clock: clock.read)
        let a = Pending()
        var got: PeerConnectionStatsGate.Stamp?
        clock.set(5)
        ask(gate, a) { got = $0 }
        gate.close()
        XCTAssertEqual(gate.outstandingCount, 0)
        let after = Pending()
        clock.set(8)
        ask(gate, after) { _ in }
        XCTAssertEqual(gate.outstandingCount, 0, "a closed connection registers nothing")
        clock.set(9)
        a.answer?(1)
        XCTAssertEqual(got?.reqNs, 5)
        XCTAssertEqual(got?.arriveNs, 9)
        XCTAssertEqual(gate.outstandingCount, 0)
    }

    func testTheTwoSelectorCallsOfAPollMakeOneSnapshot() {
        let receiver = PeerConnectionStatsGate.Stamp(reqNs: 100, arriveNs: 180, oldestNs: 90)
        let sender = PeerConnectionStatsGate.Stamp(reqNs: 110, arriveNs: 260, oldestNs: 100)
        let one = PeerConnectionStatsGate.combine(receiver, sender)
        XCTAssertEqual(one, PeerConnectionStatsGate.Stamp(reqNs: 100, arriveNs: 260, oldestNs: 90))
        XCTAssertEqual(PeerConnectionStatsGate.combine(sender, receiver), one)
    }

    /// Many callers on several queues at once: every stamp keeps `oldest <= req <= arrive` and nothing stays registered.
    func testManyCallersOnSeveralQueuesKeepTheOrderOfTheStamps() {
        let gate = PeerConnectionStatsGate()
        let queues = (0..<4).map { DispatchQueue(label: "test.gate.\($0)") }
        let group = DispatchGroup()
        let lock = NSLock()
        var bad = 0
        var answered = 0
        for q in queues {
            for _ in 0..<250 {
                group.enter()
                q.async {
                    gate.request(native: { (done: @escaping (Int) -> Void) in
                        DispatchQueue.global().async { done(1) }
                    }, completion: { _, stamp in
                        lock.lock()
                        if !(stamp.oldestNs <= stamp.reqNs && stamp.reqNs <= stamp.arriveNs) { bad += 1 }
                        answered += 1
                        lock.unlock()
                        group.leave()
                    })
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(bad, 0)
        XCTAssertEqual(answered, 1000)
        XCTAssertEqual(gate.outstandingCount, 0)
    }
}
