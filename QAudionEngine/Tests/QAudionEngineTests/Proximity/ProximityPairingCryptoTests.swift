import XCTest
import CryptoKit
import CLiboqs
@testable import QAudionEngine

/// Behavioural tests for ProximityPairingCrypto (byte-exact vectors live in
/// ProximityPairingKatTests). Pure: no Bluetooth, no Keychain.
final class ProximityPairingCryptoTests: XCTestCase {

    // MARK: - Helpers

    private func bytes(_ count: Int, _ value: UInt8) -> Data {
        return Data(repeating: value, count: count)
    }

    private func flipped(_ data: Data, at index: Int) -> Data {
        var copy = Data(data)
        let position: Int = copy.startIndex + index
        copy[position] = copy[position] ^ 0x01
        return copy
    }

    private func pattern(_ count: Int, seed: UInt8) -> Data {
        var out = Data(count: count)
        var i: Int = 0
        while i < count {
            out[i] = UInt8(truncatingIfNeeded: i &* 7) &+ seed
            i += 1
        }
        return out
    }

    // MARK: - ProximityBytes

    func testBigEndianHelpers() {
        XCTAssertEqual(ProximityBytes.u16be(0x0102), Data([0x01, 0x02]))
        XCTAssertEqual(ProximityBytes.u32be(0x01020304), Data([0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(ProximityBytes.u32be(UInt32.max), Data([0xff, 0xff, 0xff, 0xff]))
        XCTAssertEqual(ProximityBytes.lp32(Data([0xaa, 0xbb])), Data([0, 0, 0, 2, 0xaa, 0xbb]))
        XCTAssertEqual(ProximityBytes.lp32(Data()), Data([0, 0, 0, 0]))

        let data = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
        XCTAssertEqual(ProximityBytes.readU16be(data, at: 0), 0x0011)
        XCTAssertEqual(ProximityBytes.readU16be(data, at: 4), 0x4455)
        XCTAssertNil(ProximityBytes.readU16be(data, at: 5))
        XCTAssertNil(ProximityBytes.readU16be(data, at: -1))
        XCTAssertNil(ProximityBytes.readU16be(Data([0x01]), at: 0))
        XCTAssertNil(ProximityBytes.readU16be(Data(), at: 0))
        XCTAssertEqual(ProximityBytes.readU32be(data, at: 2), 0x22334455)
        XCTAssertNil(ProximityBytes.readU32be(data, at: 3))
        XCTAssertNil(ProximityBytes.readU32be(data, at: Int.max))
        XCTAssertNil(ProximityBytes.readU32be(Data([1, 2, 3]), at: 0))

        // Slices keep a non-zero startIndex; offsets must stay zero-based.
        let slice: Data = data[2..<6]
        XCTAssertEqual(slice.startIndex, 2)
        XCTAssertEqual(ProximityBytes.readU16be(slice, at: 0), 0x2233)
        XCTAssertEqual(ProximityBytes.readU32be(slice, at: 0), 0x22334455)
        XCTAssertNil(ProximityBytes.readU16be(slice, at: 3))
    }

    // MARK: - Randomness

    func testRandomBytes() throws {
        let a = try ProximityPairingCrypto.randomBytes(32)
        let b = try ProximityPairingCrypto.randomBytes(32)
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(b.count, 32)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try ProximityPairingCrypto.randomBytes(1).count, 1)
        XCTAssertThrowsError(try ProximityPairingCrypto.randomBytes(0))
        XCTAssertThrowsError(try ProximityPairingCrypto.randomBytes(-1))
    }

    // MARK: - ML-KEM-1024

    func testKemSizesMatchLiboqs() {
        XCTAssertEqual(ProximityPairing.mlKemPublicKeyBytes, Int(OQS_KEM_ml_kem_1024_length_public_key))
        XCTAssertEqual(ProximityPairing.mlKemSecretKeyBytes, Int(OQS_KEM_ml_kem_1024_length_secret_key))
        XCTAssertEqual(ProximityPairing.mlKemCiphertextBytes, Int(OQS_KEM_ml_kem_1024_length_ciphertext))
        XCTAssertEqual(ProximityPairing.sharedSecretBytes, Int(OQS_KEM_ml_kem_1024_length_shared_secret))
        XCTAssertEqual(64, Int(OQS_KEM_ml_kem_1024_length_keypair_seed))
        XCTAssertEqual(32, Int(OQS_KEM_ml_kem_1024_length_encaps_seed))
    }

    func testKemRandomRoundTrip() throws {
        let pair = try ProximityPairingCrypto.kemGenerateKeyPair()
        XCTAssertEqual(pair.publicKey.count, ProximityPairing.mlKemPublicKeyBytes)
        XCTAssertEqual(pair.secretKey.count, ProximityPairing.mlKemSecretKeyBytes)
        let enc = try ProximityPairingCrypto.kemEncapsulate(publicKey: pair.publicKey)
        XCTAssertEqual(enc.ciphertext.count, ProximityPairing.mlKemCiphertextBytes)
        XCTAssertEqual(enc.sharedSecret.count, ProximityPairing.sharedSecretBytes)
        let dec = try ProximityPairingCrypto.kemDecapsulate(ciphertext: enc.ciphertext, secretKey: pair.secretKey)
        XCTAssertEqual(dec, enc.sharedSecret)

        let other = try ProximityPairingCrypto.kemGenerateKeyPair()
        XCTAssertNotEqual(other.publicKey, pair.publicKey)
        let enc2 = try ProximityPairingCrypto.kemEncapsulate(publicKey: pair.publicKey)
        XCTAssertNotEqual(enc2.ciphertext, enc.ciphertext)
        XCTAssertNotEqual(enc2.sharedSecret, enc.sharedSecret)
    }

    func testKemDerandIsDeterministic() throws {
        let seedA = pattern(64, seed: 0x10)
        let seedB = flipped(seedA, at: 63)
        let pairA1 = try ProximityPairingCrypto.kemGenerateKeyPair(seed: seedA)
        let pairA2 = try ProximityPairingCrypto.kemGenerateKeyPair(seed: seedA)
        let pairB = try ProximityPairingCrypto.kemGenerateKeyPair(seed: seedB)
        XCTAssertEqual(pairA1.publicKey, pairA2.publicKey)
        XCTAssertEqual(pairA1.secretKey, pairA2.secretKey)
        XCTAssertNotEqual(pairA1.secretKey, pairB.secretKey)

        let encSeedA = pattern(32, seed: 0x55)
        let encSeedB = flipped(encSeedA, at: 0)
        let encA1 = try ProximityPairingCrypto.kemEncapsulate(publicKey: pairA1.publicKey, seed: encSeedA)
        let encA2 = try ProximityPairingCrypto.kemEncapsulate(publicKey: pairA1.publicKey, seed: encSeedA)
        let encB = try ProximityPairingCrypto.kemEncapsulate(publicKey: pairA1.publicKey, seed: encSeedB)
        XCTAssertEqual(encA1.ciphertext, encA2.ciphertext)
        XCTAssertEqual(encA1.sharedSecret, encA2.sharedSecret)
        XCTAssertNotEqual(encA1.ciphertext, encB.ciphertext)
        XCTAssertNotEqual(encA1.sharedSecret, encB.sharedSecret)

        let dec = try ProximityPairingCrypto.kemDecapsulate(ciphertext: encA1.ciphertext, secretKey: pairA1.secretKey)
        XCTAssertEqual(dec, encA1.sharedSecret)
    }

    func testKemTamperedCiphertextYieldsDifferentSecretWithoutThrowing() throws {
        let pair = try ProximityPairingCrypto.kemGenerateKeyPair()
        let enc = try ProximityPairingCrypto.kemEncapsulate(publicKey: pair.publicKey)
        let positions: [Int] = [0, 777, ProximityPairing.mlKemCiphertextBytes - 1]
        for position in positions {
            let tampered = flipped(enc.ciphertext, at: position)
            let secret = try ProximityPairingCrypto.kemDecapsulate(ciphertext: tampered, secretKey: pair.secretKey)
            XCTAssertEqual(secret.count, ProximityPairing.sharedSecretBytes)
            XCTAssertNotEqual(secret, enc.sharedSecret)
        }
    }

    func testKemRejectsMalformedKeys() throws {
        // FIPS 203 §7.2 modulus check: every 12-bit coefficient 0xFFF >= q.
        let badPublicKey = bytes(ProximityPairing.mlKemPublicKeyBytes, 0xff)
        XCTAssertThrowsError(try ProximityPairingCrypto.kemEncapsulate(publicKey: badPublicKey))
        XCTAssertThrowsError(try ProximityPairingCrypto.kemEncapsulate(publicKey: badPublicKey,
                                                                      seed: bytes(32, 1)))

        // FIPS 203 §7.3 hash check: dk = dk_pke ‖ ek ‖ H(ek) ‖ z; corrupt H(ek).
        let pair = try ProximityPairingCrypto.kemGenerateKeyPair()
        let enc = try ProximityPairingCrypto.kemEncapsulate(publicKey: pair.publicKey)
        let hashOffset: Int = ProximityPairing.mlKemSecretKeyBytes - 64
        let badSecretKey = flipped(pair.secretKey, at: hashOffset)
        XCTAssertThrowsError(try ProximityPairingCrypto.kemDecapsulate(ciphertext: enc.ciphertext,
                                                                      secretKey: badSecretKey))
    }

    func testKemWrongLengthsThrow() throws {
        let pair = try ProximityPairingCrypto.kemGenerateKeyPair()
        let enc = try ProximityPairingCrypto.kemEncapsulate(publicKey: pair.publicKey)
        let pk = pair.publicKey
        let sk = pair.secretKey
        let ct = enc.ciphertext

        let keypairSeeds: [Int] = [0, 32, 63, 65]
        for length in keypairSeeds {
            XCTAssertThrowsError(try ProximityPairingCrypto.kemGenerateKeyPair(seed: bytes(length, 7)))
        }
        let publicKeyLengths: [Int] = [0, 1, pk.count - 1, pk.count + 1]
        for length in publicKeyLengths {
            let candidate: Data = length <= pk.count ? Data(pk.prefix(length)) : pk + Data([0])
            XCTAssertThrowsError(try ProximityPairingCrypto.kemEncapsulate(publicKey: candidate))
            XCTAssertThrowsError(try ProximityPairingCrypto.kemEncapsulate(publicKey: candidate, seed: bytes(32, 1)))
        }
        let encapsSeeds: [Int] = [0, 31, 33, 64]
        for length in encapsSeeds {
            XCTAssertThrowsError(try ProximityPairingCrypto.kemEncapsulate(publicKey: pk, seed: bytes(length, 1)))
        }
        let ciphertexts: [Data] = [Data(), Data(ct.prefix(ct.count - 1)), ct + Data([0])]
        for candidate in ciphertexts {
            XCTAssertThrowsError(try ProximityPairingCrypto.kemDecapsulate(ciphertext: candidate, secretKey: sk))
        }
        let secretKeys: [Data] = [Data(), Data(sk.prefix(sk.count - 1)), sk + Data([0]), pk]
        for candidate in secretKeys {
            XCTAssertThrowsError(try ProximityPairingCrypto.kemDecapsulate(ciphertext: ct, secretKey: candidate))
        }
    }

    // MARK: - X25519

    func testX25519AgreementIsSymmetric() throws {
        let a = Curve25519.KeyAgreement.PrivateKey()
        let b = Curve25519.KeyAgreement.PrivateKey()
        let ab = try ProximityPairingCrypto.x25519SharedSecret(privateKey: a,
                                                               peerPublicKey: b.publicKey.rawRepresentation)
        let ba = try ProximityPairingCrypto.x25519SharedSecret(privateKey: b,
                                                               peerPublicKey: a.publicKey.rawRepresentation)
        XCTAssertEqual(ab.count, 32)
        XCTAssertEqual(ab, ba)

        // Slices with a non-zero startIndex are accepted.
        var padded = Data([0xee, 0xee])
        padded.append(b.publicKey.rawRepresentation)
        let slice: Data = padded[2..<34]
        let fromSlice = try ProximityPairingCrypto.x25519SharedSecret(privateKey: a, peerPublicKey: slice)
        XCTAssertEqual(fromSlice, ab)
    }

    func testX25519RejectsLowOrderPoints() {
        var ffTail = Data([0xec])
        ffTail.append(bytes(30, 0xff))
        ffTail.append(Data([0x7f]))                      // p - 1
        var pEncoding = Data([0xed])
        pEncoding.append(bytes(30, 0xff))
        pEncoding.append(Data([0x7f]))                   // p (non-canonical 0)
        var pPlusOne = Data([0xee])
        pPlusOne.append(bytes(30, 0xff))
        pPlusOne.append(Data([0x7f]))                    // p + 1 (non-canonical 1)
        var one = Data([0x01])
        one.append(bytes(31, 0x00))

        let lowOrder: [Data] = [
            bytes(32, 0x00),
            one,
            proxCryptoHex("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"),
            proxCryptoHex("5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157"),
            ffTail,
            pEncoding,
            pPlusOne
        ]
        let key = Curve25519.KeyAgreement.PrivateKey()
        for point in lowOrder {
            XCTAssertEqual(point.count, 32)
            XCTAssertThrowsError(try ProximityPairingCrypto.x25519SharedSecret(privateKey: key,
                                                                              peerPublicKey: point))
        }
    }

    func testX25519RejectsWrongLengths() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let peer = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let candidates: [Data] = [Data(), Data(peer.prefix(31)), peer + Data([0x01])]
        for candidate in candidates {
            XCTAssertThrowsError(try ProximityPairingCrypto.x25519SharedSecret(privateKey: key,
                                                                              peerPublicKey: candidate))
        }
    }

    // MARK: - Ed25519

    func testSignVerify() throws {
        let key = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation
        let payload = ProximityPairingCrypto.signaturePayload(role: .scanner, transcriptHash: bytes(32, 0x42))
        let signature = try ProximityPairingCrypto.sign(payload, signingPrivateKey: key.rawRepresentation)
        XCTAssertEqual(signature.count, ProximityPairing.ed25519SignatureBytes)
        XCTAssertTrue(ProximityPairingCrypto.verify(signature: signature, payload: payload,
                                                    signingPublicKey: publicKey))

        XCTAssertFalse(ProximityPairingCrypto.verify(signature: signature, payload: flipped(payload, at: 40),
                                                     signingPublicKey: publicKey))
        XCTAssertFalse(ProximityPairingCrypto.verify(signature: flipped(signature, at: 10), payload: payload,
                                                     signingPublicKey: publicKey))
        XCTAssertFalse(ProximityPairingCrypto.verify(signature: signature, payload: payload,
                                                     signingPublicKey: other.publicKey.rawRepresentation))
        // Role separation: a scanner signature is not a displayer signature.
        let displayerPayload = ProximityPairingCrypto.signaturePayload(role: .displayer,
                                                                       transcriptHash: bytes(32, 0x42))
        XCTAssertFalse(ProximityPairingCrypto.verify(signature: signature, payload: displayerPayload,
                                                     signingPublicKey: publicKey))
    }

    func testSignVerifyRejectMalformedInputs() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation
        let payload = Data("payload".utf8)
        let signature = try ProximityPairingCrypto.sign(payload, signingPrivateKey: key.rawRepresentation)

        XCTAssertThrowsError(try ProximityPairingCrypto.sign(payload, signingPrivateKey: Data()))
        XCTAssertThrowsError(try ProximityPairingCrypto.sign(payload, signingPrivateKey: bytes(31, 1)))
        XCTAssertThrowsError(try ProximityPairingCrypto.sign(payload, signingPrivateKey: bytes(33, 1)))
        XCTAssertThrowsError(try ProximityPairingCrypto.sign(Data(), signingPrivateKey: key.rawRepresentation))

        XCTAssertFalse(ProximityPairingCrypto.verify(signature: Data(signature.prefix(63)), payload: payload,
                                                     signingPublicKey: publicKey))
        XCTAssertFalse(ProximityPairingCrypto.verify(signature: signature + Data([0]), payload: payload,
                                                     signingPublicKey: publicKey))
        XCTAssertFalse(ProximityPairingCrypto.verify(signature: Data(), payload: payload,
                                                     signingPublicKey: publicKey))
        XCTAssertFalse(ProximityPairingCrypto.verify(signature: signature, payload: payload,
                                                     signingPublicKey: Data(publicKey.prefix(31))))
        XCTAssertFalse(ProximityPairingCrypto.verify(signature: signature, payload: payload,
                                                     signingPublicKey: Data()))
        XCTAssertFalse(ProximityPairingCrypto.verify(signature: signature, payload: Data(),
                                                     signingPublicKey: publicKey))
    }

    // MARK: - constantTimeEquals

    func testConstantTimeEquals() {
        let a = pattern(32, seed: 3)
        XCTAssertTrue(ProximityPairingCrypto.constantTimeEquals(a, Data(a)))
        XCTAssertFalse(ProximityPairingCrypto.constantTimeEquals(a, flipped(a, at: 0)))
        XCTAssertFalse(ProximityPairingCrypto.constantTimeEquals(a, flipped(a, at: 31)))
        XCTAssertFalse(ProximityPairingCrypto.constantTimeEquals(a, Data(a.prefix(31))))
        XCTAssertFalse(ProximityPairingCrypto.constantTimeEquals(a, a + Data([0])))
        XCTAssertFalse(ProximityPairingCrypto.constantTimeEquals(Data(), Data()))
        XCTAssertFalse(ProximityPairingCrypto.constantTimeEquals(Data(), a))
        XCTAssertFalse(ProximityPairingCrypto.constantTimeEquals(a, Data()))
        XCTAssertTrue(ProximityPairingCrypto.constantTimeEquals(Data([0]), Data([0])))

        var padded = Data([9, 9, 9])
        padded.append(a)
        let slice: Data = padded[3..<35]
        XCTAssertTrue(ProximityPairingCrypto.constantTimeEquals(slice, a))
        XCTAssertTrue(ProximityPairingCrypto.constantTimeEquals(a, slice))
    }

    // MARK: - Non-throwing derivations fail closed on wrong lengths

    func testNonThrowingDerivationsReturnEmptyOnWrongLengths() {
        let secret = bytes(32, 1)
        let sessionId = bytes(16, 2)
        let key32 = bytes(32, 3)
        let th = bytes(32, 4)
        XCTAssertEqual(ProximityPairingCrypto.frameKey(sessionSecret: secret, sessionId: sessionId, frameIndex: 0).count, 32)
        XCTAssertTrue(ProximityPairingCrypto.frameKey(sessionSecret: bytes(31, 1), sessionId: sessionId, frameIndex: 0).isEmpty)
        XCTAssertTrue(ProximityPairingCrypto.frameKey(sessionSecret: secret, sessionId: bytes(17, 2), frameIndex: 0).isEmpty)

        XCTAssertEqual(ProximityPairingCrypto.helloTag(frameKey: key32, sessionId: sessionId, frameIndex: 1,
                                                       scannerEphemeralX25519: key32, scannerNonce: key32).count, 32)
        XCTAssertTrue(ProximityPairingCrypto.helloTag(frameKey: bytes(31, 3), sessionId: sessionId, frameIndex: 1,
                                                      scannerEphemeralX25519: key32, scannerNonce: key32).isEmpty)
        XCTAssertTrue(ProximityPairingCrypto.helloTag(frameKey: key32, sessionId: bytes(15, 2), frameIndex: 1,
                                                      scannerEphemeralX25519: key32, scannerNonce: key32).isEmpty)
        XCTAssertTrue(ProximityPairingCrypto.helloTag(frameKey: key32, sessionId: sessionId, frameIndex: 1,
                                                      scannerEphemeralX25519: bytes(33, 3), scannerNonce: key32).isEmpty)
        XCTAssertTrue(ProximityPairingCrypto.helloTag(frameKey: key32, sessionId: sessionId, frameIndex: 1,
                                                      scannerEphemeralX25519: key32, scannerNonce: bytes(31, 3)).isEmpty)

        XCTAssertEqual(ProximityPairingCrypto.commitment(sessionId: sessionId, offerBody: Data([1])).count, 32)
        XCTAssertTrue(ProximityPairingCrypto.commitment(sessionId: bytes(15, 2), offerBody: Data([1])).isEmpty)
        XCTAssertTrue(ProximityPairingCrypto.commitment(sessionId: sessionId, offerBody: Data()).isEmpty)

        let qr = bytes(85, 5)
        let hello = bytes(100, 6)
        XCTAssertEqual(ProximityPairingCrypto.transcriptHash(qrBytes: qr, helloBody: hello,
                                                             offerBody: Data([1]), acceptUnsignedBody: Data([2])).count, 32)
        XCTAssertTrue(ProximityPairingCrypto.transcriptHash(qrBytes: bytes(84, 5), helloBody: hello,
                                                            offerBody: Data([1]), acceptUnsignedBody: Data([2])).isEmpty)
        XCTAssertTrue(ProximityPairingCrypto.transcriptHash(qrBytes: qr, helloBody: bytes(101, 6),
                                                            offerBody: Data([1]), acceptUnsignedBody: Data([2])).isEmpty)
        XCTAssertTrue(ProximityPairingCrypto.transcriptHash(qrBytes: qr, helloBody: hello,
                                                            offerBody: Data(), acceptUnsignedBody: Data([2])).isEmpty)
        XCTAssertTrue(ProximityPairingCrypto.transcriptHash(qrBytes: qr, helloBody: hello,
                                                            offerBody: Data([1]), acceptUnsignedBody: Data()).isEmpty)

        XCTAssertEqual(ProximityPairingCrypto.transcriptMac(key: key32, transcriptHash: th).count, 32)
        XCTAssertTrue(ProximityPairingCrypto.transcriptMac(key: bytes(31, 3), transcriptHash: th).isEmpty)
        XCTAssertTrue(ProximityPairingCrypto.transcriptMac(key: key32, transcriptHash: bytes(33, 4)).isEmpty)
        XCTAssertEqual(ProximityPairingCrypto.confirmationMac(key: key32).count, 32)
        XCTAssertTrue(ProximityPairingCrypto.confirmationMac(key: Data()).isEmpty)
        XCTAssertTrue(ProximityPairingCrypto.signaturePayload(role: .scanner, transcriptHash: bytes(31, 4)).isEmpty)
        XCTAssertTrue(ProximityPairingCrypto.signaturePayload(role: .displayer, transcriptHash: Data()).isEmpty)

        XCTAssertEqual(ProximityPairingCrypto.sas(fromBytes: bytes(7, 1)), "")
        XCTAssertEqual(ProximityPairingCrypto.sas(fromBytes: bytes(9, 1)), "")
        XCTAssertEqual(ProximityPairingCrypto.sas(fromBytes: Data()), "")
    }

    func testFrameKeysDifferPerIndexAndSession() {
        let secret = bytes(32, 1)
        let sessionId = bytes(16, 2)
        let k0 = ProximityPairingCrypto.frameKey(sessionSecret: secret, sessionId: sessionId, frameIndex: 0)
        let k1 = ProximityPairingCrypto.frameKey(sessionSecret: secret, sessionId: sessionId, frameIndex: 1)
        let kOtherSession = ProximityPairingCrypto.frameKey(sessionSecret: secret, sessionId: flipped(sessionId, at: 0),
                                                            frameIndex: 0)
        let kOtherSecret = ProximityPairingCrypto.frameKey(sessionSecret: flipped(secret, at: 0), sessionId: sessionId,
                                                           frameIndex: 0)
        XCTAssertNotEqual(k0, k1)
        XCTAssertNotEqual(k0, kOtherSession)
        XCTAssertNotEqual(k0, kOtherSecret)
    }

    // MARK: - Key schedule

    private func baseScheduleInputs() -> [Data] {
        return [pattern(32, seed: 0xa0), pattern(32, seed: 0xb0), pattern(32, seed: 0xc0),
                pattern(32, seed: 0xd0), pattern(32, seed: 0xe0)]
    }

    private func scheduleOutputs(_ inputs: [Data]) throws -> [Data] {
        let keys = try ProximityPairingCrypto.deriveSessionKeys(transcriptHash: inputs[0],
                                                                kemSharedSecret: inputs[1],
                                                                x25519SharedSecret: inputs[2],
                                                                scannerNonce: inputs[3],
                                                                displayerNonce: inputs[4])
        return [keys.macKeyScanner, keys.macKeyDisplayer, keys.confirmKeyScanner,
                keys.confirmKeyDisplayer, keys.sasBytes, keys.psk]
    }

    func testDeriveSessionKeysRejectsWrongLengths() {
        let base = baseScheduleInputs()
        var slot: Int = 0
        while slot < base.count {
            let lengths: [Int] = [0, 31, 33, 64]
            for length in lengths {
                var inputs = base
                inputs[slot] = bytes(length, 0x11)
                XCTAssertThrowsError(try scheduleOutputs(inputs))
            }
            slot += 1
        }
    }

    func testDerivedOutputsArePairwiseDistinct() throws {
        let keys = try ProximityPairingCrypto.deriveSessionKeys(transcriptHash: bytes(32, 1),
                                                                kemSharedSecret: bytes(32, 2),
                                                                x25519SharedSecret: bytes(32, 3),
                                                                scannerNonce: bytes(32, 4),
                                                                displayerNonce: bytes(32, 5))
        let outputs: [Data] = [keys.macKeyScanner, keys.macKeyDisplayer, keys.confirmKeyScanner,
                               keys.confirmKeyDisplayer, keys.sasBytes, keys.psk]
        XCTAssertEqual(keys.macKeyScanner.count, 32)
        XCTAssertEqual(keys.sasBytes.count, 8)
        XCTAssertEqual(keys.psk.count, 32)
        XCTAssertEqual(keys.prk.count, 32)
        XCTAssertEqual(keys.sas.count, 6)
        XCTAssertEqual(keys.sas, ProximityPairingCrypto.sas(fromBytes: keys.sasBytes))
        var i: Int = 0
        while i < outputs.count {
            var j: Int = i + 1
            while j < outputs.count {
                XCTAssertNotEqual(outputs[i], outputs[j])
                // The 8 SAS bytes must not be a prefix of any 32-byte key either.
                XCTAssertNotEqual(Data(outputs[i].prefix(8)), Data(outputs[j].prefix(8)))
                j += 1
            }
            i += 1
        }
    }

    func testEverySingleInputByteChangesEveryOutput() throws {
        let base = baseScheduleInputs()
        let reference = try scheduleOutputs(base)
        var slot: Int = 0
        while slot < base.count {
            var position: Int = 0
            while position < 32 {
                var inputs = base
                inputs[slot] = flipped(base[slot], at: position)
                let changed = try scheduleOutputs(inputs)
                var k: Int = 0
                while k < reference.count {
                    if changed[k] == reference[k] {
                        let location: String = "slot " + String(describing: slot) + " byte " + String(describing: position)
                        XCTFail(location)
                    }
                    k += 1
                }
                position += 1
            }
            slot += 1
        }
    }

    func testRoleMacsAreNotInterchangeable() throws {
        let th = bytes(32, 9)
        let keys = try ProximityPairingCrypto.deriveSessionKeys(transcriptHash: th,
                                                                kemSharedSecret: bytes(32, 2),
                                                                x25519SharedSecret: bytes(32, 3),
                                                                scannerNonce: bytes(32, 4),
                                                                displayerNonce: bytes(32, 5))
        let macS = ProximityPairingCrypto.transcriptMac(key: keys.macKeyScanner, transcriptHash: th)
        let macD = ProximityPairingCrypto.transcriptMac(key: keys.macKeyDisplayer, transcriptHash: th)
        let confirmS = ProximityPairingCrypto.confirmationMac(key: keys.confirmKeyScanner)
        let confirmD = ProximityPairingCrypto.confirmationMac(key: keys.confirmKeyDisplayer)
        XCTAssertFalse(ProximityPairingCrypto.constantTimeEquals(macS, macD))
        XCTAssertFalse(ProximityPairingCrypto.constantTimeEquals(confirmS, confirmD))
        XCTAssertFalse(ProximityPairingCrypto.constantTimeEquals(macS, confirmS))
        let otherTh = flipped(th, at: 0)
        XCTAssertFalse(ProximityPairingCrypto.constantTimeEquals(
            macS, ProximityPairingCrypto.transcriptMac(key: keys.macKeyScanner, transcriptHash: otherTh)))
    }

    func testEndToEndHybridAgreementMatchesOnBothSides() throws {
        // Scanner encapsulates to the displayer's ek and runs X25519; displayer
        // decapsulates and runs X25519 the other way. Both key schedules must agree.
        let kem = try ProximityPairingCrypto.kemGenerateKeyPair()
        let xD = Curve25519.KeyAgreement.PrivateKey()
        let xS = Curve25519.KeyAgreement.PrivateKey()
        let nonceS = try ProximityPairingCrypto.randomBytes(32)
        let nonceD = try ProximityPairingCrypto.randomBytes(32)
        let th = try ProximityPairingCrypto.randomBytes(32)

        let enc = try ProximityPairingCrypto.kemEncapsulate(publicKey: kem.publicKey)
        let ssXScanner = try ProximityPairingCrypto.x25519SharedSecret(privateKey: xS,
                                                                       peerPublicKey: xD.publicKey.rawRepresentation)
        var scannerKeys = try ProximityPairingCrypto.deriveSessionKeys(transcriptHash: th,
                                                                       kemSharedSecret: enc.sharedSecret,
                                                                       x25519SharedSecret: ssXScanner,
                                                                       scannerNonce: nonceS,
                                                                       displayerNonce: nonceD)

        let ssKemDisplayer = try ProximityPairingCrypto.kemDecapsulate(ciphertext: enc.ciphertext,
                                                                       secretKey: kem.secretKey)
        let ssXDisplayer = try ProximityPairingCrypto.x25519SharedSecret(privateKey: xD,
                                                                         peerPublicKey: xS.publicKey.rawRepresentation)
        var displayerKeys = try ProximityPairingCrypto.deriveSessionKeys(transcriptHash: th,
                                                                         kemSharedSecret: ssKemDisplayer,
                                                                         x25519SharedSecret: ssXDisplayer,
                                                                         scannerNonce: nonceS,
                                                                         displayerNonce: nonceD)

        XCTAssertEqual(scannerKeys.psk, displayerKeys.psk)
        XCTAssertEqual(scannerKeys.sas, displayerKeys.sas)
        let macS = ProximityPairingCrypto.transcriptMac(key: scannerKeys.macKeyScanner, transcriptHash: th)
        let expected = ProximityPairingCrypto.transcriptMac(key: displayerKeys.macKeyScanner, transcriptHash: th)
        XCTAssertTrue(ProximityPairingCrypto.constantTimeEquals(macS, expected))

        scannerKeys.zeroize()
        displayerKeys.zeroize()
        XCTAssertTrue(scannerKeys.psk.isEmpty)
        XCTAssertTrue(displayerKeys.macKeyScanner.isEmpty)
    }
}

// MARK: - File-private hex decoding (other test files have their own)

private func proxCryptoHex(_ text: String) -> Data {
    let chars: [UInt8] = Array(text.utf8)
    var out = Data(capacity: chars.count / 2)
    var i: Int = 0
    while i + 1 < chars.count {
        let hi: UInt8 = proxCryptoNibble(chars[i])
        let lo: UInt8 = proxCryptoNibble(chars[i + 1])
        out.append((hi << 4) | lo)
        i += 2
    }
    return out
}

private func proxCryptoNibble(_ c: UInt8) -> UInt8 {
    switch c {
    case 48...57: return c - 48
    case 97...102: return c - 87
    case 65...70: return c - 55
    default: return 0
    }
}
