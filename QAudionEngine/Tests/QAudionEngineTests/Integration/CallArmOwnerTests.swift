import XCTest
@testable import QAudionEngine

/// The owner of a call's unit switches is the call's OWN arm, never the arm in force: after a promotion to a
/// group a late switch-off of the ended 1:1 call must not turn the group's unit off, and a call that
/// enabled nothing itself still switches its unit off with its own arm.
final class CallArmOwnerTests: XCTestCase {

    private final class FakeUnit: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = 0
        private var enabled = false
        private var skipped: [String] = []

        func arm(_ token: Int, enabled on: Bool = false) { lock.lock(); armed = token; enabled = on; lock.unlock() }
        func release(_ token: Int) {
            lock.lock()
            if armed == token { armed = 0; enabled = false }
            lock.unlock()
        }
        var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
        var skippedSwitches: [String] { lock.lock(); defer { lock.unlock() }; return skipped }

        func apply(_ active: Bool, owner: Int, label: String) {
            lock.lock()
            defer { lock.unlock() }
            guard owner != 0, NativeAudioUnitGateDecisions.switchIsOwned(required: owner, current: armed) else {
                skipped.append(label)
                return
            }
            enabled = active
        }
    }

    private func makeQueue() -> AudioEngineSerialQueue {
        AudioEngineSerialQueue(label: "test.callarm.\(UUID().uuidString)")
    }

    func test_owner_isTheEnablesOwnWhenThereIsOne_elseTheCallsArm_andNeverAnythingElse() {
        var tracker = CallArmTracker()
        XCTAssertEqual(tracker.switchOwner(enableOwner: 0), 0, "no arm of this call: nothing of it can be on")
        tracker.note(7, wiredGeneration: 1, currentGeneration: 1)
        XCTAssertEqual(tracker.switchOwner(enableOwner: 0), 7)
        XCTAssertEqual(tracker.switchOwner(enableOwner: 9), 9)
    }

    /// (1) After a promotion (1:1 arm T1, teardown, group arms G) a late didDeactivate or mic-granted
    /// switch-off of the 1:1 call does not switch G off.
    func test_afterPromotion_aLateSwitchOffOfTheOneToOneCall_doesNotTurnOffTheGroupsUnit() {
        let queue = makeQueue()
        let unit = FakeUnit()
        var tracker = CallArmTracker()
        unit.arm(1, enabled: true)
        tracker.note(1, wiredGeneration: 1, currentGeneration: 1)  // the 1:1 call's own arm T1
        var nativeUnitOwnerToken = 1  // its enable

        // Teardown: the call's enable owner is cleared, the call's arm is kept.
        nativeUnitOwnerToken = 0
        // The peer connection closes and the group takes over with its own arm G.
        unit.release(1)
        unit.arm(2, enabled: true)

        // A late didDeactivate of the ended 1:1 call, and a mic-granted nudge: both submit an OFF now.
        let lateOwner = tracker.switchOwner(enableOwner: nativeUnitOwnerToken)
        XCTAssertEqual(lateOwner, 1, "the call's own arm, not the group's")
        queue.submit { unit.apply(false, owner: lateOwner, label: "late-didDeactivate") }
        queue.submit { unit.apply(false, owner: lateOwner, label: "mic-granted") }
        queue.waitUntilIdle()

        XCTAssertTrue(unit.isEnabled, "the group's unit must stay on")
        XCTAssertEqual(unit.skippedSwitches, ["late-didDeactivate", "mic-granted"])
    }

    /// (2) The unit was enabled only by the peer connection's own arm (no enable of the call service): the
    /// engage switch-off still turns it off, with the call's arm.
    func test_engageWhenOnlyThePeerConnectionArmEnabledTheUnit_stillSwitchesItOff() {
        let queue = makeQueue()
        let unit = FakeUnit()
        var tracker = CallArmTracker()
        unit.arm(4, enabled: true)
        tracker.note(4, wiredGeneration: 2, currentGeneration: 2)
        let nativeUnitOwnerToken = 0  // the call service never enabled it
        let owner = tracker.switchOwner(enableOwner: nativeUnitOwnerToken)
        queue.submit { unit.apply(false, owner: owner, label: "engage") }
        queue.waitUntilIdle()
        XCTAssertFalse(unit.isEnabled, "the native unit must not stay on next to the custom capture")
        XCTAssertTrue(unit.skippedSwitches.isEmpty)
    }

    /// (3) A new call does not inherit the previous call's arm, and a late report from the old call is dropped.
    func test_aNewCall_doesNotInheritThePreviousCallsArm() {
        var tracker = CallArmTracker()
        tracker.note(3, wiredGeneration: 1, currentGeneration: 1)
        XCTAssertEqual(tracker.token, 3)

        tracker.reset()  // the new call starts
        XCTAssertEqual(tracker.token, 0)
        XCTAssertEqual(tracker.switchOwner(enableOwner: 0), 0)

        // The old call's report arrives late, wired in generation 1, while generation 2 runs.
        tracker.note(3, wiredGeneration: 1, currentGeneration: 2)
        XCTAssertEqual(tracker.token, 0)

        tracker.note(8, wiredGeneration: 2, currentGeneration: 2)
        XCTAssertEqual(tracker.token, 8)
    }
}
