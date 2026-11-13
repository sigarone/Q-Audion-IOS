import XCTest
import CryptoKit
@testable import QAudionEngine

/// The sections `rekeyChain`, `frameKeyV6` and the rekey lines of `level.logLine` of the shared known-answer file, run against
/// the pure derivations and decisions. Every vector is compared byte for byte.
final class RekeyChainKatTests: XCTestCase {

    // MARK: - Loading

    private func load() throws -> [String: Any] {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "kat"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "Resources/kat")
        ]
        let url = try XCTUnwrap(candidates.compactMap { $0 }.first, "pqc-hardening-v1-kat.json is not in the test bundle")
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url), options: [])
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

    private func vectors(_ root: [String: Any], _ section: String, _ name: String) throws -> [[String: Any]] {
        let top = try XCTUnwrap(root[section] as? [String: Any], section)
        // Most sections are `{rule, vectors: [...]}`; the frameKeyV6 keys, frames and negatives are plain arrays.
        if let plain = top[name] as? [[String: Any]] { return plain }
        let sub = try XCTUnwrap(top[name] as? [String: Any], name)
        return try XCTUnwrap(sub["vectors"] as? [[String: Any]], name)
    }

    private func str(_ d: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(d[key] as? String, key)
    }

    private func int(_ d: [String: Any], _ key: String) throws -> Int {
        try XCTUnwrap((d[key] as? NSNumber)?.intValue, key)
    }

    func testTheNewLabelsHaveTheirLengths() {
        XCTAssertEqual(HkdfLabels.rekeyChainKeyV1.count, 17)
        XCTAssertEqual(HkdfLabels.sessionKeyChainedV1.count, 23)
        XCTAssertEqual(HkdfLabels.frameKeyInfoPrefixV6.count, 21)
        XCTAssertEqual(HkdfLabels.frameKeySaltV6.count, 21)
    }

    // MARK: - rekeyChain.ck

    func testChainKeysMatchTheSharedVectors() throws {
        let list = try vectors(try load(), "rekeyChain", "ck")
        XCTAssertEqual(list.count, 6)
        for v in list {
            let name = try str(v, "name")
            XCTAssertEqual(RekeyChain.asciiLower(try str(v, "channelCallId")), try str(v, "callIdL"), name)
            let ck = RekeyChain.deriveChainKey(
                sessionKey: hex(try str(v, "sessionKey")), callIdL: try str(v, "callIdL"), epoch: Int32(try int(v, "E")))
            XCTAssertEqual(ck, hex(try str(v, "ck")), name)
        }
    }

    func testChainKeyRefusesWrongInputs() {
        let key = Data(repeating: 7, count: 32)
        XCTAssertNil(RekeyChain.deriveChainKey(sessionKey: Data(repeating: 7, count: 31), callIdL: "a", epoch: 0))
        XCTAssertNil(RekeyChain.deriveChainKey(sessionKey: key, callIdL: "", epoch: 0))
        XCTAssertNil(RekeyChain.deriveChainKey(sessionKey: key, callIdL: "a", epoch: -1))
        XCTAssertNil(RekeyChain.deriveChainKey(sessionKey: key, callIdL: "a", epoch: Int32.max))
        XCTAssertNotNil(RekeyChain.deriveChainKey(sessionKey: key, callIdL: "a", epoch: Int32.max - 1))
    }

    // MARK: - rekeyChain.sessionKey

    func testChainedSessionKeysMatchTheSharedVectors() throws {
        let list = try vectors(try load(), "rekeyChain", "sessionKey")
        XCTAssertEqual(list.count, 6)
        for v in list {
            let name = try str(v, "name")
            let psk = try str(v, "psk")
            let pskData: Data? = psk.isEmpty ? nil : hex(psk)
            let accept = hex(try str(v, "acceptV6Sha256"))
            XCTAssertEqual(RekeyChain.sessionKeySalt(psk: pskData), hex(try str(v, "salt")), name)
            let chained = RekeyChain.deriveSessionKeyChained(
                pqcSharedSecret: hex(try str(v, "pqcSS")), x25519Shared: hex(try str(v, "x25519SS")),
                ckB: ChainKeyBuffer(copying: hex(try str(v, "ckB"))), base: Int32(try int(v, "B")), psk: pskData,
                acceptHash: accept)
            XCTAssertEqual(chained, hex(try str(v, "sessionKey")), name)
            let unchained = QAudionCallIntegration.deriveTranscriptBoundSessionKey(
                pqcSharedSecret: hex(try str(v, "pqcSS")), x25519Shared: hex(try str(v, "x25519SS")), psk: pskData,
                transcriptHash: accept)
            XCTAssertEqual(unchained, hex(try str(v, "unchainedSessionKey")), name)
            XCTAssertNotEqual(chained, unchained, name)
        }
    }

    func testChainedSessionKeyNeedsALiveChainKey() {
        let buffer = ChainKeyBuffer(copying: Data(repeating: 9, count: 32))
        buffer.wipe()
        XCTAssertTrue(buffer.isWipedForTesting)
        XCTAssertNil(RekeyChain.deriveSessionKeyChained(
            pqcSharedSecret: Data(repeating: 1, count: 32), x25519Shared: Data(repeating: 2, count: 32), ckB: buffer, base: 0,
            psk: nil, acceptHash: Data(repeating: 3, count: 32)))
    }

    // MARK: - rekeyChain.chainBaseDecisions

    func testChainBaseDecisionsMatchTheSharedVectors() throws {
        let list = try vectors(try load(), "rekeyChain", "chainBaseDecisions")
        XCTAssertEqual(list.count, 32)
        for v in list {
            let name = try str(v, "name")
            let expect = try XCTUnwrap(v["expect"] as? [String: Any], name)
            let verdict = try str(expect, "verdict")
            let json = try str(v, "offerJson")
            guard case .valid(let members) = StrictBundleJSON.validate(json) else {
                XCTAssertEqual(verdict, "malformed", name)
                continue
            }
            if name == "rekeyRound-2-pow-31-malformed" {
                // grammar-valid; the call-level outcome is the round range of the routing
                XCTAssertEqual(verdict, "malformed", name)
                continue
            }
            XCTAssertNotEqual(verdict, "malformed", name)
            let retained = Set(try XCTUnwrap(v["retainedChainKeys"] as? [NSNumber], name).map { $0.int32Value })
            let messageKind = try str(v, "messageKind")
            let negotiated = v["callNegotiatedRekeyChainV1"] as? Bool ?? false
            let applies = negotiated && messageKind == "rekeyOffer"
            let decision = RekeyChain.decideChainBase(
                members: members, epoch: Int32(try int(v, "E")), hasRecord: v["chainRecordExists"] as? Bool ?? false,
                holdsCk: { retained.contains($0) }, applies: applies)
            switch verdict {
            case "accept":
                XCTAssertEqual(decision, .accept(base: Int32(try int(expect, "base"))), name)
            case "ignore":
                XCTAssertEqual(decision, .ignored, name)
            case "refuse":
                guard case .refuse = decision else { XCTFail("refused: \(name)"); continue }
            default:
                XCTFail("unknown verdict \(verdict) in \(name)")
            }
        }
    }

    // MARK: - frameKeyV6.keys

    func testFrameKeysMatchTheSharedVectors() throws {
        let root = try load()
        let list = try vectors(root, "frameKeyV6", "keys")
        XCTAssertEqual(list.count, 20)
        for v in list {
            let name = (try str(v, "set")) + "/" + (try str(v, "kind")) + "/" + (try str(v, "dir"))
            let sessionKey = hex(try str(v, "sessionKey"))
            let all = try XCTUnwrap(FrameKeysV6.derive(sessionKey: sessionKey, callIdL: try str(v, "callIdL")), name)
            let kind: FrameKeysV6.Kind = (try str(v, "kind")) == "audio" ? .audio : .video
            let pair = all.keys(for: kind)
            let key = (try str(v, "dir")) == "o2a" ? pair.offererToAcceptor : pair.acceptorToOfferer
            XCTAssertEqual(key, hex(try str(v, "key")), name)
            XCTAssertNotEqual(key, hex(try str(v, "v5Key")), name)
        }
    }

    // MARK: - frameKeyV6.frames and negatives (the frame model)

    private func aesKey(setKeyMaterial: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: setKeyMaterial), salt: Data(), info: Data(repeating: 0, count: 128),
            outputByteCount: 32)
    }

    private func be32(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    func testFrameModelReproducesTheSharedFrames() throws {
        let list = try vectors(try load(), "frameKeyV6", "frames")
        XCTAssertEqual(list.count, 6)
        for v in list {
            let name = try str(v, "name")
            let sessionKey = hex(try str(v, "sessionKey"))
            let all = try XCTUnwrap(FrameKeysV6.derive(sessionKey: sessionKey, callIdL: try str(v, "callIdL")), name)
            let kind: FrameKeysV6.Kind = (try str(v, "kind")) == "audio" ? .audio : .video
            let pair = all.keys(for: kind)
            let setKey = (try str(v, "dir")) == "o2a" ? pair.offererToAcceptor : pair.acceptorToOfferer
            XCTAssertEqual(setKey, hex(try str(v, "setKeyMaterial")), name)
            let key = aesKey(setKeyMaterial: setKey)
            XCTAssertEqual(key.withUnsafeBytes { Data($0) }, hex(try str(v, "aesKey")), name)

            let ssrc = UInt32(try int(v, "ssrc"))
            let ts = UInt32(truncatingIfNeeded: try int(v, "rtpTs"))
            let counter = UInt32(truncatingIfNeeded: try int(v, "counter"))
            var iv = be32(ssrc)
            iv.append(be32(ts))
            iv.append(be32(ts &- counter))
            XCTAssertEqual(iv, hex(try str(v, "iv")), name)

            let plaintext = hex(try str(v, "plaintext"))
            let unencrypted = try int(v, "U")
            let header = Data(plaintext.prefix(unencrypted))
            let payload = Data(plaintext.dropFirst(unencrypted))
            let box = try AES.GCM.seal(payload, using: key, nonce: AES.GCM.Nonce(data: iv), authenticating: header)
            let trailer = Data([0x0C, UInt8(try int(v, "E") % 16)])
            XCTAssertEqual(trailer, hex(try str(v, "trailer")), name)
            XCTAssertEqual(try int(v, "keyIndex"), try int(v, "E") % 16, name)
            var frame = header
            frame.append(box.ciphertext)
            frame.append(box.tag)
            frame.append(iv)
            frame.append(trailer)
            XCTAssertEqual(frame, hex(try str(v, "frame")), name)
        }
    }

    func testFrameModelRefusesTheWrongKeys() throws {
        let root = try load()
        let frames = try vectors(root, "frameKeyV6", "frames")
        let negatives = try vectors(root, "frameKeyV6", "negatives")
        XCTAssertEqual(negatives.count, 5)
        for n in negatives {
            let name = try str(n, "name")
            let frameName = try str(n, "frame")
            let entry = try XCTUnwrap(frames.first { ($0["name"] as? String) == frameName }, name)
            let frame = hex(try str(entry, "frame"))
            let unencrypted = try int(entry, "U")
            let header = Data(frame.prefix(unencrypted))
            let body = Data(frame.dropFirst(unencrypted).dropLast(14))
            let iv = Data(frame.dropLast(2).suffix(12))
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: iv), ciphertext: body.dropLast(16), tag: body.suffix(16))
            let key = aesKey(setKeyMaterial: hex(try str(n, "key")))
            let opened = try? AES.GCM.open(box, using: key, authenticating: header)
            if (try str(n, "expect")) == "open" {
                XCTAssertNotNil(opened, name)
            } else {
                XCTAssertNil(opened, name)
            }
        }
    }

    // MARK: - frameKeyV6.tagDecisions and advertise

    func testTagDecisionsMatchTheSharedVectors() throws {
        let list = try vectors(try load(), "frameKeyV6", "tagDecisions")
        XCTAssertEqual(list.count, 10)
        for v in list {
            let name = try str(v, "name")
            let own = CapsBind.analyze(json: "{\"capabilities\":" + (try str(v, "ownCapabilitiesJson")) + "}")
            let peer = CapsBind.analyze(json: "{\"capabilities\":" + (try str(v, "peerCapabilitiesJson")) + "}")
            XCTAssertEqual(CapsBind.isActive(own: own, peer: peer), v["ext"] as? Bool, name)
            let expect = try str(v, "expect")
            if expect == "handshake_malformed" {
                XCTAssertTrue(CapsBind.peerCapabilitiesMalformed(ownAdvertises: own.hasTag, peer: peer), name)
            } else {
                XCTAssertFalse(CapsBind.peerCapabilitiesMalformed(ownAdvertises: own.hasTag, peer: peer), name)
                XCTAssertEqual(CapsBind.negotiateS8b(own: own, peer: peer, tag: "frameKeyV6"), expect == "v6", name)
            }
        }
    }

    func testAdvertiseFollowsTheKeyMaterial() throws {
        let list = try vectors(try load(), "frameKeyV6", "advertise")
        XCTAssertEqual(list.count, 2)
        for v in list {
            let earbud = (try str(v, "keyMaterial")) != "sessionKey_E"
            let name = try str(v, "name")
            XCTAssertEqual(FrameKeyV6Policy.keyMaterialIsSessionKeyE(earbudPaired: earbud), v["advertise"] as? Bool, name)
        }
    }

    // MARK: - level.logLine (the rekey lines)

    func testTheRekeyLogLines() throws {
        let section = try XCTUnwrap(try XCTUnwrap(try load()["level"] as? [String: Any])["logLine"] as? [String: Any])
        let list = try XCTUnwrap(section["rekeyVectors"] as? [[String: Any]])
        XCTAssertEqual(list.count, 8)
        for vector in list {
            let f = try XCTUnwrap(vector["fields"] as? [String: Any])
            func s(_ key: String) -> String { f[key] as? String ?? "" }
            var line = PqLevelLine()
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
            line.rreason = s("rreason")
            let expected = try str(vector, "line")
            let name = try str(vector, "name")
            XCTAssertEqual(line.format(), expected, name)
        }
    }
}
