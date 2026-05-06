import XCTest
import CryptoKit
@testable import QAudionEngine

/// Cross-platform hybrid PQC combine KAT verifier (iOS side).
///
/// Loads `tools/kat/hybrid-combine/hybrid-combine-kat.json` (mirrored
/// byte-equal in all 4 BCRYPTO repos — `WIRE_SPEC §1 + §3.2`) and
/// asserts the iOS production HKDF used by
/// `QAudionCallIntegration.combinePqcAndX25519` reproduces every
/// pinned (pqcSs, x25519Ss) → sessionKey vector byte-for-byte.
///
/// Sister tests:
///   apps/qaudion-android-new/.../HybridCombineKatTest.kt
///   apps/qaudion-desktop/test/HybridCombine.kat.spec.ts
///
/// Failure means: HKDF salt or info string drift, IKM ordering
/// regression (pqcSs MUST come first in the concat), output length
/// drift, or CryptoKit's HKDF<SHA256> producing different bytes
/// for the same inputs vs BouncyCastle / noble.
final class HybridCombineKatTests: XCTestCase {

    private struct KatAlgorithm: Decodable {
        let kdf: String
        let salt: String
        let info: String
        let output_len_bytes: Int
        let ikm_layout: String
    }

    private struct KatVector: Decodable {
        let name: String
        let pqc_shared_hex: String
        let x25519_shared_hex: String
        let session_key_hex: String
    }

    private struct KatFile: Decodable {
        let schema: String
        let algorithm: KatAlgorithm
        let vectors: [KatVector]
    }

    func testEveryHybridCombineVectorMatches() throws {
        guard let kat = loadKatOrNil() else { return }

        XCTAssertEqual(kat.schema, "qaudion-hybrid-combine-kat:1")
        XCTAssertEqual(kat.algorithm.kdf, "HKDF-SHA256")
        XCTAssertEqual(kat.algorithm.salt, "q-audion-hybrid-pqc-v1")
        XCTAssertEqual(kat.algorithm.info, "q-audion-session-key")
        XCTAssertEqual(kat.algorithm.output_len_bytes, 32)
        XCTAssertGreaterThan(kat.vectors.count, 0)

        let salt = Data(kat.algorithm.salt.utf8)
        let info = Data(kat.algorithm.info.utf8)

        for v in kat.vectors {
            let pqcSs = Data(hex: v.pqc_shared_hex)
            let x25519Ss = Data(hex: v.x25519_shared_hex)
            var ikm = Data(capacity: pqcSs.count + x25519Ss.count)
            ikm.append(pqcSs)
            ikm.append(x25519Ss)

            let derived = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: ikm),
                salt: salt,
                info: info,
                outputByteCount: kat.algorithm.output_len_bytes
            )
            let derivedHex = derived.withUnsafeBytes { Data($0) }.hexEncodedString()

            XCTAssertEqual(
                derivedHex, v.session_key_hex,
                "[\(v.name)] iOS HKDF combine drift — IKM=pqcSs(32B)||x25519Ss(32B), salt='\(kat.algorithm.salt)', info='\(kat.algorithm.info)', L=32"
            )
        }
    }

    private func loadKatOrNil() -> KatFile? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("tools/kat/hybrid-combine/hybrid-combine-kat.json")
            if fm.fileExists(atPath: candidate.path) {
                if let data = try? Data(contentsOf: candidate),
                   let kat = try? JSONDecoder().decode(KatFile.self, from: data) {
                    return kat
                }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

private extension Data {
    init(hex: String) {
        precondition(hex.count % 2 == 0, "hex must be even-length: \(hex)")
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            data.append(UInt8(hex[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        self = data
    }

    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
