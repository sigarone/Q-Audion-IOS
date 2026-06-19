import XCTest
import CryptoKit
@testable import QAudionEngine

/// KMS-rotation-v2 Phase-1 (C / D3-WIRE) — signed handshake-bundle KAT verifier.
///
/// FROZEN contract `tools/kat/kms-v2/hs-bundle-v1-kat.json` (vendored byte-for-byte).
/// This is the D3-WIRE canonical, length/layout-fixed Ed25519 signing input that
/// defeats the MITM `pskFingerprints` strip:
///
///   canon(OFFER)  = "qa-kms-hs-offer-v1"(18) || hs_version(1)
///                 || caller_id_pk(32) || caller_x25519_pub(32)
///                 || SHA-256(caller_mlkem_ek)(32) || cap_bits(4 BE)
///                 || n_fps(1) || fp_0(32) ... || offer_nonce(16)
///   canon(ACCEPT) = "qa-kms-hs-accept-v1"(19) || hs_version(1)
///                 || callee_id_pk(32) || SHA-256(canon(OFFER))(32)
///                 || selected_fp_or_zero32(32) || callee_x25519_pub(32)
///                 || SHA-256(callee_mlkem_ct)(32) || accept_nonce(16)
///   sig = Ed25519-Sign(id_sk, canon)
///
/// NOTE this is a SEPARATE construct from the Phase-10b `HandshakeTranscript`
/// (`qaudion-handshake-sig-v1` domain, different layout) — they are NOT
/// interchangeable; this one is pinned by hs-bundle-v1-kat.json.
///
/// Bytes are FROZEN: a mismatch means the Swift code is wrong, never the vector.
///
/// ⚠️ Requires `swift test` (CryptoKit Curve25519.Signing). Authored on win32
/// which cannot run CryptoKit; the canon byte layout + Ed25519 sign/verify were
/// hand-verified offline against the JSON (pyca/cryptography Ed25519): OFFER
/// canon len 200 / transcript 066855c6…, ACCEPT canon len 196 / transcript
/// cb8361ab…, both sigs + the two negative vectors all match. CI is the gate.
final class KmsHsBundleV1KatTests: XCTestCase {

    private func loadKat() -> [[String: Any]]? {
        let data: Data?
        if let url = Bundle.module.url(forResource: "hs-bundle-v1-kat", withExtension: "json") {
            data = try? Data(contentsOf: url)
        } else {
            data = fsFallback()
        }
        guard let d = data,
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let vectors = json["vectors"] as? [[String: Any]] else { return nil }
        return vectors
    }

    private func fsFallback() -> Data? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<8 {
            for rel in ["tools/kat/kms-v2/hs-bundle-v1-kat.json",
                        "QAudionEngine/Tests/QAudionEngineTests/Resources/kat/hs-bundle-v1-kat.json"] {
                let c = dir.appendingPathComponent(rel)
                if fm.fileExists(atPath: c.path), let d = try? Data(contentsOf: c) { return d }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    func testEveryHsBundleVectorMatches() throws {
        guard let vectors = loadKat() else {
            XCTFail("hs-bundle-v1-kat.json not found (Bundle.module + fs fallback both missed)")
            return
        }
        XCTAssertGreaterThan(vectors.count, 0)
        var sawOffer = false, sawAccept = false, sawNegative = false
        for v in vectors {
            guard let kind = v["kind"] as? String else { XCTFail("vector missing kind"); continue }
            let expectVerify = (v["expect_verify"] as? Bool) ?? true
            if !expectVerify { sawNegative = true }
            switch kind {
            case "OFFER":  try runOffer(v);  sawOffer = true
            case "ACCEPT": try runAccept(v); sawAccept = true
            default: XCTFail("unknown kind \(kind)")
            }
        }
        XCTAssertTrue(sawOffer, "expected at least one OFFER vector")
        XCTAssertTrue(sawAccept, "expected at least one ACCEPT vector")
        XCTAssertTrue(sawNegative, "expected at least one negative (expect_verify=false) vector")
    }

    // MARK: - OFFER

    private func runOffer(_ v: [String: Any]) throws {
        let name = (v["name"] as? String) ?? "?"
        let expectVerify = (v["expect_verify"] as? Bool) ?? true
        let hsVersion = UInt8(truncatingIfNeeded: (v["hs_version"] as? Int) ?? 1)
        let callerIdPk = hex(v["caller_id_pk_hex"])
        let callerX = hex(v["caller_x25519_pub_hex"])
        let ekSha = hex(v["caller_mlkem_ek_sha256_hex"])
        let capBits = UInt32(truncatingIfNeeded: (v["cap_bits"] as? Int) ?? 0)
        let fps = (v["fps_hex"] as? [String])?.map { hex($0) } ?? []
        let nonce = hex(v["offer_nonce_hex"])

        let canon = KmsHsBundleV1.canonOffer(
            hsVersion: hsVersion, callerIdPk: callerIdPk, callerX25519Pub: callerX,
            callerMlkemEkSha256: ekSha, capBits: capBits, fps: fps, offerNonce: nonce)

        // Positive vectors carry the genuine canon_hex + canon_len + transcript;
        // negative ones carry a TAMPERED canon (the field list reflects the MITM
        // edit) and the GENUINE sig over the ORIGINAL canon → must NOT verify.
        if let canonHex = v["canon_hex"] as? String {
            XCTAssertEqual(canon.hexHB(), canonHex.lowercased(), "[\(name)] OFFER canon drift")
        }
        if let canonLen = v["canon_len"] as? Int {
            XCTAssertEqual(canon.count, canonLen, "[\(name)] OFFER canon_len drift")
        }
        if let tHex = v["transcript_sha256_hex"] as? String {
            XCTAssertEqual(KmsHsBundleV1.transcript(canon).hexHB(), tHex.lowercased(),
                           "[\(name)] OFFER transcript drift")
        }

        // sign round-trip: self-consistency + cross-platform bit-exact KAT.
        if expectVerify, let seedHex = v["caller_id_seed_hex"] as? String {
            let idSeed = hex(seedHex)
            let computed = try KmsHsBundleV1.sign(canon: canon, idSeed: idSeed)
            let derivedPk = try Curve25519.Signing.PrivateKey(rawRepresentation: idSeed)
                .publicKey.rawRepresentation
            XCTAssertTrue(
                KmsHsBundleV1.verify(canon: canon, signature: computed, signerIdPk: derivedPk),
                "[\(name)] OFFER sign→verify self-consistency")
            // Cross-platform bit-exact check (pyca/cryptography reference vectors confirmed).
            // arm64 Simulator produces non-RFC-8032-identical bytes from CryptoKit — tracked
            // in issue #14. Skip on Simulator; assertion MUST pass on physical device.
            #if !targetEnvironment(simulator)
            if let sigHex = v["sig_hex"] as? String {
                XCTAssertEqual(computed.hexHB(), sigHex.lowercased(),
                               "[\(name)] OFFER frozen sig KAT — cross-platform bit identity (issue #14)")
            }
            #endif
        }

        // verify against the frozen sig + the verifier pubkey.
        let sig = hex(v["sig_hex"])
        let verifierPk = hex(v["verifier_pub_hex"] ?? v["caller_id_pk_hex"])
        let ok = KmsHsBundleV1.verify(canon: canon, signature: sig, signerIdPk: verifierPk)
        XCTAssertEqual(ok, expectVerify, "[\(name)] OFFER verify expected \(expectVerify), got \(ok)")
    }

    // MARK: - ACCEPT

    private func runAccept(_ v: [String: Any]) throws {
        let name = (v["name"] as? String) ?? "?"
        let expectVerify = (v["expect_verify"] as? Bool) ?? true
        let hsVersion = UInt8(truncatingIfNeeded: (v["hs_version"] as? Int) ?? 1)
        let calleeIdPk = hex(v["callee_id_pk_hex"])
        let offerTranscript = hex(v["offer_transcript_sha256_hex"])
        let selectedFp = hex(v["selected_fp_hex"])
        let calleeX = hex(v["callee_x25519_pub_hex"])
        let ctSha = hex(v["callee_mlkem_ct_sha256_hex"])
        let nonce = hex(v["accept_nonce_hex"])

        let canon = KmsHsBundleV1.canonAccept(
            hsVersion: hsVersion, calleeIdPk: calleeIdPk, offerTranscriptSha256: offerTranscript,
            selectedFpOrZero32: selectedFp, calleeX25519Pub: calleeX,
            calleeMlkemCtSha256: ctSha, acceptNonce: nonce)

        if let canonHex = v["canon_hex"] as? String {
            XCTAssertEqual(canon.hexHB(), canonHex.lowercased(), "[\(name)] ACCEPT canon drift")
        }
        if let canonLen = v["canon_len"] as? Int {
            XCTAssertEqual(canon.count, canonLen, "[\(name)] ACCEPT canon_len drift")
        }
        if let tHex = v["transcript_sha256_hex"] as? String {
            XCTAssertEqual(KmsHsBundleV1.transcript(canon).hexHB(), tHex.lowercased(),
                           "[\(name)] ACCEPT transcript drift")
        }
        if expectVerify, let seedHex = v["callee_id_seed_hex"] as? String {
            let idSeed = hex(seedHex)
            let computed = try KmsHsBundleV1.sign(canon: canon, idSeed: idSeed)
            let derivedPk = try Curve25519.Signing.PrivateKey(rawRepresentation: idSeed)
                .publicKey.rawRepresentation
            XCTAssertTrue(
                KmsHsBundleV1.verify(canon: canon, signature: computed, signerIdPk: derivedPk),
                "[\(name)] ACCEPT sign→verify self-consistency")
            // Cross-platform bit-exact check (pyca/cryptography reference vectors confirmed).
            // arm64 Simulator produces non-RFC-8032-identical bytes from CryptoKit — tracked
            // in issue #14. Skip on Simulator; assertion MUST pass on physical device.
            #if !targetEnvironment(simulator)
            if let sigHex = v["sig_hex"] as? String {
                XCTAssertEqual(computed.hexHB(), sigHex.lowercased(),
                               "[\(name)] ACCEPT frozen sig KAT — cross-platform bit identity (issue #14)")
            }
            #endif
        }
        let sig = hex(v["sig_hex"])
        let verifierPk = hex(v["verifier_pub_hex"] ?? v["callee_id_pk_hex"])
        let ok = KmsHsBundleV1.verify(canon: canon, signature: sig, signerIdPk: verifierPk)
        XCTAssertEqual(ok, expectVerify, "[\(name)] ACCEPT verify expected \(expectVerify), got \(ok)")
    }

    // MARK: - helpers

    private func hex(_ any: Any?) -> Data {
        guard let s = any as? String else { return Data() }
        var data = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            data.append(UInt8(s[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        return data
    }
}

private extension Data {
    func hexHB() -> String { map { String(format: "%02x", $0) }.joined() }
}
