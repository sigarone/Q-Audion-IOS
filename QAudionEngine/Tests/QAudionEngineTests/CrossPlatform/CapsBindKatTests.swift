import XCTest
import CryptoKit
@testable import QAudionEngine

/// The sections `capsx`, `extx`, `kcmacExt` and `roleTie` of the shared known-answer file (a byte-for-byte copy, its
/// SHA-256 is pinned in `PqcHardeningV1KatTests`), run against `CapsBind`, `CapsBindRole` and the legacy outer sealer. Every
/// vector is compared byte for byte.
///
/// This code was written on a machine that cannot compile Swift for iOS: the macOS CI job is what runs it.
final class CapsBindKatTests: XCTestCase {

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

    private func flag(_ dict: [String: Any], _ key: String) throws -> Bool {
        try XCTUnwrap(dict[key] as? Bool, key)
    }

    /// The JSON text of a bundle as the vectors describe it: the stored `capabilities` text (escapes unprocessed) and the other
    /// optional members.
    private func bundleText(_ bundle: [String: Any]) throws -> String {
        var text = "{\"capabilities\":" + (try string(bundle, "capabilitiesJson"))
        for key in bundle.keys.sorted() where key != "capabilitiesJson" {
            let value = try XCTUnwrap(bundle[key])
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            text += ",\"" + key + "\":" + String(decoding: data, as: UTF8.self)
        }
        return text + "}"
    }

    // MARK: - capsx

    func testCapsxVectors() throws {
        let cases = try list(try object(try load()["capsx"])["cases"])
        XCTAssertGreaterThan(cases.count, 20)
        for entry in cases {
            let name = try string(entry, "name")
            let text = "{\"capabilities\":" + (try string(entry, "capabilitiesJson")) + "}"
            let peer = CapsBind.analyze(json: text)
            let own = try flag(entry, "ownCapsBindV1")
            XCTAssertEqual(peer.hasTag, try flag(entry, "peerHasCapsBindV1"), name)
            let ext = own && peer.hasTag
            XCTAssertEqual(ext, try flag(entry, "ext"), name)
            let malformed = CapsBind.peerCapabilitiesMalformed(ownAdvertises: own, peer: peer)
            XCTAssertEqual(malformed, (try string(entry, "result")) == "handshake_malformed", name)
            if ext, !malformed, let expected = entry["capsx"] as? String {
                XCTAssertEqual(hexString(peer.capsx), expected, name)
                if let lpExpected = entry["lpCapsx"] as? String {
                    XCTAssertEqual(lpExpected, String(format: "%04x", peer.capsx.count) + expected, name)
                }
            }
        }
    }

    // MARK: - extx

    func testExtxVectors() throws {
        let cases = try list(try object(try load()["extx"])["cases"])
        XCTAssertGreaterThan(cases.count, 30)
        var allAbsent = ""
        for entry in cases {
            if (try string(entry, "name")) == "all-absent" { allAbsent = try string(entry, "extx") }
        }
        XCTAssertFalse(allAbsent.isEmpty)
        for entry in cases {
            let name = try string(entry, "name")
            let fields = try object(entry["bundleFields"])
            let result = CapsBind.extx(ofBundleObject: fields)
            XCTAssertEqual(hexString(result.extx), try string(entry, "extx"), name)
            XCTAssertEqual(result.withdrawn.joined(separator: ","), try string(entry, "withdrawnJoined"), name)
            XCTAssertEqual(hexString(Data(SHA256.hash(data: hex(try string(entry, "preimage"))))), try string(entry, "extx"), name)
            if entry["equalsAllAbsent"] as? Bool == true {
                XCTAssertEqual(hexString(result.extx), allAbsent, name)
            }
        }
    }

    func testTheCanonicalBase64RuleIsExplicit() {
        let good = Data(0..<32).base64EncodedString()
        XCTAssertEqual(CapsBind.strictBase64(good), Data(0..<32))
        XCTAssertNil(CapsBind.strictBase64(good + "\n"))
        XCTAssertNil(CapsBind.strictBase64(String(good.dropLast())))
        XCTAssertNil(CapsBind.strictBase64(" " + good))
        let standard = Data(repeating: 0xFB, count: 32).base64EncodedString()
        XCTAssertNotNil(CapsBind.strictBase64(standard), "standard alphabet with plus and slash")
        XCTAssertNil(CapsBind.strictBase64(standard.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")),
                     "URL-safe alphabet")
        XCTAssertNil(CapsBind.strictBase64(42))
        XCTAssertNil(CapsBind.strictBase64(nil))
        // a value that decodes to more than one LP field holds is absent, never an error
        let big = Data(repeating: 0xAB, count: 70_000).base64EncodedString()
        XCTAssertNil(CapsBind.strictBase64(big))
        let ok = CapsBind.extx(ofBundleObject: ["relayKem": ["mlkem": big, "x25519": good]])
        let onlyX = CapsBind.extx(ofBundleObject: ["relayKem": ["x25519": good]])
        XCTAssertEqual(ok.extx, onlyX.extx)
    }

    // MARK: - kcmacExt

    func testKcmacExtVectorsByteForByte() throws {
        let cases = try list(try object(try load()["kcmacExt"])["cases"])
        XCTAssertGreaterThan(cases.count, 10)
        for entry in cases {
            let name = try string(entry, "name")
            let kcKey = hex(try string(entry, "kcKey"))
            let v1 = hex(try string(entry, "kcTranscriptV1"))
            let views = try list(entry["views"])
            XCTAssertEqual(views.count, 2, name)
            var macs: [(Data, Data)] = []
            for view in views {
                let offerObject = try object(view["offer"])
                let acceptObject = try object(view["accept"])
                let offer = CapsBind.analyze(json: try bundleText(offerObject))
                let accept = CapsBind.analyze(json: try bundleText(acceptObject))
                let offerer = (try string(view, "side")) == "offerer"
                let own = offerer ? offer : accept
                let peer = offerer ? accept : offer
                let ext = CapsBind.isActive(own: own, peer: peer)
                XCTAssertEqual(ext, try flag(view, "ext"), name)
                var transcript = v1
                if ext {
                    XCTAssertEqual(hexString(offer.capsx), try string(view, "capsxOffer"), name)
                    XCTAssertEqual(hexString(accept.capsx), try string(view, "capsxAccept"), name)
                    XCTAssertEqual(hexString(offer.extx), try string(view, "extxOffer"), name)
                    XCTAssertEqual(hexString(accept.extx), try string(view, "extxAccept"), name)
                    let x = try XCTUnwrap(CapsBind.kcTranscriptX(kcTranscript: v1, offer: offer, accept: accept), name)
                    XCTAssertEqual(hexString(x), try string(view, "kcTranscriptX"), name)
                    transcript = x
                }
                let init1 = KeyConfirmation.macInit(kcKey: kcKey, transcript: transcript)
                let resp = KeyConfirmation.macResp(kcKey: kcKey, transcript: transcript)
                XCTAssertEqual(hexString(init1), try string(view, "kcMacInit"), name)
                XCTAssertEqual(hexString(resp), try string(view, "kcMacResp"), name)
                macs.append((init1, resp))
            }
            let agree = macs[0].0 == macs[1].0 && macs[0].1 == macs[1].1
            XCTAssertEqual(agree, try flag(entry, "macsAgree"), name)
        }
    }

    func testAnOldPeerLeavesTheMacsExactlyAsToday() throws {
        let cases = try list(try object(try load()["kcmacExt"])["cases"])
        var checked = 0
        for entry in cases {
            let name = try string(entry, "name")
            guard name.hasSuffix("ext-off-equals-v6-macs") || name == "old-peer-ext-off" else { continue }
            for view in try list(entry["views"]) {
                XCTAssertEqual(view["ext"] as? Bool, false, name)
                XCTAssertNil(view["kcTranscriptX"], name)
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 6)
    }

    func testKcTranscriptXNeedsA32ByteTranscript() {
        let info = CapsBind.analyze(json: "{\"capabilities\":{\"capsBindV1\":true}}")
        XCTAssertNil(CapsBind.kcTranscriptX(kcTranscript: Data(count: 31), offer: info, accept: info))
        XCTAssertNotNil(CapsBind.kcTranscriptX(kcTranscript: Data(count: 32), offer: info, accept: info))
    }

    // MARK: - roleTie

    func testTheUserIdRoleAndTheTieClassification() throws {
        let section = try object(try load()["roleTie"])
        for entry in try list(section["roleA"]) {
            let me = try string(entry, "self")
            let peer = try string(entry, "peer")
            XCTAssertEqual(CapsBindRole.idsTie(me, peer),try flag(entry, "tie"), "\(me) \(peer)")
            XCTAssertEqual(CapsBindRole.selfIsRoleA(selfUserId: me, peerUserId: peer, context: nil),
                           try flag(entry, "selfIsRoleA"), "\(me) \(peer)")
        }
    }

    func testTheTieTableOneRowEach() throws {
        let section = try object(try load()["roleTie"])
        let rows = try list(section["tieTable"])
        XCTAssertEqual(rows.count, 4)
        for row in rows {
            let own = (try string(row, "own")) == "yes"
            let peer = (try string(row, "peer")) == "yes"
            let expected = try string(row, "role")
            let caller = CapsBindRole.selfIsRoleA(
                selfUserId: "AbC", peerUserId: "abc",
                context: CapsBindRole.Context(selfIsCaller: true, ownCapsBind: own, peerCapsBind: peer))
            let callee = CapsBindRole.selfIsRoleA(
                selfUserId: "abc", peerUserId: "AbC",
                context: CapsBindRole.Context(selfIsCaller: false, ownCapsBind: own, peerCapsBind: peer))
            switch expected {
            case "B":
                XCTAssertFalse(caller)
                XCTAssertFalse(callee)
            case "A":
                XCTAssertTrue(caller)
                XCTAssertTrue(callee)
            default:
                XCTAssertTrue(caller, "caller A")
                XCTAssertFalse(callee, "callee B")
            }
        }
    }

    func testTieScenariosSealAndOpenAsTheVectorsSay() throws {
        let root = try load()
        let common = try object(root["common"])
        let section = try object(root["roleTie"])
        let sessionKey = hex(try string(common, "sessionKey1"))
        let callId = try string(common, "callId")
        let plaintext = hex(try string(section, "plaintext"))
        for scenario in try list(section["tieScenarios"]) {
            let name = try string(scenario, "name")
            var frames: [Bool: Data] = [:]
            var receivers: [Bool: PqcRtpFrameSealer] = [:]
            for (isCaller, key) in [(true, "caller"), (false, "callee")] {
                let side = try object(scenario[key])
                let own = try flag(side, "advertisesCapsBindV1")
                let peer = try flag(side, "peerAdvertisesCapsBindV1")
                let userId = try string(side, "userId")
                let peerId = isCaller ? "abc" : "AbC"
                let roleA = CapsBindRole.selfIsRoleA(
                    selfUserId: userId, peerUserId: peerId,
                    context: CapsBindRole.Context(selfIsCaller: isCaller, ownCapsBind: own, peerCapsBind: peer))
                XCTAssertEqual(roleA ? "A" : "B", try string(side, "role"), name)
                XCTAssertEqual(roleA ? "outerKeyA2B" : "outerKeyB2A", try string(side, "sendKey"), name)
                let pair = try PqcRtpFrameSealer.createDirectional(
                    pqcSessionKey: sessionKey, callId: callId, selfIsRoleA: roleA, selfIsCaller: isCaller)
                let frame = try pair.send.seal(plaintext)
                XCTAssertEqual(hexString(frame), try string(side, "frameCounter0"), name)
                XCTAssertEqual(Int(frame[frame.startIndex]), try XCTUnwrap(side["nonceByte0"] as? Int), name)
                frames[isCaller] = frame
                receivers[isCaller] = pair.recv
            }
            let callerFrame = try XCTUnwrap(frames[true])
            let calleeFrame = try XCTUnwrap(frames[false])
            XCTAssertEqual(callerFrame[callerFrame.startIndex] != calleeFrame[calleeFrame.startIndex],
                           try flag(scenario, "nonceDiffersInByte0"), name)
            XCTAssertEqual((try? receivers[false]?.open(callerFrame)) == plaintext,
                           try flag(scenario, "callerFrameOpensAtCallee"), name)
            XCTAssertEqual((try? receivers[true]?.open(calleeFrame)) == plaintext,
                           try flag(scenario, "calleeFrameOpensAtCaller"), name)
        }
    }
}
