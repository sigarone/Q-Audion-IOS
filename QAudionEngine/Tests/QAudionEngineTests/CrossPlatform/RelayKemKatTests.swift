import XCTest
import CryptoKit
import CLiboqs
@testable import QAudionEngine

/// The key exchange of the outer relay layer against the shared known-answer file (sections `relayKemV1.round1`, `mixedCaseChannel`,
/// `acceptorEncapsulation`, `x25519Zero`, `bundleDecisions`, `failureClassification`), and the bundle layer around it: the raw
/// reader of the member with this app's slash escaping, the copy helpers, the wire shape with the tags off.
final class RelayKemKatTests: XCTestCase {

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

    private func relaySection(_ root: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(root["relayKemV1"] as? [String: Any], "relayKemV1")
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

    private func wire(_ d: [String: Any]) throws -> RelayKemWire {
        RelayKemWire(mlkem: hex(try str(d, "mlkem")), x25519: hex(try str(d, "x25519")))
    }

    // MARK: - Deterministic ML-KEM, as function parameters

    private func deriveKeyPair(seed: Data) throws -> (publicKey: Data, secretKey: Data) {
        var publicKey = Data(count: Int(OQS_KEM_ml_kem_1024_length_public_key))
        var secretKey = Data(count: Int(OQS_KEM_ml_kem_1024_length_secret_key))
        let status = publicKey.withUnsafeMutableBytes { pkBuf in
            secretKey.withUnsafeMutableBytes { skBuf in
                seed.withUnsafeBytes { seedBuf in
                    OQS_KEM_ml_kem_1024_keypair_derand(
                        pkBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        skBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        seedBuf.baseAddress!.assumingMemoryBound(to: UInt8.self))
                }
            }
        }
        XCTAssertEqual(status, OQS_SUCCESS)
        return (publicKey, secretKey)
    }

    private func encapsulateDeterministic(key: Data, randomness: Data) -> (ct: Data, ss: Data)? {
        var ciphertext = Data(count: Int(OQS_KEM_ml_kem_1024_length_ciphertext))
        var shared = Data(count: Int(OQS_KEM_ml_kem_1024_length_shared_secret))
        let status = ciphertext.withUnsafeMutableBytes { ctBuf in
            shared.withUnsafeMutableBytes { ssBuf in
                key.withUnsafeBytes { pkBuf in
                    randomness.withUnsafeBytes { mBuf in
                        OQS_KEM_ml_kem_1024_encaps_derand(
                            ctBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            ssBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            pkBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            mBuf.baseAddress!.assumingMemoryBound(to: UInt8.self))
                    }
                }
            }
        }
        if status != OQS_SUCCESS { return nil }
        return (ciphertext, shared)
    }

    // MARK: - round1

    func testRound1TheOfferTheAcceptTheSecretsAndTheFourKeysMatchTheVector() throws {
        let round1 = try XCTUnwrap(try relaySection(try load())["round1"] as? [String: Any])
        let seed = hex(try str(round1, "mlkemSeed_d_z"))
        let pair = try deriveKeyPair(seed: seed)
        let offerVector = try wire(try XCTUnwrap(round1["offer"] as? [String: Any]))
        XCTAssertEqual(pair.publicKey, offerVector.mlkem)
        let offerKeys = try XCTUnwrap(RelayOfferKeys(
            mlkemPublic: pair.publicKey, mlkemSecret: pair.secretKey, x25519Scalar: hex(try str(round1, "x25519ScalarOfferer"))))
        XCTAssertEqual(offerKeys.pub, offerVector)

        // the acceptor
        let randomness = hex(try str(round1, "mlkemEncapsulationRandomness_m"))
        let acceptVector = try wire(try XCTUnwrap(round1["accept"] as? [String: Any]))
        let encapsulated = RelayKem.encapsulate(
            offer: offerVector,
            mlkemEncaps: { key in self.encapsulateDeterministic(key: key, randomness: randomness) },
            x25519Scalar: hex(try str(round1, "x25519ScalarAcceptor")))
        guard case .ok(let accept, let acceptorSecrets) = encapsulated else { return XCTFail("the acceptor did not encapsulate") }
        XCTAssertEqual(accept, acceptVector)
        XCTAssertEqual(acceptorSecrets.relaySS.copyData(), hex(try str(round1, "relaySS")))
        XCTAssertEqual(acceptorSecrets.relayx.copyData(), hex(try str(round1, "relayx")))
        XCTAssertEqual(RelayKem.relayx(offer: offerVector, accept: acceptVector), hex(try str(round1, "relayx")))

        // the offerer reaches the same secrets
        guard case .ok(let offererSecrets) = offerKeys.decapsulate(acceptVector) else { return XCTFail("the offerer did not decapsulate") }
        XCTAssertEqual(offererSecrets.relaySS.copyData(), hex(try str(round1, "relaySS")))
        XCTAssertEqual(offererSecrets.relayx.copyData(), hex(try str(round1, "relayx")))
        XCTAssertTrue(offerKeys.isWipedForTesting)

        // the four keys, and the HKDF info of each
        let callIdL = try str(round1, "callIdL")
        let sessionKey = hex(try str(round1, "sessionKey"))
        let binding = hex(try str(round1, "acceptBinding"))
        let derived = try XCTUnwrap(RelayKem.deriveOuterKeys(
            secrets: offererSecrets, sessionKey: sessionKey, acceptBinding: binding, callIdL: callIdL))
        let list = try XCTUnwrap(round1["kOut"] as? [[String: Any]])
        XCTAssertEqual(list.count, 4)
        for entry in list {
            let kind: InnerSealV2.Kind = try str(entry, "kind") == "audio" ? .audio : .video
            let direction: InnerSealV2.Direction = try str(entry, "dir") == "o2a" ? .offererToAcceptor : .acceptorToOfferer
            let infoHex = try str(entry, "info")
            XCTAssertEqual(derived.key(kind: kind, direction: direction).copyData(), hex(try str(entry, "kOut")), infoHex)
            XCTAssertEqual(RelayKem.keyInfo(callIdL: callIdL, kind: kind, direction: direction, acceptBinding: binding,
                                            relayx: hex(try str(round1, "relayx"))), hex(infoHex))
        }
        derived.wipe()
    }

    func testTheChannelIdWithUpperCaseLettersGivesTheKeysOfItsLowercaseForm() throws {
        let section = try relaySection(try load())
        let mixed = try XCTUnwrap(section["mixedCaseChannel"] as? [String: Any])
        let round1 = try XCTUnwrap(section["round1"] as? [String: Any])
        XCTAssertEqual(RekeyChain.asciiLower(try str(mixed, "channelCallId")), try str(round1, "callIdL"))
        XCTAssertEqual(try str(mixed, "callIdL"), try str(round1, "callIdL"))
        let a = try XCTUnwrap(mixed["kOut"] as? [[String: Any]]).map { try? str($0, "kOut") }
        let b = try XCTUnwrap(round1["kOut"] as? [[String: Any]]).map { try? str($0, "kOut") }
        XCTAssertEqual(a, b)
    }

    // MARK: - acceptorEncapsulation and x25519Zero

    func testTheAcceptorSendsNoMemberForAKeyOutOfRange() throws {
        let vectors = try XCTUnwrap(try relaySection(try load())["acceptorEncapsulation"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 2)
        for vector in vectors {
            let expect = try XCTUnwrap(vector["expect"] as? [String: Any])
            let key = hex(try str(vector, "offerEncapsulationKey"))
            let offer = RelayKemWire(mlkem: key, x25519: Data(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation))
            let result = RelayKem.encapsulate(offer: offer)
            if expect["acceptorSendsRelayKem"] as? Bool == true {
                guard case .ok = result else { return XCTFail(try str(vector, "name")) }
            } else {
                guard case .badKey = result else { return XCTFail(try str(vector, "name")) }
            }
        }
    }

    func testALowOrderX25519PointIsAZeroOutputWhetherTheLibraryThrowsOrNot() throws {
        let vectors = try XCTUnwrap(try relaySection(try load())["x25519Zero"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 3)
        for vector in vectors {
            let name = try str(vector, "name")
            XCTAssertNil(RelayKem.x25519Shared(scalar: hex(try str(vector, "ownScalar")), peerPublic: hex(try str(vector, "peerPublicKey"))),
                         name)
        }
        // an honest peer is not a zero output
        let own = Curve25519.KeyAgreement.PrivateKey()
        let other = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertNotNil(RelayKem.x25519Shared(scalar: own.rawRepresentation, peerPublic: other.publicKey.rawRepresentation))
    }

    // MARK: - bundleDecisions and failureClassification

    func testTheTwentyFourBundleDecisionsRunThroughTheRealAnalysis() throws {
        let vectors = try XCTUnwrap(
            (try relaySection(try load())["bundleDecisions"] as? [String: Any])?["vectors"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 24)
        for vector in vectors {
            let name = try str(vector, "name")
            let own = CapsBind.analyze(json: try str(vector, "offerBundleJson"))
            let peer = CapsBind.analyze(json: try str(vector, "acceptBundleJson"))
            let srtp = try XCTUnwrap(vector["srtpDirKeyV1Negotiated"] as? Bool, name)
            let decision = RelayDecision.decide(own: own, peer: peer, srtpDirKeyV1Negotiated: srtp)
            let expect = try XCTUnwrap(vector["expect"] as? [String: Any])
            let outerWord: String
            switch decision.outer {
            case .kout: outerWord = "kOut"
            case .legacy: outerWord = "legacy"
            case .rule3: outerWord = "rule3"
            }
            XCTAssertEqual(outerWord, try str(expect, "outer"), name)
            XCTAssertEqual(decision.relayKemInEffect, expect["relayKemInEffect"] as? Bool, name)
            XCTAssertEqual(decision.relayRotInEffect, expect["relayRotInEffect"] as? Bool, name)
            XCTAssertEqual(decision.token, try str(expect, "relayToken"), name)
            // the same decision through the features of the key state
            let features = LiveCallCrypto.Features.negotiate(
                own: own, peer: peer, ownCapabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true), selfIsCaller: true)
            XCTAssertEqual(features.relayKemV1, decision.relayKemInEffect, name)
            XCTAssertEqual(features.relayRotV1, decision.relayRotInEffect, name)
        }
    }

    func testTheEightFailureClassificationsFollowTheVectors() throws {
        let vectors = try XCTUnwrap(try relaySection(try load())["failureClassification"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 8)
        for vector in vectors {
            let name = try str(vector, "name")
            let phase: RelayFailurePolicy.Phase = try str(vector, "phase") == "round1" ? .round1 : .rekey
            let failure: RelayFailurePolicy.Failure
            switch try str(vector, "failure") {
            case "x25519-all-zero", "x25519-library-throws-on-low-order-point": failure = .x25519Zero
            case "other-exception-after-accept-4b": failure = .otherAfterAccept
            case "other-local-exception-in-derivation": failure = .otherLocalException
            default: failure = .peerRelayKemAbsentOrInvalid
            }
            let srtp = try XCTUnwrap(vector["srtpDirKeyV1Negotiated"] as? Bool, name)
            let outcome = RelayFailurePolicy.classify(phase: phase, failure: failure, srtpDirKeyV1: srtp)
            let expect = try XCTUnwrap(vector["expect"] as? [String: Any])
            XCTAssertEqual(outcome.reason, try str(expect, "reason"), name)
            XCTAssertEqual(outcome.endsCall, expect["endsCall"] as? Bool, name)
            XCTAssertEqual(outcome.kOutInstalled, expect["kOutInstalled"] as? Bool, name)
            XCTAssertEqual(outcome.sendsOuterOffV1, expect["sendsOuterOffV1"] as? Bool, name)
            if let legacy = expect["legacySealerInstalled"] as? Bool { XCTAssertEqual(outcome.legacySealerInstalled, legacy, name) }
            if let word = expect["outer"] as? String { XCTAssertEqual(outcome.outerOff, word == "off", name) }
            if let inEffect = expect["relayKemInEffect"] as? Bool { XCTAssertEqual(outcome.relayKemInEffect, inEffect, name) }
            if let stays = expect["relayKemStaysActive"] as? Bool { XCTAssertEqual(outcome.relayKemInEffect, stays, name) }
        }
    }

    // MARK: - The member as this app writes it

    private func relayBundleJson(member: String, tags: String = "\"capsBindV1\":true,\"relayKemV1\":true") -> String {
        "{\"callId\":\"c\",\"capabilities\":{" + tags + "}," + member + "}"
    }

    func testAMemberWithSlashesInItsBase64IsReadByTheRawReaderAsThisAppWritesIt() throws {
        let wire = RelayKemWire(mlkem: Data(repeating: 0xFF, count: 1568), x25519: Data(repeating: 0xFB, count: 32))
        let bundle = AndroidHandshakeBundle(
            kind: .offer, callId: "c", pqcPublicKey: "", x25519PublicKey: "",
            capabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true, capsBindV1: true, relayKemV1: true),
            relayKem: AndroidHandshakeBundle.RelayKemMember(wire: wire))
        let text = AndroidHandshakeEnvelope.jsonPayload(of: bundle)
        XCTAssertTrue(text.contains("\\/"), "this app writes every slash of a base64 value escaped")
        let analysis = CapsBind.analyze(json: text)
        XCTAssertEqual(analysis.relay, .valid(wire))
        // the same text with plain slashes gives the same member and the same EXTX
        let plain = CapsBind.analyze(json: text.replacingOccurrences(of: "\\/", with: "/"))
        XCTAssertEqual(plain.relay, .valid(wire))
        XCTAssertEqual(plain.extx, analysis.extx)
        XCTAssertEqual(CapsBind.analyze(bundle: bundle), analysis)
    }

    func testARepeatedOrUnknownMemberIsInvalidAndCountsAsAbsentInExtx() throws {
        let good = "\"mlkem\":\"\(Data(repeating: 1, count: 1568).base64EncodedString())\",\"x25519\":\"\(Data(repeating: 2, count: 32).base64EncodedString())\""
        let absent = CapsBind.analyze(json: "{\"callId\":\"c\",\"capabilities\":{\"capsBindV1\":true,\"relayKemV1\":true}}")
        XCTAssertEqual(absent.relay, .absent)
        let valid = CapsBind.analyze(json: relayBundleJson(member: "\"relayKem\":{" + good + "}"))
        guard case .valid = valid.relay else { return XCTFail("a well-formed member") }
        XCTAssertNotEqual(valid.extx, absent.extx)
        let repeated = CapsBind.analyze(json: relayBundleJson(member: "\"relayKem\":{" + good + ",\"mlkem\":\"AAAA\"}"))
        XCTAssertEqual(repeated.relay, .invalid)
        XCTAssertEqual(repeated.extx, absent.extx)
        let extra = CapsBind.analyze(json: relayBundleJson(member: "\"relayKem\":{" + good + ",\"extra\":\"AAAA\"}"))
        XCTAssertEqual(extra.relay, .invalid)
        XCTAssertEqual(extra.extx, absent.extx)
        let twice = CapsBind.analyze(json: relayBundleJson(member: "\"relayKem\":{" + good + "},\"relayKem\":{" + good + "}"))
        XCTAssertEqual(twice.relay, .invalid)
        XCTAssertEqual(twice.extx, absent.extx)
        let notObject = CapsBind.analyze(json: relayBundleJson(member: "\"relayKem\":\"x\""))
        XCTAssertEqual(notObject.relay, .invalid)
        XCTAssertEqual(notObject.extx, absent.extx)
        // a wrong length is invalid but its bytes still enter EXTX as sent
        let shortKey = CapsBind.analyze(json: relayBundleJson(
            member: "\"relayKem\":{\"mlkem\":\"\(Data(repeating: 1, count: 1567).base64EncodedString())\",\"x25519\":\"\(Data(repeating: 2, count: 32).base64EncodedString())\"}"))
        XCTAssertEqual(shortKey.relay, .invalid)
        XCTAssertNotEqual(shortKey.extx, absent.extx)
    }

    // MARK: - The copy helpers and the wire shape

    func testTheMemberAndBothTagsSurviveEveryCopyOfTheBundle() throws {
        let wire = RelayKemWire(mlkem: Data(repeating: 3, count: 1568), x25519: Data(repeating: 4, count: 32))
        let caps = AndroidHandshakeBundle.Capabilities(ratchetV3: true, capsBindV1: true, relayKemV1: true, relayRotV1: true)
        let base = AndroidHandshakeBundle(
            kind: .offer, callId: "c", pqcPublicKey: "", x25519PublicKey: "", capabilities: caps,
            relayKem: AndroidHandshakeBundle.RelayKemMember(wire: wire))
        let copies: [AndroidHandshakeBundle] = [
            base.with(chainBase: 2), base.withSasCommit("x"),
            base.withSecondSignature(capabilities: caps.with(sigHybridV1: true), mldsaKeyId: "k", sigHybrid: "s", capsWithdrawn: nil),
            base.with(relayKem: base.relayKem)
        ]
        for copy in copies {
            let text = AndroidHandshakeEnvelope.jsonPayload(of: copy)
            XCTAssertTrue(text.contains("\"relayKem\":{"))
            XCTAssertTrue(text.contains("\"relayKemV1\":true"))
            XCTAssertTrue(text.contains("\"relayRotV1\":true"))
        }
        let stripped = AndroidHandshakeEnvelope.jsonPayload(of: base.withoutRelay())
        XCTAssertFalse(stripped.contains("relayKem"))
        XCTAssertFalse(stripped.contains("relayRotV1"))
        XCTAssertNil(base.with(relayKem: nil).relayKem)
        XCTAssertTrue(AndroidHandshakeEnvelope.jsonPayload(of: base.with(relayKem: nil)).contains("\"relayKemV1\":true"))
    }

    func testWithTheTagsOffNothingOfTheLayerIsWritten() throws {
        let off = AndroidHandshakeBundle(
            kind: .offer, callId: "c", pqcPublicKey: "", x25519PublicKey: "",
            capabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true, capsBindV1: true))
        let text = AndroidHandshakeEnvelope.jsonPayload(of: off)
        XCTAssertFalse(text.contains("relayKemV1"))
        XCTAssertFalse(text.contains("relayRotV1"))
        XCTAssertFalse(text.contains("relayKem"))
        XCTAssertEqual(CapsBind.analyze(json: text).relay, .absent)
    }

    // MARK: - Secrets

    func testTheOfferersPrivateKeysAreUsedOnceAndWiped() throws {
        let keys = try XCTUnwrap(RelayKem.generateOfferKeys())
        XCTAssertTrue(RelayKem.isCanonicalMlKemEncapsulationKey(keys.pub.mlkem))
        guard case .ok(let accept, let acceptorSecrets) = RelayKem.encapsulate(offer: keys.pub) else { return XCTFail("encapsulate") }
        guard case .ok(let offererSecrets) = keys.decapsulate(accept) else { return XCTFail("decapsulate") }
        XCTAssertEqual(offererSecrets.relaySS.copyData(), acceptorSecrets.relaySS.copyData())
        XCTAssertTrue(keys.isWipedForTesting)
        guard case .failed = keys.decapsulate(accept) else { return XCTFail("a second use must fail") }
        let other = try XCTUnwrap(RelayKem.generateOfferKeys())
        other.wipe()
        guard case .failed = other.decapsulate(accept) else { return XCTFail("a wiped pair must fail") }
        offererSecrets.wipe()
        acceptorSecrets.wipe()
        XCTAssertTrue(offererSecrets.isWipedForTesting)
        XCTAssertTrue(acceptorSecrets.isWipedForTesting)
    }

    // MARK: - The member must fit the frame rule with the second signature kept

    func testTheMaximalBundlesOfTheOverflowVectorsGiveUpTheMemberAndKeepTheSignature() throws {
        let vectors = try XCTUnwrap((try load()["bundle-max"] as? [String: Any])?["overflowVectors"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 2)
        for vector in vectors {
            let name = try str(vector, "name")
            let before = try XCTUnwrap(vector["before"] as? [String: Any])
            let after = try XCTUnwrap(vector["after"] as? [String: Any])
            let expect = try XCTUnwrap(vector["expect"] as? [String: Any])
            func escaped(_ framed: String) -> String {
                let pipe = framed.firstIndex(of: "|") ?? framed.startIndex
                return String(framed[..<pipe]) + "|" + String(framed[framed.index(after: pipe)...]).replacingOccurrences(of: "/", with: "\\/")
            }
            XCTAssertFalse(OpaqueFrameRule.fits(payload: escaped(try str(before, "framed"))), name)
            XCTAssertTrue(OpaqueFrameRule.fits(payload: escaped(try str(after, "framed"))), name)
            func members(_ framed: String) throws -> [String: Any] {
                let pipe = try XCTUnwrap(framed.firstIndex(of: "|"))
                let json = String(framed[framed.index(after: pipe)...])
                return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            }
            let beforeObject = try members(try str(before, "framed"))
            var afterObject = try members(try str(after, "framed"))
            XCTAssertNotNil(beforeObject["sigHybrid"], name)
            XCTAssertNotNil(afterObject["sigHybrid"], name)
            let dropped = try XCTUnwrap(expect["droppedMembers"] as? [String])
            // the capabilities of the reduced bundle equal those of the full one without the dropped tags
            var beforeCaps = try XCTUnwrap(beforeObject["capabilities"] as? [String: Any])
            var afterCaps = try XCTUnwrap(afterObject["capabilities"] as? [String: Any])
            var beforeTop = beforeObject
            for member in dropped {
                beforeTop.removeValue(forKey: member)
                afterObject.removeValue(forKey: member)
                beforeCaps.removeValue(forKey: member)
                afterCaps.removeValue(forKey: member)
            }
            beforeTop["capabilities"] = beforeCaps
            afterObject["capabilities"] = afterCaps
            XCTAssertEqual(NSDictionary(dictionary: afterObject), NSDictionary(dictionary: beforeTop), name)
        }
    }
}
