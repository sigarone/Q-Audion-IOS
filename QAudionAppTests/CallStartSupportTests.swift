import XCTest
@testable import QAudionApp

/// Pins the two pure pieces behind the call start path (`CallStartSupport.swift`):
///
///  - `CallStartGate`, the in-flight latch `AppState.startCall` takes as its very
///    first statement (report 1caed57d: audio and video `startCall` in the same
///    millisecond from one tap).
///  - `CallEngineLifecycle`, which rebuilds the call engine after a logout so a
///    new login can place calls again (report bea72b22: "engine not available"
///    on every call until relaunch).
///
/// `AppState` has no lightweight test init, so both are exercised through a
/// stand-in engine class; the bundle does not link QAudionEngine.
final class CallStartSupportTests: XCTestCase {

    private final class FakeEngine {
        let id: Int
        init(id: Int) { self.id = id }
    }

    private struct FakeEngineError: Error {}

    /// Builds a lifecycle that counts what it made and what it released.
    private final class Rig {
        var made: [FakeEngine] = []
        var released: [FakeEngine] = []
        var failNext = false
        lazy var lifecycle = CallEngineLifecycle<FakeEngine>(
            make: { [unowned self] in
                if self.failNext {
                    self.failNext = false
                    throw FakeEngineError()
                }
                let engine = FakeEngine(id: self.made.count + 1)
                self.made.append(engine)
                return engine
            },
            release: { [unowned self] old in self.released.append(old) }
        )
    }

    // MARK: - CallStartGate

    func test_gate_firstStartIsAdmitted_secondIsRefusedUntilReleased() {
        var gate = CallStartGate()
        XCTAssertTrue(gate.tryBegin())
        XCTAssertTrue(gate.inFlight)
        XCTAssertFalse(gate.tryBegin(), "a second start before the first committed must be refused")
        gate.end()
        XCTAssertFalse(gate.inFlight)
        XCTAssertTrue(gate.tryBegin(), "after release a new start is admitted again")
    }

    /// The reported shape: one tap fires an audio start and a video start in the
    /// same runloop turn, before either could reach any later guard.
    func test_gate_audioAndVideoFromOneTap_onlyOneProceeds() {
        var gate = CallStartGate()
        var admitted: [String] = []
        for label in ["audio", "video"] {
            if gate.tryBegin() { admitted.append(label) }
        }
        XCTAssertEqual(admitted, ["audio"])
    }

    /// Failure path: an early exit (already in a call, engine missing) releases
    /// the gate, otherwise the first failed tap would block every later call.
    func test_gate_releasedOnFailure_nextStartIsAdmitted() {
        var gate = CallStartGate()
        XCTAssertTrue(gate.tryBegin())
        gate.end()
        XCTAssertTrue(gate.tryBegin())
    }

    func test_gate_endWhenNotHeld_isHarmless() {
        var gate = CallStartGate()
        gate.end()
        XCTAssertFalse(gate.inFlight)
        XCTAssertTrue(gate.tryBegin())
    }

    // MARK: - CallEngineLifecycle

    func test_lifecycle_startsEmpty() {
        let rig = Rig()
        XCTAssertNil(rig.lifecycle.engine)
        XCTAssertEqual(rig.lifecycle.builtCount, 0)
    }

    func test_lifecycle_firstEnsureCreates() {
        let rig = Rig()
        XCTAssertEqual(rig.lifecycle.ensure(), .created)
        XCTAssertNotNil(rig.lifecycle.engine)
        XCTAssertEqual(rig.made.count, 1)
    }

    /// No double instances: ensuring while an engine exists changes nothing.
    func test_lifecycle_ensureIsIdempotent_neverBuildsASecondEngine() {
        let rig = Rig()
        _ = rig.lifecycle.ensure()
        let first = rig.lifecycle.engine
        XCTAssertEqual(rig.lifecycle.ensure(), .existing)
        XCTAssertEqual(rig.lifecycle.ensure(), .existing)
        XCTAssertTrue(rig.lifecycle.engine === first)
        XCTAssertEqual(rig.made.count, 1)
        XCTAssertTrue(rig.released.isEmpty)
    }

    /// The reported path: login, logout (engine released and dropped), login
    /// again. The engine must come back, as a NEW instance, and the old one must
    /// have been released exactly once.
    func test_lifecycle_logoutThenRelogin_recreatesEngine() {
        let rig = Rig()
        XCTAssertEqual(rig.lifecycle.ensure(), .created)
        let old = rig.lifecycle.engine

        XCTAssertTrue(rig.lifecycle.teardown())
        XCTAssertNil(rig.lifecycle.engine, "after logout there is no engine")
        XCTAssertEqual(rig.released.count, 1)
        XCTAssertTrue(rig.released.first === old)

        XCTAssertEqual(rig.lifecycle.ensure(), .recreated)
        XCTAssertNotNil(rig.lifecycle.engine)
        XCTAssertFalse(rig.lifecycle.engine === old, "a fresh instance, not the released one")
        XCTAssertEqual(rig.made.count, 2)
        XCTAssertEqual(rig.released.count, 1, "re-creating must not release anything again")
    }

    func test_lifecycle_severalLogoutLoginCycles_eachReleasedExactlyOnce() {
        let rig = Rig()
        for _ in 0..<3 {
            _ = rig.lifecycle.ensure()
            XCTAssertTrue(rig.lifecycle.teardown())
        }
        _ = rig.lifecycle.ensure()
        XCTAssertEqual(rig.made.count, 4)
        XCTAssertEqual(rig.released.count, 3)
        XCTAssertEqual(Set(rig.released.map { ObjectIdentifier($0) }).count, 3)
    }

    func test_lifecycle_teardownWithoutEngine_isNoOp() {
        let rig = Rig()
        XCTAssertFalse(rig.lifecycle.teardown())
        XCTAssertTrue(rig.released.isEmpty)
        _ = rig.lifecycle.ensure()
        XCTAssertTrue(rig.lifecycle.teardown())
        XCTAssertFalse(rig.lifecycle.teardown(), "a second teardown must not release again")
        XCTAssertEqual(rig.released.count, 1)
    }

    /// A factory failure leaves no engine and no half state; the next ensure
    /// retries, and a retry after a first-ever failure is still "created".
    func test_lifecycle_failedBuild_leavesNoEngine_andNextEnsureRetries() {
        let rig = Rig()
        rig.failNext = true
        if case .failed = rig.lifecycle.ensure() {} else {
            XCTFail("expected .failed when the factory throws")
        }
        XCTAssertNil(rig.lifecycle.engine)
        XCTAssertEqual(rig.lifecycle.builtCount, 0)
        XCTAssertEqual(rig.lifecycle.ensure(), .created)
        XCTAssertNotNil(rig.lifecycle.engine)
    }

    func test_lifecycle_failedRebuildAfterLogout_staysEmptyThenRecovers() {
        let rig = Rig()
        _ = rig.lifecycle.ensure()
        _ = rig.lifecycle.teardown()
        rig.failNext = true
        if case .failed = rig.lifecycle.ensure() {} else {
            XCTFail("expected .failed")
        }
        XCTAssertNil(rig.lifecycle.engine)
        XCTAssertEqual(rig.lifecycle.ensure(), .recreated)
    }

    /// No leak: once torn down and let go, the old engine has no remaining
    /// owner inside the lifecycle (the rig only keeps what it recorded, so it
    /// is dropped from there first).
    func test_lifecycle_teardownDropsItsOwnReference() {
        let rig = Rig()
        _ = rig.lifecycle.ensure()
        weak var weakOld = rig.lifecycle.engine
        _ = rig.lifecycle.teardown()
        rig.made.removeAll()
        rig.released.removeAll()
        XCTAssertNil(weakOld, "the lifecycle must not keep the released engine alive")
    }
}
