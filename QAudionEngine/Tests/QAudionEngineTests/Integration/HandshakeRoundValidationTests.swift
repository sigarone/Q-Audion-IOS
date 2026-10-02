import XCTest
@testable import QAudionEngine

/// R-ROUND (WIRE_SPEC §3.7): `rekeyRound` MUST be present and >= 1 (the initial round is 1). A
/// missing or 0 round makes the bundle malformed — the transcript cannot be rebuilt (nil), which
/// ends the call; it is never defaulted.
final class HandshakeRoundValidationTests: XCTestCase {

    private typealias F = V6TestFixtures

    private let signerKey = F.signer(seed: 41).pubRaw

    private func offerBundle(round: Int?, nonce: String? = F.rekeyNonce.base64EncodedString()) -> AndroidHandshakeBundle {
        AndroidHandshakeBundle(
            kind: .offer, callId: F.callId,
            pqcPublicKey: Data(repeating: 0xA1, count: 1568).base64EncodedString(),
            x25519PublicKey: Data(repeating: 0xA2, count: 32).base64EncodedString(),
            // R-COMMIT-FIELD: round 1 carries the commitment, every later round none.
            sasCommit: round == 1 ? F.sasCommit.base64EncodedString() : nil,
            rekeyNonce: nonce, rekeyRound: round)
    }

    private func acceptBundle(round: Int?) -> AndroidHandshakeBundle {
        AndroidHandshakeBundle(
            kind: .accept, callId: F.callId, pqcPublicKey: "", x25519PublicKey: "",
            ciphertext: AndroidHandshakeBundle.Ciphertext(
                pqc: Data(repeating: 0xB1, count: 1568).base64EncodedString(),
                x25519: Data(repeating: 0xB2, count: 32).base64EncodedString()),
            rekeyNonce: F.rekeyNonce.base64EncodedString(), rekeyRound: round)
    }

    private func offerT(_ b: AndroidHandshakeBundle) -> Data? {
        QAudionCallIntegration.offerTranscript(
            from: b, callId: F.callId, signerKeyRaw: signerKey, dtlsFingerprint: F.fingerprint("offerer"))
    }

    private func acceptT(_ b: AndroidHandshakeBundle) -> Data? {
        QAudionCallIntegration.acceptTranscript(
            from: b, callId: F.callId, signerKeyRaw: signerKey,
            offerBinding: Data(repeating: 0x5A, count: 32), dtlsFingerprint: F.fingerprint("acceptor"))
    }

    func testOfferWithRoundZeroIsMalformed() {
        XCTAssertNil(offerT(offerBundle(round: 0)), "round 0 must not build a transcript")
    }

    func testOfferWithMissingRoundIsMalformed() {
        XCTAssertNil(offerT(offerBundle(round: nil)))
    }

    func testOfferWithNegativeOrHugeRoundIsMalformed() {
        XCTAssertNil(offerT(offerBundle(round: -1)))
        XCTAssertNil(offerT(offerBundle(round: Int(UInt32.max) + 1)))
    }

    func testOfferWithRoundOneAndLaterRoundsBuilds() throws {
        let one = try XCTUnwrap(offerT(offerBundle(round: 1)))
        let two = try XCTUnwrap(offerT(offerBundle(round: 2)))
        XCTAssertNotEqual(one, two, "the round is bound into the transcript")
        XCTAssertNotNil(offerT(offerBundle(round: Int(UInt32.max))))
    }

    func testAcceptWithRoundZeroOrMissingIsMalformed() {
        XCTAssertNil(acceptT(acceptBundle(round: 0)))
        XCTAssertNil(acceptT(acceptBundle(round: nil)))
        XCTAssertNotNil(acceptT(acceptBundle(round: 1)))
    }
}

/// R-SLOT (key round epoch from the signed round) and R-CERT (a signed call never gets a second
/// certificate) at the integration layer.
final class HandshakeRoundEpochAndCertTests: XCTestCase {

    private let callId = "11111111-2222-3333-4444-555555555555"

    func testKeyEpochIsTheSignedRoundMinusOne() {
        XCTAssertEqual(QAudionCallIntegration.keyEpoch(forRekeyRound: 1), 0)
        XCTAssertEqual(QAudionCallIntegration.keyEpoch(forRekeyRound: 2), 1)
        XCTAssertEqual(QAudionCallIntegration.keyEpoch(forRekeyRound: 17), 16)
        XCTAssertNil(QAudionCallIntegration.keyEpoch(forRekeyRound: 0), "round 0 is malformed, never an epoch")
        XCTAssertNil(QAudionCallIntegration.keyEpoch(forRekeyRound: UInt32.max))
    }

    /// The epoch of a key comes from the round that derived THAT key, so a round that never
    /// completed leaves a gap (round 2 skipped: rounds 1 and 3 give epochs 0 and 2) instead of a
    /// local counter silently renumbering the keys.
    func testRoundIsRememberedPerKeyAndLeavesGapsForMissedRounds() throws {
        let integ = QAudionCallIntegration()
        let k1 = Data(repeating: 1, count: 32), k3 = Data(repeating: 3, count: 32)
        integ.recordKeyRound(callId: callId, key: k1, round: 1)
        integ.recordKeyRound(callId: callId, key: k3, round: 3)
        let r1 = try XCTUnwrap(integ.keyRound(forSessionKey: k1, callId: callId.uppercased()))
        let r3 = try XCTUnwrap(integ.keyRound(forSessionKey: k3, callId: callId))
        XCTAssertEqual(QAudionCallIntegration.keyEpoch(forRekeyRound: r1), 0)
        XCTAssertEqual(QAudionCallIntegration.keyEpoch(forRekeyRound: r3), 2)
        XCTAssertNil(integ.keyRound(forSessionKey: Data(repeating: 9, count: 32), callId: callId))
        XCTAssertNil(integ.keyRound(forSessionKey: k1, callId: "another-call"))
    }

    func testFirstRoundWithoutCertificateJustCannotStart() {
        let integ = QAudionCallIntegration()
        integ.provideLocalDtlsFingerprint = { _ in nil }
        var fatals: [String] = []
        integ.onHandshakeFatal = { _, reason in fatals.append(reason) }
        XCTAssertThrowsError(try integ.localDtlsFingerprint(callId: callId)) { error in
            guard case IntegrationError.handshakeAborted(let code) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, "dtls_cert_unavailable")
        }
        XCTAssertTrue(fatals.isEmpty, "a call that never signed is not ended by the certificate rule")
    }

    /// A call that already signed (it sent an OFFER) must not get a new certificate: when its
    /// context is missing the call ends with `dtls_fp_mismatch` (WIRE_SPEC §3.8 R-CERT).
    func testSignedCallWhoseContextIsGoneEndsWithDtlsFpMismatch() {
        let integ = QAudionCallIntegration()
        integ.provideLocalDtlsFingerprint = { _ in nil }
        var fatals: [(String, String)] = []
        integ.onHandshakeFatal = { id, reason in fatals.append((id, reason)) }
        integ.sentOfferTranscriptByCall[callId.lowercased()] = Data([1, 2, 3])
        XCTAssertThrowsError(try integ.localDtlsFingerprint(callId: callId)) { error in
            guard case IntegrationError.handshakeAborted(let code) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, "dtls_fp_mismatch")
        }
        XCTAssertEqual(fatals.count, 1)
        XCTAssertEqual(fatals.first?.0, callId)
        XCTAssertEqual(fatals.first?.1, "dtls_fp_mismatch")
    }
}
