import XCTest
@testable import QAudionEngine

/// A change of media path makes the speaker-change reference stale, but path
/// reports churn: the reference is rebuilt only for a path that HOLDS, and
/// only when it differs from the one the reference was built under.
final class AcousticPathAnchorTests: XCTestCase {

    /// A scheduler the test drives by hand: it records what was scheduled and
    /// runs it, in order, when told to.
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [(delay: Double, work: @Sendable () -> Void)] = []
        private(set) var delays: [Double] = []

        var schedule: AcousticPathAnchor.Schedule {
            { [unowned self] delay, work in
                self.lock.lock()
                self.pending.append((delay, work))
                self.delays.append(delay)
                self.lock.unlock()
            }
        }

        /// Fire everything scheduled so far, in order, as the settle times pass.
        func fireAll() {
            lock.lock()
            let due = pending
            pending.removeAll()
            lock.unlock()
            for item in due { item.work() }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func makeAnchor(_ clock: ManualClock, _ count: Counter) -> AcousticPathAnchor {
        let anchor = AcousticPathAnchor(schedule: clock.schedule)
        anchor.onReanchor = { count.bump() }
        return anchor
    }

    func testAPathThatHoldsReanchorsOnceAfterTheSettleTime() {
        let clock = ManualClock()
        let count = Counter()
        let anchor = makeAnchor(clock, count)
        anchor.observe("p2p")
        anchor.anchorToCurrent()
        anchor.observe("turn")
        XCTAssertEqual(count.value, 0, "not before the path has held")
        XCTAssertEqual(clock.delays.last, AcousticPathAnchor.settleSeconds)
        XCTAssertEqual(AcousticPathAnchor.settleSeconds, 5)
        clock.fireAll()
        XCTAssertEqual(count.value, 1)
    }

    /// The same path reported again is not a change.
    func testTheSamePathAgainDoesNothing() {
        let clock = ManualClock()
        let count = Counter()
        let anchor = makeAnchor(clock, count)
        anchor.observe("p2p")
        anchor.anchorToCurrent()
        anchor.observe("p2p")
        anchor.observe("p2p")
        clock.fireAll()
        XCTAssertEqual(count.value, 0)
    }

    /// A burst that ends where it started costs nothing; a burst that ends
    /// elsewhere re-anchors once, for where it ended.
    func testABurstOfChurnReanchorsOnlyForWhereItSettles() {
        let clock = ManualClock()
        let count = Counter()
        let anchor = makeAnchor(clock, count)
        anchor.observe("p2p")
        anchor.anchorToCurrent()

        anchor.observe("turn")
        anchor.observe("p2p")
        clock.fireAll()
        XCTAssertEqual(count.value, 0, "ended on the path the reference was built under")

        anchor.observe("turn")
        anchor.observe("p2p")
        anchor.observe("relay")
        clock.fireAll()
        XCTAssertEqual(count.value, 1, "one re-anchor, for the path that held")
    }

    /// Once re-anchored for a path, going back and forth to it is not new.
    func testAReanchoredPathIsTheNewReference() {
        let clock = ManualClock()
        let count = Counter()
        let anchor = makeAnchor(clock, count)
        anchor.observe("p2p")
        anchor.anchorToCurrent()
        anchor.observe("turn")
        clock.fireAll()
        XCTAssertEqual(count.value, 1)
        anchor.observe("turn")
        clock.fireAll()
        XCTAssertEqual(count.value, 1)
        anchor.observe("p2p")
        clock.fireAll()
        XCTAssertEqual(count.value, 2, "back to the old path is a change from the new one")
    }

    /// No path reported is never a path to re-anchor for, and it cancels what
    /// was waiting for the path that has just gone.
    func testNoPathIsNeverATarget() {
        let clock = ManualClock()
        let count = Counter()
        let anchor = makeAnchor(clock, count)
        anchor.observe("p2p")
        anchor.anchorToCurrent()
        anchor.observe("turn")
        anchor.observe("")
        clock.fireAll()
        XCTAssertEqual(count.value, 0, "the path was gone before it held")
        anchor.observe("")
        clock.fireAll()
        XCTAssertEqual(count.value, 0)
    }

    /// Anchoring to the path the call is on at the start of the check keeps its
    /// first path from being read as a change.
    func testAnchoringToTheCurrentPathAbsorbsThePendingFirstReport() {
        let clock = ManualClock()
        let count = Counter()
        let anchor = makeAnchor(clock, count)
        anchor.observe("p2p")          // the path is reported before the check starts
        anchor.anchorToCurrent()       // the check starts on it
        clock.fireAll()
        XCTAssertEqual(count.value, 0, "the call came up on this path")
    }

    /// Without that anchoring, a call that comes up on its first path does
    /// re-anchor once for it.
    func testTheFirstPathOfACallThatWasNotAnchoredReanchorsOnce() {
        let clock = ManualClock()
        let count = Counter()
        let anchor = makeAnchor(clock, count)
        anchor.observe("p2p")
        clock.fireAll()
        XCTAssertEqual(count.value, 1)
    }

    /// The app starts the per-contact check more than once per call. A repeat
    /// for the contact already anchored must not cancel a path change that is
    /// waiting to settle: it still re-anchors once, when it has held.
    func testARepeatedStartForTheSameContactKeepsAPendingReanchor() {
        let clock = ManualClock()
        let count = Counter()
        let anchor = makeAnchor(clock, count)
        anchor.observe("p2p")
        XCTAssertTrue(anchor.anchorToCurrent(forContact: "alice"), "nothing was anchored yet")
        anchor.observe("turn")
        XCTAssertFalse(anchor.anchorToCurrent(forContact: "alice"), "same contact again")
        clock.fireAll()
        XCTAssertEqual(count.value, 1, "the real path change was not lost")
    }

    /// A different contact is a new reference, anchored on the path the call
    /// is on at that moment.
    func testAnotherContactAnchorsAgain() {
        let clock = ManualClock()
        let count = Counter()
        let anchor = makeAnchor(clock, count)
        anchor.observe("p2p")
        XCTAssertTrue(anchor.anchorToCurrent(forContact: "alice"))
        anchor.observe("turn")
        XCTAssertTrue(anchor.anchorToCurrent(forContact: "bob"), "the contact changed")
        clock.fireAll()
        XCTAssertEqual(count.value, 0, "bob's reference is built on the path he is on now")
    }

    /// The end of a call forgets the contact too, so the same contact in the
    /// next call anchors on that call's path.
    func testTheSameContactAnchorsAgainAfterTheCallEnded() {
        let clock = ManualClock()
        let count = Counter()
        let anchor = makeAnchor(clock, count)
        anchor.observe("p2p")
        XCTAssertTrue(anchor.anchorToCurrent(forContact: "alice"))
        anchor.reset()
        anchor.observe("turn")
        XCTAssertTrue(anchor.anchorToCurrent(forContact: "alice"), "a new call anchors again")
        clock.fireAll()
        XCTAssertEqual(count.value, 0, "the second call came up on this path")
    }

    /// The end of a call drops what was waiting, so nothing of it can
    /// re-anchor the next call.
    func testResetDropsWhatWasPending() {
        let clock = ManualClock()
        let count = Counter()
        let anchor = makeAnchor(clock, count)
        anchor.observe("p2p")
        anchor.anchorToCurrent()
        anchor.observe("turn")
        anchor.reset()
        clock.fireAll()
        XCTAssertEqual(count.value, 0)
    }

    /// A late check from an earlier episode finds out it is stale.
    func testAStaleCheckDoesNothing() {
        let clock = ManualClock()
        let count = Counter()
        let anchor = makeAnchor(clock, count)
        anchor.observe("p2p")
        anchor.anchorToCurrent()
        anchor.observe("turn")
        anchor.anchorToCurrent()      // the reference was rebuilt for "turn" in the meantime
        clock.fireAll()
        XCTAssertEqual(count.value, 0)
    }
}
