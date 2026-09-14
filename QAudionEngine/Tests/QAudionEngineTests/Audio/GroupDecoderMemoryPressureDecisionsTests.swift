import XCTest
@testable import QAudionEngine

/// W-GRPMEMPRESSURE (2026-08-26) — pins `GroupDecoderMemoryPressureDecisions
/// .decodersToEvict` against Android's own real crash/memory-response gap
/// this closes on iOS: zero matches for memory-warning handling anywhere in
/// the group-call stack before this. Same discipline as
/// `RestartIceDecisionsTests` — no `OpusCodec`/lock/notification state, so
/// the ranking is pinnable without a live call.
final class GroupDecoderMemoryPressureDecisionsTests: XCTestCase {

    private let floor = GroupDecoderMemoryPressureDecisions.decoderFloor

    func testAtOrBelowTheFloor_evictsNothing() {
        var lastActive: [String: Date] = [:]
        for i in 0..<floor {
            lastActive["peer\(i)"] = Date(timeIntervalSinceNow: TimeInterval(-i))
        }
        XCTAssertEqual(GroupDecoderMemoryPressureDecisions.decodersToEvict(lastActive: lastActive, floor: floor), [])
    }

    func testEmptyMap_evictsNothing() {
        XCTAssertEqual(GroupDecoderMemoryPressureDecisions.decodersToEvict(lastActive: [:], floor: floor), [])
    }

    /// The whole point: with one more sender than the floor allows, exactly
    /// ONE eviction happens, and it is the OLDEST (least-recently-active)
    /// one — the peer everyone has actually forgotten about, never the peer
    /// who just spoke.
    func testOneOverTheFloor_evictsExactlyTheOldestSingleSender() {
        let now = Date()
        var lastActive: [String: Date] = [:]
        for i in 0..<floor {
            lastActive["recent\(i)"] = now.addingTimeInterval(TimeInterval(-i)) // all recent-ish
        }
        lastActive["ancient"] = now.addingTimeInterval(-3600) // an hour ago — clearly oldest
        let evicted = GroupDecoderMemoryPressureDecisions.decodersToEvict(lastActive: lastActive, floor: floor)
        XCTAssertEqual(evicted, ["ancient"])
    }

    /// Several senders over the floor: evicts EXACTLY `count - floor`,
    /// oldest-first, and never touches a sender inside the kept floor.
    func testSeveralOverTheFloor_evictsExactlyTheOverflowCount_oldestFirst() {
        let now = Date()
        var lastActive: [String: Date] = [:]
        // 3 over the floor.
        let total = floor + 3
        for i in 0..<total {
            // Higher i = more recently active (i=0 is oldest).
            lastActive["peer\(i)"] = now.addingTimeInterval(TimeInterval(i))
        }
        let evicted = Set(GroupDecoderMemoryPressureDecisions.decodersToEvict(lastActive: lastActive, floor: floor))
        XCTAssertEqual(evicted.count, 3)
        XCTAssertEqual(evicted, Set(["peer0", "peer1", "peer2"]), "must evict exactly the 3 oldest, not any of the floor's worth of recent ones")
    }

    func testEvictedSet_neverOverlapsWithTheKeptFloorCount() {
        let now = Date()
        var lastActive: [String: Date] = [:]
        let total = floor + 5
        for i in 0..<total {
            lastActive["peer\(i)"] = now.addingTimeInterval(TimeInterval(i))
        }
        let evicted = GroupDecoderMemoryPressureDecisions.decodersToEvict(lastActive: lastActive, floor: floor)
        XCTAssertEqual(lastActive.count - evicted.count, floor, "exactly `floor` senders must remain after eviction")
    }

    /// A negative floor is a defensively-rejected caller error, not an
    /// "evict everything" signal.
    func testNegativeFloor_evictsNothing() {
        let lastActive = ["a": Date(), "b": Date()]
        XCTAssertEqual(GroupDecoderMemoryPressureDecisions.decodersToEvict(lastActive: lastActive, floor: -1), [])
    }

    /// Floor of zero is a legal (if aggressive) configuration — evicts
    /// every currently-idle-enough sender down to nothing.
    func testZeroFloor_canEvictEveryEntry() {
        let now = Date()
        let lastActive = ["a": now, "b": now.addingTimeInterval(1)]
        let evicted = Set(GroupDecoderMemoryPressureDecisions.decodersToEvict(lastActive: lastActive, floor: 0))
        XCTAssertEqual(evicted, Set(["a", "b"]))
    }
}
