import XCTest
import CryptoKit
import CLiboqs
@testable import QAudionEngine

// This file's Decodable structs mirror KAT JSON fixture keys verbatim
// (snake_case, no CodingKeys) — renaming would silently break decoding
// against the shared cross-platform fixture.
// swiftlint:disable identifier_name

/// Cross-platform KAT gate: every vector here comes verbatim from
/// bcrypto-server's `test/kat/wire_v1.0.0/` (the single source of truth all
/// 3 clients must reproduce byte-for-byte — see that repo's
/// test/kat/README.md and WIRE_SPEC.md §9). Unlike the pre-existing local
/// KAT suites in this package, these assertions run the REAL CryptoKit /
/// liboqs primitives against the server-generated ground truth, so a silent
/// drift in this platform's implementation is caught here instead of first
/// surfacing as a live call that can't complete key agreement.
///
/// Scope note: unlike Android/Desktop, this file does NOT cover
/// `canonical_cbor/sealed_sender_cert_v2.json` — `SenderCertV2`/sealed-sender
/// is not implemented on iOS at all (verified 2026-07-30: zero matches for
/// SenderCert/SealedSender anywhere in this repo). That's a real feature gap,
/// not a test gap, and is out of scope for this file.
///
/// ⚠️ Requires `swift test` (CryptoKit/liboqs) — authored on win32 which
/// cannot run either. Every byte-construction here was hand-verified offline
/// against the bcrypto-server Go reference and, for ML-KEM-1024, empirically
/// cross-checked against BouncyCastle (Android) and noble-post-quantum
/// (Desktop) using the SAME server-published seed — both independently
/// reproduce the server's expected_ek_b64 for the raw 64-byte seed. The
/// liboqs call below (`OQS_KEM_ml_kem_1024_keypair_derand`) is that same
/// algorithm's official FIPS-203 derand entry point, so it is expected to
/// agree too, but this file itself has NOT been compiled or run locally.
/// CI (`kat-cross-platform.yml`, macos-latest) is the actual gate.
final class WireV1CrossPlatformKatTests: XCTestCase {

    // MARK: - fixture loading

    private func loadVectors<T: Decodable>(_ type: T.Type, category: String, file: String) -> T? {
        let data: Data?
        if let url = Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "wire_v1.0.0/\(category)") {
            data = try? Data(contentsOf: url)
        } else if let url = Bundle.module.url(forResource: file, withExtension: "json") {
            data = try? Data(contentsOf: url)
        } else {
            data = fsFallback(category: category, file: file)
        }
        guard let d = data else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    private func fsFallback(category: String, file: String) -> Data? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(
                "QAudionEngine/Tests/QAudionEngineTests/Crypto/Resources/wire_v1.0.0/\(category)/\(file).json")
            if fm.fileExists(atPath: candidate.path), let d = try? Data(contentsOf: candidate) {
                return d
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private func b64(_ s: String) -> Data { Data(base64Encoded: s) ?? Data() }

    // MARK: - HKDF

    private struct HkdfVec: Decodable {
        let label: String
        let prk_b64: String
        let salt_b64: String
        let info_b64: String
        let length: Int
        let output_b64: String
    }

    /// The vector's `prk_b64` field is the raw IKM fed into the server's
    /// full HKDF-Extract-then-Expand (Go's hkdf.New(hash, secret, salt,
    /// info) does both steps internally) — NOT an already-extracted PRK.
    /// `HKDF<SHA256>.deriveKey` runs both steps in one call, matching that
    /// construction (confirmed against the server vectors on Android/Desktop
    /// 2026-07-30 — the naive expand-only reading fails).
    func testHkdfMatchesServerVectors() throws {
        guard let vectors = loadVectors([HkdfVec].self, category: "hkdf", file: "expand") else {
            XCTFail("wire_v1.0.0/hkdf/expand.json not found"); return
        }
        XCTAssertEqual(vectors.count, 13, "expected 13 canonical HKDF labels")
        for v in vectors {
            let ikm = SymmetricKey(data: b64(v.prk_b64))
            let derived = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: ikm,
                salt: b64(v.salt_b64),
                info: b64(v.info_b64),
                outputByteCount: v.length,
            )
            let actual = derived.withUnsafeBytes { Data($0) }
            XCTAssertEqual(actual, b64(v.output_b64), "HKDF label '\(v.label)' output drift")
        }
    }

    // MARK: - X25519

    private struct X25519DeriveVec: Decodable {
        let label: String
        let priv_b64: String
        let expected_pub_b64: String
    }
    private struct X25519EcdhVec: Decodable {
        let label: String
        let priv_a_b64: String
        let pub_b_b64: String
        let expected_shared_secret_b64: String
    }

    func testX25519DeriveMatchesServerVectors() throws {
        // Filename is "x25519-derive" not "derive" — SPM requires resource
        // basenames unique across the whole target, and "derive.json"
        // collided with aead_nonce's file (see Package.swift comment).
        guard let vectors = loadVectors([X25519DeriveVec].self, category: "x25519", file: "x25519-derive") else {
            XCTFail("wire_v1.0.0/x25519/x25519-derive.json not found"); return
        }
        for v in vectors {
            let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: b64(v.priv_b64))
            let actualPub = priv.publicKey.rawRepresentation
            XCTAssertEqual(actualPub, b64(v.expected_pub_b64), "X25519 derive '\(v.label)' pub drift")
        }
    }

    func testX25519EcdhMatchesServerVectors() throws {
        guard let vectors = loadVectors([X25519EcdhVec].self, category: "x25519", file: "ecdh") else {
            XCTFail("wire_v1.0.0/x25519/ecdh.json not found"); return
        }
        for v in vectors {
            let privA = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: b64(v.priv_a_b64))
            let pubB = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: b64(v.pub_b_b64))
            let shared = try privA.sharedSecretFromKeyAgreement(with: pubB)
            let actual = shared.withUnsafeBytes { Data($0) }
            XCTAssertEqual(actual, b64(v.expected_shared_secret_b64), "X25519 ECDH '\(v.label)' shared-secret drift")
        }
    }

    // MARK: - AEAD nonce

    private struct AeadNonceVec: Decodable {
        let label: String
        let prefix_b64: String
        let seq: UInt64
        let expected_nonce_b64: String
    }

    /// Independently reimplements the pinned wire-format formula (4-byte
    /// prefix || 8-byte big-endian seq) rather than calling
    /// `PqcRtpFrameSealer`'s real `nextNonce()` — that method is a stateful
    /// instance counter with no standalone `(prefix, seq) -> nonce` entry
    /// point (confirmed 2026-07-30; unlike Android/Desktop, no visibility
    /// change was made here since there is no local Xcode to compile-check
    /// a production-code edit blind). This test pins the wire format itself,
    /// which is what the vector's own design intent covers (see
    /// bcrypto-server's aead_nonce KAT header comment) — it does not
    /// exercise iOS's internal counter plumbing.
    func testAeadNonceFormulaMatchesServerVectors() throws {
        // Filename is "aead-nonce-derive" not "derive" — see the x25519
        // comment above for why (SPM basename collision).
        guard let vectors = loadVectors([AeadNonceVec].self, category: "aead_nonce", file: "aead-nonce-derive") else {
            XCTFail("wire_v1.0.0/aead_nonce/aead-nonce-derive.json not found"); return
        }
        XCTAssertEqual(vectors.count, 9, "expected 9 canonical AEAD-nonce boundary cases")
        for v in vectors {
            let prefix = b64(v.prefix_b64)
            XCTAssertEqual(prefix.count, 4, "prefix must be 4B for '\(v.label)'")
            var nonce = Data(prefix)
            var seqBE = v.seq.bigEndian
            withUnsafeBytes(of: &seqBE) { nonce.append(contentsOf: $0) }
            XCTAssertEqual(nonce, b64(v.expected_nonce_b64), "AEAD nonce '\(v.label)' drift")
        }
    }

    // MARK: - ML-KEM-1024

    private struct MlKemKeygenVec: Decodable {
        let label: String
        let seed_b64: String
        let expected_ek_b64: String
        let expected_dk_b64: String
    }
    private struct MlKemDecapVec: Decodable {
        let label: String
        let seed_b64: String
        let ct_b64: String
        let expected_shared_secret_b64: String
    }

    /// Only `expected_ek_b64` (the FIPS-203-standardized 1568B public key)
    /// is a valid cross-library invariant. `expected_dk_b64` is NOT
    /// compared: it's Go's `crypto/mlkem` re-exporting the 64-byte seed
    /// verbatim as its compact "private key" bytes — not the FIPS 203
    /// 3168-byte decapsulation-key encoding liboqs/BC/noble produce. See
    /// the Android/Desktop equivalents of this file for the same note.
    func testMlKemKeygenPublicKeyMatchesServerVectors() throws {
        guard let vectors = loadVectors([MlKemKeygenVec].self, category: "ml_kem_1024", file: "keygen") else {
            XCTFail("wire_v1.0.0/ml_kem_1024/keygen.json not found"); return
        }
        XCTAssertEqual(vectors.count, 5, "expected 5 canonical ML-KEM keygen labels")
        for v in vectors {
            let seed = b64(v.seed_b64)
            XCTAssertEqual(seed.count, Int(OQS_KEM_ml_kem_1024_length_keypair_seed), "seed length for '\(v.label)'")

            var publicKey = Data(count: Int(OQS_KEM_ml_kem_1024_length_public_key))
            var secretKey = Data(count: Int(OQS_KEM_ml_kem_1024_length_secret_key))

            let result = publicKey.withUnsafeMutableBytes { pkBuf in
                secretKey.withUnsafeMutableBytes { skBuf in
                    seed.withUnsafeBytes { seedBuf in
                        OQS_KEM_ml_kem_1024_keypair_derand(
                            pkBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            skBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            seedBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        )
                    }
                }
            }
            XCTAssertEqual(result, OQS_SUCCESS, "ML-KEM-1024 derand keygen failed for '\(v.label)'")
            XCTAssertEqual(publicKey, b64(v.expected_ek_b64), "ML-KEM-1024 keygen '\(v.label)' public-key drift")
        }
    }

    /// Decap invariant: re-derive the same keypair from `seed` via the same
    /// derand path, then decapsulate the server's pinned ciphertext and
    /// assert the shared secret matches — the cryptographically load-bearing
    /// cross-platform check (see the Android/Desktop equivalents).
    func testMlKemDecapMatchesServerVectors() throws {
        guard let vectors = loadVectors([MlKemDecapVec].self, category: "ml_kem_1024", file: "decap") else {
            XCTFail("wire_v1.0.0/ml_kem_1024/decap.json not found"); return
        }
        XCTAssertEqual(vectors.count, 5, "expected 5 canonical ML-KEM decap labels")
        for v in vectors {
            let seed = b64(v.seed_b64)
            var publicKey = Data(count: Int(OQS_KEM_ml_kem_1024_length_public_key))
            var secretKey = Data(count: Int(OQS_KEM_ml_kem_1024_length_secret_key))

            let keygenResult = publicKey.withUnsafeMutableBytes { pkBuf in
                secretKey.withUnsafeMutableBytes { skBuf in
                    seed.withUnsafeBytes { seedBuf in
                        OQS_KEM_ml_kem_1024_keypair_derand(
                            pkBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            skBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            seedBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        )
                    }
                }
            }
            XCTAssertEqual(keygenResult, OQS_SUCCESS, "ML-KEM-1024 derand keygen failed for '\(v.label)'")

            let ciphertext = b64(v.ct_b64)
            var sharedSecret = Data(count: Int(OQS_KEM_ml_kem_1024_length_shared_secret))
            let decapResult = sharedSecret.withUnsafeMutableBytes { ssBuf in
                ciphertext.withUnsafeBytes { ctBuf in
                    secretKey.withUnsafeBytes { skBuf in
                        OQS_KEM_ml_kem_1024_decaps(
                            ssBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            ctBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            skBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        )
                    }
                }
            }
            XCTAssertEqual(decapResult, OQS_SUCCESS, "ML-KEM-1024 decaps failed for '\(v.label)'")
            XCTAssertEqual(sharedSecret, b64(v.expected_shared_secret_b64), "ML-KEM-1024 decap '\(v.label)' shared-secret drift")
        }
    }
}
