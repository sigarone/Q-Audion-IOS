import XCTest
@testable import QAudionEngine

/// The call setup reads these providers off the main thread. A provider guarded by
/// `Thread.isMainThread` answers false there whatever the flag says; the snapshot must not.
final class CallFlagProvidersTests: XCTestCase {

    func testSnapshotKeepsTheTrueValueWhenReadOffMain() async {
        let provider = await MainActor.run { CallFlagProviders.snapshot { true } }
        let value = await Task.detached { () -> Bool in
            XCTAssertFalse(Thread.isMainThread)
            return provider()
        }.value
        XCTAssertTrue(value)
    }

    func testSnapshotKeepsTheFalseValueWhenReadOffMain() async {
        let provider = await MainActor.run { CallFlagProviders.snapshot { false } }
        let value = await Task.detached { provider() }.value
        XCTAssertFalse(value)
    }

    func testSnapshotReadsOnceAtWiringTime() {
        var flag = true
        let provider = CallFlagProviders.snapshot { flag }
        flag = false
        XCTAssertTrue(provider())
    }

    /// The pattern this replaces: documents why a main-thread guard is wrong off-main.
    func testMainThreadGuardedProviderAnswersFalseOffMain() async {
        let guarded: () -> Bool = { Thread.isMainThread ? true : false }
        let value = await Task.detached { guarded() }.value
        XCTAssertFalse(value)
    }
}
