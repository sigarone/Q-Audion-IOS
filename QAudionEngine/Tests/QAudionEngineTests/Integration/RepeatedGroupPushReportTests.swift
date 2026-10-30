import XCTest
@testable import QAudionEngine

/// A group push that arrives for a call this device already handled (joined, live or declined) is still
/// reported to CallKit and ended at once. That report must never share the uuid of the live call: ending it
/// would end the live call's CallKit entry and consume its audio end balance, and the call would lose its audio.
final class RepeatedGroupPushReportTests: XCTestCase {

    private let liveCall = UUID(uuidString: "D7631DB4-0000-4000-8000-000000000001")!

    func testNotPresentableReportNeverUsesTheDerivedUuidAndIsMarked() {
        let ledger = CallKitCallLedger()
        ledger.recordNativeBalance(liveCall)
        ledger.markAudioSelfActivated(liveCall)
        for _ in 0..<50 {
            let spec = ledger.groupNotPresentableReport(derivedUuid: liveCall)
            XCTAssertNotEqual(spec.uuid, liveCall)
            XCTAssertNotNil(spec.endReason)
            XCTAssertEqual(ledger.consumeEndBalance(spec.uuid),
                           .init(nativeManualCall: false, selfActivated: false, duplicateNative: false))
        }
        XCTAssertTrue(ledger.consumeEndBalance(liveCall).selfActivated)
    }

    func testARepeatedEndOfTheReportStaysInertWhileTheLegacyFlagIsArmed() {
        let ledger = CallKitCallLedger()
        ledger.markAudioSelfActivated(nil)
        let throwaway = ledger.groupNotPresentableReport(derivedUuid: liveCall).uuid
        XCTAssertFalse(ledger.consumeEndBalance(throwaway).selfActivated)
        XCTAssertFalse(ledger.consumeEndBalance(throwaway).selfActivated, "second end is inert too")
        XCTAssertTrue(ledger.consumeEndBalance(liveCall).selfActivated, "flag still owed to the live call")
    }

    func testTheReportIsGenericAndEndsAtOnce() {
        let spec = PushKitProvider.groupNotPresentableSpec()
        XCTAssertEqual(spec.callerName, PushKitProvider.placeholderCallerName)
        XCTAssertFalse(spec.hasVideo)
        guard case .failed(let reason)? = spec.endReason else {
            return XCTFail("a push that cannot ring is reported and then ended at once")
        }
        XCTAssertEqual(reason, PushKitProvider.groupNotPresentableEndReason)
        XCTAssertFalse(PushKitProvider.isBlockedCallerSpec(spec))
    }

    func testEndingTheReportDoesNotConsumeTheLiveNativeCallsEndBalance() {
        let ledger = CallKitCallLedger()
        ledger.recordNativeBalance(liveCall)
        ledger.markAudioSelfActivated(liveCall)

        let throwaway = PushKitProvider.groupNotPresentableSpec().uuid
        ledger.markReportOnly(throwaway)
        XCTAssertEqual(ledger.consumeEndBalance(throwaway),
                       .init(nativeManualCall: false, selfActivated: false, duplicateNative: false))

        XCTAssertEqual(ledger.consumeEndBalance(liveCall),
                       .init(nativeManualCall: true, selfActivated: true, duplicateNative: false),
                       "the genuine end of the live call still owes its one deactivation")
    }

    func testEndingTheReportDoesNotTakeTheProcessWideFlagOfALegacyCall() {
        let ledger = CallKitCallLedger()
        ledger.markAudioSelfActivated(nil)

        let throwaway = UUID()
        ledger.markReportOnly(throwaway)
        XCTAssertFalse(ledger.consumeEndBalance(throwaway).selfActivated)

        XCTAssertTrue(ledger.consumeEndBalance(liveCall).selfActivated,
                      "the legacy call's genuine end still takes the flag")
        XCTAssertFalse(ledger.consumeEndBalance(liveCall).selfActivated, "and only once")
    }
}
