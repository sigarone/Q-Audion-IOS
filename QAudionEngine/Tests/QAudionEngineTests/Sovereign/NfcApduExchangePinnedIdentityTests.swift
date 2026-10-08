import XCTest
@testable import QAudionEngine

/// SECURITY M-6 — pins `NfcApduExchange.verifyPinnedPeerIdentity`, the
/// re-pair identity-pin decision `runPhase14cExchange` applies right after
/// GET_IDENTITY_KEY. The NFC I/O itself cannot run in CI (CoreNFC needs real
/// hardware), so the decision is extracted as a plain function and tested in
/// isolation, exactly like `NfcApduExchangeSasGateTests` does for the SAS gate.
final class NfcApduExchangePinnedIdentityTests: XCTestCase {

    private let keyA = Data(repeating: 0xA1, count: 32)
    private let keyB = Data(repeating: 0xB2, count: 32)

    /// First pairing: no stored key -> trust on first use, any key accepted.
    func test_nilPin_isTofu_acceptsAnyKey() {
        XCTAssertNoThrow(try NfcApduExchange.verifyPinnedPeerIdentity(pinned: nil, presented: keyA))
        XCTAssertNoThrow(try NfcApduExchange.verifyPinnedPeerIdentity(pinned: nil, presented: keyB))
    }

    /// Re-pair with the same peer: presented key equals the pinned one.
    func test_matchingPin_isAccepted() {
        XCTAssertNoThrow(try NfcApduExchange.verifyPinnedPeerIdentity(pinned: keyA, presented: keyA))
    }

    /// Re-pair presenting a different identity key: must abort with
    /// `peerIdentityMismatch` (key-substitution defence).
    func test_mismatchingPin_throwsPeerIdentityMismatch() {
        XCTAssertThrowsError(try NfcApduExchange.verifyPinnedPeerIdentity(pinned: keyA, presented: keyB)) { error in
            guard case NfcApduExchange.ExchangeError.peerIdentityMismatch = error else {
                return XCTFail("expected peerIdentityMismatch, got \(error)")
            }
        }
    }

    /// A single flipped bit in the last byte must still be rejected (the
    /// compare covers the whole key, not a prefix).
    func test_singleBitDifference_isRejected() {
        var flipped = keyA
        flipped[flipped.count - 1] ^= 0x01
        XCTAssertThrowsError(try NfcApduExchange.verifyPinnedPeerIdentity(pinned: keyA, presented: flipped))
    }

    /// A truncated/extended presented key never matches (length is checked).
    func test_lengthMismatch_isRejected() {
        XCTAssertThrowsError(try NfcApduExchange.verifyPinnedPeerIdentity(pinned: keyA, presented: keyA.prefix(31)))
        XCTAssertThrowsError(try NfcApduExchange.verifyPinnedPeerIdentity(pinned: keyA, presented: keyA + Data([0x00])))
    }
}
