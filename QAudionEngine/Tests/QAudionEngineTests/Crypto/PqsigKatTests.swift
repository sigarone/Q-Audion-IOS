import XCTest
import CryptoKit
import CLiboqs
@testable import QAudionEngine

/// The ML-DSA-87 helpers reproduce, byte for byte, the shared vector files `pqc-hardening-v1-kat.json` (sections
/// mldsaSeed, xcert, sigHybrid) and `mldsa87-v1.json` (the primitive), and reject every negative.
///
/// Deterministic signing (the C layer with 32 zero bytes of randomness) is used only here, to compare with the
/// vectors; the library itself only signs hedged. CryptoKit signs Ed25519 non-deterministically, so the Ed25519
/// halves are compared by verification (the vector signature must verify, and a fresh signature must verify), never
/// by bytes; the ML-DSA halves, XC, HT and every derived value are compared by bytes.
///
/// This code was written on a machine that cannot compile Swift for iOS: the simulator CI job is what runs it.
final class PqsigKatTests: XCTestCase {

    static let pinnedPqcSHA256 = "3c135f42e7d70a34e88555ed10b04ee89ad29a03e327679f8652ce20836f2267"
    static let pinnedMldsaSHA256 = "dccdd89dd85b9a9619b28e0a26e4430aedf781c505dd64bdeffbb4fc0251dd04"

    // MARK: - Loading

    private func fileBytes(_ name: String) throws -> Data {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: name, withExtension: "json"),
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "kat"),
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources/kat")
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            throw NSError(domain: "PqsigKat", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(name).json is not in the test bundle"])
        }
        return try Data(contentsOf: url)
    }

    private func json(_ name: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try fileBytes(name), options: [])
        return try XCTUnwrap(object as? [String: Any])
    }

    private func pqc() throws -> [String: Any] { try json("pqc-hardening-v1-kat") }
    private func mldsa() throws -> [String: Any] { try json("mldsa87-v1") }

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

    private func hexString(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    private func sha256Hex(_ d: Data) -> String { hexString(Data(SHA256.hash(data: d))) }

    private func object(_ any: Any?) throws -> [String: Any] { try XCTUnwrap(any as? [String: Any]) }
    private func list(_ any: Any?) throws -> [[String: Any]] { try XCTUnwrap(any as? [[String: Any]]) }
    private func strings(_ any: Any?) throws -> [String] { try XCTUnwrap(any as? [String]) }
    private func str(_ d: [String: Any], _ k: String) throws -> String { try XCTUnwrap(d[k] as? String, k) }
    private func int(_ d: [String: Any], _ k: String) throws -> Int { try XCTUnwrap(d[k] as? Int, k) }

    private func seedCases() throws -> [[String: Any]] { try list(try object(try pqc()["mldsaSeed"])["cases"]) }

    // MARK: - Deterministic signing (test only)

    /// FIPS 204 pure-mode signature with rnd = 0^32, straight from the C layer.
    private func deterministicSign(seed: Data, msg: Data, ctx: String) -> Data {
        var pk = [UInt8](repeating: 0, count: Pqsig.publicKeySize)
        var sk = [UInt8](repeating: 0, count: Int(QA_MLDSA87_SECRET_KEY_BYTES))
        let seedBytes = [UInt8](seed)
        XCTAssertEqual(qa_mldsa87_keygen_from_seed(&pk, &sk, seedBytes), 0)
        let rnd = [UInt8](repeating: 0, count: Int(QA_MLDSA87_RND_BYTES))
        var sig = [UInt8](repeating: 0, count: Pqsig.signatureSize)
        let m = [UInt8](msg)
        let c = Array(ctx.utf8)
        XCTAssertEqual(qa_mldsa87_sign_pure(&sig, m, m.count, c, c.count, rnd, sk), 0)
        return Data(sig)
    }

    private func seedOfCase(_ i: Int) throws -> Data {
        let c = try seedCases()[i]
        return try XCTUnwrap(Pqsig.deriveSeed(edSeed: hex(try str(c, "edSeed")), edPub: hex(try str(c, "edPub")),
                                              gen: try int(c, "gen")))
    }

    private func keyOfCase(_ i: Int) throws -> Pqsig.MlDsaPrivateKey {
        let c = try seedCases()[i]
        return try XCTUnwrap(Pqsig.keyFromIdentity(edSeed: hex(try str(c, "edSeed")), edPub: hex(try str(c, "edPub")),
                                                   gen: try int(c, "gen")))
    }

    private func pubOfCase(_ i: Int) throws -> Data { hex(try str(try seedCases()[i], "mldsaPub")) }

    // MARK: - The files

    func testBothVectorFilesArePinned() throws {
        XCTAssertEqual(sha256Hex(try fileBytes("pqc-hardening-v1-kat")), Self.pinnedPqcSHA256)
        XCTAssertEqual(sha256Hex(try fileBytes("mldsa87-v1")), Self.pinnedMldsaSHA256)
        let p = try pqc()
        for section in ["mldsaSeed", "xcert", "sigHybrid"] { XCTAssertNotNil(p[section], section) }
    }

    // MARK: - mldsa87-v1.json: the primitive

    func testPrimitiveKeygenSignaturesAndVerificationMatch() throws {
        let m = try mldsa()
        XCTAssertEqual(try strings(m["contexts"]), [Pqsig.ctxHandshake, Pqsig.ctxXCert])
        let sizes = try object(m["sizes"])
        XCTAssertEqual(try int(sizes, "publicKey"), Pqsig.publicKeySize)
        XCTAssertEqual(try int(sizes, "seed"), Pqsig.seedSize)
        XCTAssertEqual(try int(sizes, "signature"), Pqsig.signatureSize)
        let seeds = try strings(m["seedsHex"]).map(hex)
        let pubs = try strings(m["publicKeysHex"]).map(hex)
        let msgs = try strings(m["messagesHex"]).map(hex)
        XCTAssertEqual(seeds.count, 3)
        XCTAssertEqual(pubs.count, 3)
        XCTAssertEqual(msgs.count, 3)
        var keys: [Pqsig.MlDsaPrivateKey] = []
        for (i, s) in seeds.enumerated() {
            let k = try XCTUnwrap(Pqsig.keyFromSeed(s), "seed \(i)")
            XCTAssertEqual(k.publicKey.bytes(), pubs[i], "public key \(i)")
            XCTAssertEqual(pubs[i].count, Pqsig.publicKeySize)
            keys.append(k)
        }
        let sigs = try list(m["signatures"])
        XCTAssertEqual(sigs.count, 18)
        for v in sigs {
            let ctx = try str(v, "context")
            let seedIndex = try int(v, "seedIndex")
            let msgIndex = try int(v, "msgIndex")
            let label = "\(ctx) seed \(seedIndex) msg \(msgIndex)"
            let expected = hex(try str(v, "signatureHex"))
            XCTAssertEqual(expected.count, Pqsig.signatureSize, label)
            XCTAssertEqual(deterministicSign(seed: seeds[seedIndex], msg: msgs[msgIndex], ctx: ctx), expected, label)
            let pub = keys[seedIndex].publicKey
            XCTAssertTrue(pub.verify(msgs[msgIndex], expected, ctx: ctx), label)
            let other = ctx == Pqsig.ctxXCert ? Pqsig.ctxHandshake : Pqsig.ctxXCert
            XCTAssertFalse(pub.verify(msgs[msgIndex], expected, ctx: other), label)
            XCTAssertFalse(pub.verify(msgs[msgIndex] + Data([0]), expected, ctx: ctx), label)
        }
    }

    func testHedgedSigningDiffersBetweenCallsAndBothVerify() throws {
        let key = try keyOfCase(0)
        let seed = try seedOfCase(0)
        let msg = Data("hedged".utf8)
        for ctx in [Pqsig.ctxHandshake, Pqsig.ctxXCert] {
            let a = try XCTUnwrap(key.sign(msg, ctx: ctx))
            let b = try XCTUnwrap(key.sign(msg, ctx: ctx))
            XCTAssertEqual(a.count, Pqsig.signatureSize)
            XCTAssertNotEqual(a, b, "hedged signatures must differ")
            XCTAssertTrue(key.publicKey.verify(msg, a, ctx: ctx))
            XCTAssertTrue(key.publicKey.verify(msg, b, ctx: ctx))
            XCTAssertNotEqual(a, deterministicSign(seed: seed, msg: msg, ctx: ctx))
        }
    }

    func testEmptyMessageSignsAndVerifies() throws {
        let key = try keyOfCase(0)
        let sig = try XCTUnwrap(key.sign(Data(), ctx: Pqsig.ctxHandshake))
        XCTAssertTrue(key.publicKey.verify(Data(), sig, ctx: Pqsig.ctxHandshake))
        XCTAssertFalse(key.publicKey.verify(Data([0]), sig, ctx: Pqsig.ctxHandshake))
        let seed = try seedOfCase(0)
        let det = deterministicSign(seed: seed, msg: Data(), ctx: "")
        XCTAssertTrue(key.publicKey.verify(Data(), det, ctx: ""))
    }

    func testMalformedPrimitiveInputsNeverCrash() throws {
        XCTAssertNil(Pqsig.keyFromSeed(Data(count: 31)))
        XCTAssertNil(Pqsig.keyFromSeed(Data(count: 33)))
        XCTAssertNil(Pqsig.keyFromSeed(Data()))
        XCTAssertNil(Pqsig.parsePublicKey(Data(count: 2591)))
        XCTAssertNil(Pqsig.parsePublicKey(Data(count: 2593)))
        let key = try keyOfCase(0)
        let m = Data(count: 3)
        XCTAssertNil(key.sign(m, ctx: String(repeating: "x", count: 256)))
        XCTAssertNotNil(key.sign(m, ctx: String(repeating: "x", count: 255)))
        let sig = try XCTUnwrap(key.sign(m, ctx: "c"))
        XCTAssertFalse(key.publicKey.verify(m, sig.dropLast(), ctx: "c"))
        XCTAssertFalse(key.publicKey.verify(m, sig + Data([0]), ctx: "c"))
        XCTAssertFalse(key.publicKey.verify(m, Data(), ctx: "c"))
        XCTAssertFalse(key.publicKey.verify(m, sig, ctx: String(repeating: "x", count: 256)))
        XCTAssertFalse(Pqsig.verify(nil, m, sig, ctx: "c"))
        XCTAssertTrue(Pqsig.verify(key.publicKey, m, sig, ctx: "c"))
        var bad = sig
        bad[10] ^= 1
        XCTAssertFalse(key.publicKey.verify(m, bad, ctx: "c"))
        // a signature made for one key never verifies under another
        let other = try keyOfCase(3)
        XCTAssertFalse(other.publicKey.verify(m, sig, ctx: "c"))
    }

    // MARK: - mldsaSeed

    func testSeedDerivationPublicKeyAndKeyIdMatchEveryCase() throws {
        let cases = try seedCases()
        XCTAssertEqual(cases.count, 5)
        for c in cases {
            let name = try str(c, "name")
            let edSeed = hex(try str(c, "edSeed"))
            let edPub = hex(try str(c, "edPub"))
            let gen = try int(c, "gen")
            XCTAssertEqual(hexString(Data("qaudion-identity-mldsa87".utf8) + edPub + Data([UInt8(gen >> 8), UInt8(gen & 0xFF)])),
                           try str(c, "hkdfInfo"), name)
            let xi = try XCTUnwrap(Pqsig.deriveSeed(edSeed: edSeed, edPub: edPub, gen: gen), name)
            XCTAssertEqual(hexString(xi), try str(c, "xi"), name)
            let key = try XCTUnwrap(Pqsig.keyFromSeed(xi), name)
            XCTAssertEqual(key.publicKey.bytes(), hex(try str(c, "mldsaPub")), name)
            XCTAssertEqual(hexString(key.publicKey.keyId()), try str(c, "mldsaKeyId"), name)
            XCTAssertEqual(sha256Hex(hex(try str(c, "mldsaPub"))), try str(c, "mldsaKeyId"), name)
            let viaIdentity = try XCTUnwrap(Pqsig.keyFromIdentity(edSeed: edSeed, edPub: edPub, gen: gen), name)
            XCTAssertEqual(viaIdentity.publicKey.bytes(), key.publicKey.bytes(), name)
            XCTAssertEqual(Pqsig.parsePublicKey(hex(try str(c, "mldsaPub")))?.bytes(), hex(try str(c, "mldsaPub")), name)
        }
    }

    func testSeedDerivationNegativesAreRefused() throws {
        let negatives = try list(try object(try pqc()["mldsaSeed"])["negatives"])
        XCTAssertEqual(negatives.count, 2)
        for n in negatives {
            XCTAssertEqual(try str(n, "expect"), "refuse")
            let name = try str(n, "name")
            let seed = hex(try str(n, "edSeed"))
            let pub = hex(try str(n, "edPub"))
            XCTAssertNil(Pqsig.deriveSeed(edSeed: seed, edPub: pub, gen: try int(n, "gen")), name)
            XCTAssertNil(Pqsig.keyFromIdentity(edSeed: seed, edPub: pub, gen: try int(n, "gen")), name)
        }
        let c = try seedCases()[0]
        let s = hex(try str(c, "edSeed"))
        let p = hex(try str(c, "edPub"))
        XCTAssertNil(Pqsig.deriveSeed(edSeed: s.dropLast(), edPub: p, gen: 0))
        XCTAssertNil(Pqsig.deriveSeed(edSeed: s, edPub: p.dropLast(), gen: 0))
        XCTAssertNil(Pqsig.deriveSeed(edSeed: s, edPub: p, gen: -1))
        XCTAssertNil(Pqsig.deriveSeed(edSeed: s, edPub: p, gen: 65536))
        XCTAssertNotNil(Pqsig.deriveSeed(edSeed: s, edPub: p, gen: 65535))
    }

    // MARK: - xcert

    private func xcFields(_ v: [String: Any], deviceIdHex: String? = nil, seedCase: Int? = nil) throws -> Pqsig.XcFields {
        Pqsig.XcFields(
            uuid: hex(try str(v, "uuid")),
            deviceId: hex(try deviceIdHex ?? str(v, "deviceIdHex")),
            edPub: hex(try str(v, "edPub")),
            mldsaPub: try pubOfCase(try seedCase ?? int(v, "seedCase")),
            gen: try int(v, "gen"),
            createdMs: try XCTUnwrap(UInt64(try str(v, "createdMs")), "createdMs"))
    }

    func testXcertPositiveVectorsReproduceXcAndBothSignatures() throws {
        let vectors = try list(try object(try pqc()["xcert"])["vectors"])
        XCTAssertEqual(vectors.count, 3)
        let cases = try seedCases()
        for v in vectors {
            let name = try str(v, "name")
            let f = try xcFields(v)
            let xc = try XCTUnwrap(Pqsig.encodeXC(f), name)
            XCTAssertEqual(xc, hex(try str(v, "xc")), name)
            XCTAssertEqual(sha256Hex(f.mldsaPub), try str(v, "mldsaKeyId"), name)
            let seedCase = try int(v, "seedCase")
            let edSeed = hex(try str(cases[seedCase], "edSeed"))
            // ML-DSA half: deterministic variant, test only. Ed25519 half: verification (CryptoKit is randomized).
            XCTAssertEqual(deterministicSign(seed: try seedOfCase(seedCase), msg: xc, ctx: Pqsig.ctxXCert),
                           hex(try str(v, "xcPq")), name)
            let katSigs = Pqsig.XcSignatures(ed: hex(try str(v, "xcEd")), pq: hex(try str(v, "xcPq")))
            XCTAssertTrue(Pqsig.verifyXC(f, katSigs), name)
            // production path: hedged, verifies, the PQ halves of two calls differ
            let key = try keyOfCase(seedCase)
            let s1 = try XCTUnwrap(Pqsig.signXC(f, edSeed: edSeed, pq: key), name)
            let s2 = try XCTUnwrap(Pqsig.signXC(f, edSeed: edSeed, pq: key), name)
            XCTAssertEqual(s1.ed.count, Pqsig.edSignatureSize)
            XCTAssertEqual(s1.pq.count, Pqsig.signatureSize)
            XCTAssertNotEqual(s1.pq, s2.pq, name)
            XCTAssertTrue(Pqsig.verifyXC(f, s1), name)
            XCTAssertTrue(Pqsig.verifyXC(f, s2), name)
        }
    }

    func testXcertNfcAndNfdDeviceIdsGiveDifferentXc() throws {
        let vectors = try list(try object(try pqc()["xcert"])["vectors"])
        let byName = Dictionary(uniqueKeysWithValues: try vectors.map { (try str($0, "name"), $0) })
        let nfc = try XCTUnwrap(byName["nfc-device-id"])
        let nfd = try XCTUnwrap(byName["nfd-device-id"])
        XCTAssertNotEqual(try str(nfc, "deviceIdHex"), try str(nfd, "deviceIdHex"))
        XCTAssertNotEqual(try str(nfc, "xc"), try str(nfd, "xc"))
        // no normalization: each exact byte string is signed as given
        let crossed = try xcFields(nfc, deviceIdHex: try str(nfd, "deviceIdHex"))
        XCTAssertFalse(Pqsig.verifyXC(crossed, Pqsig.XcSignatures(ed: hex(try str(nfc, "xcEd")), pq: hex(try str(nfc, "xcPq")))))
    }

    func testXcertDeviceIdRules() throws {
        let x = try object(try pqc()["xcert"])
        let rules = try list(x["deviceRules"])
        XCTAssertEqual(rules.count, 5)
        let base = try list(x["vectors"])[0]
        let edSeed = hex(try str(try seedCases()[0], "edSeed"))
        let key = try keyOfCase(0)
        for r in rules {
            let name = try str(r, "name")
            let f = try xcFields(base, deviceIdHex: try str(r, "deviceIdHex"))
            let xc = Pqsig.encodeXC(f)
            if try str(r, "expect") == "ok" {
                XCTAssertEqual(xc, hex(try str(r, "xc")), name)
            } else {
                XCTAssertNil(xc, name)
                XCTAssertNil(Pqsig.signXC(f, edSeed: edSeed, pq: key), name)
                XCTAssertFalse(Pqsig.verifyXC(f, Pqsig.XcSignatures(ed: Data(count: 64), pq: Data(count: Pqsig.signatureSize))), name)
            }
        }
        // a surrogate encoded in UTF-8, an overlong NUL, a code point above U+10FFFF and an overlong slash
        for bad in ["eda080", "c080", "f4908080", "e080af"] {
            XCTAssertNil(Pqsig.encodeXC(try xcFields(base, deviceIdHex: bad)), bad)
        }
        // valid multi-byte sequences are accepted unchanged
        for good in ["c2a0", "e0a080", "efbfbf", "f0908080", "f48fbfbf", "67657261cc88"] {
            XCTAssertNotNil(Pqsig.encodeXC(try xcFields(base, deviceIdHex: good)), good)
        }
        // the String helper keeps the scalars as given (no normalization)
        XCTAssertEqual(Pqsig.XcFields.deviceIdBytes("ger\u{00E4}t"), Data([0x67, 0x65, 0x72, 0xC3, 0xA4, 0x74]))
        XCTAssertEqual(Pqsig.XcFields.deviceIdBytes("gera\u{0308}t"), Data([0x67, 0x65, 0x72, 0x61, 0xCC, 0x88, 0x74]))
    }

    func testXcertFieldSizesAndGenRangeAreEnforced() throws {
        let v = try list(try object(try pqc()["xcert"])["vectors"])[0]
        let f = try xcFields(v)
        func with(uuid: Data? = nil, ed: Data? = nil, pq: Data? = nil, gen: Int? = nil) -> Pqsig.XcFields {
            Pqsig.XcFields(uuid: uuid ?? f.uuid, deviceId: f.deviceId, edPub: ed ?? f.edPub, mldsaPub: pq ?? f.mldsaPub,
                           gen: gen ?? f.gen, createdMs: f.createdMs)
        }
        XCTAssertNil(Pqsig.encodeXC(with(uuid: Data(count: 15))))
        XCTAssertNil(Pqsig.encodeXC(with(uuid: Data(count: 17))))
        XCTAssertNil(Pqsig.encodeXC(with(ed: Data(count: 31))))
        XCTAssertNil(Pqsig.encodeXC(with(pq: Data(count: 2591))))
        XCTAssertNil(Pqsig.encodeXC(with(gen: -1)))
        XCTAssertNil(Pqsig.encodeXC(with(gen: 65536)))
        XCTAssertNotNil(Pqsig.encodeXC(with(gen: 65535)))
        // the largest created value is encoded as eight 0xFF bytes
        let max = Pqsig.XcFields(uuid: f.uuid, deviceId: f.deviceId, edPub: f.edPub, mldsaPub: f.mldsaPub, gen: 0,
                                 createdMs: UInt64.max)
        XCTAssertEqual(Pqsig.encodeXC(max)?.suffix(8), Data(repeating: 0xFF, count: 8))
    }

    func testXcertEveryNegativeIsRejected() throws {
        let negatives = try list(try object(try pqc()["xcert"])["negatives"])
        XCTAssertEqual(negatives.count, 11)
        for n in negatives {
            XCTAssertEqual(try str(n, "expect"), "invalid")
            let f = try xcFields(n, seedCase: try int(n, "mldsaPubFromSeedCase"))
            let ok = Pqsig.verifyXC(f, Pqsig.XcSignatures(ed: hex(try str(n, "xcEd")), pq: hex(try str(n, "xcPq"))))
            let label = "\(try str(n, "name")): \(try str(n, "why"))"
            XCTAssertFalse(ok, label)
        }
    }

    // MARK: - sigHybrid

    private func htFields(kind: UInt8) throws -> Pqsig.HtFields {
        let hy = try object(try pqc()["sigHybrid"])
        let i = try object(hy["inputs"])
        let k = try object(hy["keys"])
        let offer = kind == Pqsig.kindOffer
        return Pqsig.HtFields(
            kind: kind,
            bundleHash: hex(try str(i, offer ? "bundleHashOffer" : "bundleHashAccept")),
            edPub: hex(try str(k, "edPub")),
            mldsaKeyId: hex(try str(k, "mldsaKeyId")),
            dtlsFpSelf: hex(try str(i, offer ? "dtlsFpOfferer" : "dtlsFpAcceptor")),
            dtlsFpPeer: offer ? Data() : hex(try str(i, "dtlsFpOfferer")),
            capsx: hex(try str(i, "capsx")),
            extx: hex(try str(i, "extx")))
    }

    func testHybridVectorsReproduceHtMessageHalvesAndSignature() throws {
        let hy = try object(try pqc()["sigHybrid"])
        let seedCase = try int(try object(hy["keys"]), "seedCase")
        let cases = try seedCases()
        let edSeed = hex(try str(cases[seedCase], "edSeed"))
        let edPub = hex(try str(cases[seedCase], "edPub"))
        let key = try keyOfCase(seedCase)
        let seed = try seedOfCase(seedCase)
        let vectors = try list(hy["vectors"])
        XCTAssertEqual(vectors.count, 2)
        for v in vectors {
            let name = try str(v, "name")
            let kind = UInt8(try int(v, "kind"))
            let ht = try XCTUnwrap(Pqsig.encodeHT(try htFields(kind: kind)), name)
            XCTAssertEqual(ht, hex(try str(v, "ht")), name)
            XCTAssertEqual(hex(try str(v, "edMessage")), Data("qaudion-hs-hybrid-ed25519-v1".utf8) + ht, name)
            XCTAssertEqual(try int(v, "sigLength"), Pqsig.hybridSigSize, name)
            let sig = hex(try str(v, "sig"))
            XCTAssertEqual(sig.count, Pqsig.hybridSigSize, name)
            XCTAssertEqual(sig, hex(try str(v, "sigEd")) + hex(try str(v, "sigPq")), name)
            // ML-DSA half by bytes; Ed25519 half by verification (inside verifyHybrid)
            XCTAssertEqual(deterministicSign(seed: seed, msg: ht, ctx: Pqsig.ctxHandshake), hex(try str(v, "sigPq")), name)
            XCTAssertTrue(Pqsig.verifyHybrid(ht, sig, edPub: edPub, pq: key.publicKey), name)
            // production path: hedged
            let h1 = try XCTUnwrap(Pqsig.signHybrid(ht, edSeed: edSeed, pq: key), name)
            let h2 = try XCTUnwrap(Pqsig.signHybrid(ht, edSeed: edSeed, pq: key), name)
            XCTAssertEqual(h1.count, Pqsig.hybridSigSize)
            XCTAssertNotEqual(h1, h2, name)
            XCTAssertTrue(Pqsig.verifyHybrid(ht, h1, edPub: edPub, pq: key.publicKey), name)
            XCTAssertTrue(Pqsig.verifyHybrid(ht, h2, edPub: edPub, pq: key.publicKey), name)
        }
    }

    func testHybridEveryNegativeIsRejected() throws {
        let hy = try object(try pqc()["sigHybrid"])
        let key = try keyOfCase(try int(try object(hy["keys"]), "seedCase"))
        let edPub = hex(try str(try object(hy["keys"]), "edPub"))
        let negatives = try list(hy["negatives"])
        XCTAssertEqual(negatives.count, 10)
        for n in negatives {
            XCTAssertEqual(try str(n, "expect"), "invalid")
            let ok = Pqsig.verifyHybrid(hex(try str(n, "ht")), hex(try str(n, "sig")), edPub: edPub, pq: key.publicKey)
            let label = "\(try str(n, "name")): \(try str(n, "why"))"
            XCTAssertFalse(ok, label)
        }
    }

    func testHybridMalformedInputsNeverCrash() throws {
        let key = try keyOfCase(0)
        let c = try seedCases()[0]
        let edSeed = hex(try str(c, "edSeed"))
        let edPub = hex(try str(c, "edPub"))
        let ht = try XCTUnwrap(Pqsig.encodeHT(try htFields(kind: Pqsig.kindOffer)))
        let sig = try XCTUnwrap(Pqsig.signHybrid(ht, edSeed: edSeed, pq: key))
        XCTAssertFalse(Pqsig.verifyHybrid(ht, sig, edPub: edPub, pq: nil))
        XCTAssertFalse(Pqsig.verifyHybrid(ht, sig, edPub: edPub.dropLast(), pq: key.publicKey))
        XCTAssertFalse(Pqsig.verifyHybrid(ht, sig.dropLast(), edPub: edPub, pq: key.publicKey))
        XCTAssertFalse(Pqsig.verifyHybrid(ht, sig + Data([0]), edPub: edPub, pq: key.publicKey))
        XCTAssertFalse(Pqsig.verifyHybrid(ht, Data(), edPub: edPub, pq: key.publicKey))
        XCTAssertFalse(Pqsig.verifyHybrid(ht + Data([0]), sig, edPub: edPub, pq: key.publicKey))
        XCTAssertNil(Pqsig.signHybrid(ht, edSeed: edSeed.dropLast(), pq: key))

        let offer = try htFields(kind: Pqsig.kindOffer)
        let accept = try htFields(kind: Pqsig.kindAccept)
        func copy(_ f: Pqsig.HtFields, kind: UInt8? = nil, bundleHash: Data? = nil, edPub: Data? = nil,
                  mldsaKeyId: Data? = nil, selfFp: Data? = nil, peer: Data? = nil, capsx: Data? = nil,
                  extx: Data? = nil) -> Pqsig.HtFields {
            Pqsig.HtFields(kind: kind ?? f.kind, bundleHash: bundleHash ?? f.bundleHash, edPub: edPub ?? f.edPub,
                           mldsaKeyId: mldsaKeyId ?? f.mldsaKeyId, dtlsFpSelf: selfFp ?? f.dtlsFpSelf,
                           dtlsFpPeer: peer ?? f.dtlsFpPeer, capsx: capsx ?? f.capsx, extx: extx ?? f.extx)
        }
        XCTAssertNil(Pqsig.encodeHT(copy(offer, peer: accept.dtlsFpPeer)))
        XCTAssertNil(Pqsig.encodeHT(copy(accept, peer: Data())))
        XCTAssertNil(Pqsig.encodeHT(copy(accept, peer: Data(count: 32))))
        XCTAssertNil(Pqsig.encodeHT(copy(offer, kind: 0)))
        XCTAssertNil(Pqsig.encodeHT(copy(offer, kind: 3)))
        XCTAssertNil(Pqsig.encodeHT(copy(offer, selfFp: Data(count: 32))))
        XCTAssertNil(Pqsig.encodeHT(copy(offer, bundleHash: Data(count: 31))))
        XCTAssertNil(Pqsig.encodeHT(copy(offer, edPub: Data(count: 33))))
        XCTAssertNil(Pqsig.encodeHT(copy(offer, mldsaKeyId: Data(count: 31))))
        XCTAssertNil(Pqsig.encodeHT(copy(offer, extx: Data(count: 31))))
        XCTAssertNil(Pqsig.encodeHT(copy(offer, capsx: Data(count: 65536))))
        XCTAssertNotNil(Pqsig.encodeHT(copy(offer, capsx: Data(count: 65535))))
        XCTAssertNotNil(Pqsig.encodeHT(copy(offer, capsx: Data())))
    }
}
