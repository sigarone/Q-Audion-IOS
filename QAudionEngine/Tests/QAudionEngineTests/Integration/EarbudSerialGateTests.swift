import XCTest
@testable import QAudionEngine

/// `EarbudSerialGate`: the operations of the one CoreBluetooth earbud client run one at a time, in order.
final class EarbudSerialGateTests: XCTestCase {

    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var maxActive = 0
        private(set) var order: [Int] = []
        func enter(_ id: Int) {
            lock.lock(); active += 1; maxActive = max(maxActive, active); order.append(id); lock.unlock()
        }
        func leave() { lock.lock(); active -= 1; lock.unlock() }
    }

    private enum Boom: Error { case boom }

    func testBodiesNeverOverlap() async {
        let gate = EarbudSerialGate()
        let tally = Tally()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<24 {
                group.addTask {
                    await gate.run {
                        tally.enter(i)
                        try? await Task.sleep(nanoseconds: 2_000_000)
                        tally.leave()
                    }
                }
            }
        }
        XCTAssertEqual(tally.maxActive, 1, "two operations on the one write/read continuation would leak one of them")
        XCTAssertEqual(Set(tally.order), Set(0..<24), "every body ran")
    }

    func testBodiesRunInTheOrderTheyAsked() async {
        let gate = EarbudSerialGate()
        let tally = Tally()
        let hold = Task {
            await gate.run {
                tally.enter(0)
                try? await Task.sleep(nanoseconds: 300_000_000)
                tally.leave()
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)   // 0 holds the gate
        var tasks: [Task<Void, Never>] = [hold]
        for i in 1...4 {
            tasks.append(Task {
                await gate.run {
                    tally.enter(i)
                    tally.leave()
                }
            })
            try? await Task.sleep(nanoseconds: 30_000_000)   // 1, 2, 3, 4 queue up in this order
        }
        for t in tasks { await t.value }
        XCTAssertEqual(tally.order, [0, 1, 2, 3, 4])
    }

    func testTheValueOfTheBodyIsReturned() async throws {
        let gate = EarbudSerialGate()
        let v: Int = await gate.run { 41 + 1 }
        XCTAssertEqual(v, 42)
    }

    func testAThrowingBodyReleasesTheGate() async {
        let gate = EarbudSerialGate()
        do {
            try await gate.run { throw Boom.boom }
            XCTFail("the error must propagate")
        } catch {
            XCTAssertEqual(error as? Boom, Boom.boom)
        }
        let ran = await gate.run { true }
        XCTAssertTrue(ran, "the next operation is not locked out by the failed one")
    }
}
