import XCTest
@testable import QAudionEngine

/// The rule: every switch of the native audio unit runs on the audio queue and carries the owner captured
/// when it was submitted. These tests drive the real queue and the real owner decision
/// (`NativeAudioUnitGateDecisions.switchIsOwned`) with a stand-in for the unit.
final class NativeUnitSwitchOnQueueTests: XCTestCase {

    /// The unit and the arm in force, as the gate holds them.
    private final class FakeUnit: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = 0
        private var enabled = false
        private var skipped: [String] = []

        func arm(_ token: Int) { lock.lock(); armed = token; lock.unlock() }
        /// The arm released with the unit switched off (the one synchronous exception).
        func release(_ token: Int) {
            lock.lock()
            if armed == token { armed = 0; enabled = false }
            lock.unlock()
        }
        var currentArm: Int { lock.lock(); defer { lock.unlock() }; return armed }
        var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
        var skippedSwitches: [String] { lock.lock(); defer { lock.unlock() }; return skipped }

        /// What `NativeAudioSessionGate.applySwitchOnAudioQueue` does.
        func apply(_ active: Bool, owner: Int, label: String) {
            lock.lock()
            defer { lock.unlock() }
            guard owner != 0,
                  NativeAudioUnitGateDecisions.switchIsOwned(required: owner, current: armed) else {
                skipped.append(label)
                return
            }
            enabled = active
        }
    }

    private func makeQueue() -> AudioEngineSerialQueue {
        AudioEngineSerialQueue(label: "test.unitswitch.\(UUID().uuidString)")
    }

    func test_ownerDecision() {
        typealias G = NativeAudioUnitGateDecisions
        XCTAssertTrue(G.switchIsOwned(required: 3, current: 3))
        XCTAssertFalse(G.switchIsOwned(required: 3, current: 4))
        XCTAssertFalse(G.switchIsOwned(required: 0, current: 0))
        XCTAssertFalse(G.switchIsOwned(required: 3, current: 0))
        XCTAssertTrue(G.switchIsOwned(required: nil, current: 2))
        XCTAssertFalse(G.switchIsOwned(required: nil, current: 0))
    }

    /// An early didDeactivate: the enable is still queued behind slow audio work when the deactivation
    /// arrives. Its switch-off is queued behind the enable with the same owner, so the unit ends up off.
    func test_earlyDidDeactivate_endsWithTheUnitOff() {
        let queue = makeQueue()
        let unit = FakeUnit()
        unit.arm(5)
        let inSlowWork = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.submit {  // slow audio work ahead of everything
            inSlowWork.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(inSlowWork.wait(timeout: .now() + 5), .success)

        // Main: the enable is submitted and its owner recorded right then (not after the switch ran).
        var nativeUnitOwnerToken = 0
        let owner = unit.currentArm
        nativeUnitOwnerToken = owner
        queue.submit { unit.apply(true, owner: owner, label: "enable") }
        // Main: the early didDeactivate sees the recorded owner and queues its switch-off.
        let deactivationOwner = nativeUnitOwnerToken
        XCTAssertEqual(deactivationOwner, 5, "the owner is known before the enable has run")
        queue.submit { unit.apply(false, owner: deactivationOwner, label: "deactivate") }

        release.signal()
        queue.waitUntilIdle()
        XCTAssertFalse(unit.isEnabled, "the unit must end up off")
        XCTAssertTrue(unit.skippedSwitches.isEmpty)
    }

    /// Promotion to a group: the 1:1 teardown switch-off is queued with the 1:1 owner; the 1:1 arm is
    /// released, and the group takes over with its own arm and enable. The queued switch-off must not
    /// turn off the group's unit.
    func test_teardownSwitchOff_afterPromotionToAGroup_doesNotTurnOffTheGroupsUnit() {
        let queue = makeQueue()
        let unit = FakeUnit()
        unit.arm(1)
        let inSlowWork = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.submit {
            inSlowWork.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(inSlowWork.wait(timeout: .now() + 5), .success)

        // endCall: the teardown switch-off, owner = the 1:1 arm captured now.
        let oneToOneOwner = unit.currentArm
        queue.submit { unit.apply(false, owner: oneToOneOwner, label: "teardown-1to1") }
        // The peer connection closes (arm released, unit off), then the group takes over.
        unit.release(1)
        unit.arm(2)
        let groupOwner = unit.currentArm
        queue.submit { unit.apply(true, owner: groupOwner, label: "group-enable") }

        release.signal()
        queue.waitUntilIdle()
        XCTAssertTrue(unit.isEnabled, "the group's unit must stay on")
        XCTAssertEqual(unit.skippedSwitches, ["teardown-1to1"])
    }

    /// A switch with no owner (nothing armed when it was submitted) never applies.
    func test_switchWithNoOwner_isANoOp() {
        let queue = makeQueue()
        let unit = FakeUnit()
        queue.submit { unit.apply(true, owner: 0, label: "ownerless") }
        queue.waitUntilIdle()
        XCTAssertFalse(unit.isEnabled)
        XCTAssertEqual(unit.skippedSwitches, ["ownerless"])
    }

    func test_submitSwitch_goesThroughTheQueue_andReportsOnIt() {
        // Not armed in the test host: the owner-checked switch is a no-op and reports `false`, on the queue.
        let queue = makeQueue()
        let done = expectation(description: "completion")
        var onQueue = false
        var changed = true
        NativeAudioSessionGate.submitSwitch(
            true, ifCurrent: 0, reason: 0, queue: queue
        ) { result in
            onQueue = queue.isOnQueue
            changed = result
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(onQueue)
        XCTAssertFalse(changed)
    }

    // MARK: - interruption ended after a stop

    func test_interruptionGuard() {
        typealias Guard = InterruptionHandlingGuard
        XCTAssertTrue(Guard.shouldHandle(observerActive: true, observedEpoch: 4, currentEpoch: 4))
        XCTAssertFalse(Guard.shouldHandle(observerActive: false, observedEpoch: 4, currentEpoch: 4))
        XCTAssertFalse(Guard.shouldHandle(observerActive: true, observedEpoch: 4, currentEpoch: 5))
    }

    /// `.ended` observed before a stop and handled after it: the stop bumped the epoch, so the resume is dropped.
    func test_interruptionEndedQueuedAfterAStop_doesNotResume() {
        let queue = makeQueue()
        let log = NSLock()
        var resumed = false
        let inSlowWork = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.submit {
            inSlowWork.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(inSlowWork.wait(timeout: .now() + 5), .success)

        let observedEpoch = queue.currentEpoch  // the notification is observed now
        queue.submitStop { }  // the stop is submitted right after
        queue.submit {
            if InterruptionHandlingGuard.shouldHandle(
                observerActive: true, observedEpoch: observedEpoch, currentEpoch: queue.currentEpoch) {
                log.lock(); resumed = true; log.unlock()
            }
        }
        release.signal()
        queue.waitUntilIdle()
        XCTAssertFalse(resumed)
    }

    // MARK: - CallKit-free mode, back-to-back calls

    /// The old capture's stop is queued behind slow work. The new call bumps the capture serial right after
    /// its defensive teardown (before configuring the session), configures the session, and the old stop
    /// then decides at the moment of the deactivation: it leaves the new session alone.
    func test_backToBackCalls_oldStopDecidesAtDeactivation() {
        let queue = makeQueue()
        let lock = NSLock()
        var serial = 1
        var sessionActive = true
        let inSlowWork = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.submit {
            inSlowWork.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(inSlowWork.wait(timeout: .now() + 5), .success)

        // New call, main thread: defensive teardown submits the old capture's stop with the serial now ...
        let submittedSerial = serial
        queue.submitStop {
            // ... the stop itself runs first, the deactivation is decided after it.
            lock.lock(); let current = serial; lock.unlock()
            if CaptureStopPolicy.shouldDeactivateSession(
                requested: true, submittedGeneration: submittedSerial, currentGeneration: current) {
                sessionActive = false
            }
        }
        // ... the new call bumps the serial before it configures the session.
        lock.lock(); serial += 1; lock.unlock()
        sessionActive = true  // the new call's configureForVoIP

        release.signal()
        queue.waitUntilIdle()
        XCTAssertTrue(sessionActive, "the stop of the earlier call must not deactivate the new session")
    }

    func test_endOfCallStopWithNoNewCall_deactivates() {
        XCTAssertTrue(CaptureStopPolicy.shouldDeactivateSession(requested: true, submittedGeneration: 3, currentGeneration: 3))
    }

    // MARK: - telemetry

    func test_engineRunningAtEnd_isUnknownNeverFalseWhenItCouldNotBeRead() {
        let pipeline = AudioProcessingPipeline()
        pipeline.noteEngineRunningAtEndUnknown()
        let unknown = pipeline.consumeAudioDiagStats()
        XCTAssertEqual(unknown.engineRunningAtEndAttr as? String, "unknown")

        pipeline.noteEngineRunningAtEnd(false)
        let known = pipeline.consumeAudioDiagStats()
        XCTAssertEqual(known.engineRunningAtEndAttr as? Bool, false)

        pipeline.noteEngineRunningAtEndUnknown()
        pipeline.noteEngineRunningAtEnd(true)
        XCTAssertEqual(pipeline.consumeAudioDiagStats().engineRunningAtEndAttr as? Bool, true)
    }
}
