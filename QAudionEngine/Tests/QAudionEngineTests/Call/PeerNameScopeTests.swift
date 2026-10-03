import XCTest
@testable import QAudionEngine

/// W-CALLERBUSY (2026-10-03, review of #169) — the previous callee's identity must not leak into the next incoming
/// ring. `ContentView` keeps `outgoingDisplayName` / `outgoingShortNumber` / `outgoingAvatarUrl` alive for the busy /
/// unreachable outcome screen (`callContactId` is already `nil` there), and the 1:1 incoming ring reuses the same
/// values, so the first frame of the next incoming call showed the person just dialled. `PeerNameScope` is the rule
/// the incoming screen applies; `CallerBusyWiringTests` pins that `ContentView` applies it.
final class PeerNameScopeTests: XCTestCase {

    private let callee = "user-callee-1111"
    private let caller = "user-caller-2222"

    func testResolvedValuesBelongToTheCallTheyWereResolvedFor() {
        XCTAssertTrue(PeerNameScope.matches(resolvedFor: callee, callContactId: callee))
        XCTAssertTrue(PeerNameScope.matches(resolvedFor: callee.uppercased(), callContactId: callee), "wire ids drift in case")
    }

    /// The leak: the dialled person's values, an incoming call from someone else.
    func testAnotherPersonsValuesDoNotBelongToTheIncomingCall() {
        XCTAssertFalse(PeerNameScope.matches(resolvedFor: callee, callContactId: caller))
    }

    /// No call contact (the outcome screen's moment, or no call at all) and nothing resolved: nothing matches.
    func testNothingMatchesWithoutBothIds() {
        XCTAssertFalse(PeerNameScope.matches(resolvedFor: callee, callContactId: nil), "no outgoing call behind a nil contact")
        XCTAssertFalse(PeerNameScope.matches(resolvedFor: nil, callContactId: caller))
        XCTAssertFalse(PeerNameScope.matches(resolvedFor: nil, callContactId: nil))
        XCTAssertFalse(PeerNameScope.matches(resolvedFor: "", callContactId: ""))
    }

    func testTheIncomingRingNeverPrefersAnotherPersonsResolvedName() {
        let name = PeerNameScope.incomingRingName(
            resolvedName: "Maria Rossi", resolvedFor: callee, callContactId: caller, wireName: "Luca Bianchi")
        XCTAssertEqual(name, "Luca Bianchi", "the first frame of the next incoming call shows ITS caller")
    }

    func testTheIncomingRingUsesTheResolvedNameOfItsOwnCaller() {
        let name = PeerNameScope.incomingRingName(
            resolvedName: "Luca (rubrica)", resolvedFor: caller, callContactId: caller, wireName: "Luca Bianchi")
        XCTAssertEqual(name, "Luca (rubrica)", "the address-book name wins for the same caller, as before")
    }

    func testTheIncomingRingFallsBackToTheWireNameWhileNothingIsResolved() {
        XCTAssertEqual(
            PeerNameScope.incomingRingName(resolvedName: "", resolvedFor: nil, callContactId: caller, wireName: "Luca"),
            "Luca")
        XCTAssertEqual(
            PeerNameScope.incomingRingName(resolvedName: "", resolvedFor: caller, callContactId: caller, wireName: "Luca"),
            "Luca", "an empty resolution is not a name")
    }

    /// Neither a resolved nor a wire name: the screen says "unknown".
    func testNoNameAtAllIsNil() {
        XCTAssertNil(PeerNameScope.incomingRingName(resolvedName: "", resolvedFor: nil, callContactId: nil, wireName: ""))
        XCTAssertNil(PeerNameScope.incomingRingName(
            resolvedName: "Maria Rossi", resolvedFor: callee, callContactId: caller, wireName: ""),
            "the dialled person's name is never a fallback for an unnamed caller")
    }
}
