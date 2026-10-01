import XCTest
import CryptoKit
@testable import QAudionEngine

/// SAS-PIN (post-v5): with no pin and no server key a 1:1 round is held as `identity_unresolved`.
/// The user's explicit SAS confirmation of that round makes its signer key the call-scoped pin (and the
/// app persists it as the durable pin). A later key round of the same call signed by the confirmed key
/// verifies; one signed by another key is held again; an existing pin that differs is never replaced.
final class SasSignerPinTests: XCTestCase {

    private typealias F = V5TestFixtures

    private let peer = "peer-0001"
    private let keyA = F.signer(seed: 61)
    private let keyB = F.signer(seed: 62)

    /// A signed OFFER_v5 bundle of `round` under `signer` (every value synthetic).
    private func signedOffer(
        signer: (priv: Curve25519.Signing.PrivateKey, pubRaw: Data), round: Int
    ) throws -> AndroidHandshakeBundle {
        let unsigned = AndroidHandshakeBundle(
            kind: .offer, callId: F.callId,
            pqcPublicKey: Data(repeating: 0xA1, count: 1568).base64EncodedString(),
            x25519PublicKey: Data(repeating: 0xA2, count: 32).base64EncodedString(),
            rekeyNonce: F.rekeyNonce.base64EncodedString(), rekeyRound: round)
        let t = try XCTUnwrap(QAudionCallIntegration.offerTranscript(
            from: unsigned, callId: F.callId, signerKeyRaw: signer.pubRaw,
            dtlsFingerprint: F.fingerprint("offerer")))
        let sig = try signer.priv.signature(for: t)
        return AndroidHandshakeBundle(
            kind: .offer, callId: F.callId,
            pqcPublicKey: unsigned.pqcPublicKey, x25519PublicKey: unsigned.x25519PublicKey,
            signerIdentityKey: signer.pubRaw.base64EncodedString(),
            sigV5: sig.base64EncodedString(),
            dtlsFingerprint: F.fingerprintText("offerer"),
            rekeyNonce: unsigned.rekeyNonce, rekeyRound: round)
    }

    private func verdict(_ integ: QAudionCallIntegration, _ b: AndroidHandshakeBundle) -> HandshakeSigningPolicy.Verdict {
        integ.evaluateInbound(
            bundle: b, callId: F.callId, peerId: peer, peerDeviceId: nil, expectedOfferBinding: nil).verdict
    }

    private func assertAuthenticated(
        _ v: HandshakeSigningPolicy.Verdict, pinCandidate: Data?, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .authenticated(let pin, _, _, _) = v else {
            return XCTFail("expected .authenticated, got \(v)", file: file, line: line)
        }
        XCTAssertEqual(pin, pinCandidate, file: file, line: line)
    }

    // MARK: - the round is remembered, never trusted

    func testUnresolvedRoundRemembersItsSignerKeyButPinsNothing() throws {
        let integ = QAudionCallIntegration()
        let v = verdict(integ, try signedOffer(signer: keyA, round: 1))
        XCTAssertEqual(v, .abort(code: "identity_unresolved"))
        XCTAssertNil(integ.sasPins.confirmedSigner(callId: F.callId), "nothing is pinned without a SAS confirmation")
        // Still unresolved on the next evaluation: remembering the key is not trusting it.
        XCTAssertEqual(verdict(integ, try signedOffer(signer: keyA, round: 1)), .abort(code: "identity_unresolved"))
    }

    func testSignerAwaitingSasIsLookedUpBySessionKeyRound() throws {
        let integ = QAudionCallIntegration()
        _ = verdict(integ, try signedOffer(signer: keyA, round: 1))
        let k1 = Data(repeating: 0x11, count: 32)
        integ.recordKeyRound(callId: F.callId, key: k1, round: 1)
        XCTAssertEqual(integ.signerKeyAwaitingSas(callId: F.callId.uppercased(), sessionKey: k1), keyA.pubRaw)
        // A session key of another (or unknown) round has nothing to adopt.
        let k2 = Data(repeating: 0x22, count: 32)
        integ.recordKeyRound(callId: F.callId, key: k2, round: 2)
        XCTAssertNil(integ.signerKeyAwaitingSas(callId: F.callId, sessionKey: k2))
        XCTAssertNil(integ.signerKeyAwaitingSas(callId: F.callId, sessionKey: Data(repeating: 0x33, count: 32)))
    }

    /// A rekey OFFER signed by ANOTHER key that lands while the SAS of round 1 is on screen must not be
    /// adoptable by confirming round 1's words: the lookup is by the round of the compared session key.
    func testLaterUnresolvedRoundWithAnotherKeyCannotBeAdoptedByConfirmingTheEarlierRound() throws {
        let integ = QAudionCallIntegration()
        _ = verdict(integ, try signedOffer(signer: keyA, round: 1))
        _ = verdict(integ, try signedOffer(signer: keyB, round: 2))
        let k1 = Data(repeating: 0x11, count: 32)
        integ.recordKeyRound(callId: F.callId, key: k1, round: 1)
        XCTAssertEqual(integ.signerKeyAwaitingSas(callId: F.callId, sessionKey: k1), keyA.pubRaw)
    }

    // MARK: - after the confirmation

    func testRekeyOfTheSameCallSignedByTheConfirmedKeyVerifiesAndAnotherKeyIsHeldAgain() throws {
        let integ = QAudionCallIntegration()
        _ = verdict(integ, try signedOffer(signer: keyA, round: 1))
        let k1 = Data(repeating: 0x11, count: 32)
        integ.recordKeyRound(callId: F.callId, key: k1, round: 1)
        let key = try XCTUnwrap(integ.signerKeyAwaitingSas(callId: F.callId, sessionKey: k1))
        integ.confirmSasSigner(callId: F.callId, key: key)

        // Same key, next round: verifies against the call-scoped pin, no pin candidate to commit.
        assertAuthenticated(verdict(integ, try signedOffer(signer: keyA, round: 2)), pinCandidate: nil)
        // Another signer: a key change against the confirmed pin, held again.
        XCTAssertEqual(verdict(integ, try signedOffer(signer: keyB, round: 3)), .abort(code: "identity_key_mismatch"))
        // Once confirmed there is nothing left awaiting a SAS for this call.
        XCTAssertNil(integ.signerKeyAwaitingSas(callId: F.callId, sessionKey: k1))
    }

    func testCallScopedPinDoesNotLeakIntoAnotherCall() throws {
        let integ = QAudionCallIntegration()
        integ.confirmSasSigner(callId: F.callId, key: keyA.pubRaw)
        XCTAssertNil(integ.sasPins.confirmedSigner(callId: "another-call"))
        integ.sasPins.clearAll()
        XCTAssertNil(integ.sasPins.confirmedSigner(callId: F.callId))
        XCTAssertEqual(verdict(integ, try signedOffer(signer: keyA, round: 1)), .abort(code: "identity_unresolved"))
    }

    func testStoredPinThatDiffersKeepsTheMismatchVerdictEvenWithACallScopedPin() throws {
        let integ = QAudionCallIntegration()
        let stored = keyB.pubRaw
        integ.resolvePinnedPeerKeyForDevice = { _, _ in stored }
        integ.confirmSasSigner(callId: F.callId, key: keyA.pubRaw)
        // The durable pin (key B) wins over the call-scoped one: a bundle signed by A is a key change.
        XCTAssertEqual(verdict(integ, try signedOffer(signer: keyA, round: 1)), .abort(code: "identity_key_mismatch"))
    }

    func testAuthenticatedRoundIsNeverRememberedAsUnresolved() throws {
        let integ = QAudionCallIntegration()
        let server = keyA.pubRaw
        integ.resolveServerPeerKey = { _ in server }
        assertAuthenticated(verdict(integ, try signedOffer(signer: keyA, round: 1)), pinCandidate: keyA.pubRaw)
        let k1 = Data(repeating: 0x11, count: 32)
        integ.recordKeyRound(callId: F.callId, key: k1, round: 1)
        XCTAssertNil(integ.signerKeyAwaitingSas(callId: F.callId, sessionKey: k1))
    }
}

final class CallScopedSasPinBookTests: XCTestCase {

    private let key = Data(repeating: 7, count: 32)
    private let other = Data(repeating: 8, count: 32)

    func testNothingIsConfirmedWithoutAnExplicitConfirm() {
        let book = CallScopedSasPinBook()
        book.noteUnresolved(callId: "C1", round: 1, signerKey: key)
        XCTAssertNil(book.confirmedSigner(callId: "c1"))
        XCTAssertEqual(book.signerAwaitingSas(callId: "c1", round: 1), key)
        XCTAssertNil(book.signerAwaitingSas(callId: "c1", round: 2))
        XCTAssertNil(book.signerAwaitingSas(callId: "c1", round: nil))
    }

    func testConfirmMakesTheCallScopedPinAndClearsTheAwaitingState() {
        let book = CallScopedSasPinBook()
        book.noteUnresolved(callId: "c1", round: 1, signerKey: key)
        book.confirm(callId: "C1", key: key)
        XCTAssertEqual(book.confirmedSigner(callId: "c1"), key)
        XCTAssertNil(book.signerAwaitingSas(callId: "c1", round: 1))
        book.clear(callId: "c1")
        XCTAssertNil(book.confirmedSigner(callId: "c1"))
    }

    func testMalformedInputsAreIgnored() {
        let book = CallScopedSasPinBook()
        book.noteUnresolved(callId: "c1", round: 0, signerKey: key)
        book.noteUnresolved(callId: "c1", round: nil, signerKey: key)
        book.noteUnresolved(callId: "c1", round: -3, signerKey: key)
        book.noteUnresolved(callId: "c1", round: 1, signerKey: Data(repeating: 1, count: 31))
        book.noteUnresolved(callId: "c1", round: 1, signerKey: nil)
        book.noteUnresolved(callId: "", round: 1, signerKey: key)
        XCTAssertNil(book.signerAwaitingSas(callId: "c1", round: 1))
        book.confirm(callId: "c1", key: Data(repeating: 1, count: 31))
        XCTAssertNil(book.confirmedSigner(callId: "c1"))
    }

    func testRemembersAtMostEightRoundsPerCallDroppingTheOldest() {
        let book = CallScopedSasPinBook()
        for r in 1...12 { book.noteUnresolved(callId: "c1", round: r, signerKey: key) }
        XCTAssertNil(book.signerAwaitingSas(callId: "c1", round: 1))
        XCTAssertNil(book.signerAwaitingSas(callId: "c1", round: 4))
        XCTAssertEqual(book.signerAwaitingSas(callId: "c1", round: 5), key)
        XCTAssertEqual(book.signerAwaitingSas(callId: "c1", round: 12), key)
    }

    func testStoredPinWinsOverTheCallScopedPin() {
        XCTAssertEqual(CallScopedSasPinBook.effectivePin(stored: key, callScoped: other), key)
        XCTAssertEqual(CallScopedSasPinBook.effectivePin(stored: nil, callScoped: other), other)
        XCTAssertNil(CallScopedSasPinBook.effectivePin(stored: nil, callScoped: nil))
    }

    func testPinPolicyNeverOverwritesADifferentPin() {
        XCTAssertEqual(SasSignerPinPolicy.decide(storedPin: nil, confirmedKey: key), .pin)
        XCTAssertEqual(SasSignerPinPolicy.decide(storedPin: key, confirmedKey: key), .alreadyPinned)
        XCTAssertEqual(SasSignerPinPolicy.decide(storedPin: other, confirmedKey: key), .conflict)
        XCTAssertEqual(SasSignerPinPolicy.decide(storedPin: nil, confirmedKey: Data(repeating: 1, count: 5)), .conflict)
    }
}
