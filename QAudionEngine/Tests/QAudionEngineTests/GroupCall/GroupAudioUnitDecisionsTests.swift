import XCTest
@testable import QAudionEngine

/// WHEN the audio unit of a group call may run: the same rule as the 1:1 native
/// path (only on a session CallKit activated, or that CallKit will never activate).
final class GroupAudioUnitDecisionsTests: XCTestCase {

    func testNothingRunsBeforeTheCallBegan() {
        for source in [AudioSessionActivationSource.callKit, .selfManaged, .selfExpectingCallKit] {
            XCTAssertEqual(GroupAudioUnitDecisions.action(begun: false, source: source, callKitAlreadySeen: true), .ignore)
        }
    }

    func testAnInactiveSessionIsIgnored() {
        XCTAssertEqual(GroupAudioUnitDecisions.action(begun: true, source: .notActivated, callKitAlreadySeen: false), .ignore)
    }

    func testCallKitsOwnActivationAndAnAppManagedOneEnableAtOnce() {
        XCTAssertEqual(GroupAudioUnitDecisions.action(begun: true, source: .callKit, callKitAlreadySeen: false), .enableNow)
        XCTAssertEqual(GroupAudioUnitDecisions.action(begun: true, source: .selfManaged, callKitAlreadySeen: false), .enableNow)
    }

    func testAnAppActivationThatStillExpectsCallKitWaitsForItUnlessItAlreadyCame() {
        XCTAssertEqual(GroupAudioUnitDecisions.action(begun: true, source: .selfExpectingCallKit, callKitAlreadySeen: false),
                       .enableAfterCallKitWait)
        XCTAssertEqual(GroupAudioUnitDecisions.action(begun: true, source: .selfExpectingCallKit, callKitAlreadySeen: true),
                       .enableNow)
    }

    func testTheGateHasReasonsForTheGroupUnit() {
        XCTAssertNotEqual(NativeAudioUnitGateDecisions.ChangeReason.groupEnable.rawValue,
                          NativeAudioUnitGateDecisions.ChangeReason.groupEnd.rawValue)
        XCTAssertNotEqual(NativeAudioUnitGateDecisions.ChangeReason.groupEnable.rawValue,
                          NativeAudioUnitGateDecisions.ChangeReason.selfManagedReactivation.rawValue)
    }
}
