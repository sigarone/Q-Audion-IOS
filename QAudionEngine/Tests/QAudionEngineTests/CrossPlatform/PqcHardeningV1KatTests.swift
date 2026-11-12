import XCTest
import CryptoKit
@testable import QAudionEngine

/// The call-media layer vectors (phase 1) of the server repository: `tools/kat/pqc-hardening-v1/pqc-hardening-v1-kat.json`, a
/// BYTE-FOR-BYTE copy. Its SHA-256 is pinned here. The file is read as untyped JSON on purpose: its sections have very different
/// shapes. Sections run here: the inner nonce, the legacy outer nonce prefix, the `outer-off-v1` frame, the retransmit cache and the
/// protection level with its log line. The sections mldsaSeed, xcert and sigHybrid are run by PqsigKatTests.
///
/// This code was written on a machine that cannot compile Swift for iOS: the macOS CI job is what runs it.
final class PqcHardeningV1KatTests: XCTestCase {

    static let pinnedSHA256 = "8780b498db01d38b028cbc274383f1c86c3fc522d6d4f6528ac6e4687d545584"

    // MARK: - Loading

    private func fileBytes() throws -> Data {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "kat"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "Resources/kat")
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            throw NSError(domain: "PqcHardeningV1Kat", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "pqc-hardening-v1-kat.json is not in the test bundle"])
        }
        return try Data(contentsOf: url)
    }

    private func load() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try fileBytes(), options: [])
        return try XCTUnwrap(object as? [String: Any])
    }

    private func hex(_ s: String) -> Data {
        var out = Data()
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            out.append(UInt8(s[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private func hexString(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    private func object(_ any: Any?) throws -> [String: Any] {
        try XCTUnwrap(any as? [String: Any])
    }

    private func list(_ any: Any?) throws -> [[String: Any]] {
        try XCTUnwrap(any as? [[String: Any]])
    }

    private func string(_ dict: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(dict[key] as? String, key)
    }

    private func counter(_ dict: [String: Any], _ key: String = "ctr") throws -> UInt64 {
        try XCTUnwrap(UInt64(try string(dict, key)), key)
    }

    // MARK: - The file itself

    func testTheFileIsTheOneThePlatformsShare() throws {
        let digest = SHA256.hash(data: try fileBytes())
        XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(), Self.pinnedSHA256)
        let root = try load()
        XCTAssertEqual(root["format"] as? String, "pqc-hardening-v1-kat")
    }

    // MARK: - innerNonceV1

    func testInnerNonceLayoutAndTheTwoHalvesOfTheCounter() throws {
        let root = try load()
        let section = try object(root["innerNonceV1"])
        for entry in try list(section["nonces"]) {
            let dir = UInt8(truncating: try XCTUnwrap(entry["dir"] as? NSNumber))
            let ctr = try counter(entry)
            XCTAssertEqual(hexString(QAudionEngine.innerNonce(dirTag: dir, ctr: ctr)), try string(entry, "nonce"))
            let low32 = UInt32(truncating: try XCTUnwrap(entry["iosWireSeqLow32"] as? NSNumber))
            XCTAssertEqual(UInt32(truncatingIfNeeded: ctr), low32)
        }
        let stop = try object(section["stopAtCounter"])
        XCTAssertEqual(QAudionEngine.innerCtrLimit, try counter(stop))
    }

    func testInnerSealOfTheEnvelopeAndOfTheRekeyRevertSequence() throws {
        let root = try load()
        let common = try object(root["common"])
        let section = try object(root["innerNonceV1"])
        let block = hex(try string(common, "innerPaddedBlock"))
        let cipher = AeadCipher()

        // One envelope: the ciphertext (with its tag) of the padded block under sessionKey1 and the nonce.
        let envelope = try object(section["envelope"])
        let key1 = hex(try string(common, "sessionKey1"))
        let nonce = hex(try string(envelope, "nonce"))
        let sealed = try cipher.encrypt(plaintext: block, key: key1, nonce: nonce, associatedData: nil)
        XCTAssertEqual(sealed.nonce, nonce)
        XCTAssertEqual(hexString(sealed.ciphertext + sealed.tag), try string(envelope, "ct"))

        // The whole sequence: the counter goes up by one at every seal across rekey, revert, latch and leg swap, so no nonce repeats.
        let sequence = try object(section["counterAcrossRekeyRevert"])
        let keys = try object(sequence["keys"])
        var seen = Set<Data>()
        var previous: UInt64 = 0
        var seals = 0
        for event in try list(sequence["events"]) where event["event"] as? String == "seal" {
            let round = try XCTUnwrap(event["round"] as? NSNumber).intValue
            let keyName = try string(keys, String(round))
            let key = hex(try string(common, keyName))
            let ctr = try counter(event)
            XCTAssertEqual(ctr, previous + 1)
            previous = ctr
            let n = hex(try string(event, "nonce"))
            XCTAssertEqual(QAudionEngine.innerNonce(dirTag: 1, ctr: ctr), n)
            XCTAssertTrue(seen.insert(n).inserted, "nonce repeated at ctr \(ctr)")
            let out = try cipher.encrypt(plaintext: block, key: key, nonce: n, associatedData: nil)
            XCTAssertEqual(hexString(out.ciphertext + out.tag), try string(event, "ct"))
            seals += 1
        }
        XCTAssertGreaterThan(seals, 5)
    }

    // MARK: - legacyOuterNonce

    private func legacyOuterKeyMaterial() throws -> (sessionKey: Data, callId: String, plaintext: Data, vectors: [[String: Any]]) {
        let root = try load()
        let common = try object(root["common"])
        let section = try object(root["legacyOuterNonce"])
        return (hex(try string(common, "sessionKey1")), try string(common, "callId"),
                hex(try string(section, "plaintext")), try list(section["vectors"]))
    }

    func testTheSenderWritesItsRolePrefixAndEveryReceiverOpensTheFrame() throws {
        let material = try legacyOuterKeyMaterial()
        // Role A sends with the a2b key in every vector, whatever the sender's call role (a tie, or an old build).
        let vectors = material.vectors
        XCTAssertEqual(vectors.count, 6)

        // Senders that start at counter 0 or 1: the real sealer must produce the vector bytes.
        func sealer(_ tag: Bool?) throws -> PqcRtpFrameSealer {
            try PqcRtpFrameSealer.createDirectional(
                pqcSessionKey: material.sessionKey, callId: material.callId, selfIsRoleA: true, selfIsCaller: tag).send
        }
        let caller = try sealer(true)
        XCTAssertEqual(hexString(try caller.seal(material.plaintext)), try string(vectors[0], "sealedWithOuterKeyA2B"))
        XCTAssertEqual(hexString(try caller.seal(material.plaintext)), try string(vectors[1], "sealedWithOuterKeyA2B"))
        XCTAssertEqual(hexString(try sealer(false).seal(material.plaintext)), try string(vectors[2], "sealedWithOuterKeyA2B"))
        XCTAssertEqual(hexString(try sealer(nil).seal(material.plaintext)), try string(vectors[4], "sealedWithOuterKeyA2B"))

        // Every vector (new prefix and old, small and large counters) opens at a receiver that reads the counter from bytes 4..11.
        for vector in vectors {
            let receiver = try PqcRtpFrameSealer.createDirectional(
                pqcSessionKey: material.sessionKey, callId: material.callId, selfIsRoleA: false).recv
            let opened = try receiver.open(hex(try string(vector, "sealedWithOuterKeyA2B")))
            XCTAssertEqual(opened, material.plaintext)
            XCTAssertEqual(vector["opens"] as? Bool, true)
        }
    }

    func testTwoSendersUnderOneKeyAndCounterDifferInTheFirstByte() throws {
        let material = try legacyOuterKeyMaterial()
        let caller = try PqcRtpFrameSealer.createDirectional(
            pqcSessionKey: material.sessionKey, callId: material.callId, selfIsRoleA: true, selfIsCaller: true).send
        let callee = try PqcRtpFrameSealer.createDirectional(
            pqcSessionKey: material.sessionKey, callId: material.callId, selfIsRoleA: true, selfIsCaller: false).send
        let a = try caller.seal(material.plaintext)
        let b = try callee.seal(material.plaintext)
        XCTAssertEqual(a[a.startIndex], 0x01)
        XCTAssertEqual(b[b.startIndex], 0x02)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - outerOffV1

    func testOuterOffFrameClassification() throws {
        let root = try load()
        let section = try object(root["outerOffV1"])
        XCTAssertEqual(OuterLayerPolicy.outerOffFrame, hex(try string(section, "frame")))
        XCTAssertEqual(OuterLayerPolicy.minSealedFrameLength, try XCTUnwrap(section["minSealedFrameLength"] as? Int))
        XCTAssertEqual(CallCapabilities.outerOffV1, try string(section, "capabilityString"))
        XCTAssertTrue(CallCapabilities.local.contains(CallCapabilities.outerOffV1))
        for vector in try list(section["vectors"]) {
            let bytes = hex(try string(vector, "bytes"))
            let leg: OuterLayerLeg = (try string(vector, "leg")) == "dc" ? .dataChannel : .wsRelay
            let honoured = OuterLayerPolicy.isOuterOffFromDataChannel(bytes, leg: leg)
            let action = try string(vector, "action")
            let label = try string(vector, "bytes")
            XCTAssertEqual(honoured, action == "honour", label)
        }
    }

    // MARK: - nackResend

    func testResendIsTheCachedBytesAndTheSendSwitchDropsTheCache() throws {
        let root = try load()
        let section = try object(root["nackResend"])
        let frames = try list(section["frames"])
        let ring = NackRetransmitRing()
        // Frames 1 to 3 are sent in round 1; frame 4 after the send switch to round 2.
        for frame in frames.prefix(3) {
            ring.record(seq: Int64(try counter(frame, "innerSeq")), envelope: hex(try string(frame, "wire")))
        }
        var recordedFourth = false
        for event in try list(section["events"]) {
            switch try string(event, "op") {
            case "nack":
                let seq = Int64(try counter(event, "innerSeq"))
                if (try string(event, "result")) == "resend" {
                    let cached = try XCTUnwrap(ring.lookup(seq: seq), "seq \(seq)")
                    XCTAssertEqual(hexString(cached), try string(event, "resendBytes"))
                    XCTAssertEqual(event["byteIdentical"] as? Bool, true)
                } else {
                    XCTAssertNil(ring.lookup(seq: seq), "seq \(seq)")
                }
            case "sendSwitch":
                ring.clear()
                if !recordedFourth, let fourth = frames.last {
                    ring.record(seq: Int64(try counter(fourth, "innerSeq")), envelope: hex(try string(fourth, "wire")))
                    recordedFourth = true
                }
            default:
                XCTFail("unknown op")
            }
        }
        XCTAssertTrue(recordedFourth)
    }

    func testAReceiverThatNeverSawTheOriginalAcceptsTheResendAndOneThatDidDropsIt() throws {
        let root = try load()
        let common = try object(root["common"])
        let section = try object(root["nackResend"])
        let frame = try XCTUnwrap(try list(section["frames"]).first)
        let sessionKey = hex(try string(common, "sessionKey1"))
        let callId = try string(common, "callId")
        let wire = hex(try string(frame, "wire"))
        let receiverPlaintext = hex(try string(try object(try object(section["receiver"])["neverSawOriginal"]), "plaintext"))

        let fresh = try PqcRtpFrameSealer.createDirectional(pqcSessionKey: sessionKey, callId: callId, selfIsRoleA: false).recv
        XCTAssertEqual(try fresh.open(wire), receiverPlaintext)

        let saw = try PqcRtpFrameSealer.createDirectional(pqcSessionKey: sessionKey, callId: callId, selfIsRoleA: false).recv
        XCTAssertNoThrow(try saw.open(wire))
        XCTAssertThrowsError(try saw.open(wire)) { error in
            XCTAssertEqual(error as? PqcRtpFrameSealer.SealerError, .replayRejected)
        }
    }

    // MARK: - level

    private func layers(of path: [String: Any]) throws -> [PqSecret] {
        let dtlsPq = (path["dtls"] as? String) == "pq"
        let innerPq = (path["inner"] as? String) == "pq"
        let outer = PqOuterState(rawValue: (path["outer"] as? String) ?? "off") ?? .off
        switch try string(path, "path") {
        case "rtp": return PqLevelCalc.rtp(dtlsPq: dtlsPq)
        case "dcmux": return PqLevelCalc.dcmux(dtlsPq: dtlsPq, innerPq: innerPq, outer: outer)
        case "relay", "rvideo": return PqLevelCalc.relay(innerPq: innerPq, outer: outer)
        default:
            XCTFail("unknown path")
            return []
        }
    }

    func testOneToOneLevels() throws {
        let root = try load()
        let section = try object(root["level"])
        let vectors = try list(section["oneToOne"])
        XCTAssertGreaterThan(vectors.count, 15)
        for vector in vectors {
            let name = try string(vector, "name")
            let paths = try list(vector["paths"])
            let perPath = try XCTUnwrap(vector["perPath"] as? [String])
            XCTAssertEqual(paths.count, perPath.count, name)
            var all: [[PqSecret]] = []
            for (index, path) in paths.enumerated() {
                let secrets = try layers(of: path)
                XCTAssertEqual(PqLevelCalc.pathLevel(secrets).token, perPath[index], name)
                all.append(secrets)
            }
            XCTAssertEqual(PqLevelCalc.callLevel(paths: all)?.token, try string(vector, "level"), name)
        }
    }

    func testGroupLevels() throws {
        let root = try load()
        let section = try object(root["level"])
        func announcement(_ d: [String: Any]) -> PqLevelCalc.GroupAnnouncement {
            PqLevelCalc.GroupAnnouncement(tl: d["tl"] as? String, kd: d["kd"] as? String)
        }
        for vector in try list(section["group"]) {
            let name = try string(vector, "name")
            let own = announcement(try object(vector["own"]))
            let others = try list(vector["others"]).map(announcement)
            let result = PqLevelCalc.groupLevel(own: own, others: others)
            XCTAssertEqual(result.level.token, try string(vector, "level"), name)
            XCTAssertEqual(result.unk, try XCTUnwrap(vector["unk"] as? Int), name)
        }
    }

    func testTheLogLine() throws {
        let root = try load()
        let section = try object(try object(root["level"])["logLine"])
        for vector in try list(section["vectors"]) {
            let f = try object(vector["fields"])
            var line = PqLevelLine()
            func s(_ key: String) -> String { f[key] as? String ?? "" }
            line.call = s("call")
            line.kind = s("kind")
            line.level = s("level")
            line.auth = s("auth")
            line.sas = s("sas")
            line.dtls = s("dtls")
            line.frame = s("frame")
            line.relay = s("relay")
            line.dcmux = s("dcmux")
            line.inner = s("inner")
            line.rvideo = s("rvideo")
            line.pin = s("pin")
            line.hold = s("hold")
            line.withdraw = s("withdraw")
            line.caps = s("caps")
            line.pqstate = s("pqstate")
            line.pqSig = s("pq_sig")
            line.outer = s("outer")
            line.reason = s("reason")
            line.rekey = s("rekey")
            line.round = s("round")
            line.tl = f["tl"] as? String
            line.kd = f["kd"] as? String
            line.unk = f["unk"] as? String
            XCTAssertEqual(line.format(), try string(vector, "line"))
        }
    }
}
