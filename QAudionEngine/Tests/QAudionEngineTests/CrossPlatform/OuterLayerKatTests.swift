import XCTest
import CryptoKit
@testable import QAudionEngine

/// The outer relay layer against the shared known-answer file: the sections `relayKemV1.frames`, `receiverNegatives`,
/// `controlFrames` and `chains`, `relayRotV1.rounds`, `legSwap`, `noRotation` and `scripts` (two real sets and the real cipher), and
/// the parts of `nackResendV2` that are about the layer. Every wire is compared byte for byte.
final class OuterLayerKatTests: XCTestCase {

    final class TestClock: @unchecked Sendable {
        var now = 0
    }

    // MARK: - Loading

    private func load() throws -> [String: Any] {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "kat"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "Resources/kat")
        ]
        let url = try XCTUnwrap(candidates.compactMap { $0 }.first, "pqc-hardening-v1-kat.json is not in the test bundle")
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined(), PqcHardeningV1KatTests.pinnedSHA256)
        let object = try JSONSerialization.jsonObject(with: bytes, options: [])
        return try XCTUnwrap(object as? [String: Any])
    }

    private func hex(_ s: String) -> Data {
        var out = Data()
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            out.append(UInt8(s[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    private func str(_ d: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(d[key] as? String, key)
    }

    private func counter(_ d: [String: Any], _ key: String = "ctrOut") throws -> UInt64 {
        try XCTUnwrap(UInt64(try str(d, key)), key)
    }

    private func kind(_ word: String) -> InnerSealV2.Kind { word == "audio" ? .audio : .video }

    private func role(sealing dir: String) -> LiveCallCrypto.Role { dir == "o2a" ? .offerer : .acceptor }

    private func role(opening dir: String) -> LiveCallCrypto.Role { dir == "o2a" ? .acceptor : .offerer }

    private func failureWord(_ failure: OuterFailure) -> String {
        switch failure {
        case .closed: return "closed"
        case .short: return "short"
        case .noncePrefix: return "nonce_prefix"
        case .dirTag: return "dir_tag"
        case .kindTag: return "kind_tag"
        case .epochByte: return "epoch_byte"
        case .noSlot: return "no_slot"
        case .replay: return "replay"
        case .tooOld: return "too_old"
        case .aead: return "aead"
        case .malformed: return "malformed"
        }
    }

    /// The four keys of a round from a vector's `kOut` list.
    private func roundKeys(_ list: [[String: Any]]) throws -> OuterRoundKeys {
        func buffer(_ kindWord: String, _ dirWord: String) throws -> ChainKeyBuffer {
            let entry = try XCTUnwrap(list.first { ($0["kind"] as? String) == kindWord && ($0["dir"] as? String) == dirWord })
            return ChainKeyBuffer(copying: hex(try str(entry, "kOut")))
        }
        return OuterRoundKeys(
            audioOffererToAcceptor: try buffer("audio", "o2a"), audioAcceptorToOfferer: try buffer("audio", "a2o"),
            videoOffererToAcceptor: try buffer("video", "o2a"), videoAcceptorToOfferer: try buffer("video", "a2o"))
    }

    private func round1Keys(_ root: [String: Any]) throws -> OuterRoundKeys {
        let round1 = try XCTUnwrap((root["relayKemV1"] as? [String: Any])?["round1"] as? [String: Any])
        return try roundKeys(try XCTUnwrap(round1["kOut"] as? [[String: Any]]))
    }

    private func rotRound(_ root: [String: Any], _ epoch: Int) throws -> [String: Any] {
        let rounds = try XCTUnwrap((root["relayRotV1"] as? [String: Any])?["rounds"] as? [[String: Any]])
        return try XCTUnwrap(rounds.first { ($0["E"] as? NSNumber)?.intValue == epoch }, "round \(epoch)")
    }

    private func rotKeys(_ root: [String: Any], _ epoch: Int) throws -> OuterRoundKeys {
        try roundKeys(try XCTUnwrap(try rotRound(root, epoch)["kOut"] as? [[String: Any]]))
    }

    /// Keys of which only one (kind, direction) is known: the others are random (the receiver vectors name one key).
    private func keys(with known: Data, kind: InnerSealV2.Kind, direction: InnerSealV2.Direction) -> OuterRoundKeys {
        func random() -> ChainKeyBuffer { ChainKeyBuffer(copying: Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })) }
        func pick(_ k: InnerSealV2.Kind, _ d: InnerSealV2.Direction) -> ChainKeyBuffer {
            (k == kind && d == direction) ? ChainKeyBuffer(copying: known) : random()
        }
        return OuterRoundKeys(
            audioOffererToAcceptor: pick(.audio, .offererToAcceptor), audioAcceptorToOfferer: pick(.audio, .acceptorToOfferer),
            videoOffererToAcceptor: pick(.video, .offererToAcceptor), videoAcceptorToOfferer: pick(.video, .acceptorToOfferer))
    }

    private func makeSet(_ role: LiveCallCrypto.Role, rot: Bool, clock: TestClock = TestClock()) -> OuterSealerSet {
        OuterSealerSet(role: role, rot: rot, nowMs: { clock.now })
    }

    private func sealed(_ outcome: OuterSealOutcome) -> Data? {
        if case .sealed(let wire, _) = outcome { return wire }
        return nil
    }

    // MARK: - relayKemV1: frames, receiver, control frames

    func testTheSevenFramesAreTheVectorsByteForByte() throws {
        let root = try load()
        let frames = try XCTUnwrap((root["relayKemV1"] as? [String: Any])?["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 7)
        for frame in frames {
            let name = try str(frame, "name")
            let dir = try str(frame, "dir")
            let set = makeSet(role(sealing: dir), rot: false)
            XCTAssertEqual(set.installRound0(try round1Keys(root)).result, .ok, name)
            let out = set.sealWithCounterForTesting(kind(try str(frame, "kind")), hex(try str(frame, "payload")), ctr: try counter(frame))
            XCTAssertEqual(sealed(out), hex(try str(frame, "wire")), name)
            // and the peer opens it
            let peer = makeSet(role(opening: dir), rot: false)
            XCTAssertEqual(peer.installRound0(try round1Keys(root)).result, .ok, name)
            let opened = peer.open(kind(try str(frame, "kind")), hex(try str(frame, "wire")))
            XCTAssertEqual(opened, .opened(payload: hex(try str(frame, "payload")), epoch: 0), name)
        }
    }

    func testTheEightReceiverNegativesAreDroppedForTheNamedReason() throws {
        let root = try load()
        let vectors = try XCTUnwrap((root["relayKemV1"] as? [String: Any])?["receiverNegatives"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 8)
        for vector in vectors {
            let name = try str(vector, "name")
            let receiver = try XCTUnwrap(vector["receiver"] as? [String: Any])
            let dir = try str(receiver, "direction")
            let kindWord = try str(receiver, "kind")
            let rot = try XCTUnwrap(receiver["relayRotV1"] as? Bool, name)
            let slots = try XCTUnwrap(receiver["slots"] as? [[String: Any]])
            let set = makeSet(role(opening: dir), rot: rot)
            let direction: InnerSealV2.Direction = dir == "o2a" ? .offererToAcceptor : .acceptorToOfferer
            for slot in slots {
                let epoch = Int32(try XCTUnwrap((slot["E"] as? NSNumber)?.intValue, name))
                let slotKeys = keys(with: hex(try str(slot, "kOut")), kind: kind(kindWord), direction: direction)
                XCTAssertEqual(set.installRound0(slotKeys, epoch: epoch).result, .ok, name)
            }
            for committed in (receiver["committedCounters"] as? [String]) ?? [] {
                set.commitReceivedCounterForTesting(kind(kindWord), ctr: try XCTUnwrap(UInt64(committed), name))
            }
            let expect = try XCTUnwrap(vector["expect"] as? [String: Any])
            let outcome = set.open(kind(kindWord), hex(try str(vector, "wire")))
            if try str(expect, "result") == "open" {
                guard case .opened = outcome else { XCTFail(name); continue }
            } else {
                guard case .dropped(let why, _) = outcome else { XCTFail(name); continue }
                XCTAssertEqual(failureWord(why), try str(expect, "reason"), name)
            }
        }
    }

    func testTheControlFramesUseTheAudioKeyAndTheVideoKeyDoesNotOpenThem() throws {
        let root = try load()
        let control = try XCTUnwrap((root["relayKemV1"] as? [String: Any])?["controlFrames"] as? [String: Any])
        let vectors = try XCTUnwrap(control["vectors"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 4)
        let sender = makeSet(.offerer, rot: false)
        XCTAssertEqual(sender.installRound0(try round1Keys(root)).result, .ok)
        let receiver = makeSet(.acceptor, rot: false)
        XCTAssertEqual(receiver.installRound0(try round1Keys(root)).result, .ok)
        for vector in vectors {
            let name = try str(vector, "name")
            let frame = hex(try str(vector, "controlFrame"))
            let out = sender.sealWithCounterForTesting(.audio, frame, ctr: try counter(vector))
            XCTAssertEqual(sealed(out), hex(try str(vector, "wire")), name)
            XCTAssertEqual(receiver.open(.audio, hex(try str(vector, "wire"))), .opened(payload: frame, epoch: 0), name)
        }
        // a fresh receiver: the counter of the negative frame is one the first receiver already committed
        let negative = try XCTUnwrap(control["negative"] as? [String: Any])
        let freshReceiver = makeSet(.acceptor, rot: false)
        XCTAssertEqual(freshReceiver.installRound0(try round1Keys(root)).result, .ok)
        guard case .dropped(let why, _) = freshReceiver.open(.audio, hex(try str(negative, "wire"))) else { return XCTFail("a control frame sealed with the video key") }
        XCTAssertEqual(failureWord(why), try str(negative, "reason"))
    }

    // MARK: - chains

    func testTheInnerEnvelopeInsideTheOuterFrameIsTheVectorByteForByte() throws {
        let root = try load()
        let audio = try XCTUnwrap(((root["relayKemV1"] as? [String: Any])?["chains"] as? [String: Any])?["audio"] as? [String: Any])
        let set = makeSet(.offerer, rot: false)
        XCTAssertEqual(set.installRound0(try round1Keys(root)).result, .ok)
        XCTAssertEqual(sealed(set.sealWithCounterForTesting(.audio, hex(try str(audio, "innerEnvelope")), ctr: 0)), hex(try str(audio, "outerWire")))
    }

    /// The whole chain of relay video through the production objects: the key state of both ends, the inner video seal, the binary
    /// payload and the outer wire.
    func testRelayVideoDoubleSealThroughTheKeyStateOfBothEnds() throws {
        let root = try load()
        let section = try XCTUnwrap(root["relayKemV1"] as? [String: Any])
        let round1 = try XCTUnwrap(section["round1"] as? [String: Any])
        let chain = try XCTUnwrap((section["chains"] as? [String: Any])?["relayVideoDoubleSeal"] as? [String: Any])
        let fragment = hex(try str(chain, "fragmentPlaintext"))
        let features = LiveCallCrypto.Features(
            ext: true, rekeyChainV1: false, frameKeyV6: false, innerSealV2: true, relayKemV1: true, relayRotV1: false,
            ownCapabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true), ownTag: true, peerTag: true, selfIsCaller: true)
        func adopted(_ role: LiveCallCrypto.Role) throws -> LiveCallCrypto {
            let secrets = RelaySecrets(relaySS: hex(try str(round1, "relaySS")), relayx: hex(try str(round1, "relayx")))
            defer { secrets.wipe() }
            return try XCTUnwrap(LiveCallCrypto.adopt(
                callId: try str(round1, "channelCallId"), role: role, features: features, sessionKey: hex(try str(round1, "sessionKey")),
                outer: .kem(secrets: secrets, acceptBinding: hex(try str(round1, "acceptBinding")))))
        }
        let caller = try adopted(.offerer)
        let callee = try adopted(.acceptor)
        XCTAssertEqual(caller.relayVideoMode, .double)
        let sendLayers = RelayVideoLayers(mode: caller.relayVideoMode, outer: caller.outerSealPort, inner: caller.innerVideoPort)
        let receiveLayers = RelayVideoLayers(mode: callee.relayVideoMode, outer: callee.outerSealPort, inner: callee.innerVideoPort)
        let out = try XCTUnwrap(sendLayers.sealFragment(fragment, fragIdx: 0, totalFrags: 2, isKey: true))
        XCTAssertEqual(out.wire, hex(try str(chain, "outerWire")))
        XCTAssertEqual(out.outerEpoch, 0)
        XCTAssertEqual(out.innerEpoch, 0)
        let opened = try XCTUnwrap(receiveLayers.openFragment(out.wire))
        XCTAssertEqual(opened, RelayVideoOpened(fragment: fragment, fragIdx: 0, totalFrags: 2, isKey: true))
        // the binary payload and the JSON envelope of the vector
        let desktop = try XCTUnwrap(chain["desktop"] as? [String: Any])
        let envelope = try XCTUnwrap(desktop["envelope"] as? [String: Any])
        XCTAssertEqual(out.wire.base64EncodedString(), try str(envelope, "frame"))
        let shape = try XCTUnwrap(RelayVideoPayload.decodeShape(hex(try str(chain, "binaryPayload"))))
        XCTAssertEqual(shape.fragIdx, 0)
        XCTAssertEqual(shape.totalFrags, 2)
        XCTAssertTrue(shape.isKey)
        XCTAssertEqual(shape.unit, hex(try str(chain, "innerEnvelope")))
        // the members of the envelope are never read: a wire whose JSON members lie still opens to the same fragment
        for ignored in try XCTUnwrap(desktop["membersIgnored"] as? [[String: Any]]) {
            let member = try XCTUnwrap(ignored["envelope"] as? [String: Any])
            let lateWire = try XCTUnwrap(Data(base64Encoded: try str(member, "frame")))
            let freshReceiver = try adopted(.acceptor)
            let layers = RelayVideoLayers(mode: freshReceiver.relayVideoMode, outer: freshReceiver.outerSealPort, inner: freshReceiver.innerVideoPort)
            let ignoredName = try str(ignored, "name")
            let accepted = try XCTUnwrap(layers.openFragment(lateWire), ignoredName)
            XCTAssertEqual(accepted.fragment, fragment)
            XCTAssertEqual(Int(accepted.fragIdx), try XCTUnwrap(((ignored["expect"] as? [String: Any])?["fragIdx"] as? NSNumber)?.intValue))
        }
        // without the inner seal: the plain fragment inside the outer frame, outer counter 1 in the vector
        let only = try XCTUnwrap(desktop["relayKemOnly"] as? [String: Any])
        let plainSet = makeSet(.offerer, rot: false)
        XCTAssertEqual(plainSet.installRound0(try round1Keys(root)).result, .ok)
        let plainPayload = RelayVideoPayload.encode(fragIdx: 0, totalFrags: 2, isKey: true, unit: hex(try str(only, "sealedPlaintext")).dropFirst(6))
        XCTAssertEqual(plainPayload, hex(try str(only, "sealedPlaintext")))
        XCTAssertEqual(sealed(plainSet.sealWithCounterForTesting(.video, plainPayload, ctr: 1)), hex(try str(only, "wire")))
        caller.close()
        callee.close()
    }

    // MARK: - relayRotV1

    func testTheSixRoundsGiveTheirKeysAndTheirEpochByte() throws {
        let root = try load()
        let rounds = try XCTUnwrap((root["relayRotV1"] as? [String: Any])?["rounds"] as? [[String: Any]])
        XCTAssertEqual(rounds.count, 6)
        for round in rounds {
            let epoch = Int32(try XCTUnwrap((round["E"] as? NSNumber)?.intValue))
            let frame = try XCTUnwrap(round["frame"] as? [String: Any])
            let name = "round " + String(epoch)
            let sender = makeSet(.offerer, rot: true)
            XCTAssertEqual(sender.installRound0(try rotKeys(root, Int(epoch)), epoch: epoch).result, .ok, name)
            let wire = try XCTUnwrap(sealed(sender.sealWithCounterForTesting(kind(try str(frame, "kind")), hex(try str(frame, "payload")), ctr: try counter(frame))), name)
            XCTAssertEqual(wire, hex(try str(frame, "wire")), name)
            XCTAssertEqual(wire[wire.startIndex + 1], UInt8(try XCTUnwrap((round["epochByte"] as? NSNumber)?.intValue)), name)
            XCTAssertEqual(wire[wire.startIndex + 1], UInt8(truncatingIfNeeded: epoch), name)
            let receiver = makeSet(.acceptor, rot: true)
            XCTAssertEqual(receiver.installRound0(try rotKeys(root, Int(epoch)), epoch: epoch).result, .ok, name)
            XCTAssertEqual(receiver.open(kind(try str(frame, "kind")), wire), .opened(payload: hex(try str(frame, "payload")), epoch: epoch), name)
        }
    }

    func testTheLegSwapFramesAllOpenOnOneSetWithTwoSlots() throws {
        let root = try load()
        let swap = try XCTUnwrap((root["relayRotV1"] as? [String: Any])?["legSwap"] as? [String: Any])
        let frames = try XCTUnwrap(swap["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 5)
        let receiver = makeSet(.acceptor, rot: true)
        XCTAssertEqual(receiver.installRound0(try rotKeys(root, 0), epoch: 0).result, .ok)
        XCTAssertEqual(receiver.install(epoch: 1, keys: try rotKeys(root, 1)).result, .ok)
        for frame in frames {
            let epoch = Int32(try XCTUnwrap((frame["E"] as? NSNumber)?.intValue))
            let ctr = try counter(frame)
            let name = "E" + String(epoch) + " ctr " + String(ctr)
            let sender = makeSet(.offerer, rot: true)
            XCTAssertEqual(sender.installRound0(try rotKeys(root, Int(epoch)), epoch: epoch).result, .ok, name)
            XCTAssertEqual(sealed(sender.sealWithCounterForTesting(.audio, hex(try str(frame, "payload")), ctr: ctr)), hex(try str(frame, "wire")), name)
            XCTAssertEqual(receiver.open(.audio, hex(try str(frame, "wire"))), .opened(payload: hex(try str(frame, "payload")), epoch: epoch), name)
        }
    }

    func testByteOneIsDroppedWithoutRotationAndSelectsTheSlotWithIt() throws {
        let root = try load()
        let vector = try XCTUnwrap((root["relayRotV1"] as? [String: Any])?["noRotation"] as? [String: Any])
        let wire = hex(try str(vector, "wire"))
        let keyOfRound1 = hex(try str(vector, "kOutAudioO2A_E1"))
        let plain = makeSet(.acceptor, rot: false)
        XCTAssertEqual(plain.installRound0(keys(with: keyOfRound1, kind: .audio, direction: .offererToAcceptor)).result, .ok)
        guard case .dropped(.epochByte, _) = plain.open(.audio, wire) else { return XCTFail("without relayRotV1") }
        let rotating = makeSet(.acceptor, rot: true)
        XCTAssertEqual(rotating.installRound0(try rotKeys(root, 0), epoch: 0).result, .ok)
        XCTAssertEqual(rotating.install(epoch: 1, keys: keys(with: keyOfRound1, kind: .audio, direction: .offererToAcceptor)).result, .ok)
        XCTAssertEqual(rotating.open(.audio, wire), .opened(payload: hex(try str(vector, "payload")), epoch: 1))
    }

    // MARK: - relayRotV1.scripts, two real sets and the real cipher

    func testTheSevenScriptsRunOnTwoRealSets() throws {
        let root = try load()
        let scripts = try XCTUnwrap((root["relayRotV1"] as? [String: Any])?["scripts"] as? [[String: Any]])
        XCTAssertEqual(scripts.map { ($0["events"] as? [Any])?.count ?? 0 }, [11, 19, 29, 10, 8, 3, 3])
        for script in scripts {
            try runScript(script, root: root)
        }
    }

    private func runScript(_ script: [String: Any], root: [String: Any]) throws {
        let scriptName = try str(script, "name")
        let clock = TestClock()
        let initial = Int32(try XCTUnwrap((script["initialEpoch"] as? NSNumber)?.intValue))
        let caller = makeSet(.offerer, rot: true, clock: clock)
        let callee = makeSet(.acceptor, rot: true, clock: clock)
        for set in [caller, callee] {
            XCTAssertEqual(set.installRound0(try rotKeys(root, Int(initial)), epoch: initial).result, .ok, scriptName)
            _ = set.peerKcmac(epoch: initial)
            _ = set.markKcmacSent(epoch: initial)
        }
        let events = try XCTUnwrap(script["events"] as? [[String: Any]])
        for (index, event) in events.enumerated() {
            let kindOfEvent = try str(event, "ev")
            let side = try str(event, "side")
            let set = side == "caller" ? caller : callee
            let time = try XCTUnwrap((event["t"] as? NSNumber)?.intValue)
            let expect = try XCTUnwrap(event["expect"] as? [String: Any])
            let where_ = scriptName + " #" + String(index) + " " + kindOfEvent + " " + side + " t=" + String(time)
            clock.now = time
            switch kindOfEvent {
            case "stage":
                let epoch = Int32(try XCTUnwrap((event["E"] as? NSNumber)?.intValue))
                let report = set.install(epoch: epoch, keys: try rotKeys(root, Int(epoch)))
                if report.result == .ok { _ = set.markKcmacSent(epoch: epoch) }
                XCTAssertEqual(report.result == .ok, expect["installed"] as? Bool, where_)
                if let collision = expect["collision"] as? Bool { XCTAssertEqual(report.result == .slotCollision, collision, where_) }
            case "hold4a":
                // this side installs no key for the round: the set is not touched
                XCTAssertEqual(expect["installed"] as? Bool, false, where_)
            case "peerKcmac":
                let epoch = Int32(try XCTUnwrap((event["E"] as? NSNumber)?.intValue))
                _ = set.peerKcmac(epoch: epoch)
                if let ends = (expect["trialEndsAt"] as? NSNumber)?.intValue { XCTAssertEqual(set.snapshot().trialEndsAt, ends, where_) }
            case "abandon":
                _ = set.abandon(epoch: Int32(try XCTUnwrap((event["E"] as? NSNumber)?.intValue)))
            case "tick":
                let born = set.tick()
                if let reverted = expect["revert"] as? Bool { XCTAssertEqual(born.reverted != nil, reverted, where_) }
            case "rx":
                let frame = try XCTUnwrap(event["frame"] as? [String: Any])
                let outcome = set.open(kind(try str(frame, "kind")), hex(try str(frame, "wire")))
                let result = try str(expect, "result")
                if result == "accept" {
                    XCTAssertEqual(outcome, .opened(payload: hex(try str(frame, "payload")),
                                                    epoch: Int32(try XCTUnwrap((frame["E"] as? NSNumber)?.intValue))), where_)
                } else if case .dropped(let why, _) = outcome {
                    XCTAssertEqual("drop:" + failureWord(why), result, where_)
                } else {
                    XCTFail(where_)
                }
            case "send":
                // the counters of the file belong to a longer conversation: bring ours to the frame's counter with dummy frames
                let frame = try XCTUnwrap(event["frame"] as? [String: Any])
                let sendKind = kind(try str(frame, "kind"))
                let want = try counter(frame)
                while (sendKind == .audio ? set.snapshot().txAudio : set.snapshot().txVideo) < want {
                    _ = set.seal(sendKind, Data([0]))
                }
                let wire = try XCTUnwrap(sealed(set.seal(sendKind, hex(try str(frame, "payload")))), where_)
                XCTAssertEqual(wire, hex(try str(frame, "wire")), where_)
                XCTAssertEqual(wire[wire.startIndex + 1], UInt8(try XCTUnwrap((expect["epochByte"] as? NSNumber)?.intValue)), where_)
                XCTAssertEqual(set.sendEpoch(), Int32(try XCTUnwrap((expect["epoch"] as? NSNumber)?.intValue)), where_)
            default:
                XCTFail("unknown event " + kindOfEvent)
            }
            XCTAssertEqual(set.sendEpoch(), Int32(try XCTUnwrap((expect["S"] as? NSNumber)?.intValue)), where_ + " S")
            XCTAssertEqual(set.snapshot().epochs, try XCTUnwrap(expect["slots"] as? [NSNumber]).map { $0.int32Value }, where_ + " slots")
        }
        caller.close()
        callee.close()
    }

    // MARK: - nackResendV2

    func testTheCachedWireIsTheOriginalAndAResealIsAnotherFrame() throws {
        let root = try load()
        let section = try XCTUnwrap(root["nackResendV2"] as? [String: Any])
        let sender = try XCTUnwrap(section["sender"] as? [String: Any])
        let round0 = try XCTUnwrap(sender["round0"] as? [String: Any])
        let original = try XCTUnwrap(section["original"] as? [String: Any])
        let known = hex(try str(round0, "kOut"))
        let inner = hex(try str(original, "innerEnvelope"))
        let set = makeSet(.offerer, rot: true)
        XCTAssertEqual(set.installRound0(keys(with: known, kind: .audio, direction: .offererToAcceptor), epoch: 0).result, .ok)
        // the original, from the counter the file names
        XCTAssertEqual(sealed(set.sealWithCounterForTesting(.audio, inner, ctr: try counter(original, "outerCtr"))), hex(try str(original, "wire")))
        XCTAssertEqual(hex(try str(original, "cachedWire")), hex(try str(original, "wire")))
        // the resend is those bytes and moves no counter
        let resend = try XCTUnwrap(section["resend"] as? [String: Any])
        XCTAssertEqual(hex(try str(resend, "wire")), hex(try str(original, "wire")))
        XCTAssertEqual(set.snapshot().txAudio, 0)
        // re-sealing the cached inner envelope is another frame, never the original
        let forbidden = try XCTUnwrap(section["forbiddenReseal"] as? [String: Any])
        let resealed = try XCTUnwrap(sealed(set.sealWithCounterForTesting(.audio, inner, ctr: try counter(forbidden, "outerCtrUsed"))))
        XCTAssertEqual(resealed, hex(try str(forbidden, "wire")))
        XCTAssertNotEqual(resealed, hex(try str(original, "wire")))
        // the video fragment: the same rule
        let video = try XCTUnwrap(section["relayVideoFragment"] as? [String: Any])
        XCTAssertEqual(hex(try str(video, "cachedWire")), hex(try str(video, "resendWire")))
    }

    func testTheReceiverDropsACopyItSawAndOpensOneItNeverSawAndDropsAnErasedRound() throws {
        let root = try load()
        let section = try XCTUnwrap(root["nackResendV2"] as? [String: Any])
        let original = try XCTUnwrap(section["original"] as? [String: Any])
        let wire = hex(try str(original, "wire"))
        func receiver(slots: [[String: Any]]) throws -> OuterSealerSet {
            let set = makeSet(.acceptor, rot: true)
            for slot in slots {
                let epoch = Int32(try XCTUnwrap((slot["E"] as? NSNumber)?.intValue))
                XCTAssertEqual(set.installRound0(keys(with: hex(try str(slot, "kOut")), kind: .audio, direction: .offererToAcceptor), epoch: epoch).result, .ok)
            }
            return set
        }
        let saw = try XCTUnwrap(section["receiverSawOriginal"] as? [String: Any])
        let seen = try receiver(slots: try XCTUnwrap(saw["slots"] as? [[String: Any]]))
        for committed in try XCTUnwrap(saw["committedOuterCounters"] as? [String]) {
            seen.commitReceivedCounterForTesting(.audio, ctr: try XCTUnwrap(UInt64(committed)))
        }
        guard case .dropped(.replay, _) = seen.open(.audio, wire) else { return XCTFail("a copy the receiver saw") }
        let never = try XCTUnwrap(section["receiverNeverSawOriginal"] as? [String: Any])
        let fresh = try receiver(slots: try XCTUnwrap(never["slots"] as? [[String: Any]]))
        XCTAssertEqual(fresh.open(.audio, wire), .opened(payload: hex(try str(never, "plaintext")), epoch: 0))
        let erase = try XCTUnwrap(section["eraseNegative"] as? [String: Any])
        let erased = try receiver(slots: try XCTUnwrap(erase["receiverSlots"] as? [[String: Any]]))
        guard case .dropped(let why, _) = erased.open(.audio, hex(try str(erase, "wire"))) else { return XCTFail("a round that was erased") }
        XCTAssertEqual(failureWord(why), try str(try XCTUnwrap(erase["expect"] as? [String: Any]), "reason"))
    }
}
