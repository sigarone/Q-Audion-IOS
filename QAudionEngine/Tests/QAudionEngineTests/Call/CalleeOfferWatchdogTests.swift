import XCTest
@testable import QAudionEngine

final class CalleeOfferWatchdogTests: XCTestCase {

    func testAnAnsweredCallWithNoProcessedOfferEnds() {
        XCTAssertEqual(
            CalleeOfferWatchdog.verdict(watchedCallId: "abc", activeCallId: "abc", offerProcessed: false, linkHealthy: true),
            .endPeerIncompatible)
    }

    func testTheIdsAreComparedCaseInsensitively() {
        XCTAssertEqual(
            CalleeOfferWatchdog.verdict(watchedCallId: "ABC-1", activeCallId: "abc-1", offerProcessed: false, linkHealthy: true),
            .endPeerIncompatible)
    }

    func testAProcessedOfferNeverEnds() {
        XCTAssertEqual(
            CalleeOfferWatchdog.verdict(watchedCallId: "abc", activeCallId: "abc", offerProcessed: true, linkHealthy: true), .nothing)
    }

    func testACallThatEndedOrWasReplacedIsLeftAlone() {
        XCTAssertEqual(
            CalleeOfferWatchdog.verdict(watchedCallId: "abc", activeCallId: nil, offerProcessed: false, linkHealthy: true), .nothing)
        XCTAssertEqual(
            CalleeOfferWatchdog.verdict(watchedCallId: "abc", activeCallId: "", offerProcessed: false, linkHealthy: true), .nothing)
        XCTAssertEqual(
            CalleeOfferWatchdog.verdict(watchedCallId: "abc", activeCallId: "def", offerProcessed: false, linkHealthy: true), .nothing)
    }

    /// No OFFER because the network is down (or our accept never left) is not an incompatible peer.
    func testOfferAbsentWithTheNetworkDownIsNotIncompatible() {
        XCTAssertEqual(
            CalleeOfferWatchdog.verdict(watchedCallId: "abc", activeCallId: "abc", offerProcessed: false, linkHealthy: false),
            .nothing)
    }

    func testTheWindowIsLongerThanTheOfferRetryInterval() {
        XCTAssertGreaterThanOrEqual(CalleeOfferWatchdog.windowSeconds, 15)
    }
}
