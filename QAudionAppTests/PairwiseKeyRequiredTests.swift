import XCTest
@testable import QAudionApp
import QAudionEngine

/// A peer with no bound pairwise key has no candidates, and nothing derived from public ids stands in for one.
final class PairwiseKeyRequiredTests: XCTestCase {

    func testNoCandidatesForAPeerWithoutABoundKey() {
        let peer = "no-key-peer-\(UUID().uuidString)"
        XCTAssertTrue(PairwiseChainKeyResolver.orderedPskCandidates(peerId: peer, vault: SovereignKeyVault()).isEmpty)
    }

    func testResolvePskThrowsWhenNothingIsBound() {
        let peer = "no-key-peer-\(UUID().uuidString)"
        XCTAssertThrowsError(try PairwiseChainKeyResolver.resolvePsk(peerId: peer, vault: SovereignKeyVault())) { error in
            guard case PairwiseChainKeyResolver.ResolveError.pskMissing = error else {
                return XCTFail("expected pskMissing, got \(error)")
            }
        }
    }
}

/// Key-exchange requests prompted by inbound frames are limited to one per peer per interval.
final class KeyExchangeThrottleTests: XCTestCase {

    func testOneRequestPerPeerPerInterval() {
        var throttle = KeyExchangeThrottle(interval: 30)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(throttle.allow(peerId: "a", now: t0))
        XCTAssertFalse(throttle.allow(peerId: "a", now: t0.addingTimeInterval(29)))
        XCTAssertTrue(throttle.allow(peerId: "b", now: t0.addingTimeInterval(1)), "another peer is not limited by the first")
        XCTAssertTrue(throttle.allow(peerId: "a", now: t0.addingTimeInterval(30)))
    }

    func testTheSlotIsNotTakenUntilTheRequestIsRecorded() {
        var throttle = KeyExchangeThrottle(interval: 30)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(throttle.isAllowed(peerId: "a", now: t0))
        XCTAssertTrue(throttle.isAllowed(peerId: "a", now: t0.addingTimeInterval(1)), "checking does not consume the slot")
        throttle.record(peerId: "a", now: t0.addingTimeInterval(2))
        XCTAssertFalse(throttle.isAllowed(peerId: "a", now: t0.addingTimeInterval(10)))
        XCTAssertTrue(throttle.isAllowed(peerId: "a", now: t0.addingTimeInterval(32)))
    }

    func testAVaultThatCanBeReadWithoutAKeyIsNotReportedAsUnreadable() {
        let peer = "no-key-peer-\(UUID().uuidString)"
        XCTAssertFalse(PairwiseChainKeyResolver.vaultUnreadable(peerId: peer, vault: SovereignKeyVault()))
    }
}
