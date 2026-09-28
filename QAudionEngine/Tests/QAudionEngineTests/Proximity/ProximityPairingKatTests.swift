import XCTest
import CryptoKit
@testable import QAudionEngine

/// Byte-for-byte check of ProximityPairingCrypto against the independent
/// Python reference implementation (scripts/kat/gen_proximity_pairing_kat.py,
/// spec §15). ML-KEM / X25519 shared secrets are fixed inputs in the vector.
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

    // MARK: - Building blocks

    func testOfferBodyAndCommitment() throws {
        let kat = try loadKat()
        let displayerUserId: String = try kat.inputString("displayerUserId")
        let userId: Data = Data(displayerUserId.utf8)
        var offerBody = Data()
        offerBody.append(try kat.inputHex("displayerMlKemPublicKey"))
        offerBody.append(try kat.inputHex("displayerEphemeralX25519"))
        offerBody.append(try kat.inputHex("displayerNonce"))
        offerBody.append(try kat.inputHex("displayerSigningPublicKey"))
        offerBody.append(try kat.inputHex("displayerEncryptionPublicKey"))
        offerBody.append(ProximityBytes.u16be(UInt16(userId.count)))
        offerBody.append(userId)
        XCTAssertEqual(offerBody, try kat.expectedHex("offerBody"))

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

    func testAcceptUnsignedBodyAndTranscriptHash() throws {
        let kat = try loadKat()
        let scannerUserId: String = try kat.inputString("scannerUserId")
        let userId: Data = Data(scannerUserId.utf8)
        var accept = Data()
        accept.append(try kat.inputHex("mlKemCiphertext"))
        accept.append(try kat.inputHex("scannerSigningPublicKey"))
        accept.append(try kat.inputHex("scannerEncryptionPublicKey"))
        accept.append(ProximityBytes.u16be(UInt16(userId.count)))
        accept.append(userId)
        XCTAssertEqual(accept, try kat.expectedHex("acceptUnsignedBody"))

        let th = ProximityPairingCrypto.transcriptHash(qrBytes: try kat.expectedHex("qrBytes"),
                                                      helloBody: try kat.expectedHex("helloBody"),
                                                      offerBody: try kat.expectedHex("offerBody"),
                                                      acceptUnsignedBody: accept)
        XCTAssertEqual(th, try kat.expectedHex("transcriptHash"))
    }

    // MARK: - Key schedule

    private func deriveKatKeys(_ kat: Kat) throws -> ProximityPairingCrypto.SessionKeys {
        return try ProximityPairingCrypto.deriveSessionKeys(
            transcriptHash: try kat.expectedHex("transcriptHash"),
            kemSharedSecret: try kat.inputHex("kemSharedSecret"),
            x25519SharedSecret: try kat.inputHex("x25519SharedSecret"),
            scannerNonce: try kat.inputHex("scannerNonce"),
            displayerNonce: try kat.inputHex("displayerNonce"))
    }

    func testSessionKeys() throws {
        let kat = try loadKat()
        let keys = try deriveKatKeys(kat)
        XCTAssertEqual(keys.prk, try kat.expectedHex("prk"))
        XCTAssertEqual(keys.macKeyScanner, try kat.expectedHex("macKeyScanner"))
        XCTAssertEqual(keys.macKeyDisplayer, try kat.expectedHex("macKeyDisplayer"))
        XCTAssertEqual(keys.confirmKeyScanner, try kat.expectedHex("confirmKeyScanner"))
        XCTAssertEqual(keys.confirmKeyDisplayer, try kat.expectedHex("confirmKeyDisplayer"))
        XCTAssertEqual(keys.sasBytes, try kat.expectedHex("sasBytes"))
        XCTAssertEqual(keys.sas, try kat.expectedString("sas"))
        XCTAssertEqual(keys.psk, try kat.expectedHex("psk"))
        XCTAssertEqual(ProximityPairingCrypto.sas(fromBytes: keys.sasBytes), try kat.expectedString("sas"))
        XCTAssertEqual(PskAdvertising.canonicalFingerprint(forPsk: keys.psk),
                       try kat.expectedString("pskFingerprint"))
    }

    func testTranscriptAndConfirmationMacs() throws {
        let kat = try loadKat()
        let keys = try deriveKatKeys(kat)
        let th = try kat.expectedHex("transcriptHash")

        let macS = ProximityPairingCrypto.transcriptMac(key: keys.macKeyScanner, transcriptHash: th)
        XCTAssertEqual(macS, try kat.expectedHex("macScanner"))
        let macD = ProximityPairingCrypto.transcriptMac(key: keys.macKeyDisplayer, transcriptHash: th)
        XCTAssertEqual(macD, try kat.expectedHex("macDisplayer"))

        let confirmS = ProximityPairingCrypto.confirmationMac(key: keys.confirmKeyScanner)
        XCTAssertEqual(confirmS, try kat.expectedHex("confirmMacScanner"))
        let confirmD = ProximityPairingCrypto.confirmationMac(key: keys.confirmKeyDisplayer)
        XCTAssertEqual(confirmD, try kat.expectedHex("confirmMacDisplayer"))

        var confirmMessage = Data([ProximityPairing.MessageType.confirm.rawValue])
        confirmMessage.append(confirmS)
        XCTAssertEqual(confirmMessage, try kat.expectedHex("confirmMessageScanner"))

        XCTAssertTrue(ProximityPairingCrypto.constantTimeEquals(macS, try kat.expectedHex("macScanner")))
        XCTAssertFalse(ProximityPairingCrypto.constantTimeEquals(macS, macD))
    }

    func testSignaturePayloads() throws {
        let kat = try loadKat()
        let th = try kat.expectedHex("transcriptHash")
        let scanner = ProximityPairingCrypto.signaturePayload(role: .scanner, transcriptHash: th)
        XCTAssertEqual(scanner, try kat.expectedHex("signaturePayloadScanner"))
        let displayer = ProximityPairingCrypto.signaturePayload(role: .displayer, transcriptHash: th)
        XCTAssertEqual(displayer, try kat.expectedHex("signaturePayloadDisplayer"))
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

    func testSessionKeysZeroizeEmptiesEveryField() throws {
        let kat = try loadKat()
        var keys = try deriveKatKeys(kat)
        keys.zeroize()
        XCTAssertTrue(keys.macKeyScanner.isEmpty)
        XCTAssertTrue(keys.macKeyDisplayer.isEmpty)
        XCTAssertTrue(keys.confirmKeyScanner.isEmpty)
        XCTAssertTrue(keys.confirmKeyDisplayer.isEmpty)
        XCTAssertTrue(keys.psk.isEmpty)
        XCTAssertTrue(keys.prk.isEmpty)
        XCTAssertTrue(keys.sasBytes.isEmpty)
        XCTAssertEqual(keys.sas, "")
        // A zeroized key can no longer produce a MAC that verifies.
        XCTAssertTrue(ProximityPairingCrypto.confirmationMac(key: keys.confirmKeyScanner).isEmpty)
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
