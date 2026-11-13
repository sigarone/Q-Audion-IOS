import XCTest
import CryptoKit
@testable import QAudionEngine

/// The outer relay layer in the key state of a call: two real objects built from one real exchange, the rules of a rotation round,
/// an outer failure that never fails a round, the modes of relay video, the epoch guards of the resend caches, the size rule for the
/// key-exchange member, the strict VNACK parser and the refusal record of a colliding round.
final class RelayLayerBehaviourTests: XCTestCase {

    private struct Failure: Error {}

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var now: Int { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Int) { lock.lock(); value = newValue; lock.unlock() }
    }

    private final class MoveBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[Int32]] = []
        func add(_ from: Int32, _ to: Int32) { lock.lock(); stored.append([from, to]); lock.unlock() }
        var moves: [[Int32]] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    // MARK: - Fixtures

    private func exchange() throws -> (offerer: RelaySecrets, acceptor: RelaySecrets) {
        let keys = try XCTUnwrap(RelayKem.generateOfferKeys())
        guard case .ok(let accept, let acceptorSecrets) = RelayKem.encapsulate(offer: keys.pub) else { throw Failure() }
        guard case .ok(let offererSecrets) = keys.decapsulate(accept) else { throw Failure() }
        return (offererSecrets, acceptorSecrets)
    }

    private func features(inner: Bool = false, relay: Bool = true, rot: Bool = true) -> LiveCallCrypto.Features {
        LiveCallCrypto.Features(
            ext: true, rekeyChainV1: false, frameKeyV6: false, innerSealV2: inner, relayKemV1: relay, relayRotV1: rot,
            ownCapabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true), ownTag: true, peerTag: true, selfIsCaller: true)
    }

    private let sessionKey = Data(repeating: 7, count: 32)
    private let binding = Data(repeating: 9, count: 32)

    private func pair(_ clock: TestClock, inner: Bool = false, rot: Bool = true) throws -> (caller: LiveCallCrypto, callee: LiveCallCrypto) {
        let ex = try exchange()
        defer {
            ex.offerer.wipe()
            ex.acceptor.wipe()
        }
        let caller = try XCTUnwrap(LiveCallCrypto.adopt(
            callId: "call-s11", role: .offerer, features: features(inner: inner, rot: rot), sessionKey: sessionKey,
            outer: .kem(secrets: ex.offerer, acceptBinding: binding), nowMs: { clock.now }))
        let callee = try XCTUnwrap(LiveCallCrypto.adopt(
            callId: "call-s11", role: .acceptor, features: features(inner: inner, rot: rot), sessionKey: sessionKey,
            outer: .kem(secrets: ex.acceptor, acceptBinding: binding), nowMs: { clock.now }))
        return (caller, callee)
    }

    /// Stages a rotation round on both ends with a fresh exchange.
    private func stageBoth(_ caller: LiveCallCrypto, _ callee: LiveCallCrypto, epoch: Int32, seed: UInt8) throws {
        let ex = try exchange()
        let key = Data(repeating: seed, count: 32)
        let bind = Data(repeating: seed &+ 1, count: 32)
        let a = caller.stageRoundReport(epoch: epoch, sessionKey: key, ours: true, handle: nil, outer: .kem(secrets: ex.offerer, acceptBinding: bind))
        let b = callee.stageRoundReport(epoch: epoch, sessionKey: key, ours: false, handle: nil, outer: .kem(secrets: ex.acceptor, acceptBinding: bind))
        XCTAssertEqual(a.result, .staged)
        XCTAssertEqual(b.result, .staged)
        XCTAssertTrue(a.outerInstalled)
        XCTAssertTrue(b.outerInstalled)
        XCTAssertTrue(ex.offerer.isWipedForTesting, "the secrets of a staged round are wiped")
        XCTAssertTrue(ex.acceptor.isWipedForTesting)
    }

    private let payload = Data(repeating: 0x42, count: 60)

    private func sealedWire(_ port: OuterSealPort, _ kind: InnerSealV2.Kind = .audio) throws -> (wire: Data, epoch: Int32) {
        guard case .sealed(let wire, let epoch) = port.seal(kind, payload) else { throw Failure() }
        return (wire, epoch)
    }

    // MARK: - Round 1 of a call, both ends

    func testRound1SealsBothWaysOnOnePortWithConsecutiveCountersAndOpensOnlyOnThePeer() throws {
        let clock = TestClock()
        let (caller, callee) = try pair(clock)
        XCTAssertEqual(caller.outerStatusValue, .ok)
        let callerPort = try XCTUnwrap(caller.outerSealPort)
        let calleePort = try XCTUnwrap(callee.outerSealPort)
        var wires: [Data] = []
        for index in 0 ..< 3 {
            let out = try sealedWire(callerPort)
            XCTAssertEqual(out.epoch, 0)
            let base = out.wire.startIndex
            XCTAssertEqual(Array(out.wire[base ..< base + 4]), [0x52, 0x00, 0x01, 0x01])
            XCTAssertEqual(Array(out.wire[base + 4 ..< base + 12]), [0, 0, 0, 0, 0, 0, 0, UInt8(index)])
            wires.append(out.wire)
        }
        // video has a counter of its own
        let video = try sealedWire(callerPort, .video)
        XCTAssertEqual(Array(video.wire[video.wire.startIndex + 2 ..< video.wire.startIndex + 4]), [0x01, 0x02])
        XCTAssertEqual(video.wire[video.wire.startIndex + 11], 0)
        // the sender cannot open its own frame, the peer opens each once
        guard case .dropped(.dirTag, _) = callerPort.open(.audio, wires[0]) else { return XCTFail("own frame") }
        for wire in wires {
            XCTAssertEqual(calleePort.open(.audio, wire), .opened(payload: payload, epoch: 0))
        }
        guard case .dropped(.replay, _) = calleePort.open(.audio, wires[0]) else { return XCTFail("a copy") }
        // and the other way
        let back = try sealedWire(calleePort)
        XCTAssertEqual(back.wire[back.wire.startIndex + 2], 0x02)
        XCTAssertEqual(callerPort.open(.audio, back.wire), .opened(payload: payload, epoch: 0))
        // the end of the call closes the layer: nothing is sealed or opened afterwards, and the port of a closed object is gone
        caller.close()
        XCTAssertNil(caller.outerSealPort)
        guard case .refused(.closed) = callerPort.seal(.audio, payload) else { return XCTFail("seal after close") }
        guard case .dropped(.closed, _) = callerPort.open(.audio, back.wire) else { return XCTFail("open after close") }
        XCTAssertEqual(callerPort.sendEpoch(), -1)
        XCTAssertTrue(caller.outerKeyBuffersForTesting().allSatisfy { $0.isWipedForTesting })
        callee.close()
    }

    func testARotationRoundMovesThePointersAsTheRulesSayAndTheTrialRevertsWhenThePeerIsSilent() throws {
        // both ends answer
        let clock = TestClock()
        let (caller, callee) = try pair(clock)
        let callerPort = try XCTUnwrap(caller.outerSealPort)
        let calleePort = try XCTUnwrap(callee.outerSealPort)
        try stageBoth(caller, callee, epoch: 1, seed: 21)
        _ = caller.markOuterKcmacSent(epoch: 1)
        _ = callee.markOuterKcmacSent(epoch: 1)
        _ = caller.confirmRound(epoch: 0)
        _ = callee.confirmRound(epoch: 0)
        let callerConfirm = caller.confirmRound(epoch: 1)
        XCTAssertEqual(callerConfirm.outerEvents.switched, OuterSwitchEvent(from: 0, to: 1, trial: true))
        XCTAssertEqual(callerPort.sendEpoch(), 1)
        let fromCaller = try sealedWire(callerPort)
        XCTAssertEqual(fromCaller.epoch, 1)
        XCTAssertEqual(fromCaller.wire[fromCaller.wire.startIndex + 1], 1)
        // the callee opens it under the staged slot, and its own pointer waits for the confirmation
        XCTAssertEqual(calleePort.open(.audio, fromCaller.wire), .opened(payload: payload, epoch: 1))
        XCTAssertEqual(calleePort.sendEpoch(), 0)
        let calleeConfirm = callee.confirmRound(epoch: 1)
        XCTAssertEqual(calleeConfirm.outerEvents.switched, OuterSwitchEvent(from: 0, to: 1, trial: false))
        let fromCallee = try sealedWire(calleePort)
        XCTAssertEqual(fromCallee.epoch, 1)
        XCTAssertEqual(callerPort.open(.audio, fromCallee.wire), .opened(payload: payload, epoch: 1))
        // the frame of the trial round made the move permanent: no revert at the end of the trial
        clock.set(5000)
        XCTAssertNil(caller.tickOuter().reverted)
        XCTAssertEqual(callerPort.sendEpoch(), 1)
        XCTAssertEqual(caller.outerLevelInput().revertFrom, nil)

        // the callee never answers under the new round: the caller goes back after 3 s
        let clock2 = TestClock()
        let (silentCaller, silentCallee) = try pair(clock2)
        let silentPort = try XCTUnwrap(silentCaller.outerSealPort)
        try stageBoth(silentCaller, silentCallee, epoch: 1, seed: 31)
        _ = silentCaller.confirmRound(epoch: 1)
        XCTAssertEqual(silentPort.sendEpoch(), 1)
        clock2.set(2999)
        XCTAssertNil(silentCaller.tickOuter().reverted)
        clock2.set(3000)
        XCTAssertEqual(silentCaller.tickOuter().reverted, OuterRevertEvent(from: 1, to: 0))
        XCTAssertEqual(silentPort.sendEpoch(), 0)
        XCTAssertEqual(silentCaller.outerLevelInput().revertFrom, 1)
        XCTAssertEqual(OuterLevelWords.compute(silentCaller.outerLevelInput()).reason, "send_revert")

        // a hold of the peer pauses the trial and defers the move until media resumes
        let clock3 = TestClock()
        let (heldCaller, heldCallee) = try pair(clock3)
        let heldPort = try XCTUnwrap(heldCaller.outerSealPort)
        try stageBoth(heldCaller, heldCallee, epoch: 1, seed: 41)
        _ = heldCaller.setOuterHold(true)
        XCTAssertNil(heldCaller.confirmRound(epoch: 1).outerEvents.switched)
        XCTAssertEqual(heldPort.sendEpoch(), 0)
        clock3.set(10_000)
        XCTAssertNil(heldCaller.tickOuter().reverted)
        XCTAssertEqual(heldCaller.setOuterHold(false).switched, OuterSwitchEvent(from: 0, to: 1, trial: true))
        XCTAssertEqual(heldPort.sendEpoch(), 1)
        clock3.set(13_000)
        XCTAssertEqual(heldCaller.tickOuter().reverted, OuterRevertEvent(from: 1, to: 0))
    }

    // MARK: - An outer failure never fails a round

    func testAnOuterFailureStagesTheRoundHoldsTheEpochAndLeavesTheLayerUp() throws {
        let clock = TestClock()
        let (caller, callee) = try pair(clock)
        // a derivation that fails: the round is staged with a hold, nothing is installed
        let bad = RelaySecrets(relaySS: Data(count: 10), relayx: Data(count: 32))
        let report = caller.stageRoundReport(epoch: 1, sessionKey: sessionKey, ours: true, handle: nil, outer: .kem(secrets: bad, acceptBinding: binding))
        XCTAssertEqual(report.result, .staged)
        XCTAssertFalse(report.outerInstalled)
        XCTAssertEqual(report.outerHold, .relayKem)
        XCTAssertEqual(caller.outerStatusValue, .ok)
        XCTAssertEqual(caller.outerSnapshot()?.epochs, [0])
        // a held round (the peer's member was absent): the same, with the reason it was given
        let held = caller.stageRoundReport(epoch: 2, sessionKey: sessionKey, ours: true, handle: nil, outer: .hold(.x25519Zero))
        XCTAssertEqual(held.result, .staged)
        XCTAssertEqual(held.outerHold, .x25519Zero)
        XCTAssertEqual(OuterLevelWords.compute(caller.outerLevelInput()).reason, "x25519_zero")
        // a frame of that epoch from the peer finds no slot, and the audio of epoch 0 goes on
        let calleePort = try XCTUnwrap(callee.outerSealPort)
        XCTAssertEqual(try XCTUnwrap(caller.outerSealPort).open(.audio, try sealedWire(calleePort).wire), .opened(payload: payload, epoch: 0))
        // a colliding round (epoch 256 shares its byte with the live slot of round 0) stages, reports the collision and leaves slot 0
        let ex = try exchange()
        let collision = caller.stageRoundReport(epoch: 256, sessionKey: sessionKey, ours: true, handle: nil,
                                                outer: .kem(secrets: ex.offerer, acceptBinding: binding))
        XCTAssertEqual(collision.result, .staged)
        XCTAssertEqual(collision.outerHold, .slotCollision)
        XCTAssertEqual(caller.outerSnapshot()?.epochs, [0])
        XCTAssertEqual(try XCTUnwrap(caller.outerSealPort).open(.audio, try sealedWire(calleePort).wire), .opened(payload: payload, epoch: 0))
        ex.acceptor.wipe()

        // at adoption: the object exists, the layer is marked failed, there is no port
        let failed = try XCTUnwrap(LiveCallCrypto.adopt(
            callId: "call-s11", role: .offerer, features: features(), sessionKey: sessionKey, outer: .failed, nowMs: { clock.now }))
        XCTAssertEqual(failed.outerStatusValue, .failed)
        XCTAssertNil(failed.outerSealPort)
        XCTAssertEqual(failed.relayVideoMode, .none)
        let unsound = RelaySecrets(relaySS: Data(count: 10), relayx: Data(count: 32))
        let broken = try XCTUnwrap(LiveCallCrypto.adopt(
            callId: "call-s11", role: .offerer, features: features(), sessionKey: sessionKey,
            outer: .kem(secrets: unsound, acceptBinding: binding), nowMs: { clock.now }))
        XCTAssertEqual(broken.outerStatusValue, .failed)
        XCTAssertNil(broken.outerSealPort)
    }

    // MARK: - Relay video modes

    func testTheModeOfRelayVideoFollowsWhatTheCallNegotiated() throws {
        let clock = TestClock()
        func mode(inner: Bool, relay: Bool) throws -> RelayVideoMode {
            let ex = try exchange()
            defer { ex.offerer.wipe() }
            let input: OuterRound1Input = relay ? .kem(secrets: ex.offerer, acceptBinding: binding) : .none
            let object = try XCTUnwrap(LiveCallCrypto.adopt(
                callId: "call-s11", role: .offerer, features: features(inner: inner, relay: relay, rot: false), sessionKey: sessionKey,
                outer: input, nowMs: { clock.now }))
            return object.relayVideoMode
        }
        XCTAssertEqual(try mode(inner: true, relay: false), .legacy, "the inner seal alone never changes relay video")
        XCTAssertEqual(try mode(inner: false, relay: true), .outerOnly)
        XCTAssertEqual(try mode(inner: true, relay: true), .double)
        let ex = try exchange()
        let object = try XCTUnwrap(LiveCallCrypto.adopt(
            callId: "call-s11", role: .offerer, features: features(inner: true), sessionKey: sessionKey,
            outer: .kem(secrets: ex.offerer, acceptBinding: binding), nowMs: { clock.now }))
        XCTAssertNotNil(object.innerVideoPort)
        XCTAssertTrue(object.outerOff())
        XCTAssertEqual(object.relayVideoMode, .none)
        XCTAssertNil(object.outerSealPort)
        XCTAssertFalse(object.outerOff(), "the second call changes nothing")
        // the layers of a mode that sends nothing drop everything
        let none = RelayVideoLayers(mode: .none, outer: nil, inner: nil)
        XCTAssertNil(none.sealFragment(Data([1, 2, 3]), fragIdx: 0, totalFrags: 1, isKey: true))
        XCTAssertNil(none.openFragment(Data(count: 40)))
    }

    // MARK: - The resend guards

    func testAnEntryOfAnEarlierRoundIsNotResent() {
        let ring = NackRetransmitRing()
        ring.record(seq: 5, envelope: Data([0x52, 0x01, 0x01, 0x01, 0, 0, 0, 0, 0, 0, 0, 5, 9, 9]))
        XCTAssertNotNil(ring.lookup(seq: 5))
        XCTAssertNotNil(ring.lookup(seq: 5, outerEpochByte: nil))
        XCTAssertNotNil(ring.lookup(seq: 5, outerEpochByte: 1))
        XCTAssertNil(ring.lookup(seq: 5, outerEpochByte: 2))
        ring.record(seq: 6, envelope: Data([0x52, 0x02, 0x01, 0x01, 0, 0, 0, 0, 0, 0, 0, 6, 9, 9]), epochByte: 3)
        XCTAssertNotNil(ring.lookup(seq: 6, sendEpochByte: 3, outerEpochByte: 2))
        XCTAssertNil(ring.lookup(seq: 6, sendEpochByte: 3, outerEpochByte: 1))
        XCTAssertNil(ring.lookup(seq: 6, sendEpochByte: 4, outerEpochByte: 2))
        XCTAssertTrue(RelayVideoLayers.mayResend(entryOuter: 2, entryInner: 3, currentOuter: 2, currentInner: 3))
        XCTAssertFalse(RelayVideoLayers.mayResend(entryOuter: 1, entryInner: 3, currentOuter: 2, currentInner: 3))
        XCTAssertFalse(RelayVideoLayers.mayResend(entryOuter: 2, entryInner: 2, currentOuter: 2, currentInner: 3))
        XCTAssertTrue(RelayVideoLayers.mayResend(entryOuter: 2, entryInner: -1, currentOuter: 2, currentInner: -1))
        XCTAssertTrue(RelayVideoLayers.mayResend(entryOuter: -1, entryInner: -1, currentOuter: -1, currentInner: -1))
    }

    func testTheSendSwitchListenerFiresAtASwitchAndARevertAndNeverAtAStage() throws {
        let clock = TestClock()
        let (caller, callee) = try pair(clock)
        let integration = QAudionCallIntegration()
        integration.swapLiveForTesting(caller)
        let moves = MoveBox()
        integration.onOuterSendSwitch = { from, to in moves.add(from, to) }
        let ex = try exchange()
        let key = Data(repeating: 51, count: 32)
        XCTAssertEqual(
            integration.liveStage(caller, epoch: 1, sessionKey: key, ours: true, handle: nil,
                                  outer: .kem(secrets: ex.offerer, acceptBinding: binding)), .staged)
        XCTAssertTrue(moves.moves.isEmpty, "a stage is not a switch")
        integration.liveConfirm(gen: caller.gen, round: 2)
        XCTAssertEqual(moves.moves, [[0, 1]])
        integration.liveConfirm(gen: caller.gen, round: 2)
        XCTAssertEqual(moves.moves.count, 1)
        clock.set(3000)
        integration.dispatchOuterEvents(caller.tickOuter(), from: caller)
        XCTAssertEqual(moves.moves, [[0, 1], [1, 0]])
        ex.acceptor.wipe()
        callee.close()
    }

    // MARK: - The refusal record of a colliding round (inner seal)

    func testTheStickyRefusalIsWrittenOnlyForAnOfferWhoseSignatureVerified() throws {
        let integration = QAudionCallIntegration()
        let object = try XCTUnwrap(integration.adoptLiveForTesting(
            callId: "call-s11", role: .acceptor, features: features(inner: true, relay: false, rot: false), sessionKey: sessionKey))
        XCTAssertEqual(integration.liveStage(object, epoch: 1, sessionKey: Data(repeating: 2, count: 32), ours: false, handle: nil), .staged)
        XCTAssertEqual(
            integration.liveStage(object, epoch: 257, sessionKey: Data(repeating: 3, count: 32), ours: false, handle: nil, offerSigOk: false),
            .slotCollision)
        XCTAssertNil(object.lastRefusalEpoch, "an unverified OFFER writes nothing")
        XCTAssertEqual(
            integration.liveStage(object, epoch: 257, sessionKey: Data(repeating: 3, count: 32), ours: false, handle: nil, offerSigOk: true),
            .slotCollision)
        XCTAssertEqual(object.lastRefusalEpoch, 257)
    }

    // MARK: - VNACK

    private func loadKat() throws -> [String: Any] {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "kat"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "Resources/kat")
        ]
        let url = try XCTUnwrap(candidates.compactMap { $0 }.first, "pqc-hardening-v1-kat.json is not in the test bundle")
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined(), PqcHardeningV1KatTests.pinnedSHA256)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes, options: []) as? [String: Any])
    }

    func testTheEighteenVnackVectorsThroughTheStrictParserAndTheExactCallId() throws {
        let section = try XCTUnwrap(try loadKat()["vnackText"] as? [String: Any])
        XCTAssertEqual(section["maxFragmentsPerFrame"] as? Int, CallPiggyBack.vnackMaxFragmentsPerFrame)
        let vectors = try XCTUnwrap(section["vectors"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 18)
        for vector in vectors {
            let name = try XCTUnwrap(vector["name"] as? String)
            let live = try XCTUnwrap(vector["liveCallId"] as? String, name)
            let expect = try XCTUnwrap(vector["expect"] as? [String: Any], name)
            let parsed = CallPiggyBack.parse(try XCTUnwrap(vector["data"] as? String, name))
            var request: (frameId: Int, missing: [Int])?
            if case .vnack(let callId, let frameId, let missing)? = parsed, callId == live {
                request = (frameId, missing)
            }
            if (expect["result"] as? String) == "request" {
                let got = try XCTUnwrap(request, name)
                XCTAssertEqual(got.frameId, expect["frameId"] as? Int, name)
                XCTAssertEqual(got.missing, (expect["missing"] as? [NSNumber])?.map { $0.intValue }, name)
            } else {
                XCTAssertNil(request, name)
            }
        }
        // a message the older rule read in part is now malformed as a whole
        XCTAssertNil(CallPiggyBack.parse("id|VNACK:7:1,x,2"))
        XCTAssertNil(CallPiggyBack.parse("id|VNACK:7:"))
        XCTAssertEqual(CallPiggyBack.parse("id|VNACK:7:2,2,1"), .vnack(callId: "id", frameId: 7, missing: [2, 1]))
    }

    // MARK: - The size rule for the key-exchange member

    private let edSeed = Data(repeating: 0x31, count: 32)
    private var edPub: Data { try! Curve25519.Signing.PrivateKey(rawRepresentation: edSeed).publicKey.rawRepresentation }
    private let fpOffer = V6TestFixtures.fingerprint("offerer")

    private func runtime(available: Bool) -> PqSigRuntime {
        let seed = edSeed
        let pub = edPub
        return PqSigRuntime(
            isAvailable: { available }, makeSigner: { HybridBundleSigner(edSeed: seed, edPub: pub) },
            resolvePeerKey: { _, _, _, _ in nil })
    }

    private func relayMember() -> AndroidHandshakeBundle.RelayKemMember {
        AndroidHandshakeBundle.RelayKemMember(wire: RelayKemWire(mlkem: Data(repeating: 0xA3, count: 1568), x25519: Data(repeating: 0xA4, count: 32)))
    }

    private func offer(_ call: String, round: Int, relay: Bool, padding: Int) -> AndroidHandshakeBundle {
        AndroidHandshakeBundle(
            kind: .offer, callId: call,
            pqcPublicKey: Data(repeating: 0xA1, count: 1568).base64EncodedString(),
            x25519PublicKey: Data(repeating: 0xA2, count: 32).base64EncodedString(),
            capabilities: AndroidHandshakeBundle.Capabilities(
                ratchetV3: true, sframeV1: true, vkeyV1: true, hsTranscriptBindV1: true, capsBindV1: true,
                relayKemV1: relay ? true : nil, relayRotV1: relay ? true : nil),
            pskFingerprints: [],
            selectedPskFingerprint: padding > 0 ? String(repeating: "a", count: padding) : nil,
            sasCommit: round == 1 ? V6TestFixtures.sasCommit.base64EncodedString() : nil,
            rekeyNonce: V6TestFixtures.rekeyNonce.base64EncodedString(), rekeyRound: round,
            relayKem: relay ? relayMember() : nil)
    }

    private func finalize(_ layer: PqCallLayer, _ bundle: AndroidHandshakeBundle, round: Int, runtime: PqSigRuntime) throws -> AndroidHandshakeBundle {
        try layer.finalizeOwn(
            bundle: bundle, kind: Pqsig.kindOffer, round: round, callId: bundle.callId,
            transcript: V6TestFixtures.offerTranscript(signerKey: edPub, dtls: fpOffer, round: UInt32(round)),
            fpSelf: fpOffer, fpPeer: nil, runtime: runtime, capsBindEnabled: true)
    }

    /// The padding that leaves `spare` bytes under the frame rule for the bundle signed without the member.
    private func padding(round: Int, spare: Int) throws -> Int {
        let call = "00000000-0000-4000-8000-000000000001"
        let layer = PqCallLayer()
        if round > 1 { _ = try finalize(layer, offer(call, round: 1, relay: false, padding: 0), round: 1, runtime: runtime(available: true)) }
        let signed = try finalize(layer, offer(call, round: round, relay: false, padding: 0), round: round, runtime: runtime(available: true))
        let used = OpaqueFrameRule.frameBytes(payload: AndroidHandshakeEnvelope.serialize(callId: call, bundle: signed))
        return OpaqueFrameRule.maxFrameBytes - OpaqueFrameRule.serverMarginBytes - spare - used
    }

    func testARound1OfferThatDoesNotFitGivesUpTheMemberAndBothTagsAndKeepsTheSecondSignature() throws {
        let call = "00000000-0000-4000-8000-000000000001"
        let pad = try padding(round: 1, spare: 300)
        XCTAssertGreaterThan(pad, 0)
        let result = try finalize(PqCallLayer(), offer(call, round: 1, relay: true, padding: pad), round: 1, runtime: runtime(available: true))
        XCTAssertNil(result.relayKem)
        XCTAssertNil(result.capabilities?.relayKemV1)
        XCTAssertNil(result.capabilities?.relayRotV1)
        XCTAssertNotNil(result.sigHybrid, "the signature is never given up for the member")
        XCTAssertTrue(OpaqueFrameRule.fits(payload: AndroidHandshakeEnvelope.serialize(callId: call, bundle: result)))
        // the member and the tags of a bundle that fits are untouched
        let small = try finalize(PqCallLayer(), offer(call, round: 1, relay: true, padding: 0), round: 1, runtime: runtime(available: true))
        XCTAssertNotNil(small.relayKem)
        XCTAssertEqual(small.capabilities?.relayRotV1, true)
        XCTAssertNotNil(small.sigHybrid)
    }

    func testARekeyOfferThatDoesNotFitGivesUpTheMemberOnlyAndKeepsTheTags() throws {
        let call = "00000000-0000-4000-8000-000000000001"
        let pad = try padding(round: 3, spare: 300)
        let layer = PqCallLayer()
        _ = try finalize(layer, offer(call, round: 1, relay: false, padding: 0), round: 1, runtime: runtime(available: true))
        let result = try finalize(layer, offer(call, round: 3, relay: true, padding: pad), round: 3, runtime: runtime(available: true))
        XCTAssertNil(result.relayKem)
        XCTAssertEqual(result.capabilities?.relayKemV1, true)
        XCTAssertEqual(result.capabilities?.relayRotV1, true)
        XCTAssertNotNil(result.sigHybrid)
        XCTAssertTrue(OpaqueFrameRule.fits(payload: AndroidHandshakeEnvelope.serialize(callId: call, bundle: result)))
    }

    func testAnUnsignedBundleThatDoesNotFitGivesUpTheMemberToo() throws {
        let call = "00000000-0000-4000-8000-000000000001"
        // an unavailable signer: the bundle goes out unsigned; pad it so that only the member overflows
        let base = AndroidHandshakeEnvelope.serialize(callId: call, bundle: offer(call, round: 1, relay: false, padding: 0))
        let pad = OpaqueFrameRule.maxFrameBytes - OpaqueFrameRule.serverMarginBytes - 300 - OpaqueFrameRule.frameBytes(payload: base)
        XCTAssertGreaterThan(pad, 0)
        let result = try finalize(PqCallLayer(), offer(call, round: 1, relay: true, padding: pad), round: 1, runtime: runtime(available: false))
        XCTAssertNil(result.relayKem)
        XCTAssertNil(result.capabilities?.relayKemV1)
        XCTAssertTrue(OpaqueFrameRule.fits(payload: AndroidHandshakeEnvelope.serialize(callId: call, bundle: result)))
    }
}
