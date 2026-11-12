import XCTest
import CryptoKit
@testable import QAudionEngine

/// The second handshake signature end to end on one side of a call: a sender builds real signed bundles, a receiver reads them with
/// its real integration (peer key lookup, signature check, pin judgement, key-confirmation hook, safety-code exit), and the pin
/// records and log lines are read back. The scenarios are those of the design: stripped members then a replaced OFFER, an invalid
/// signer, another key id, the signed withdrawal (positive and negative), the three rekey tests, the flag test and the size rule.
///
/// This code was written on a machine that cannot compile Swift for iOS: the macOS CI job is what runs it.
final class HybridSigWiringTests: XCTestCase {

    // MARK: - Fixtures

    private let peerUser = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private let deviceId = "device-one"
    private let fpOffer = V6TestFixtures.fingerprint("offerer")
    private let fpAccept = V6TestFixtures.fingerprint("acceptor")
    private let edSeed = Data(repeating: 0x31, count: 32)

    private var edPub: Data {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: edSeed).publicKey.rawRepresentation
    }

    private var uuidRaw: Data {
        withUnsafeBytes(of: UUID(uuidString: peerUser)!.uuid) { Data($0) }
    }

    /// Log lines of the decisions, newest last.
    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool
        init(_ value: Bool) { stored = value }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private var log = LogBox()

    override func setUp() {
        super.setUp()
        PeerMldsaStore.clear()
        let box = LogBox()
        log = box
        CapsBindLog.setSink { box.add($0) }
    }

    override func tearDown() {
        CapsBindLog.setSink(nil)
        PeerMldsaStore.clear()
        super.tearDown()
    }

    private func hex(_ data: Data) -> String { HybridBundleVerifier.hex(data) }

    private func callId(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012ld", n) }

    /// Puts the peer device's second key (certificate verified against its Ed25519 key, uuid and device) in the store.
    private func installPeerKey(seed: Data? = nil) throws {
        let s = seed ?? edSeed
        let pub = try Curve25519.Signing.PrivateKey(rawRepresentation: s).publicKey.rawRepresentation
        let fields = try XCTUnwrap(MldsaIdentityPublication.build(
            edSeed: s, edPub: pub, uuidRaw: uuidRaw, deviceId: deviceId, createdMs: 1_700_000_000_000))
        let verified = try XCTUnwrap(MldsaIdentityPublication.verifyPeer(
            pubB64: fields.pubB64, createdMs: fields.createdMs, edSigB64: fields.edSigB64, pqSigB64: fields.pqSigB64,
            gen: 0, keyIdB64: fields.keyIdB64, uuidRaw: uuidRaw, deviceId: deviceId, edPub: pub))
        PeerMldsaStore.record(uuidRaw: uuidRaw, deviceId: deviceId, edPub: pub, verified: verified)
    }

    private var peerKeyId: Data {
        Pqsig.keyFromIdentity(edSeed: edSeed, edPub: edPub, gen: 0)!.publicKey.keyId()
    }

    private func receiverRuntime() -> PqSigRuntime {
        PqSigRuntime(
            isAvailable: { false }, makeSigner: { nil },
            resolvePeerKey: { user, device, ed, keyId in
                await PeerMldsaResolve.resolve(peerUserId: user, deviceId: device, signerEdPub: ed, keyId: keyId, fetchDevice: { _, _ in })
            })
    }

    private func makeReceiver() -> (integration: QAudionCallIntegration, book: CapsPinBook) {
        let integration = QAudionCallIntegration()
        let book = CapsPinBook(persistence: MemoryCapsPinPersistence())
        integration.capsBindBook = book
        integration.pqSig = receiverRuntime()
        return (integration, book)
    }

    /// The device that signs: its own layer, so the sticky state of a call lives on it.
    private final class Sender {
        let layer = PqCallLayer()
        let available: FlagBox
        let failSigning: FlagBox
        let runtime: PqSigRuntime
        let seed: Data

        init(seed: Data, available: Bool = true) {
            self.seed = seed
            let pub = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
            let availableBox = FlagBox(available)
            let failBox = FlagBox(false)
            self.available = availableBox
            self.failSigning = failBox
            self.runtime = PqSigRuntime(
                isAvailable: { availableBox.value },
                makeSigner: { HybridBundleSigner(edSeed: seed, edPub: pub) },
                resolvePeerKey: { _, _, _, _ in nil },
                forceSignFailure: { failBox.value })
        }
    }

    private func baseOffer(call: String, round: Int, capsBind: Bool = true, padding: Int = 0) -> AndroidHandshakeBundle {
        AndroidHandshakeBundle(
            kind: .offer, callId: call,
            pqcPublicKey: Data(repeating: 0xA1, count: 1568).base64EncodedString(),
            x25519PublicKey: Data(repeating: 0xA2, count: 32).base64EncodedString(),
            capabilities: AndroidHandshakeBundle.Capabilities(
                ratchetV3: true, sframeV1: true, vkeyV1: true, hsTranscriptBindV1: true, capsBindV1: capsBind ? true : nil),
            pskFingerprints: [],
            selectedPskFingerprint: padding > 0 ? String(repeating: "a", count: padding) : nil,
            sasCommit: round == 1 ? V6TestFixtures.sasCommit.base64EncodedString() : nil,
            rekeyNonce: V6TestFixtures.rekeyNonce.base64EncodedString(), rekeyRound: round)
    }

    private func baseAccept(call: String, round: Int) -> AndroidHandshakeBundle {
        AndroidHandshakeBundle(
            kind: .accept, callId: call, pqcPublicKey: "", x25519PublicKey: "",
            ciphertext: AndroidHandshakeBundle.Ciphertext(
                pqc: Data(repeating: 0xB1, count: 1568).base64EncodedString(),
                x25519: Data(repeating: 0xB2, count: 32).base64EncodedString()),
            capabilities: AndroidHandshakeBundle.Capabilities(
                ratchetV3: true, sframeV1: true, vkeyV1: true, hsTranscriptBindV1: true, capsBindV1: true),
            pskFingerprints: [],
            rekeyNonce: V6TestFixtures.rekeyNonce.base64EncodedString(), rekeyRound: round)
    }

    private func offerTranscript(round: Int) -> Data {
        V6TestFixtures.offerTranscript(signerKey: edPub, dtls: fpOffer, round: UInt32(round))
    }

    private func acceptTranscript(round: Int) -> Data {
        V6TestFixtures.acceptTranscript(signerKey: edPub, offer: offerTranscript(round: round), dtls: fpAccept, round: UInt32(round))
    }

    /// A signed OFFER of the sender, as the receiver reads it off the wire.
    private func signedOffer(_ sender: Sender, call: String, round: Int, capsBind: Bool = true,
                             planOverride: PqSigPlan? = nil) throws -> AndroidHandshakeBundle {
        try sender.layer.finalizeOwn(
            bundle: baseOffer(call: call, round: round, capsBind: capsBind), kind: Pqsig.kindOffer, round: round, callId: call,
            transcript: offerTranscript(round: round), fpSelf: fpOffer, fpPeer: nil, runtime: sender.runtime,
            capsBindEnabled: true, planOverride: planOverride)
    }

    private func signedAccept(_ sender: Sender, call: String, round: Int) throws -> AndroidHandshakeBundle {
        try sender.layer.finalizeOwn(
            bundle: baseAccept(call: call, round: round), kind: Pqsig.kindAccept, round: round, callId: call,
            transcript: acceptTranscript(round: round), fpSelf: fpAccept, fpPeer: fpOffer, runtime: sender.runtime,
            capsBindEnabled: true)
    }

    /// Through the wire text and the real parser, the way a receiver gets a bundle.
    private func onTheWire(_ bundle: AndroidHandshakeBundle) throws -> AndroidHandshakeEnvelope.Parsed {
        try XCTUnwrap(AndroidHandshakeEnvelope.parse(AndroidHandshakeEnvelope.serialize(callId: bundle.callId, bundle: bundle)))
    }

    /// What an intermediary does: removes the tags and the second-signature members (and, with `keepCapsBind`, leaves the first tag).
    private func stripped(_ bundle: AndroidHandshakeBundle, keepCapsBind: Bool) -> AndroidHandshakeBundle {
        let caps = AndroidHandshakeBundle.Capabilities(
            ratchetV3: bundle.capabilities?.ratchetV3, sframeV1: bundle.capabilities?.sframeV1, vkeyV1: bundle.capabilities?.vkeyV1,
            hsTranscriptBindV1: bundle.capabilities?.hsTranscriptBindV1, capsBindV1: keepCapsBind ? true : nil)
        return bundle.withSecondSignature(capabilities: caps, mldsaKeyId: nil, sigHybrid: nil, capsWithdrawn: nil)
    }

    /// The signature with one byte flipped.
    private func corrupted(_ bundle: AndroidHandshakeBundle) throws -> AndroidHandshakeBundle {
        var sig = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(bundle.sigHybrid)))
        sig[100] ^= 0x01
        return bundle.withSecondSignature(capabilities: bundle.capabilities, mldsaKeyId: bundle.mldsaKeyId,
                                          sigHybrid: sig.base64EncodedString(), capsWithdrawn: bundle.capsWithdrawn)
    }

    private struct Round1Outcome {
        let pq: HybridBundleVerifier.Outcome?
        let call: CapsBindCallState.PinCall?
    }

    /// One round-1 OFFER delivered to the receiver: signature check, pin judgement and, with `keyConfirmed`, the round's key
    /// confirmation (`ext` when both bundles carry the first tag).
    @discardableResult
    private func receiveRound1(_ receiver: QAudionCallIntegration, _ bundle: AndroidHandshakeBundle, keyConfirmed: Bool = true,
                               ownAdvertisesCapsBind: Bool = true) async throws -> Round1Outcome {
        let parsed = try onTheWire(bundle)
        let pq = await receiver.pqVerifyInbound(
            isOffer: true, bundle: parsed.bundle, callId: bundle.callId, peerId: peerUser, deviceId: deviceId, signerKey: edPub,
            transcript: offerTranscript(round: 1), peerOwnFp: fpOffer, answeredFp: nil, peerCaps: parsed.capsBind)
        receiver.judgeCapsRound1(callId: bundle.callId, peerId: peerUser, peer: parsed.capsBind, verifiedKey: edPub,
                                 bundle: parsed.bundle, pq: pq)
        if keyConfirmed {
            receiver.noteRound1KeyConfirmed(callId: bundle.callId, ext: ownAdvertisesCapsBind && parsed.capsBind.hasTag)
        }
        return Round1Outcome(pq: pq, call: receiver.capsBindState.pinCall(callId: bundle.callId))
    }

    private func pinnedRecord(keyId: Data? = nil) -> CapsPinRecord {
        CapsPinRecord(caps: ["capsBindV1", "sigHybridV1"], mldsaKeyId: hex(keyId ?? peerKeyId), pqState: "pinned")
    }

    private func record(_ book: CapsPinBook) -> CapsPinRecord? {
        book.record(peerUserId: peerUser, signerKey: edPub)
    }

    private func warnings(of receiver: QAudionCallIntegration) -> WarningBox {
        let box = WarningBox()
        receiver.onCapsPinAnomaly = { _, _, reasons in box.add(reasons) }
        return box
    }

    private final class WarningBox {
        private(set) var all: [[PqWarnReason]] = []
        func add(_ reasons: [PqWarnReason]) { all.append(reasons) }
    }

    // MARK: - Signing and reading a bundle

    func testASignedBundleCarriesTheTagTheKeyIdAndTheSignatureAndVerifiesAfterTheWire() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        let (receiver, _) = makeReceiver()
        let signed = try signedOffer(sender, call: callId(1), round: 1)
        XCTAssertEqual(signed.capabilities?.sigHybridV1, true)
        XCTAssertEqual(signed.capabilities?.capsBindV1, true)
        XCTAssertEqual(signed.mldsaKeyId, peerKeyId.base64EncodedString())
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(signed.sigHybrid))?.count, Pqsig.hybridSigSize)
        XCTAssertNil(signed.capsWithdrawn)
        let outcome = try await receiveRound1(receiver, signed)
        XCTAssertEqual(outcome.pq?.result, .valid)
        XCTAssertEqual(outcome.pq?.keyId, hex(peerKeyId))
    }

    func testTheSignatureBindsTheBundleThePeerFingerprintAndTheCapsMembers() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        let (receiver, _) = makeReceiver()
        let signed = try signedOffer(sender, call: callId(1), round: 1)
        let parsed = try onTheWire(signed)
        // a different transcript (another bundle) does not verify
        let other = await receiver.pqVerifyInbound(
            isOffer: true, bundle: parsed.bundle, callId: callId(1), peerId: peerUser, deviceId: deviceId, signerKey: edPub,
            transcript: offerTranscript(round: 2), peerOwnFp: fpOffer, answeredFp: nil, peerCaps: parsed.capsBind)
        XCTAssertEqual(other?.result, .invalid)
        // another fingerprint of the signer does not verify
        let otherFp = await receiver.pqVerifyInbound(
            isOffer: true, bundle: parsed.bundle, callId: callId(1), peerId: peerUser, deviceId: deviceId, signerKey: edPub,
            transcript: offerTranscript(round: 1), peerOwnFp: fpAccept, answeredFp: nil, peerCaps: parsed.capsBind)
        XCTAssertEqual(otherFp?.result, .invalid)
        // a capability added on the way (CAPSX) does not verify
        let tampered = signed.withSecondSignature(
            capabilities: AndroidHandshakeBundle.Capabilities(
                ratchetV3: true, sframeV1: true, vkeyV1: true, hsTranscriptBindV1: true, capsBindV1: true, sigHybridV1: true),
            mldsaKeyId: signed.mldsaKeyId, sigHybrid: signed.sigHybrid, capsWithdrawn: ["abc"])
        let tamperedParsed = try onTheWire(tampered)
        let changed = await receiver.pqVerifyInbound(
            isOffer: true, bundle: tamperedParsed.bundle, callId: callId(1), peerId: peerUser, deviceId: deviceId, signerKey: edPub,
            transcript: offerTranscript(round: 1), peerOwnFp: fpOffer, answeredFp: nil, peerCaps: tamperedParsed.capsBind)
        XCTAssertEqual(changed?.result, .invalid, "EXTX binds the withdrawal list")
        // the ACCEPT form binds both fingerprints
        let accept = try signedAccept(sender, call: callId(1), round: 1)
        let acceptParsed = try onTheWire(accept)
        let good = await receiver.pqVerifyInbound(
            isOffer: false, bundle: acceptParsed.bundle, callId: callId(1), peerId: peerUser, deviceId: deviceId, signerKey: edPub,
            transcript: acceptTranscript(round: 1), peerOwnFp: fpAccept, answeredFp: fpOffer, peerCaps: acceptParsed.capsBind)
        XCTAssertEqual(good?.result, .valid)
        let wrongPeerFp = await receiver.pqVerifyInbound(
            isOffer: false, bundle: acceptParsed.bundle, callId: callId(1), peerId: peerUser, deviceId: deviceId, signerKey: edPub,
            transcript: acceptTranscript(round: 1), peerOwnFp: fpAccept, answeredFp: fpAccept, peerCaps: acceptParsed.capsBind)
        XCTAssertEqual(wrongPeerFp?.result, .invalid)
    }

    func testTheKeyComesOnlyFromTheStoreBoundToTheSameEdKeyUuidDeviceAndKeyId() async throws {
        let sender = Sender(seed: edSeed)
        let signed = try signedOffer(sender, call: callId(1), round: 1)
        let parsed = try onTheWire(signed)
        let (receiver, _) = makeReceiver()
        func verify(user: String, device: String?, key: Data) async -> PqSigResult? {
            await receiver.pqVerifyInbound(
                isOffer: true, bundle: parsed.bundle, callId: callId(1), peerId: user, deviceId: device, signerKey: key,
                transcript: offerTranscript(round: 1), peerOwnFp: fpOffer, answeredFp: nil, peerCaps: parsed.capsBind)?.result
        }
        // nothing stored: no key available
        let none = await verify(user: peerUser, device: deviceId, key: edPub)
        XCTAssertEqual(none, .unavailable)
        try installPeerKey()
        let ok = await verify(user: peerUser, device: deviceId, key: edPub)
        XCTAssertEqual(ok, .valid)
        // another device id, another user, no device id, another Ed25519 key: no key
        let otherDevice = await verify(user: peerUser, device: "device-two", key: edPub)
        XCTAssertEqual(otherDevice, .unavailable)
        let otherUser = await verify(user: "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee", device: deviceId, key: edPub)
        XCTAssertEqual(otherUser, .unavailable)
        let noDevice = await verify(user: peerUser, device: nil, key: edPub)
        XCTAssertEqual(noDevice, .unavailable)
        let otherKey = await verify(user: peerUser, device: deviceId, key: Data(repeating: 0x07, count: 32))
        XCTAssertEqual(otherKey, .unavailable)
        // a stored key that is not the one the bundle names is no key
        let (r2, _) = makeReceiver()
        let renamed = signed.withSecondSignature(
            capabilities: signed.capabilities, mldsaKeyId: Data(repeating: 0x55, count: 32).base64EncodedString(),
            sigHybrid: signed.sigHybrid, capsWithdrawn: nil)
        let renamedParsed = try onTheWire(renamed)
        let named = await r2.pqVerifyInbound(
            isOffer: true, bundle: renamedParsed.bundle, callId: callId(1), peerId: peerUser, deviceId: deviceId, signerKey: edPub,
            transcript: offerTranscript(round: 1), peerOwnFp: fpOffer, answeredFp: nil, peerCaps: renamedParsed.capsBind)
        XCTAssertEqual(named?.result, .unavailable)
    }

    func testAnUnsignedBundleAndAMalformedSignatureAreJudgedWithoutALookup() async throws {
        let (receiver, _) = makeReceiver()
        let sender = Sender(seed: edSeed, available: false)
        let unsigned = try signedOffer(sender, call: callId(1), round: 1)
        XCTAssertNil(unsigned.sigHybrid)
        XCTAssertNil(unsigned.mldsaKeyId)
        XCTAssertNil(unsigned.capabilities?.sigHybridV1)
        let parsed = try onTheWire(unsigned)
        let absent = await receiver.pqVerifyInbound(
            isOffer: true, bundle: parsed.bundle, callId: callId(1), peerId: peerUser, deviceId: deviceId, signerKey: edPub,
            transcript: offerTranscript(round: 1), peerOwnFp: fpOffer, answeredFp: nil, peerCaps: parsed.capsBind)
        XCTAssertEqual(absent?.result, .absent)
        // a signature that is not canonical base64 of 4691 bytes is invalid, a key id of the wrong size too
        for (sig, keyId) in [("AAAA", Data(repeating: 1, count: 32).base64EncodedString()),
                             (Data(repeating: 1, count: Pqsig.hybridSigSize).base64EncodedString(), "AAAA"),
                             (Data(repeating: 1, count: Pqsig.hybridSigSize).base64EncodedString(), "")] {
            let b = unsigned.withSecondSignature(capabilities: unsigned.capabilities, mldsaKeyId: keyId, sigHybrid: sig, capsWithdrawn: nil)
            let p = try onTheWire(b)
            let r = await receiver.pqVerifyInbound(
                isOffer: true, bundle: p.bundle, callId: callId(1), peerId: peerUser, deviceId: deviceId, signerKey: edPub,
                transcript: offerTranscript(round: 1), peerOwnFp: fpOffer, answeredFp: nil, peerCaps: p.capsBind)
            XCTAssertEqual(r?.result, .invalid, String(sig.prefix(8)) + "/" + String(keyId.prefix(8)))
        }
        // no signer key that verified sigV6: the signature is not judged at all
        let notJudged = await receiver.pqVerifyInbound(
            isOffer: true, bundle: parsed.bundle, callId: callId(1), peerId: peerUser, deviceId: deviceId, signerKey: nil,
            transcript: offerTranscript(round: 1), peerOwnFp: fpOffer, answeredFp: nil, peerCaps: parsed.capsBind)
        XCTAssertNil(notJudged)
    }

    // MARK: - Stripped members, then a replaced OFFER

    func testStrippedMembersThenAReplacedOffer() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        let (receiver, book) = makeReceiver()
        let shown = warnings(of: receiver)

        // call 1: honest: pinned, no warning, authenticated by the second signature
        let honest1 = try signedOffer(sender, call: callId(1), round: 1)
        let c1 = try await receiveRound1(receiver, honest1)
        XCTAssertEqual(record(book), pinnedRecord())
        XCTAssertEqual(c1.call?.pq?.auth, "H")
        XCTAssertTrue(shown.all.isEmpty)
        receiver.onCallEnded()

        // call 2: an intermediary removes both tags, the signature and the key id from the pinned device's OFFER: not held, the warning is
        // shown with both reasons (the signature first), the call is not ended; the user confirms the safety code from the warning
        let honest2 = try signedOffer(sender, call: callId(2), round: 1)
        let c2 = try await receiveRound1(receiver, stripped(honest2, keepCapsBind: false))
        XCTAssertEqual(c2.pq?.result, .absent)
        XCTAssertEqual(c2.call?.pin, .anomaly)
        XCTAssertEqual(c2.call?.hold, false)
        XCTAssertEqual(c2.call?.warns, [.absent, .capsBindV1Missing])
        XCTAssertEqual(shown.all.last, [.absent, .capsBindV1Missing])
        XCTAssertFalse(receiver.isMediaHeld(callId: callId(2)), "nothing is held")
        XCTAssertEqual(record(book), pinnedRecord(), "nothing changes until the safety code is confirmed")
        XCTAssertTrue(receiver.confirmCapsPinAnomaly(callId: callId(2)))
        // the key id is kept (the second stage must show a warning too), the tag of the call settings is dropped
        XCTAssertEqual(record(book), CapsPinRecord(caps: [], mldsaKeyId: hex(peerKeyId), pqState: "withdrawn-unsigned"))
        receiver.onCallEnded()

        // call 3: another party answers with its own OFFER, signed under the identity key (sigV6 is not what this
        // test checks) but has no second signature: not held, the warning names the missing signature, logged with the shared words
        let honest3 = try signedOffer(sender, call: callId(3), round: 1)
        let c3 = try await receiveRound1(receiver, stripped(honest3, keepCapsBind: true))
        XCTAssertEqual(c3.pq?.result, .absent)
        XCTAssertEqual(c3.call?.warns, [.absent])
        XCTAssertEqual(c3.call?.hold, false)
        XCTAssertEqual(c3.call?.pq?.auth, "C")
        XCTAssertFalse(receiver.isMediaHeld(callId: callId(3)))
        // the round's key confirmation verified with both bundles carrying the first tag, so the record has it; the key id stays
        XCTAssertEqual(record(book), CapsPinRecord(caps: ["capsBindV1"], mldsaKeyId: hex(peerKeyId), pqState: "withdrawn-unsigned"))
        let line3 = try XCTUnwrap(log.lines.last { $0.contains("pq round=1 pin=anomaly") }, "the decision line")
        XCTAssertTrue(line3.contains("hold=0"), line3)
        XCTAssertTrue(line3.contains("pq_sig=absent"), line3)
        XCTAssertTrue(line3.contains("pqstate=withdrawn-unsigned"), line3)
        XCTAssertTrue(line3.contains("auth=C"), line3)
        receiver.onCallEnded()

        // call 4: honest again: pinned again, no warning
        let before = shown.all.count
        let c4 = try await receiveRound1(receiver, try signedOffer(sender, call: callId(4), round: 1))
        XCTAssertEqual(c4.call?.pq?.auth, "H")
        XCTAssertEqual(shown.all.count, before, "no warning")
        XCTAssertEqual(record(book), pinnedRecord())
    }

    func testTheSafetyCodeConfirmedBeforeTheKeyConfirmationIsAppliedWhenItVerifies() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        let (receiver, book) = makeReceiver()
        try await receiveRound1(receiver, try signedOffer(sender, call: callId(1), round: 1))
        receiver.onCallEnded()
        let honest = try signedOffer(sender, call: callId(2), round: 1)
        try await receiveRound1(receiver, stripped(honest, keepCapsBind: false), keyConfirmed: false)
        XCTAssertTrue(receiver.confirmCapsPinAnomaly(callId: callId(2)))
        XCTAssertEqual(record(book), pinnedRecord(), "the round has not verified yet: no record change")
        receiver.noteRound1KeyConfirmed(callId: callId(2), ext: false)
        XCTAssertEqual(record(book), CapsPinRecord(caps: [], mldsaKeyId: hex(peerKeyId), pqState: "withdrawn-unsigned"))
    }

    func testAFailedKeyConfirmationChangesNothingAndNoPinIsSetWithoutOne() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        let (receiver, book) = makeReceiver()
        // no key confirmation arrives (the round ended on kcmac_mismatch): the first honest round pins nothing
        try await receiveRound1(receiver, try signedOffer(sender, call: callId(1), round: 1), keyConfirmed: false)
        XCTAssertNil(record(book))
        // an unverified signer key reads and writes no record
        let parsed = try onTheWire(try signedOffer(sender, call: callId(2), round: 1))
        receiver.judgeCapsRound1(callId: callId(2), peerId: peerUser, peer: parsed.capsBind, verifiedKey: nil, bundle: parsed.bundle, pq: nil)
        XCTAssertNil(record(book))
        XCTAssertNil(receiver.capsBindState.pinCall(callId: callId(2)))
    }

    // MARK: - Invalid signer

    func testTheInvalidSignerShowsTheWarningOnEveryCallAndRecoversWhenItSignsAgain() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        let (receiver, book) = makeReceiver()
        let shown = warnings(of: receiver)
        try await receiveRound1(receiver, try signedOffer(sender, call: callId(0), round: 1))
        XCTAssertEqual(record(book), pinnedRecord())
        receiver.onCallEnded()

        // call 1: not held, warning, safety code confirmed from the warning: the record is `invalid`
        let c1 = try await receiveRound1(receiver, try corrupted(try signedOffer(sender, call: callId(1), round: 1)))
        XCTAssertEqual(c1.pq?.result, .invalid)
        XCTAssertEqual(c1.call?.warns, [.invalid])
        XCTAssertEqual(c1.call?.hold, false)
        XCTAssertFalse(receiver.isMediaHeld(callId: callId(1)))
        XCTAssertTrue(receiver.confirmCapsPinAnomaly(callId: callId(1)))
        XCTAssertEqual(record(book), CapsPinRecord(caps: ["capsBindV1"], mldsaKeyId: hex(peerKeyId), pqState: "invalid"))
        XCTAssertTrue(log.lines.contains("pq round=1 pin=anomaly pq_sig=anomaly_confirmed hold=0"), "the second line")
        receiver.onCallEnded()

        // calls 2 and 3: not held, the same warning, the state stays
        for n in 2...3 {
            let c = try await receiveRound1(receiver, try corrupted(try signedOffer(sender, call: callId(n), round: 1)))
            XCTAssertEqual(c.call?.warns, [.invalid])
            XCTAssertEqual(c.call?.hold, false)
            XCTAssertEqual(record(book)?.pqState, "invalid")
            receiver.onCallEnded()
        }
        XCTAssertEqual(shown.all.suffix(2).map { $0 }, [[.invalid], [.invalid]])

        // call 4: the signer is fixed: authenticated, pinned again, no warning
        let before = shown.all.count
        let c4 = try await receiveRound1(receiver, try signedOffer(sender, call: callId(4), round: 1))
        XCTAssertEqual(c4.call?.pq?.auth, "H")
        XCTAssertEqual(shown.all.count, before)
        XCTAssertEqual(record(book), pinnedRecord())
    }

    // MARK: - Another key id

    /// A signature that is valid under another second key of the same device (installed in the store for the test).
    private func offerSignedByAnotherKey(call: String) throws -> (bundle: AndroidHandshakeBundle, keyId: Data) {
        let other = try XCTUnwrap(Pqsig.keyFromSeed(Data(repeating: 0x42, count: 32)))
        let keyId = other.publicKey.keyId()
        let verified = MldsaIdentityPublication.VerifiedPeer(pub: other.publicKey.bytes(), keyId: keyId, createdMs: 1_700_000_000_000, gen: 0)
        PeerMldsaStore.record(uuidRaw: uuidRaw, deviceId: deviceId, edPub: edPub, verified: verified)
        let base = baseOffer(call: call, round: 1)
        let caps = AndroidHandshakeBundle.Capabilities(
            ratchetV3: true, sframeV1: true, vkeyV1: true, hsTranscriptBindV1: true, capsBindV1: true, sigHybridV1: true)
        let unsigned = base.withSecondSignature(capabilities: caps, mldsaKeyId: keyId.base64EncodedString(), sigHybrid: nil, capsWithdrawn: nil)
        let info = CapsBind.analyze(bundle: unsigned)
        let ht = try XCTUnwrap(Pqsig.encodeHT(Pqsig.HtFields(
            kind: Pqsig.kindOffer, bundleHash: Data(SHA256.hash(data: offerTranscript(round: 1))), edPub: edPub, mldsaKeyId: keyId,
            dtlsFpSelf: fpOffer, dtlsFpPeer: Data(), capsx: info.capsx, extx: info.extx)))
        let sig = try XCTUnwrap(Pqsig.signHybrid(ht, edSeed: edSeed, pq: other))
        return (unsigned.withSecondSignature(capabilities: caps, mldsaKeyId: keyId.base64EncodedString(),
                                             sigHybrid: sig.base64EncodedString(), capsWithdrawn: nil), keyId)
    }

    func testAnotherKeyIdIsAWarningIsNeverPinnedAndStaysAWarning() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        let (receiver, book) = makeReceiver()
        try await receiveRound1(receiver, try signedOffer(sender, call: callId(1), round: 1))
        XCTAssertEqual(record(book), pinnedRecord())
        receiver.onCallEnded()

        let (other, otherId) = try offerSignedByAnotherKey(call: callId(2))
        let c2 = try await receiveRound1(receiver, other)
        XCTAssertEqual(c2.pq?.result, .valid, "valid under the other key")
        XCTAssertEqual(c2.pq?.keyId, hex(otherId))
        XCTAssertEqual(c2.call?.warns, [.otherkey])
        XCTAssertEqual(c2.call?.pq?.auth, "C")
        XCTAssertEqual(c2.call?.pq?.result, "otherkey")
        XCTAssertEqual(c2.call?.hold, false)
        XCTAssertEqual(record(book), pinnedRecord(), "the new key id is never pinned automatically")
        XCTAssertTrue(receiver.confirmCapsPinAnomaly(callId: callId(2)))
        XCTAssertEqual(record(book), CapsPinRecord(caps: ["capsBindV1"], mldsaKeyId: hex(peerKeyId), pqState: "other-key"))
        XCTAssertTrue(log.lines.contains("pq round=1 pin=anomaly pq_sig=anomaly_confirmed hold=0"))
        receiver.onCallEnded()

        // it keeps warning while the device presents the other key
        let (again, _) = try offerSignedByAnotherKey(call: callId(3))
        let c3 = try await receiveRound1(receiver, again)
        XCTAssertEqual(c3.call?.warns, [.otherkey])
        XCTAssertEqual(record(book)?.pqState, "other-key")
        receiver.onCallEnded()

        // and goes back to pinned silently when the pinned key signs again
        try installPeerKey()
        let c4 = try await receiveRound1(receiver, try signedOffer(sender, call: callId(4), round: 1))
        XCTAssertEqual(c4.call?.pq?.auth, "H")
        XCTAssertEqual(record(book), pinnedRecord())
    }

    // MARK: - Withdrawal

    func testASignedWithdrawalReleasesThePinWithoutASafetyCode() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        let (receiver, book) = makeReceiver()
        let shown = warnings(of: receiver)
        try await receiveRound1(receiver, try signedOffer(sender, call: callId(1), round: 1))
        XCTAssertEqual(record(book), pinnedRecord())
        receiver.onCallEnded()

        // the pinned build withdraws on purpose: no tag, the marker, a valid signature under the pinned key
        let withdrawing = try signedOffer(sender, call: callId(2), round: 1, planOverride: .withdraw)
        XCTAssertNil(withdrawing.capabilities?.sigHybridV1)
        XCTAssertEqual(withdrawing.capsWithdrawn, ["sigHybridV1"])
        XCTAssertNotNil(withdrawing.sigHybrid)
        let c2 = try await receiveRound1(receiver, withdrawing)
        XCTAssertEqual(c2.pq?.result, .valid)
        XCTAssertEqual(c2.call?.withdrawHonoured, true)
        XCTAssertEqual(c2.call?.pq?.auth, "H")
        XCTAssertTrue(shown.all.isEmpty, "no warning, no safety code")
        XCTAssertFalse(receiver.isMediaHeld(callId: callId(2)))
        XCTAssertEqual(record(book), CapsPinRecord(caps: ["capsBindV1"], mldsaKeyId: nil, pqState: nil), "the record has no key id any more")
        XCTAssertEqual(receiver.capsBindLineWords(callId: callId(2)).withdraw, "honoured")
        receiver.onCallEnded()

        // the same build again: authenticated, and it does not pin
        let c3 = try await receiveRound1(receiver, try signedOffer(sender, call: callId(3), round: 1, planOverride: .withdraw))
        XCTAssertEqual(c3.call?.pq?.auth, "H")
        XCTAssertEqual(record(book), CapsPinRecord(caps: ["capsBindV1"], mldsaKeyId: nil, pqState: nil))
        receiver.onCallEnded()

        // a later build that signs nothing: no warning, classical
        let silent = Sender(seed: edSeed, available: false)
        let c4 = try await receiveRound1(receiver, try signedOffer(silent, call: callId(4), round: 1))
        XCTAssertEqual(c4.call?.pq?.auth, "C")
        XCTAssertTrue(shown.all.isEmpty)
    }

    func testAMarkerWithoutAValidSignatureIsIgnored() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        let (receiver, book) = makeReceiver()
        try await receiveRound1(receiver, try signedOffer(sender, call: callId(1), round: 1))
        receiver.onCallEnded()

        // an intermediary with its own bundle: no second signature, the marker, and the key confirmation verifies
        let withdrawing = try signedOffer(sender, call: callId(2), round: 1, planOverride: .withdraw)
        let replacedByIntermediary = withdrawing.withSecondSignature(
            capabilities: stripped(withdrawing, keepCapsBind: true).capabilities, mldsaKeyId: nil, sigHybrid: nil,
            capsWithdrawn: ["sigHybridV1"])
        let c2 = try await receiveRound1(receiver, replacedByIntermediary)
        XCTAssertEqual(c2.pq?.result, .absent)
        XCTAssertEqual(c2.call?.warns, [.absent])
        XCTAssertEqual(c2.call?.withdrawIgnored, true)
        XCTAssertEqual(c2.call?.hold, false)
        XCTAssertFalse(receiver.isMediaHeld(callId: callId(2)))
        XCTAssertEqual(record(book), pinnedRecord(), "the record still has the key id")
        let line = try XCTUnwrap(log.lines.last { $0.contains("pq round=1 pin=anomaly") })
        XCTAssertTrue(line.contains("hold=0") && line.contains("pq_sig=absent") && line.contains("withdraw=ignored"), line)
        XCTAssertEqual(receiver.capsBindLineWords(callId: callId(2)).withdraw, "ignored")
    }

    func testAWithdrawalMarkerNamingTheFirstTagIsIgnored() async throws {
        let sender = Sender(seed: edSeed, available: false)
        let (receiver, book) = makeReceiver()
        book.setCapsBind(peerUserId: peerUser, signerKey: edPub)
        let bundle = try signedOffer(sender, call: callId(1), round: 1, capsBind: false)
            .withSecondSignature(capabilities: nil, mldsaKeyId: nil, sigHybrid: nil, capsWithdrawn: ["capsBindV1"])
        let c = try await receiveRound1(receiver, bundle)
        XCTAssertEqual(c.call?.warns, [.capsBindV1Missing], "the marker does not withdraw the first tag")
        XCTAssertEqual(c.call?.withdrawIgnored, true)
    }

    // MARK: - Rekey rounds

    /// A call that round 1 authenticated on this side: the receiver holds the anchor.
    private func authenticatedCall(_ receiver: QAudionCallIntegration, _ sender: Sender, call: String) async throws {
        let c = try await receiveRound1(receiver, try signedOffer(sender, call: call, round: 1))
        XCTAssertEqual(c.call?.pq?.auth, "H")
        XCTAssertEqual(receiver.pqLayer.anchor(callId: call)?.keyId, hex(peerKeyId))
    }

    private func rekeyOffer(_ receiver: QAudionCallIntegration, _ bundle: AndroidHandshakeBundle, round: Int, call: String) async throws -> Bool {
        let parsed = try onTheWire(bundle)
        let pq = await receiver.pqVerifyInbound(
            isOffer: true, bundle: parsed.bundle, callId: call, peerId: peerUser, deviceId: deviceId, signerKey: edPub,
            transcript: offerTranscript(round: round), peerOwnFp: fpOffer, answeredFp: nil, peerCaps: parsed.capsBind)
        return receiver.pqRekeyRefuses(callId: call, peerId: peerUser, pq: pq, round: round, isOfferer: false)
    }

    private func rekeyAccept(_ receiver: QAudionCallIntegration, _ bundle: AndroidHandshakeBundle, round: Int, call: String) async throws -> Bool {
        let parsed = try onTheWire(bundle)
        let pq = await receiver.pqVerifyInbound(
            isOffer: false, bundle: parsed.bundle, callId: call, peerId: peerUser, deviceId: deviceId, signerKey: edPub,
            transcript: acceptTranscript(round: round), peerOwnFp: fpAccept, answeredFp: fpOffer, peerCaps: parsed.capsBind)
        return receiver.pqRekeyRefuses(callId: call, peerId: peerUser, pq: pq, round: round, isOfferer: true)
    }

    /// (a) Replaced bundles: both round-3 bundles are replaced by ones that carry the first signature only.
    func testRekeyAReplacedBundlesOnBothLegsAreRefusedAndTheNextHonestRoundIsAccepted() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        let (receiver, book) = makeReceiver()
        let shown = warnings(of: receiver)
        let call = callId(1)
        try await authenticatedCall(receiver, sender, call: call)
        XCTAssertEqual(record(book), pinnedRecord())

        // as acceptor: the substituted OFFER of round 3
        let replacedOffer = stripped(try signedOffer(sender, call: call, round: 3), keepCapsBind: true)
        let acceptorRefuses = try await rekeyOffer(receiver, replacedOffer, round: 3, call: call)
        XCTAssertTrue(acceptorRefuses, "no ACCEPT is sent, nothing is armed")
        // as offerer: the substituted ACCEPT of round 3
        let replacedAccept = stripped(try signedAccept(sender, call: call, round: 3), keepCapsBind: true)
        let offererRefuses = try await rekeyAccept(receiver, replacedAccept, round: 3, call: call)
        XCTAssertTrue(offererRefuses, "no key is derived, no MAC is sent")
        XCTAssertEqual(shown.all.last, [.absent])
        XCTAssertTrue(log.lines.contains("pq_sig=absent round=3 pin=anomaly hold=0 rekey=refused"), log.lines.joined(separator: "\n"))
        XCTAssertEqual(record(book), pinnedRecord(), "the pin record is not changed by a rekey round")
        XCTAssertEqual(receiver.pqLayer.anchor(callId: call)?.auth, "H", "auth stays H")
        XCTAssertFalse(receiver.isMediaHeld(callId: call), "no hold, no end of call")
        let words = receiver.pqLineWords(callId: call)
        XCTAssertEqual(words.rekey, "refused")
        XCTAssertEqual(words.round, "3")
        XCTAssertEqual(words.auth, "H")

        // the next scheduled round, left honest, is accepted
        let honestOffer = try signedOffer(sender, call: call, round: 4)
        let refused = try await rekeyOffer(receiver, honestOffer, round: 4, call: call)
        XCTAssertFalse(refused)
        let honestAccept = try signedAccept(sender, call: call, round: 4)
        let acceptRefused = try await rekeyAccept(receiver, honestAccept, round: 4, call: call)
        XCTAssertFalse(acceptRefused)
    }

    /// (b) One-sided strip: only the round-3 OFFER loses its signature: the acceptor refuses, the honest rest is not affected.
    func testRekeyBOneSidedStripOfTheOfferIsRefusedByTheAcceptor() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        let (receiver, _) = makeReceiver()
        let call = callId(1)
        try await authenticatedCall(receiver, sender, call: call)
        let honest = try signedOffer(sender, call: call, round: 3)
        let strippedOffer = honest.withSecondSignature(capabilities: honest.capabilities, mldsaKeyId: honest.mldsaKeyId, sigHybrid: nil, capsWithdrawn: nil)
        let acceptorRefuses = try await rekeyOffer(receiver, strippedOffer, round: 3, call: call)
        XCTAssertTrue(acceptorRefuses)
        XCTAssertEqual(receiver.pqLayer.refusal(callId: call)?.round, 3)
        // a signature under another key id is refused too, and so is one that does not verify or has no key
        let invalid = try corrupted(honest)
        let invalidRefuses = try await rekeyOffer(receiver, invalid, round: 3, call: call)
        XCTAssertTrue(invalidRefuses)
        XCTAssertEqual(receiver.pqLayer.refusal(callId: call)?.reason, .invalid)
    }

    /// (c) Signer failure: the acceptor's signing fails on round 3: no ACCEPT is built, the call goes on.
    func testRekeyCASignerFailureSendsNoRekeyBundleAndNeverEndsRound1() throws {
        let sender = Sender(seed: edSeed)
        let call = callId(1)
        // round 1 signed
        let first = try signedAccept(sender, call: call, round: 1)
        XCTAssertNotNil(first.sigHybrid)
        XCTAssertEqual(sender.layer.ownMode(callId: call), PqCallLayer.OwnMode(plan: .advertise, sent: true))
        // round 2 signed, the sender rule: every rekey bundle of the call is signed
        XCTAssertNotNil(try signedAccept(sender, call: call, round: 2).sigHybrid)
        // round 3: the signer fails: the round is not sent
        sender.failSigning.value = true
        XCTAssertThrowsError(try signedAccept(sender, call: call, round: 3)) { error in
            XCTAssertEqual(error as? PqCallLayer.LayerError, .roundNotSent)
        }
        XCTAssertThrowsError(try signedOffer(sender, call: call, round: 3))
        // the next scheduled round retries and signs again
        sender.failSigning.value = false
        XCTAssertNotNil(try signedAccept(sender, call: call, round: 4).sigHybrid)
    }

    func testASignerFailureInRound1SendsTheBundleUnsignedAndWithoutTheTag() throws {
        let sender = Sender(seed: edSeed)
        sender.failSigning.value = true
        let bundle = try signedOffer(sender, call: callId(1), round: 1)
        XCTAssertNil(bundle.sigHybrid)
        XCTAssertNil(bundle.mldsaKeyId)
        XCTAssertNil(bundle.capabilities?.sigHybridV1)
        XCTAssertEqual(bundle.capabilities?.capsBindV1, true, "the first tag is kept")
        XCTAssertEqual(sender.layer.ownMode(callId: callId(1)), PqCallLayer.OwnMode(plan: .off, sent: false))
        // the rekey bundles of that call carry no signature either and are not refused on this side
        sender.failSigning.value = false
        XCTAssertNil(try signedOffer(sender, call: callId(1), round: 2).sigHybrid)
    }

    func testACallThatRound1LeftClassicalKeepsTodaysRekeyBehaviourAndLogsAValidSignature() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        let (receiver, _) = makeReceiver()
        let call = callId(1)
        // round 1 without a signature: auth C
        let c = try await receiveRound1(receiver, stripped(try signedOffer(sender, call: call, round: 1), keepCapsBind: true))
        XCTAssertEqual(c.call?.pq?.auth, "C")
        // a rekey bundle without a signature is accepted as today
        let noSig = stripped(try signedOffer(sender, call: call, round: 2), keepCapsBind: true)
        let unsignedRefuses = try await rekeyOffer(receiver, noSig, round: 2, call: call)
        XCTAssertFalse(unsignedRefuses)
        XCTAssertNil(receiver.pqLayer.refusal(callId: call))
        // a rekey bundle with a valid signature is accepted, logged, and does not raise the call to H
        let before = log.lines.count
        let refuses = try await rekeyOffer(receiver, try signedOffer(sender, call: call, round: 3), round: 3, call: call)
        XCTAssertFalse(refuses)
        XCTAssertTrue(log.lines.dropFirst(before).contains("pq_sig=valid round=3 pin=- hold=0 rekey=accepted"))
        XCTAssertEqual(receiver.pqLayer.anchor(callId: call)?.auth, "C")
    }

    func testTheRekeyAnchorComesFromRound1AloneAndNeverReadsThePinRecord() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        let (receiver, book) = makeReceiver()
        let call = callId(1)
        // round 1 valid but the tag withdrawn: the record gets no key id, the call is still authenticated with an anchor
        let c = try await receiveRound1(receiver, try signedOffer(sender, call: call, round: 1, planOverride: .withdraw))
        XCTAssertEqual(c.call?.pq?.auth, "H")
        XCTAssertNil(record(book)?.mldsaKeyId)
        let unsigned = stripped(try signedOffer(sender, call: call, round: 3), keepCapsBind: true)
        let refusedWithoutRecord = try await rekeyOffer(receiver, unsigned, round: 3, call: call)
        XCTAssertTrue(refusedWithoutRecord, "same answer with a record that holds no key id")
        // the same bundle with another record gives the same answer
        book.putRecord(peerUserId: peerUser, signerKey: edPub, record: pinnedRecord())
        let refusedWithRecord = try await rekeyOffer(receiver, unsigned, round: 3, call: call)
        XCTAssertTrue(refusedWithRecord)
        XCTAssertEqual(record(book), pinnedRecord(), "a rekey round never changes the record")
        book.putRecord(peerUserId: peerUser, signerKey: edPub, record: nil)
        let refusedWithNone = try await rekeyOffer(receiver, unsigned, round: 3, call: call)
        XCTAssertTrue(refusedWithNone)
        XCTAssertNil(record(book))
    }

    // MARK: - The flag cannot withdraw or hold

    func testTheServerFlagCanNeverCauseAWithdrawalOrStopAnAdvertisingDevice() throws {
        // what the compiled build says: no release withdraws
        XCTAssertFalse(PqSigRelease.withdrawnByRelease)
        // the availability has no flag input: a device that already published is available whatever the flag, a device that never
        // published is not (the flag only stops NEW publications)
        for flag in [true as Bool?, false, nil] {
            _ = flag
            XCTAssertTrue(PqSigAvailability.isAvailable(deviceIdPublishable: true, acknowledgedThisRun: false, creationRecordStored: true))
            XCTAssertTrue(PqSigAvailability.isAvailable(deviceIdPublishable: true, acknowledgedThisRun: true, creationRecordStored: false))
            XCTAssertFalse(PqSigAvailability.isAvailable(deviceIdPublishable: true, acknowledgedThisRun: false, creationRecordStored: false))
            XCTAssertFalse(PqSigAvailability.isAvailable(deviceIdPublishable: false, acknowledgedThisRun: true, creationRecordStored: true))
        }
        // no combination of inputs gives `withdraw` with the compiled constant
        for capsBind in [true, false] {
            for available in [true, false] {
                XCTAssertNotEqual(PqSigAvailability.plan(capsBindEnabled: capsBind, available: available), .withdraw)
            }
        }
        XCTAssertEqual(PqSigAvailability.plan(capsBindEnabled: true, available: true), .advertise)
        XCTAssertEqual(PqSigAvailability.plan(capsBindEnabled: true, available: false), .off)
        XCTAssertEqual(PqSigAvailability.plan(capsBindEnabled: false, available: true), .off)
        // the only way to a `withdraw` plan is the release constant, which a test can only reach through the parameter
        XCTAssertEqual(PqSigAvailability.plan(capsBindEnabled: true, available: true, withdrawnByRelease: true), .withdraw)
    }

    func testAnAdvertisingDeviceKeepsSigningRound1AndEveryRekeyWhateverTheFlagReads() throws {
        // the publish flag is read only by the publish path; this stands for it flipping while the call runs
        let publishFlagOn = FlagBox(true)
        let sender = Sender(seed: edSeed)
        let call = callId(1)
        for flag in [true, false, false, true] {
            publishFlagOn.value = flag
            let round = flag ? 2 : 3
            let bundle = try signedOffer(sender, call: flag ? call : callId(2), round: 1)
            XCTAssertEqual(bundle.capabilities?.sigHybridV1, true, "advertises with the flag \(flag)")
            XCTAssertNotNil(bundle.sigHybrid)
            XCTAssertNil(bundle.capsWithdrawn, "never a withdrawal marker")
            let rekey = try signedOffer(sender, call: flag ? call : callId(2), round: round)
            XCTAssertNotNil(rekey.sigHybrid)
            XCTAssertNil(rekey.capsWithdrawn)
        }
    }

    func testNeitherTheFlagNorTheCompiledArmingCanHoldAnAnomaly() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        for scenario in 0..<4 {
            let (receiver, book) = makeReceiver()
            let held = HeldBox()
            receiver.onHandshakeIdentityUnverified = { _, _ in held.fire() }
            switch scenario {
            case 0: receiver.capsBindFlag = { true }
            case 1: receiver.capsBindFlag = { true }; book.observeFlag(true); receiver.capsBindFlag = { false }
            case 2: receiver.capsBindFlag = { nil }; book.applyCompiledArming(true)
            default: receiver.capsBindFlag = { true }; book.observeFlag(true); book.applyCompiledArming(true)
            }
            try await receiveRound1(receiver, try signedOffer(sender, call: callId(1), round: 1))
            receiver.onCallEnded()
            let c = try await receiveRound1(receiver, stripped(try signedOffer(sender, call: callId(2), round: 1), keepCapsBind: false))
            XCTAssertEqual(c.call?.pin, .anomaly, "scenario \(scenario)")
            XCTAssertEqual(c.call?.hold, false, "scenario \(scenario)")
            XCTAssertFalse(receiver.isMediaHeld(callId: callId(2)), "scenario \(scenario)")
            XCTAssertEqual(held.count, 0, "scenario \(scenario)")
            XCTAssertTrue(log.lines.contains { $0.contains("pq round=1 pin=anomaly hold=0") }, "scenario \(scenario)")
        }
    }

    private final class HeldBox: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func fire() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    // MARK: - The size rule

    func testAnOversizeSignedRound1IsStrippedAndSentUnsigned() throws {
        let sender = Sender(seed: edSeed)
        let call = callId(1)
        // pad the bundle so that it fits unsigned with 1000 bytes to spare and does not fit once signed
        let base = OpaqueFrameRule.frameBytes(payload: AndroidHandshakeEnvelope.serialize(callId: call, bundle: baseOffer(call: call, round: 1)))
        let pad = OpaqueFrameRule.maxFrameBytes - OpaqueFrameRule.serverMarginBytes - 1000 - base
        XCTAssertGreaterThan(pad, 0)
        let big = baseOffer(call: call, round: 1, padding: pad)
        let plainWire = AndroidHandshakeEnvelope.serialize(callId: call, bundle: big)
        XCTAssertTrue(OpaqueFrameRule.fits(payload: plainWire), "the unsigned bundle fits")
        let result = try sender.layer.finalizeOwn(
            bundle: big, kind: Pqsig.kindOffer, round: 1, callId: call, transcript: offerTranscript(round: 1),
            fpSelf: fpOffer, fpPeer: nil, runtime: sender.runtime, capsBindEnabled: true)
        XCTAssertNil(result.sigHybrid, "stripped")
        XCTAssertNil(result.mldsaKeyId)
        XCTAssertNil(result.capabilities?.sigHybridV1)
        XCTAssertEqual(result.capabilities?.capsBindV1, true)
        XCTAssertTrue(OpaqueFrameRule.fits(payload: AndroidHandshakeEnvelope.serialize(callId: call, bundle: result)))
        XCTAssertEqual(sender.layer.ownMode(callId: call), PqCallLayer.OwnMode(plan: .off, sent: false))
    }

    func testAnOversizeRekeyIsNotSentAndNeverEndsTheCall() throws {
        let sender = Sender(seed: edSeed)
        let call = callId(1)
        XCTAssertNotNil(try signedOffer(sender, call: call, round: 1).sigHybrid)
        let base = OpaqueFrameRule.frameBytes(payload: AndroidHandshakeEnvelope.serialize(callId: call, bundle: baseOffer(call: call, round: 2)))
        let pad = OpaqueFrameRule.maxFrameBytes - OpaqueFrameRule.serverMarginBytes - 1000 - base
        XCTAssertThrowsError(try sender.layer.finalizeOwn(
            bundle: baseOffer(call: call, round: 2, padding: pad), kind: Pqsig.kindOffer, round: 2, callId: call,
            transcript: offerTranscript(round: 2), fpSelf: fpOffer, fpPeer: nil, runtime: sender.runtime, capsBindEnabled: true)) { error in
            XCTAssertEqual(error as? PqCallLayer.LayerError, .roundNotSent)
        }
        // the next round fits and is signed
        XCTAssertNotNil(try signedOffer(sender, call: call, round: 3).sigHybrid)
    }

    func testTheSignedBundleOfARealisticSizeFitsTheFrameRuleWithSpare() throws {
        let sender = Sender(seed: edSeed)
        let signed = try signedOffer(sender, call: callId(1), round: 1)
        let wire = AndroidHandshakeEnvelope.serialize(callId: signed.callId, bundle: signed)
        let frame = OpaqueFrameRule.frameBytes(payload: wire)
        XCTAssertLessThan(frame + OpaqueFrameRule.serverMarginBytes, OpaqueFrameRule.maxFrameBytes)
        // the bundle encoder escapes slashes, so a slash of the signature costs four bytes in the frame
        XCTAssertTrue(wire.contains("\\/") || !(signed.sigHybrid ?? "").contains("/"))
    }

    // MARK: - PSK lists

    func testAReceiverTreatsMoreThan64PskFingerprintsOrRolesAsMalformed() {
        let integration = QAudionCallIntegration()
        func verdict(_ count: Int, roles: Int) -> HandshakeSigningPolicy.Verdict {
            let fingerprints = (0..<count).map { String(format: "%064lx", $0) }
            let bundle = AndroidHandshakeBundle(
                kind: .offer, callId: callId(1),
                pqcPublicKey: Data(repeating: 0xA1, count: 1568).base64EncodedString(),
                x25519PublicKey: Data(repeating: 0xA2, count: 32).base64EncodedString(),
                pskFingerprints: fingerprints, pskRoles: Array(repeating: 0, count: roles),
                sasCommit: V6TestFixtures.sasCommit.base64EncodedString(),
                rekeyNonce: V6TestFixtures.rekeyNonce.base64EncodedString(), rekeyRound: 1)
            return integration.evaluateInbound(
                bundle: bundle, callId: callId(1), peerId: "peer-1", peerDeviceId: nil, expectedOfferBinding: nil,
                capsBind: CapsBind.analyze(bundle: bundle)).verdict
        }
        XCTAssertEqual(verdict(65, roles: 0), .malformed(code: CallCloseReason.handshakeMalformed.rawValue))
        XCTAssertEqual(verdict(0, roles: 65), .malformed(code: CallCloseReason.handshakeMalformed.rawValue))
        // up to 64 is not judged by this rule (a bundle without a signature is malformed for its own reason)
        for ok in [(64, 64), (0, 0), (1, 0)] {
            XCTAssertNotEqual(verdict(ok.0, roles: ok.1), .malformed(code: CallCloseReason.handshakeMalformed.rawValue), "\(ok)")
        }
    }

    // MARK: - Bounded state and the peer key wait

    func testThePerCallStateIsBoundedWithoutEvictingAndClearedWithTheCall() {
        let layer = PqCallLayer()
        let total = PqCallLayer.stateCapacity + 10
        for n in 0..<total {
            layer.setOwn(callId: callId(n), plan: .advertise, sent: true)
            layer.setAnchor(callId: callId(n), PqCallLayer.Anchor(auth: "H", keyId: "aa", result: "valid"))
            layer.noteRefusal(callId: callId(n), round: 3, reason: .absent)
        }
        // the first calls keep their state; the ones beyond the bound are the ones that are not kept
        XCTAssertNotNil(layer.ownMode(callId: callId(0)))
        XCTAssertNotNil(layer.anchor(callId: callId(0)))
        XCTAssertNotNil(layer.refusal(callId: callId(0)))
        XCTAssertNil(layer.ownMode(callId: callId(total - 1)))
        XCTAssertNil(layer.anchor(callId: callId(total - 1)))
        XCTAssertTrue(layer.anchorsOverflowed)
        var kept = 0
        for n in 0..<total where layer.anchor(callId: callId(n)) != nil { kept += 1 }
        XCTAssertEqual(kept, PqCallLayer.stateCapacity)
        layer.reset()
        XCTAssertNil(layer.ownMode(callId: callId(0)))
        XCTAssertNil(layer.anchor(callId: callId(0)))
        XCTAssertNil(layer.refusal(callId: callId(0)))
        XCTAssertFalse(layer.anchorsOverflowed)
    }

    /// Other calls' state (16 fresh call ids, the reviewer's reproduction) never removes the live call's anchor, and a rekey round
    /// without the second signature is still refused.
    func testDecoyCallsNeverEvictTheLiveCallsAnchorAndTheUnsignedRekeyIsRefused() {
        let (receiver, _) = makeReceiver()
        receiver.pqLayer.setAnchor(callId: "live", PqCallLayer.Anchor(auth: "H", keyId: "aa", result: "valid"))
        for n in 0..<16 {
            receiver.pqLayer.setAnchor(callId: "decoy\(n)", PqCallLayer.Anchor(auth: "C", keyId: nil, result: "absent"))
        }
        XCTAssertEqual(receiver.pqLayer.anchor(callId: "live")?.auth, "H")
        let refuses = receiver.pqRekeyRefuses(
            callId: "live", peerId: peerUser, pq: HybridBundleVerifier.Outcome(result: .absent, keyId: nil), round: 3, isOfferer: false)
        XCTAssertTrue(refuses)
    }

    /// The sender's rule of the live call (`own`) survives other calls' bundles: a rekey bundle is still signed or not sent.
    func testDecoyCallsNeverEvictTheLiveCallsOwnState() {
        let layer = PqCallLayer()
        layer.setOwn(callId: "live", plan: .advertise, sent: true)
        for n in 0..<16 { layer.setOwn(callId: "decoy\(n)", plan: .off, sent: false) }
        XCTAssertEqual(layer.ownMode(callId: "live"), PqCallLayer.OwnMode(plan: .advertise, sent: true))
    }

    /// A call whose round 1 was judged and whose anchor is gone (a full table) is refused, not accepted unsigned.
    func testAMissingAnchorOfAJudgedCallRefusesTheRekeyRound() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        let (receiver, _) = makeReceiver()
        let call = callId(1)
        try await authenticatedCall(receiver, sender, call: call)
        receiver.pqLayer.clearAnchor(callId: call)
        let honest = try signedOffer(sender, call: call, round: 3)
        let refused = try await rekeyOffer(receiver, honest, round: 3, call: call)
        XCTAssertTrue(refused)
        XCTAssertEqual(receiver.pqLayer.refusal(callId: call)?.round, 3)
        // a call this layer never judged is not touched
        XCTAssertFalse(receiver.pqRekeyRefuses(callId: callId(9), peerId: peerUser, pq: nil, round: 3, isOfferer: false))
    }

    /// The rekey round is verified under the key round 1 verified under, even when the store of peer keys lost it.
    func testARekeyRoundVerifiesWithTheRound1KeyWhenThePeerKeyStoreLostIt() async throws {
        try installPeerKey()
        let sender = Sender(seed: edSeed)
        let (receiver, _) = makeReceiver()
        let call = callId(1)
        try await authenticatedCall(receiver, sender, call: call)
        PeerMldsaStore.clear()
        let honestOffer = try signedOffer(sender, call: call, round: 3)
        let offerRefused = try await rekeyOffer(receiver, honestOffer, round: 3, call: call)
        XCTAssertFalse(offerRefused)
        let honestAccept = try signedAccept(sender, call: call, round: 3)
        let acceptRefused = try await rekeyAccept(receiver, honestAccept, round: 3, call: call)
        XCTAssertFalse(acceptRefused)
        XCTAssertNil(receiver.pqLayer.refusal(callId: call))
    }

    func testThePeerKeyWaitIsBoundedToTwoSecondsAndTheTimeIsLogged() async throws {
        let sender = Sender(seed: edSeed)
        let signed = try signedOffer(sender, call: callId(1), round: 1)
        let parsed = try onTheWire(signed)
        let integration = QAudionCallIntegration()
        integration.pqSig = PqSigRuntime(
            isAvailable: { false }, makeSigner: { nil },
            resolvePeerKey: { _, _, _, _ in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return nil
            })
        let started = Date()
        let out = await integration.pqVerifyInbound(
            isOffer: true, bundle: parsed.bundle, callId: callId(1), peerId: peerUser, deviceId: deviceId, signerKey: edPub,
            transcript: offerTranscript(round: 1), peerOwnFp: fpOffer, answeredFp: nil, peerCaps: parsed.capsBind)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(out?.result, .unavailable)
        XCTAssertGreaterThan(elapsed, 1.8)
        XCTAssertLessThan(elapsed, 4.0, "the wait ends at the bound, not when the lookup answers")
        let line = try XCTUnwrap(log.lines.first { $0.hasPrefix("pq resolve ms=") })
        XCTAssertTrue(line.contains("limit=2000") && line.contains("found=0"), line)
        let ms = Int(line.dropFirst("pq resolve ms=".count).prefix { $0.isNumber }) ?? 0
        XCTAssertGreaterThanOrEqual(ms, 1800)
        XCTAssertLessThan(ms, 4000)
    }

    func testTheResolverFetchesOnceWhenTheStoreHasNothingAndThenReadsTheStore() async throws {
        let counter = HeldBox()
        let seed = edSeed
        let pub = edPub
        let user = peerUser
        let device = deviceId
        let raw = uuidRaw
        let keyId = peerKeyId
        let key = await PeerMldsaResolve.resolve(
            peerUserId: user, deviceId: device, signerEdPub: pub, keyId: keyId,
            fetchDevice: { _, _ in
                counter.fire()
                // the fetch fills the store (as the app's fetch does after it verified the bundle)
                let fields = MldsaIdentityPublication.build(edSeed: seed, edPub: pub, uuidRaw: raw, deviceId: device, createdMs: 1_700_000_000_000)
                if let fields, let verified = MldsaIdentityPublication.verifyPeer(
                    pubB64: fields.pubB64, createdMs: fields.createdMs, edSigB64: fields.edSigB64, pqSigB64: fields.pqSigB64,
                    gen: 0, keyIdB64: fields.keyIdB64, uuidRaw: raw, deviceId: device, edPub: pub) {
                    PeerMldsaStore.record(uuidRaw: raw, deviceId: device, edPub: pub, verified: verified)
                }
            })
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(key?.keyId(), keyId)
        // present in the store: no fetch
        let again = await PeerMldsaResolve.resolve(
            peerUserId: user, deviceId: device, signerEdPub: pub, keyId: keyId, fetchDevice: { _, _ in counter.fire() })
        XCTAssertNotNil(again)
        XCTAssertEqual(counter.count, 1)
        // no device id: no key and no fetch
        let none = await PeerMldsaResolve.resolve(
            peerUserId: user, deviceId: nil, signerEdPub: pub, keyId: keyId, fetchDevice: { _, _ in counter.fire() })
        XCTAssertNil(none)
        XCTAssertEqual(counter.count, 1)
    }

    // MARK: - The bundle members on the wire

    func testTheNewMembersNeverMakeABundleUndecodableAndOmitWhenAbsent() throws {
        let plain = baseOffer(call: callId(1), round: 1)
        let text = AndroidHandshakeEnvelope.jsonPayload(of: plain)
        XCTAssertFalse(text.contains("mldsaKeyId"))
        XCTAssertFalse(text.contains("sigHybrid"))
        XCTAssertFalse(text.contains("capsWithdrawn"))
        func decode(_ extra: String) -> AndroidHandshakeBundle? {
            let json = "{\"kind\":\"OFFER\",\"callId\":\"c\",\"pqcPublicKey\":\"AA==\",\"x25519PublicKey\":\"AA==\"\(extra)}"
            return AndroidHandshakeEnvelope.parse("c|" + json)?.bundle
        }
        XCTAssertEqual(decode(",\"sigHybrid\":\"abc\",\"mldsaKeyId\":\"def\"")?.sigHybrid, "abc")
        XCTAssertEqual(decode(",\"sigHybrid\":12,\"mldsaKeyId\":{\"a\":1}")?.sigHybrid, "", "a wrong type reads as a value that cannot verify")
        XCTAssertEqual(decode(",\"sigHybrid\":12,\"mldsaKeyId\":{\"a\":1}")?.mldsaKeyId, "")
        XCTAssertNil(decode(",\"sigHybrid\":null")?.sigHybrid, "null is absent")
        XCTAssertNil(decode(",\"capsWithdrawn\":\"x\"")?.capsWithdrawn, "not an array")
        XCTAssertEqual(decode(",\"capsWithdrawn\":[\"sigHybridV1\"]")?.capsWithdrawn, ["sigHybridV1"])
        XCTAssertNotNil(decode(",\"capabilities\":{\"sigHybridV1\":\"yes\"}"), "a wrong type of the tag is not a decode failure")
        XCTAssertEqual(decode(",\"capabilities\":{\"sigHybridV1\":true}")?.capabilities?.sigHybridV1, true)
    }

    // MARK: - Source order and boundaries

    private func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("QAudionApp/AppState.swift").path) { return url }
        }
        throw XCTSkip("repository root not found")
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: try repositoryRoot().appendingPathComponent(path), encoding: .utf8)
    }

    private let integrationPath = "QAudionEngine/Sources/QAudionEngine/Integration/QAudionCallIntegration.swift"

    func testARefusedRekeyRoundIsDecidedBeforeAnythingOfItIsUsed() throws {
        let src = try source(integrationPath)
        // OFFER side: before the encapsulation and before the ACCEPT is built
        let offerCase = try XCTUnwrap(src.range(of: "let offerPq = await pqVerifyInbound("))
        let tail = String(src[offerCase.lowerBound...])
        let refuse = try XCTUnwrap(tail.range(of: "pqRekeyRefuses(callId: callId, peerId: callerId, pq: offerPq"))
        let encapsulate = try XCTUnwrap(tail.range(of: "let pqcResult = try pqc.encapsulate("))
        let acceptBuilt = try XCTUnwrap(tail.range(of: "let sigV6SignedAccept = try signedBundle("))
        XCTAssertLessThan(refuse.lowerBound, encapsulate.lowerBound)
        XCTAssertLessThan(refuse.lowerBound, acceptBuilt.lowerBound)
        // ACCEPT side: before the decapsulation and before any session key is derived or installed
        let acceptCase = try XCTUnwrap(src.range(of: "let acceptPq = await pqVerifyInbound("))
        let acceptTail = String(src[acceptCase.lowerBound...])
        let acceptRefuse = try XCTUnwrap(acceptTail.range(of: "pqRekeyRefuses(callId: callId, peerId: callerId, pq: acceptPq"))
        let decapsulate = try XCTUnwrap(acceptTail.range(of: "let pqcSs = try pqc.decapsulate("))
        let initSession = try XCTUnwrap(acceptTail.range(of: "try engine.initSession("))
        XCTAssertLessThan(acceptRefuse.lowerBound, decapsulate.lowerBound)
        XCTAssertLessThan(acceptRefuse.lowerBound, initSession.lowerBound)
        // the waiting attempt is resolved with nil by the defer that precedes the refusal
        let deferAt = try XCTUnwrap(src.range(of: "resolveReKeyAttempt(id: rekeyAttempt.id, with: nil)"))
        XCTAssertLessThan(deferAt.lowerBound, acceptCase.lowerBound)
    }

    func testTheSecondSignatureIsAddedAfterSigV6AndBeforeTheBundleIsRecordedOrSent() throws {
        let src = try source(integrationPath)
        let offerBuild = try XCTUnwrap(src.range(of: "let sigV6Signed = try signedBundle(of: unsigned"))
        let tail = String(src[offerBuild.lowerBound...])
        let finalize = try XCTUnwrap(tail.range(of: "try pqLayer.finalizeOwn("))
        let stash = try XCTUnwrap(tail.range(of: "sentOfferTranscriptByCall[callId.lowercased()] = transcript"))
        let noteSent = try XCTUnwrap(tail.range(of: "capsBindState.noteSent(callId: callId, info: CapsBind.analyze(bundle: signed))"))
        XCTAssertLessThan(finalize.lowerBound, stash.lowerBound)
        XCTAssertLessThan(stash.lowerBound, noteSent.lowerBound)
        let accept = try XCTUnwrap(src.range(of: "let sigV6SignedAccept = try signedBundle("))
        let acceptTail = String(src[accept.lowerBound...])
        let acceptFinalize = try XCTUnwrap(acceptTail.range(of: "try pqLayer.finalizeOwn("))
        let acceptAnalyze = try XCTUnwrap(acceptTail.range(of: "let capsOwnInfo = CapsBind.analyze(bundle: acceptToSend)"))
        let acceptWire = try XCTUnwrap(acceptTail.range(of: "let wire = AndroidHandshakeEnvelope.serialize(callId: callId, bundle: acceptToSend)"))
        XCTAssertLessThan(acceptFinalize.lowerBound, acceptAnalyze.lowerBound)
        XCTAssertLessThan(acceptAnalyze.lowerBound, acceptWire.lowerBound)
    }

    func testTheFlagIsNeverReadWhereTheTagIsAdvertisedOrSigned() throws {
        let app = try source("QAudionApp/AppState.swift")
        let start = try XCTUnwrap(app.range(of: "private func makePqSigRuntime() -> PqSigRuntime {"))
        let tail = String(app[start.upperBound...])
        let end = try XCTUnwrap(tail.range(of: "    /// Where the creation record of this device's second key is kept"))
        let body = String(tail[..<end.lowerBound])
        for word in ["killSwitch", "FeatureFlags", "flagKey", "mldsa_publish", "MldsaPublishPolicy"] {
            XCTAssertFalse(body.contains(word), "the runtime that advertises and signs does not read \(word)")
        }
        // the layer and the policy never see a flag either
        for path in ["QAudionEngine/Sources/QAudionEngine/Integration/PqCallLayer.swift",
                     "QAudionEngine/Sources/QAudionEngine/Crypto/HybridSigPolicy.swift",
                     "QAudionEngine/Sources/QAudionEngine/Crypto/HybridBundleSig.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.contains("mldsa_publish"), path)
            XCTAssertFalse(text.contains("FeatureFlags"), path)
        }
        // the constant is false and is only ever read where the plan is made; no production code overrides the plan
        let policy = try source("QAudionEngine/Sources/QAudionEngine/Crypto/HybridSigPolicy.swift")
        XCTAssertTrue(policy.contains("public static let withdrawnByRelease: Bool = false"))
        for path in [integrationPath, "QAudionApp/AppState.swift", "QAudionApp/Services/CallService.swift"] {
            XCTAssertFalse(try source(path).contains("planOverride"), path)
        }
    }

    func testNothingHereClearsPinsOrStartsASmallThread() throws {
        for path in ["QAudionEngine/Sources/QAudionEngine/Integration/PqCallLayer.swift",
                     "QAudionEngine/Sources/QAudionEngine/Integration/CapsBindCallState.swift",
                     "QAudionEngine/Sources/QAudionEngine/Crypto/HybridBundleSig.swift",
                     "QAudionEngine/Sources/QAudionEngine/Crypto/HybridSigPolicy.swift",
                     "QAudionEngine/Sources/QAudionEngine/Crypto/PeerMldsaResolve.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.contains("clearPins"), path)
            XCTAssertFalse(text.contains("clearAll()"), path)
            XCTAssertFalse(text.contains("Thread("), path)
            XCTAssertFalse(text.contains("Thread.detachNewThread"), path)
        }
    }

    func testBothSidesCapThePskListsAtTheSameConstant() throws {
        let src = try source(integrationPath)
        XCTAssertTrue(src.contains("static let maxPskAdvertEntries = 64"))
        // the three places that build an advertisement cap it (round-1 OFFER, rekey OFFER, ACCEPT), each fingerprints and roles
        XCTAssertGreaterThanOrEqual(src.components(separatedBy: ".prefix(Self.maxPskAdvertEntries)").count - 1, 6)
    }
}
