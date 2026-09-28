import XCTest
import CryptoKit
@testable import QAudionEngine

/// Byte-for-byte check of ProximityPairingCrypto against the independent
/// Python reference implementation (scripts/kat/gen_proximity_pairing_kat.py,
/// spec §15). ML-KEM / X25519 shared secrets are fixed inputs in the vector.
///
/// Ed25519: the vector's signatures come from RFC 8032 (deterministic)
/// signing, while CryptoKit's signing is randomized, so Swift cannot
/// reproduce those bytes. The tests VERIFY the vector's signatures under the
/// vector's public keys instead (and check that each seed derives its public
/// key), and use the vector's signature bytes wherever a later value (sealed
/// box) depends on them. AES-256-GCM with the fixed zero nonce IS
/// deterministic, so both sealed boxes are reproduced byte for byte.
final class ProximityPairingKatTests: XCTestCase {

    private struct KatError: Error {
        let message: String
    }

    private struct Kat {
        let inputs: [String: Any]
        let expected: [String: Any]
        let sas: [[String: Any]]

        func inputHex(_ key: String) throws -> Data {
            guard let text = inputs[key] as? String, let data = proxKatHexDecode(text) else {
                throw KatError(message: "missing input hex " + key)
            }
            return data
        }

        func inputString(_ key: String) throws -> String {
            guard let text = inputs[key] as? String else {
                throw KatError(message: "missing input string " + key)
            }
            return text
        }

        func expectedHex(_ key: String) throws -> Data {
            guard let text = expected[key] as? String, let data = proxKatHexDecode(text) else {
                throw KatError(message: "missing expected hex " + key)
            }
            return data
        }

        func expectedString(_ key: String) throws -> String {
            guard let text = expected[key] as? String else {
                throw KatError(message: "missing expected string " + key)
            }
            return text
        }
    }

    private func loadKat() throws -> Kat {
        guard let url = Bundle.module.url(forResource: "proximity-pairing-kat", withExtension: "json") else {
            throw KatError(message: "proximity-pairing-kat.json not found in test bundle")
        }
        let raw = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: raw, options: [])
        guard let root = object as? [String: Any],
              let inputs = root["inputs"] as? [String: Any],
              let expected = root["expected"] as? [String: Any],
              let sas = root["sas"] as? [[String: Any]] else {
            throw KatError(message: "malformed KAT JSON")
        }
        return Kat(inputs: inputs, expected: expected, sas: sas)
    }

    private func frameIndex(_ kat: Kat) throws -> UInt32 {
        guard let number = kat.inputs["frameIndex"] as? NSNumber else {
            throw KatError(message: "missing frameIndex")
        }
        return number.uint32Value
    }

    private func scannerIdentity(_ kat: Kat) throws -> ProximityPeerIdentity {
        return try ProximityPeerIdentity(userId: try kat.inputString("scannerUserId"),
                                         signingPublicKey: try kat.inputHex("scannerSigningPublicKey"),
                                         encryptionPublicKey: try kat.inputHex("scannerEncryptionPublicKey"))
    }

    private func displayerIdentity(_ kat: Kat) throws -> ProximityPeerIdentity {
        return try ProximityPeerIdentity(userId: try kat.inputString("displayerUserId"),
                                         signingPublicKey: try kat.inputHex("displayerSigningPublicKey"),
                                         encryptionPublicKey: try kat.inputHex("displayerEncryptionPublicKey"))
    }

    private func handshakeKeys(_ kat: Kat) throws -> ProximityPairingCrypto.HandshakeKeys {
        return try ProximityPairingCrypto.deriveHandshakeKeys(
            transcriptHash: try kat.expectedHex("transcriptHash"),
            kemSharedSecret: try kat.inputHex("kemSharedSecret"),
            x25519SharedSecret: try kat.inputHex("x25519SharedSecret"),
            scannerNonce: try kat.inputHex("scannerNonce"),
            displayerNonce: try kat.inputHex("displayerNonce"))
    }

    private func sessionKeys(_ kat: Kat) throws -> ProximityPairingCrypto.SessionKeys {
        return try ProximityPairingCrypto.deriveSessionKeys(
            handshakeKeys: try handshakeKeys(kat),
            displayerTranscriptHash: try kat.expectedHex("displayerTranscriptHash"))
    }

    // MARK: - QR, OFFER, HELLO

    func testOfferBodyAndCommitment() throws {
        let kat = try loadKat()
        var offerBody = Data()
        offerBody.append(try kat.inputHex("displayerMlKemPublicKey"))
        offerBody.append(try kat.inputHex("displayerEphemeralX25519"))
        offerBody.append(try kat.inputHex("displayerNonce"))
        XCTAssertEqual(offerBody.count, ProximityPairing.offerBodyBytes)
        XCTAssertEqual(offerBody, try kat.expectedHex("offerBody"))

        let offer = ProximityMessage.Offer(mlKemPublicKey: try kat.inputHex("displayerMlKemPublicKey"),
                                           displayerEphemeralX25519: try kat.inputHex("displayerEphemeralX25519"),
                                           displayerNonce: try kat.inputHex("displayerNonce"))
        XCTAssertEqual(ProximityMessage.offerBody(offer), offerBody)
        XCTAssertEqual(ProximityMessage.offer(offer).encoded(), try kat.expectedHex("offerMessage"))

        let commitment = ProximityPairingCrypto.commitment(sessionId: try kat.inputHex("sessionId"),
                                                           offerBody: offerBody)
        XCTAssertEqual(commitment, try kat.expectedHex("commitment"))
    }

    func testFrameKeysAndQrBytes() throws {
        let kat = try loadKat()
        let secret = try kat.inputHex("sessionSecret")
        let sessionId = try kat.inputHex("sessionId")
        let index = try frameIndex(kat)
        XCTAssertEqual(index, 7)

        let key0 = ProximityPairingCrypto.frameKey(sessionSecret: secret, sessionId: sessionId, frameIndex: 0)
        XCTAssertEqual(key0, try kat.expectedHex("frameKey0"))
        let key7 = ProximityPairingCrypto.frameKey(sessionSecret: secret, sessionId: sessionId, frameIndex: index)
        XCTAssertEqual(key7, try kat.expectedHex("frameKey"))

        var qr = Data([ProximityPairing.protocolVersion])
        qr.append(sessionId)
        qr.append(try kat.expectedHex("commitment"))
        qr.append(ProximityBytes.u32be(index))
        qr.append(key7)
        XCTAssertEqual(qr.count, ProximityPairing.qrPayloadBytes)
        XCTAssertEqual(qr, try kat.expectedHex("qrBytes"))

        let payload = try ProximityQrPayload(sessionId: sessionId, commitment: try kat.expectedHex("commitment"),
                                             frameIndex: index, frameKey: key7)
        XCTAssertEqual(payload.encodedBytes, qr)
        XCTAssertEqual(payload.qrText, try kat.expectedString("qrText"))
    }

    func testHelloTagAndBody() throws {
        let kat = try loadKat()
        let index = try frameIndex(kat)
        let xpkS = try kat.inputHex("scannerEphemeralX25519")
        let nonceS = try kat.inputHex("scannerNonce")
        let tag = ProximityPairingCrypto.helloTag(frameKey: try kat.expectedHex("frameKey"),
                                                  sessionId: try kat.inputHex("sessionId"),
                                                  frameIndex: index,
                                                  scannerEphemeralX25519: xpkS,
                                                  scannerNonce: nonceS)
        XCTAssertEqual(tag, try kat.expectedHex("helloTag"))

        var body = ProximityBytes.u32be(index)
        body.append(xpkS)
        body.append(nonceS)
        body.append(tag)
        XCTAssertEqual(body.count, ProximityPairing.helloBodyBytes)
        XCTAssertEqual(body, try kat.expectedHex("helloBody"))
    }

    // MARK: - Stage 1: TH1, PRK1, K_enc, K_mac

    func testHandshakeTranscriptHash() throws {
        let kat = try loadKat()
        let th1 = ProximityPairingCrypto.transcriptHash(qrBytes: try kat.expectedHex("qrBytes"),
                                                       helloBody: try kat.expectedHex("helloBody"),
                                                       offerBody: try kat.expectedHex("offerBody"),
                                                       mlKemCiphertext: try kat.inputHex("mlKemCiphertext"))
        XCTAssertEqual(th1, try kat.expectedHex("transcriptHash"))
    }

    func testHandshakeKeys() throws {
        let kat = try loadKat()
        let keys = try handshakeKeys(kat)
        XCTAssertEqual(keys.prk, try kat.expectedHex("prk"))
        XCTAssertEqual(keys.encKeyScanner, try kat.expectedHex("encKeyScanner"))
        XCTAssertEqual(keys.encKeyDisplayer, try kat.expectedHex("encKeyDisplayer"))
        XCTAssertEqual(keys.macKeyScanner, try kat.expectedHex("macKeyScanner"))
        XCTAssertEqual(keys.macKeyDisplayer, try kat.expectedHex("macKeyDisplayer"))
    }

    // MARK: - Identities (SIGMA-I)

    func testSigningSeedsDeriveTheKatPublicKeys() throws {
        let kat = try loadKat()
        let scannerSeed = try kat.inputHex("scannerSigningSeed")
        let displayerSeed = try kat.inputHex("displayerSigningSeed")
        let scannerKey = try Curve25519.Signing.PrivateKey(rawRepresentation: scannerSeed)
        let displayerKey = try Curve25519.Signing.PrivateKey(rawRepresentation: displayerSeed)
        XCTAssertEqual(scannerKey.publicKey.rawRepresentation, try kat.inputHex("scannerSigningPublicKey"))
        XCTAssertEqual(displayerKey.publicKey.rawRepresentation, try kat.inputHex("displayerSigningPublicKey"))

        // ProximityLocalIdentity derives the same public key from the seed.
        let local = try ProximityLocalIdentity(userId: try kat.inputString("scannerUserId"),
                                               signingPrivateKey: scannerSeed,
                                               encryptionPublicKey: try kat.inputHex("scannerEncryptionPublicKey"))
        XCTAssertEqual(local.publicIdentity, try scannerIdentity(kat))
    }

    func testIdBlocks() throws {
        let kat = try loadKat()
        let scanner = try scannerIdentity(kat)
        let displayer = try displayerIdentity(kat)
        XCTAssertEqual(ProximityMessage.idBlock(scanner), try kat.expectedHex("scannerIdBlock"))
        XCTAssertEqual(ProximityMessage.idBlock(displayer), try kat.expectedHex("displayerIdBlock"))
        XCTAssertEqual(try ProximityMessage.decodeIdBlock(try kat.expectedHex("scannerIdBlock")), scanner)
        XCTAssertEqual(try ProximityMessage.decodeIdBlock(try kat.expectedHex("displayerIdBlock")), displayer)
    }

    func testIdentityTranscriptHashes() throws {
        let kat = try loadKat()
        let thS = ProximityPairingCrypto.identityTranscriptHash(role: .scanner,
                                                               previousHash: try kat.expectedHex("transcriptHash"),
                                                               idBlock: try kat.expectedHex("scannerIdBlock"))
        XCTAssertEqual(thS, try kat.expectedHex("scannerTranscriptHash"))
        let thD = ProximityPairingCrypto.identityTranscriptHash(role: .displayer, previousHash: thS,
                                                               idBlock: try kat.expectedHex("displayerIdBlock"))
        XCTAssertEqual(thD, try kat.expectedHex("displayerTranscriptHash"))
    }

    func testSignaturePayloadsAndKatSignaturesVerify() throws {
        let kat = try loadKat()
        let thS = try kat.expectedHex("scannerTranscriptHash")
        let thD = try kat.expectedHex("displayerTranscriptHash")
        let scannerPayload = ProximityPairingCrypto.signaturePayload(role: .scanner, transcriptHash: thS)
        XCTAssertEqual(scannerPayload, try kat.expectedHex("signaturePayloadScanner"))
        let displayerPayload = ProximityPairingCrypto.signaturePayload(role: .displayer, transcriptHash: thD)
        XCTAssertEqual(displayerPayload, try kat.expectedHex("signaturePayloadDisplayer"))

        let sigS = try kat.expectedHex("signatureScanner")
        let sigD = try kat.expectedHex("signatureDisplayer")
        let pubS = try kat.inputHex("scannerSigningPublicKey")
        let pubD = try kat.inputHex("displayerSigningPublicKey")
        XCTAssertTrue(ProximityPairingCrypto.verify(signature: sigS, payload: scannerPayload, signingPublicKey: pubS))
        XCTAssertTrue(ProximityPairingCrypto.verify(signature: sigD, payload: displayerPayload, signingPublicKey: pubD))
        // CryptoKit directly, as a cross-check of the wrapper.
        let cryptoKitKey = try Curve25519.Signing.PublicKey(rawRepresentation: pubS)
        XCTAssertTrue(cryptoKitKey.isValidSignature(sigS, for: scannerPayload))
        // Wrong key, wrong role, wrong transcript.
        XCTAssertFalse(ProximityPairingCrypto.verify(signature: sigS, payload: scannerPayload, signingPublicKey: pubD))
        XCTAssertFalse(ProximityPairingCrypto.verify(signature: sigD, payload: displayerPayload, signingPublicKey: pubS))
        let crossRole = ProximityPairingCrypto.signaturePayload(role: .displayer, transcriptHash: thS)
        XCTAssertFalse(ProximityPairingCrypto.verify(signature: sigS, payload: crossRole, signingPublicKey: pubS))
        let crossTranscript = ProximityPairingCrypto.signaturePayload(role: .scanner, transcriptHash: thD)
        XCTAssertFalse(ProximityPairingCrypto.verify(signature: sigS, payload: crossTranscript, signingPublicKey: pubS))

        // A (randomized) CryptoKit signature from the seed verifies under the same key.
        let fresh = try ProximityPairingCrypto.sign(scannerPayload,
                                                    signingPrivateKey: try kat.inputHex("scannerSigningSeed"))
        XCTAssertTrue(ProximityPairingCrypto.verify(signature: fresh, payload: scannerPayload, signingPublicKey: pubS))
    }

    func testIdentityMacs() throws {
        let kat = try loadKat()
        let keys = try handshakeKeys(kat)
        let macS = ProximityPairingCrypto.transcriptMac(key: keys.macKeyScanner,
                                                       transcriptHash: try kat.expectedHex("scannerTranscriptHash"))
        XCTAssertEqual(macS, try kat.expectedHex("macScanner"))
        let macD = ProximityPairingCrypto.transcriptMac(key: keys.macKeyDisplayer,
                                                       transcriptHash: try kat.expectedHex("displayerTranscriptHash"))
        XCTAssertEqual(macD, try kat.expectedHex("macDisplayer"))
        XCTAssertTrue(ProximityPairingCrypto.constantTimeEquals(macS, try kat.expectedHex("macScanner")))
        XCTAssertFalse(ProximityPairingCrypto.constantTimeEquals(macS, macD))
    }

    func testSealedBoxesAreByteExactAndOpen() throws {
        let kat = try loadKat()
        let keys = try handshakeKeys(kat)
        let th1 = try kat.expectedHex("transcriptHash")
        let thS = try kat.expectedHex("scannerTranscriptHash")

        // sealed_S = Seal(K_enc_S, aad = TH1, idBlock_S ‖ sig_S ‖ mac_S).
        let plaintextS = ProximityMessage.sealedPlaintext(idBlock: try kat.expectedHex("scannerIdBlock"),
                                                          signature: try kat.expectedHex("signatureScanner"),
                                                          mac: try kat.expectedHex("macScanner"))
        let sealedS = try ProximityPairingCrypto.aeadSeal(plaintextS, key: keys.encKeyScanner, transcriptHash: th1)
        XCTAssertEqual(sealedS, try kat.expectedHex("sealedScanner"))
        let openedS = try ProximityPairingCrypto.aeadOpen(try kat.expectedHex("sealedScanner"),
                                                          key: keys.encKeyScanner, transcriptHash: th1)
        XCTAssertEqual(openedS, plaintextS)
        let parsedS = try ProximityMessage.decodeSealedPlaintext(openedS)
        XCTAssertEqual(parsedS.identity, try scannerIdentity(kat))
        XCTAssertEqual(parsedS.idBlock, try kat.expectedHex("scannerIdBlock"))
        XCTAssertEqual(parsedS.signature, try kat.expectedHex("signatureScanner"))
        XCTAssertEqual(parsedS.mac, try kat.expectedHex("macScanner"))

        // sealed_D = Seal(K_enc_D, aad = TH_S, idBlock_D ‖ sig_D ‖ mac_D).
        let plaintextD = ProximityMessage.sealedPlaintext(idBlock: try kat.expectedHex("displayerIdBlock"),
                                                          signature: try kat.expectedHex("signatureDisplayer"),
                                                          mac: try kat.expectedHex("macDisplayer"))
        let sealedD = try ProximityPairingCrypto.aeadSeal(plaintextD, key: keys.encKeyDisplayer, transcriptHash: thS)
        XCTAssertEqual(sealedD, try kat.expectedHex("sealedDisplayer"))
        let openedD = try ProximityPairingCrypto.aeadOpen(try kat.expectedHex("sealedDisplayer"),
                                                          key: keys.encKeyDisplayer, transcriptHash: thS)
        let parsedD = try ProximityMessage.decodeSealedPlaintext(openedD)
        XCTAssertEqual(parsedD.identity, try displayerIdentity(kat))
        XCTAssertEqual(parsedD.signature, try kat.expectedHex("signatureDisplayer"))
        XCTAssertEqual(parsedD.mac, try kat.expectedHex("macDisplayer"))

        // Each box is bound to its key and its aad.
        XCTAssertThrowsError(try ProximityPairingCrypto.aeadOpen(sealedS, key: keys.encKeyDisplayer,
                                                                 transcriptHash: th1))
        XCTAssertThrowsError(try ProximityPairingCrypto.aeadOpen(sealedS, key: keys.encKeyScanner,
                                                                 transcriptHash: thS))
        XCTAssertThrowsError(try ProximityPairingCrypto.aeadOpen(sealedD, key: keys.encKeyDisplayer,
                                                                 transcriptHash: th1))
    }

    func testAcceptAndFinishMessages() throws {
        let kat = try loadKat()
        var acceptBody = try kat.inputHex("mlKemCiphertext")
        acceptBody.append(try kat.expectedHex("sealedScanner"))
        XCTAssertEqual(acceptBody, try kat.expectedHex("acceptBody"))
        let accept = ProximityMessage.Accept(mlKemCiphertext: try kat.inputHex("mlKemCiphertext"),
                                             sealed: try kat.expectedHex("sealedScanner"))
        XCTAssertEqual(ProximityMessage.accept(accept).encoded(), try kat.expectedHex("acceptMessage"))
        XCTAssertEqual(try ProximityMessage.decode(try kat.expectedHex("acceptMessage")), .accept(accept))

        XCTAssertEqual(try kat.expectedHex("finishBody"), try kat.expectedHex("sealedDisplayer"))
        let finish = ProximityMessage.Finish(sealed: try kat.expectedHex("finishBody"))
        XCTAssertEqual(ProximityMessage.finish(finish).encoded(), try kat.expectedHex("finishMessage"))
        XCTAssertEqual(try ProximityMessage.decode(try kat.expectedHex("finishMessage")), .finish(finish))
    }

    /// The displayer's side of the vector end to end, as the session runs it:
    /// open the ACCEPT, verify mac_S and sig_S, then the FINISH that follows.
    func testDisplayerSideReplayOfTheVector() throws {
        let kat = try loadKat()
        let keys = try handshakeKeys(kat)
        let decoded = try ProximityMessage.decode(try kat.expectedHex("acceptMessage"))
        guard case .accept(let accept) = decoded else {
            XCTFail("not an ACCEPT")
            return
        }
        let th1 = ProximityPairingCrypto.transcriptHash(qrBytes: try kat.expectedHex("qrBytes"),
                                                       helloBody: try kat.expectedHex("helloBody"),
                                                       offerBody: try kat.expectedHex("offerBody"),
                                                       mlKemCiphertext: accept.mlKemCiphertext)
        let opened = try ProximityMessage.decodeSealedPlaintext(
            try ProximityPairingCrypto.aeadOpen(accept.sealed, key: keys.encKeyScanner, transcriptHash: th1))
        let thS = ProximityPairingCrypto.identityTranscriptHash(role: .scanner, previousHash: th1,
                                                               idBlock: opened.idBlock)
        let expectedMacS = ProximityPairingCrypto.transcriptMac(key: keys.macKeyScanner, transcriptHash: thS)
        XCTAssertTrue(ProximityPairingCrypto.constantTimeEquals(expectedMacS, opened.mac))
        XCTAssertTrue(ProximityPairingCrypto.verify(
            signature: opened.signature,
            payload: ProximityPairingCrypto.signaturePayload(role: .scanner, transcriptHash: thS),
            signingPublicKey: opened.identity.signingPublicKey))

        let finishDecoded = try ProximityMessage.decode(try kat.expectedHex("finishMessage"))
        guard case .finish(let finish) = finishDecoded else {
            XCTFail("not a FINISH")
            return
        }
        let openedD = try ProximityMessage.decodeSealedPlaintext(
            try ProximityPairingCrypto.aeadOpen(finish.sealed, key: keys.encKeyDisplayer, transcriptHash: thS))
        let thD = ProximityPairingCrypto.identityTranscriptHash(role: .displayer, previousHash: thS,
                                                               idBlock: openedD.idBlock)
        XCTAssertEqual(thD, try kat.expectedHex("displayerTranscriptHash"))
        let expectedMacD = ProximityPairingCrypto.transcriptMac(key: keys.macKeyDisplayer, transcriptHash: thD)
        XCTAssertTrue(ProximityPairingCrypto.constantTimeEquals(expectedMacD, openedD.mac))
        XCTAssertTrue(ProximityPairingCrypto.verify(
            signature: openedD.signature,
            payload: ProximityPairingCrypto.signaturePayload(role: .displayer, transcriptHash: thD),
            signingPublicKey: openedD.identity.signingPublicKey))
    }

    // MARK: - Stage 2: PRK2, confirm keys, SAS, PSK

    func testSessionKeys() throws {
        let kat = try loadKat()
        let keys = try sessionKeys(kat)
        XCTAssertEqual(keys.prk, try kat.expectedHex("finalPrk"))
        XCTAssertEqual(keys.confirmKeyScanner, try kat.expectedHex("confirmKeyScanner"))
        XCTAssertEqual(keys.confirmKeyDisplayer, try kat.expectedHex("confirmKeyDisplayer"))
        XCTAssertEqual(keys.sasBytes, try kat.expectedHex("sasBytes"))
        XCTAssertEqual(keys.sas, try kat.expectedString("sas"))
        XCTAssertEqual(keys.psk, try kat.expectedHex("psk"))
        XCTAssertEqual(ProximityPairingCrypto.sas(fromBytes: keys.sasBytes), try kat.expectedString("sas"))
        XCTAssertEqual(PskAdvertising.canonicalFingerprint(forPsk: keys.psk),
                       try kat.expectedString("pskFingerprint"))
        // Stage 2 really re-extracts: PRK2 differs from PRK1.
        XCTAssertNotEqual(keys.prk, try kat.expectedHex("prk"))
    }

    func testConfirmationMacs() throws {
        let kat = try loadKat()
        let keys = try sessionKeys(kat)
        let confirmS = ProximityPairingCrypto.confirmationMac(key: keys.confirmKeyScanner)
        XCTAssertEqual(confirmS, try kat.expectedHex("confirmMacScanner"))
        let confirmD = ProximityPairingCrypto.confirmationMac(key: keys.confirmKeyDisplayer)
        XCTAssertEqual(confirmD, try kat.expectedHex("confirmMacDisplayer"))

        var confirmMessage = Data([ProximityPairing.MessageType.confirm.rawValue])
        confirmMessage.append(confirmS)
        XCTAssertEqual(confirmMessage, try kat.expectedHex("confirmMessageScanner"))
        XCTAssertFalse(ProximityPairingCrypto.constantTimeEquals(confirmS, confirmD))
    }

    func testSasVectors() throws {
        let kat = try loadKat()
        XCTAssertEqual(kat.sas.count, 5)
        for entry in kat.sas {
            guard let hex = entry["bytes"] as? String,
                  let expected = entry["sas"] as? String,
                  let bytes = proxKatHexDecode(hex) else {
                XCTFail("malformed sas vector")
                continue
            }
            let actual: String = ProximityPairingCrypto.sas(fromBytes: bytes)
            XCTAssertEqual(actual, expected, hex)
            XCTAssertEqual(actual.count, ProximityPairing.sasDigits)
        }
    }

    func testZeroizeEmptiesEveryField() throws {
        let kat = try loadKat()
        var stageOne = try handshakeKeys(kat)
        var keys = try sessionKeys(kat)
        stageOne.zeroize()
        keys.zeroize()
        XCTAssertTrue(stageOne.encKeyScanner.isEmpty)
        XCTAssertTrue(stageOne.encKeyDisplayer.isEmpty)
        XCTAssertTrue(stageOne.macKeyScanner.isEmpty)
        XCTAssertTrue(stageOne.macKeyDisplayer.isEmpty)
        XCTAssertTrue(stageOne.prk.isEmpty)
        XCTAssertTrue(keys.confirmKeyScanner.isEmpty)
        XCTAssertTrue(keys.confirmKeyDisplayer.isEmpty)
        XCTAssertTrue(keys.psk.isEmpty)
        XCTAssertTrue(keys.prk.isEmpty)
        XCTAssertTrue(keys.sasBytes.isEmpty)
        XCTAssertEqual(keys.sas, "")
        // Zeroized keys can no longer produce a MAC, open a box or run stage 2.
        XCTAssertTrue(ProximityPairingCrypto.confirmationMac(key: keys.confirmKeyScanner).isEmpty)
        XCTAssertThrowsError(try ProximityPairingCrypto.aeadOpen(try kat.expectedHex("sealedScanner"),
                                                                 key: stageOne.encKeyScanner,
                                                                 transcriptHash: try kat.expectedHex("transcriptHash")))
        XCTAssertThrowsError(try ProximityPairingCrypto.deriveSessionKeys(
            handshakeKeys: stageOne, displayerTranscriptHash: try kat.expectedHex("displayerTranscriptHash")))
    }
}

// MARK: - File-private hex decoding (other test files have their own)

private func proxKatHexDecode(_ text: String) -> Data? {
    let chars: [UInt8] = Array(text.utf8)
    guard chars.count % 2 == 0 else { return nil }
    var out = Data(capacity: chars.count / 2)
    var i: Int = 0
    while i < chars.count {
        guard let hi = proxKatNibble(chars[i]), let lo = proxKatNibble(chars[i + 1]) else { return nil }
        out.append((hi << 4) | lo)
        i += 2
    }
    return out
}

private func proxKatNibble(_ c: UInt8) -> UInt8? {
    switch c {
    case 48...57: return c - 48
    case 97...102: return c - 87
    case 65...70: return c - 55
    default: return nil
    }
}
