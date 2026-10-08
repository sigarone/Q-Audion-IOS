import XCTest
import CryptoKit
@testable import QAudionEngine

/// Small-order / non-canonical Ed25519 identity keys. With a permissive verifier the signature
/// `01 || 0^63` under the neutral element is valid for every message, so it proves no possession.
/// `Ed25519IdentityKeyPolicy` refuses such keys before CryptoKit is asked (CryptoKit's own behaviour is
/// not relied on: these tests pass whatever it does), `HandshakeTranscript.verify` uses it, and so do the
/// SAS-PIN book and the pin store in front of a write. Every value is synthetic.
final class Ed25519IdentityKeyPolicyTests: XCTestCase {

    private typealias F = V6TestFixtures

    // MARK: - Fixtures

    private func fromHex(_ text: String) -> Data {
        var out = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            out.append(UInt8(text[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    /// `b0 || ff x30 || top`: the encodings around p = 2^255-19 (`ed ff..ff 7f`).
    private func nearP(_ b0: UInt8, top: UInt8) -> Data {
        var bytes: [UInt8] = [b0]
        bytes.append(contentsOf: [UInt8](repeating: 0xff, count: 30))
        bytes.append(top)
        return Data(bytes)
    }

    /// The 8 canonical small-order points, copied here on purpose (the table in the helper is pinned
    /// against this independent copy).
    private let smallOrder: [String] = [
        "0100000000000000000000000000000000000000000000000000000000000000",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000080",
        "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
        "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85",
        "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac0374",
        "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03f4",
    ]

    private var neutral: Data { fromHex(smallOrder[0]) }
    private var orderTwo: Data { fromHex(smallOrder[1]) }
    private var honestKey: Data { F.signer(seed: 7).pubRaw }

    /// The classic forgery: `R = neutral (01 00..00)`, `S = 0`.
    private var forgedSignature: Data {
        var bytes: [UInt8] = [0x01]
        bytes.append(contentsOf: [UInt8](repeating: 0x00, count: 63))
        return Data(bytes)
    }

    // MARK: - HandshakeTranscript.verify

    func testNeutralKeyWithForgedSignatureVerifiesNothing() {
        let first = Data("first message".utf8)
        let second = Data("a different message".utf8)
        XCTAssertFalse(HandshakeTranscript.verify(
            transcript: first, signature: forgedSignature, signerIdentityKey: neutral))
        XCTAssertFalse(HandshakeTranscript.verify(
            transcript: second, signature: forgedSignature, signerIdentityKey: neutral))
    }

    func testOrderTwoKeyWithForgedSignatureVerifiesNothing() {
        // y = -1 (`ec ff..ff 7f`).
        let first = Data("first message".utf8)
        let second = Data("a different message".utf8)
        XCTAssertFalse(HandshakeTranscript.verify(
            transcript: first, signature: forgedSignature, signerIdentityKey: orderTwo))
        XCTAssertFalse(HandshakeTranscript.verify(
            transcript: second, signature: forgedSignature, signerIdentityKey: orderTwo))
    }

    func testEverySmallOrderAndAliasEncodingFailsVerifyOnAForgedSignature() {
        let message = Data("a message".utf8)
        var encodings: [Data] = smallOrder.map { fromHex($0) }
        encodings.append(nearP(0xed, top: 0x7f))
        encodings.append(nearP(0xee, top: 0x7f))
        encodings.append(nearP(0xed, top: 0xff))
        encodings.append(nearP(0xee, top: 0xff))
        encodings.append(fromHex("0100000000000000000000000000000000000000000000000000000000000080"))
        encodings.append(nearP(0xec, top: 0xff))
        for key in encodings {
            let label: String = key.map { String(format: "%02x", $0) }.joined()
            XCTAssertFalse(HandshakeTranscript.verify(
                transcript: message, signature: forgedSignature, signerIdentityKey: key), label)
        }
    }

    func testHonestSignatureStillVerifiesAndTheKeyIsAcceptable() throws {
        let signer = F.signer(seed: 11)
        let transcript = F.offerTranscript(signerKey: signer.pubRaw)
        let signature = try HandshakeTranscript.sign(
            transcript: transcript, signingPrivateKeyRaw: Data(repeating: 11, count: 32))
        XCTAssertTrue(Ed25519IdentityKeyPolicy.isAcceptable(signer.pubRaw))
        XCTAssertTrue(HandshakeTranscript.verify(
            transcript: transcript, signature: signature, signerIdentityKey: signer.pubRaw))
        // The same signature under another honest key, or on another transcript, is still refused.
        XCTAssertFalse(HandshakeTranscript.verify(
            transcript: transcript, signature: signature, signerIdentityKey: honestKey))
        XCTAssertFalse(HandshakeTranscript.verify(
            transcript: Data("other".utf8), signature: signature, signerIdentityKey: signer.pubRaw))
    }

    /// The policy verdict for a bundle that claims a small-order key and carries the forged signature,
    /// with no pin and no server key: `sig_invalid`, never `identity_unresolved` (which would let a SAS
    /// confirmation pin the key).
    func testPolicyAbortsWithSigInvalidNotIdentityUnresolvedForAForgedBundle() {
        let transcript = F.offerTranscript(signerKey: neutral)
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: neutral.base64EncodedString(),
            sigV6B64: forgedSignature.base64EncodedString(),
            dtlsFingerprintText: F.fingerprintText("offerer"),
            transcript: transcript,
            pinnedKey: nil,
            serverFetchedKey: nil,
            advertisedV4: true)
        guard case .abort(let code) = verdict else {
            return XCTFail("expected .abort, got \(verdict)")
        }
        XCTAssertEqual(code, "sig_invalid")
    }

    // MARK: - The helper

    func testTheEightCanonicalSmallOrderPointsAreRejected() {
        XCTAssertEqual(smallOrder.count, 8)
        XCTAssertEqual(Ed25519IdentityKeyPolicy.smallOrderPoints, smallOrder.map { fromHex($0) })
        for text in smallOrder {
            let key = fromHex(text)
            XCTAssertTrue(Ed25519IdentityKeyPolicy.isCanonicalSmallOrderPoint(key), text)
            XCTAssertFalse(Ed25519IdentityKeyPolicy.isAcceptable(key), text)
        }
    }

    func testSignBitVariantsOfTheXZeroPointsAreRejected() {
        // y = 1 and y = p-1 are the points with x = 0; RFC 8032 has no "negative zero".
        let neutralSigned = fromHex("0100000000000000000000000000000000000000000000000000000000000080")
        let orderTwoSigned = nearP(0xec, top: 0xff)
        for key in [neutralSigned, orderTwoSigned] {
            XCTAssertFalse(Ed25519IdentityKeyPolicy.isCanonicalSmallOrderPoint(key))
            XCTAssertTrue(Ed25519IdentityKeyPolicy.isNonCanonicalEncoding(key))
            XCTAssertFalse(Ed25519IdentityKeyPolicy.isAcceptable(key))
        }
    }

    func testEncodingsWithYAtOrAbovePAreRejected() {
        // `ee ff..ff 7f` is y = p+1: the neutral element, non-canonically.
        let candidates: [Data] = [
            nearP(0xed, top: 0x7f), nearP(0xee, top: 0x7f), nearP(0xef, top: 0x7f), nearP(0xff, top: 0x7f),
            nearP(0xed, top: 0xff), nearP(0xee, top: 0xff), nearP(0xff, top: 0xff),
            Data(repeating: 0xff, count: 32),
        ]
        for key in candidates {
            XCTAssertTrue(Ed25519IdentityKeyPolicy.isNonCanonicalEncoding(key))
            XCTAssertFalse(Ed25519IdentityKeyPolicy.isAcceptable(key))
        }
    }

    func testTheBoundaryJustBelowPIsNotCalledNonCanonical() {
        // y = p-2 is below p and not in the table: the policy leaves it to CryptoKit's own parsing.
        let key = nearP(0xeb, top: 0x7f)
        XCTAssertFalse(Ed25519IdentityKeyPolicy.isNonCanonicalEncoding(key))
        XCTAssertTrue(Ed25519IdentityKeyPolicy.isAcceptable(key))
        // One byte of the middle below 0xff is below p whatever the first byte is.
        var bytes = [UInt8](nearP(0xff, top: 0x7f))
        bytes[15] = 0xfe
        XCTAssertFalse(Ed25519IdentityKeyPolicy.isNonCanonicalEncoding(Data(bytes)))
    }

    func testWrongLengthsAreRejected() {
        XCTAssertFalse(Ed25519IdentityKeyPolicy.isAcceptable(Data()))
        XCTAssertFalse(Ed25519IdentityKeyPolicy.isAcceptable(honestKey.prefix(31)))
        XCTAssertFalse(Ed25519IdentityKeyPolicy.isAcceptable(honestKey + Data([0x00])))
    }

    func testHonestKeysAreAccepted() {
        for seed in UInt8(1)...UInt8(40) {
            XCTAssertTrue(Ed25519IdentityKeyPolicy.isAcceptable(F.signer(seed: seed).pubRaw), "seed \(seed)")
        }
    }

    // MARK: - SAS-PIN book, pin policy, pin store

    func testSasPinBookNeverRemembersOrConfirmsASmallOrderKey() {
        let book = CallScopedSasPinBook()
        book.noteUnresolved(callId: "c1", round: 1, signerKey: neutral)
        XCTAssertNil(book.signerAwaitingSas(callId: "c1", round: 1))
        XCTAssertFalse(book.isConflicted(callId: "c1"))
        // An honest key of the same call is remembered normally afterwards.
        book.noteUnresolved(callId: "c1", round: 1, signerKey: honestKey)
        XCTAssertEqual(book.signerAwaitingSas(callId: "c1", round: 1), honestKey)

        book.confirm(callId: "c2", key: neutral)
        XCTAssertNil(book.confirmedSigner(callId: "c2"))
        book.confirm(callId: "c2", key: orderTwo)
        XCTAssertNil(book.confirmedSigner(callId: "c2"))
        book.confirm(callId: "c2", key: honestKey)
        XCTAssertEqual(book.confirmedSigner(callId: "c2"), honestKey)
    }

    func testPinPolicyNeverPinsASmallOrderKey() {
        XCTAssertEqual(SasSignerPinPolicy.decide(storedPin: nil, confirmedKey: neutral), .conflict)
        XCTAssertEqual(SasSignerPinPolicy.decide(storedPin: nil, confirmedKey: nearP(0xee, top: 0x7f)), .conflict)
        XCTAssertEqual(SasSignerPinPolicy.decide(storedPin: nil, confirmedKey: honestKey), .pin)
        XCTAssertEqual(SasSignerPinPolicy.decide(storedPin: honestKey, confirmedKey: honestKey), .alreadyPinned)
    }

    /// These refusals happen before the Keychain is touched, so they run without it.
    func testPinStoreRefusesASmallOrderKeyBeforeAnyWrite() {
        let store = PeerIdentityPinStore()
        XCTAssertEqual(store.pinOrMatch(contactId: "peer-small-order", ed25519Pub: neutral), .mismatch)
        XCTAssertEqual(store.pinOrMatch(contactId: "peer-small-order", ed25519Pub: orderTwo, deviceId: "d1"), .mismatch)
        XCTAssertEqual(store.repin(contactId: "peer-small-order", ed25519Pub: neutral), .failed)
        XCTAssertEqual(store.repin(contactId: "peer-small-order", ed25519Pub: nearP(0xee, top: 0x7f), deviceId: "d1"), .failed)
    }

    func testProximityPairingVerifyRefusesASmallOrderKey() {
        XCTAssertFalse(ProximityPairingCrypto.verify(
            signature: forgedSignature, payload: Data("payload".utf8), signingPublicKey: neutral))
    }

    // MARK: - NFC SAS keeps its outcomes

    func testNfcSasStillRejectsEveryTableEntryAsSmallOrder() {
        for text in smallOrder {
            XCTAssertThrowsError(try NfcSasComputation.computeSas(
                selfIkEdPub: honestKey, peerIkEdPub: fromHex(text)), text) { error in
                XCTAssertEqual(error as? NfcSasComputation.SasError, .smallOrderPoint, text)
            }
        }
    }

    func testNfcSasStillAcceptsTwoHonestKeys() throws {
        let other = F.signer(seed: 9).pubRaw
        let sas = try NfcSasComputation.computeSas(selfIkEdPub: honestKey, peerIkEdPub: other)
        XCTAssertEqual(sas.count, NfcSasComputation.sasDigitCount)
    }
}
