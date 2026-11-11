import XCTest
import CryptoKit
@testable import QAudionEngine

/// The section `ed25519Strict` of the shared vector file `pqc-hardening-v1-kat.json`: the uniform Ed25519 rule is a canonical
/// public key that is not a small-order point, then the RFC 8032 cofactorless equation with S < L and R in canonical form.
///
/// Every vector is run twice: through CryptoKit alone (`Curve25519.Signing.PublicKey(rawRepresentation:)` and
/// `isValidSignature`, the calls the app makes) and through `Pqsig.edVerify`, the function behind `verifyHybrid` and
/// `verifyXC`. The outcome of both is printed as one table (lines starting with `ED25519STRICT`) and kept as test activity.
///
/// CryptoKit on its own, as recorded from the simulator run of these vectors:
///  - the 8 small-order public keys are all accepted (key parsing and verification), as Go's `ed25519.Verify` does;
///  - non-canonical encodings of A and of R are rejected;
///  - S + L (S not reduced) is rejected;
///  - torsioned R is rejected (the cofactorless equation) and `mixed-order-A-k1` is rejected;
///  - `mixed-order-A-k0` and the honest control are accepted.
/// So the library covers the signature-encoding rules and the cofactorless equation, and the public-key rules
/// (canonical, not small-order) come from `Ed25519IdentityKeyPolicy`, which `Pqsig.edVerify` applies first.
///
/// Vectors with `cofactoredAccepts` are signer-only constructions that a cofactored library may accept; a difference
/// there is documented, not a failure (see `cofactorNote` in the file).
final class Ed25519StrictKatTests: XCTestCase {

    static let pinnedSHA256 = "3c135f42e7d70a34e88555ed10b04ee89ad29a03e327679f8652ce20836f2267"

    // MARK: - Loading

    private func fileBytes() throws -> Data {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "kat"),
            Bundle.module.url(forResource: "pqc-hardening-v1-kat", withExtension: "json", subdirectory: "Resources/kat")
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            throw NSError(domain: "Ed25519StrictKat", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "pqc-hardening-v1-kat.json is not in the test bundle"])
        }
        return try Data(contentsOf: url)
    }

    private func vectors() throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: try fileBytes(), options: [])
        let root = try XCTUnwrap(object as? [String: Any])
        let section = try XCTUnwrap(root["ed25519Strict"] as? [String: Any])
        return try XCTUnwrap(section["vectors"] as? [[String: Any]])
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

    private func str(_ d: [String: Any], _ k: String) throws -> String { try XCTUnwrap(d[k] as? String, k) }

    // MARK: - CryptoKit alone

    private enum Raw: String {
        case initThrows = "init-throws"
        case acceptsSig = "accept"
        case rejectsSig = "reject"
    }

    /// What the library does on its own: parse the key, then verify.
    private func rawOutcome(pub: Data, msg: Data, sig: Data) -> Raw {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { return .initThrows }
        return key.isValidSignature(sig, for: msg) ? .acceptsSig : .rejectsSig
    }

    private func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }

    // MARK: - Tests

    func testTheFileIsTheOneThePlatformsShare() throws {
        let digest = SHA256.hash(data: try fileBytes())
        XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(), Self.pinnedSHA256)
    }

    func testTheKeyPolicyRejectsEverySmallOrderAndNonCanonicalKeyOfTheVectors() throws {
        var smallOrder = Set<Data>()
        var checked = 0
        var controls = 0
        for v in try vectors() {
            let name = try str(v, "name")
            let cls = try str(v, "class")
            let pub = hex(try str(v, "pub"))
            if cls == "control" {
                XCTAssertTrue(Ed25519IdentityKeyPolicy.isAcceptable(pub), name)
                controls += 1
                continue
            }
            guard cls == "smallOrderA" || cls == "nonCanonicalA" else { continue }
            XCTAssertFalse(Ed25519IdentityKeyPolicy.isAcceptable(pub), name)
            if cls == "smallOrderA" {
                smallOrder.insert(pub)
                XCTAssertTrue(Ed25519IdentityKeyPolicy.isCanonicalSmallOrderPoint(pub), name)
            }
            checked += 1
        }
        XCTAssertEqual(checked, 14)
        XCTAssertEqual(controls, 1)
        XCTAssertEqual(smallOrder.count, 8)
        XCTAssertEqual(smallOrder, Set(Ed25519IdentityKeyPolicy.smallOrderPoints))
    }

    func testEveryVectorFollowsTheUniformRuleAndPrintsTheCryptoKitOutcome() throws {
        let all = try vectors()
        XCTAssertEqual(all.count, 22)
        var rows: [String] = []
        var documented = 0
        for v in all {
            let name = try str(v, "name")
            let cls = try str(v, "class")
            let expect = try str(v, "expect")
            let pub = hex(try str(v, "pub"))
            let msg = hex(try str(v, "msg"))
            let sig = hex(try str(v, "sig"))
            let cofactored = (v["cofactoredAccepts"] as? Bool) == true
            let expectAccept = expect == "accept"

            let raw = rawOutcome(pub: pub, msg: msg, sig: sig)
            let viaPqsig = Pqsig.edVerify(pub, msg, sig)

            // Differences that the rule allows for: a cofactored acceptance of a signer-only vector, and a library that is
            // stricter than the rule on a mixed-order key (honest keys are prime order, so they never meet this case).
            var verdict = "ok"
            if viaPqsig != expectAccept {
                if cofactored && viaPqsig && !expectAccept {
                    verdict = "documented-difference (cofactored acceptance)"
                    documented += 1
                } else if cls == "mixedOrderA" && expectAccept && !viaPqsig && raw != .acceptsSig {
                    verdict = "documented-difference (library stricter on mixed-order key)"
                    documented += 1
                } else {
                    verdict = "MISMATCH"
                    XCTFail("\(name): expected \(expect), Pqsig.edVerify gave \(viaPqsig ? "accept" : "reject")")
                }
            }
            // The classes the pre-checks exist for never get a tolerance.
            if ["smallOrderA", "nonCanonicalA", "nonCanonicalR", "scalarNotReduced"].contains(cls) {
                XCTAssertFalse(viaPqsig, name)
            }
            if cls == "control" {
                XCTAssertTrue(viaPqsig, name)
                XCTAssertEqual(raw, .acceptsSig, name)
            }

            rows.append("ED25519STRICT | " + pad(name, 38) + " | " + pad(cls, 16) + " | expect " + pad(expect, 6)
                        + " | CryptoKit " + pad(raw.rawValue, 10) + " | Pqsig " + pad(viaPqsig ? "accept" : "reject", 6)
                        + " | " + verdict)
        }
        XCTAssertLessThanOrEqual(documented, 4)
        let table = rows.joined(separator: "\n")
        print("ED25519STRICT table begin\n" + table + "\nED25519STRICT table end")
        XCTContext.runActivity(named: "Ed25519 strict vectors: CryptoKit outcome versus expected") { activity in
            activity.add(XCTAttachment(string: table))
            for row in rows {
                XCTContext.runActivity(named: row) { _ in }
            }
        }
    }

    /// A key that is the neutral element (or an encoding of it) with the signature `01 || 0^63` verifies on EVERY message
    /// under a permissive decoder, so these vectors can be put in front of any hybrid or cross-certificate statement.
    func testHybridAndCrossCertificateRejectTheseKeysEvenWithAValidPostQuantumHalf() throws {
        let byName = Dictionary(uniqueKeysWithValues: try vectors().map { (try str($0, "name"), $0) })
        let names = ["small-order-A-0", "non-canonical-A-identity-y-plus-p", "non-canonical-A-identity-x0-sign"]
        let pq = try XCTUnwrap(Pqsig.keyFromSeed(Data(repeating: 0x07, count: 32)))

        // Control: an honest identity passes both paths, so a false below is not an artefact of the setup.
        let honestSeed = Data(repeating: 0x42, count: 32)
        let honestPub = try Curve25519.Signing.PrivateKey(rawRepresentation: honestSeed).publicKey.rawRepresentation
        func ht(_ edPub: Data) throws -> Data {
            try XCTUnwrap(Pqsig.encodeHT(Pqsig.HtFields(
                kind: Pqsig.kindOffer, bundleHash: Data(repeating: 1, count: 32), edPub: edPub,
                mldsaKeyId: pq.publicKey.keyId(), dtlsFpSelf: Data(repeating: 2, count: 33), dtlsFpPeer: Data(),
                capsx: Data(), extx: Data(repeating: 3, count: 32))))
        }
        func xcFields(_ edPub: Data) -> Pqsig.XcFields {
            Pqsig.XcFields(uuid: Data(repeating: 4, count: 16), deviceId: Data("device".utf8), edPub: edPub,
                           mldsaPub: pq.publicKey.bytes(), gen: 0, createdMs: 1)
        }
        let honestHt = try ht(honestPub)
        let honestHybrid = try XCTUnwrap(Pqsig.signHybrid(honestHt, edSeed: honestSeed, pq: pq))
        XCTAssertTrue(Pqsig.verifyHybrid(honestHt, honestHybrid, edPub: honestPub, pq: pq.publicKey))
        let honestXcSigs = try XCTUnwrap(Pqsig.signXC(xcFields(honestPub), edSeed: honestSeed, pq: pq))
        XCTAssertTrue(Pqsig.verifyXC(xcFields(honestPub), honestXcSigs))

        var rows: [String] = []
        for name in names {
            let v = try XCTUnwrap(byName[name], name)
            let pub = hex(try str(v, "pub"))
            let edSig = hex(try str(v, "sig"))

            let message = try ht(pub)
            let pqHalf = try XCTUnwrap(pq.sign(message, ctx: Pqsig.ctxHandshake), name)
            let hybrid = edSig + pqHalf
            let rawHybridEd = rawOutcome(pub: pub, msg: Data(Array("qaudion-hs-hybrid-ed25519-v1".utf8)) + message, sig: edSig)
            let hybridOk = Pqsig.verifyHybrid(message, hybrid, edPub: pub, pq: pq.publicKey)
            XCTAssertFalse(hybridOk, "hybrid \(name)")

            let f = xcFields(pub)
            let xc = try XCTUnwrap(Pqsig.encodeXC(f), name)
            let xcPq = try XCTUnwrap(pq.sign(xc, ctx: Pqsig.ctxXCert), name)
            let rawXcEd = rawOutcome(pub: pub, msg: xc, sig: edSig)
            let xcOk = Pqsig.verifyXC(f, Pqsig.XcSignatures(ed: edSig, pq: xcPq))
            XCTAssertFalse(xcOk, "xcert \(name)")

            rows.append("ED25519STRICT-PATHS | " + pad(name, 38) + " | hybrid ed half, CryptoKit " + pad(rawHybridEd.rawValue, 10)
                        + " | verifyHybrid " + (hybridOk ? "accept" : "reject")
                        + " | xcert ed half, CryptoKit " + pad(rawXcEd.rawValue, 10)
                        + " | verifyXC " + (xcOk ? "accept" : "reject"))
        }
        let table = rows.joined(separator: "\n")
        print("ED25519STRICT-PATHS table begin\n" + table + "\nED25519STRICT-PATHS table end")
        XCTContext.runActivity(named: "Ed25519 strict vectors: hybrid and cross-certificate paths") { activity in
            activity.add(XCTAttachment(string: table))
        }
    }
}
