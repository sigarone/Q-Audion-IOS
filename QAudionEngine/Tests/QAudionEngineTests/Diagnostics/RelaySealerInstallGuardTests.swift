import XCTest
@testable import QAudionEngine

/// W-STALESEALER (2026-09-26) — the pure generation-match decision behind the caller/responder
/// `onRelaySessionReady` guard in `AppState`: a relay sealer must never be armed for a call that
/// `endCall()` has already torn down between the closure firing and the (possibly deferred)
/// install.
final class RelaySealerInstallGuardTests: XCTestCase {

    func testInstallsWhenGenerationUnchanged() {
        // No endCall() happened since the closure was wired — same call, including a
        // re-key round mid-call (which fires the closure again with no bump in between).
        XCTAssertTrue(RelaySealerInstallGuard.shouldInstall(capturedGeneration: 0, currentGeneration: 0))
        XCTAssertTrue(RelaySealerInstallGuard.shouldInstall(capturedGeneration: 5, currentGeneration: 5))
    }

    func testDropsWhenCallEndedBeforeInstall() {
        // endCall() bumped the generation once between the closure firing and the
        // (Task-hopped or SAS-deferred) install — exactly the race this guard closes.
        XCTAssertFalse(RelaySealerInstallGuard.shouldInstall(capturedGeneration: 0, currentGeneration: 1))
    }

    func testDropsWhenMultipleCallsEndedBeforeInstall() {
        // A pathological but possible case: several calls started and ended before a very
        // late closure (e.g. a long-deferred pendingIdentityGatedMedia entry) finally runs.
        XCTAssertFalse(RelaySealerInstallGuard.shouldInstall(capturedGeneration: 2, currentGeneration: 7))
    }

    func testNeverDropsForTheSameGenerationRegardlessOfValue() {
        for generation in [0, 1, 42, 1_000] {
            XCTAssertTrue(RelaySealerInstallGuard.shouldInstall(
                capturedGeneration: generation, currentGeneration: generation))
        }
    }
}
