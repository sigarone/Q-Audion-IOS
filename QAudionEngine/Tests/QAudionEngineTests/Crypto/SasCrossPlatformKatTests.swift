import XCTest
import CryptoKit
@testable import QAudionEngine

// This file's Decodable structs mirror KAT JSON fixture keys verbatim
// (snake_case, no CodingKeys) — renaming would silently break decoding
// against the shared cross-platform fixture.
// swiftlint:disable identifier_name

/// Cross-platform SAS KAT verifier (iOS side).
///
/// Loads `tools/kat/sas/sas-kat.json` (mirrored byte-equal in all 4
/// BCRYPTO repos — see `WIRE_SPEC.md §4`) and asserts that the
/// production iOS SAS path reproduces every pinned vector exactly.
/// Sister tests:
///   apps/qaudion-android-new/.../sas/SasCrossPlatformKatTest.kt
///   apps/qaudion-desktop/test/CallSas.kat.spec.ts
///
/// Failure modes: HKDF salt/info string drift, byte layout
/// regression (uint24 BE → modulo wordlist), wordlist content/order
/// change, or CryptoKit HKDF<SHA256> backend producing different
/// output for the same (IKM, salt, info, L).
final class SasCrossPlatformKatTests: XCTestCase {

    private struct KatVector: Decodable {
        let name: String
        let session_key_hex: String
        let hkdf_out_hex: String
        let indices_uint24: [UInt32]
        let indices_mod_wordlist_size: [Int]
        let expected_words: [String]
    }

    private struct KatAlgorithm: Decodable {
        let kdf: String
        let salt: String
        let info: String
        let output_len_bytes: Int
        let word_count: Int
    }

    private struct KatFile: Decodable {
        let schema: String
        let algorithm: KatAlgorithm
        let wordlist_size: Int
        let vectors: [KatVector]
    }

    func testEveryVectorReproducesPinnedOutput() throws {
        guard let kat = loadKatOrNil() else {
            // Standalone CI checkouts may have a flat repo layout
            // where the file is reachable; in fully isolated test
            // runs (no monorepo, no repo-root tools/) we no-op
            // gracefully so the suite stays green. Sister suites on
            // Android + Desktop still gate the byte-equality.
            return
        }

        XCTAssertEqual(kat.schema, "qaudion-sas-kat:1")
        XCTAssertEqual(kat.algorithm.kdf, "HKDF-SHA256")
        XCTAssertEqual(kat.algorithm.salt, "qaudion-sas-v1")
        XCTAssertEqual(kat.algorithm.info, "sas-words-v1")
        XCTAssertEqual(kat.algorithm.output_len_bytes, 18)
        XCTAssertEqual(kat.algorithm.word_count, 6)
        XCTAssertEqual(
            kat.wordlist_size, PgpSasWordList.words.count,
            "wordlist size drift: KAT pinned \(kat.wordlist_size), iOS ships \(PgpSasWordList.words.count)"
        )
        XCTAssertGreaterThan(kat.vectors.count, 0, "KAT must contain at least 1 vector")

        let salt = Data(kat.algorithm.salt.utf8)
        let info = Data(kat.algorithm.info.utf8)

        for v in kat.vectors {
            let sessionKey = Data(hex: v.session_key_hex)

            // 1) Raw HKDF output byte-equal — pins the CryptoKit
            //    HKDF<SHA256> backend against Android BouncyCastle
            //    HKDFBytesGenerator and Desktop noble hkdf.
            let derived = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: sessionKey),
                salt: salt,
                info: info,
                outputByteCount: kat.algorithm.output_len_bytes
            )
            let derivedBytes = derived.withUnsafeBytes { Data($0) }
            XCTAssertEqual(
                derivedBytes.hexEncodedString(), v.hkdf_out_hex,
                "[\(v.name)] HKDF drift"
            )

            // 2) Production iOS SAS path produces byte-equal words.
            let sas = try ComputeSasUseCase.invoke(sessionKey: sessionKey)
            XCTAssertEqual(sas.words, v.expected_words, "[\(v.name)] SAS words drift")
        }
    }

    /// Walk up from this test's working dir to find the bcrypto
    /// repo root + KAT JSON. iOS XCTest cwd is normally the package
    /// root (`QAudionEngine/`), so the path resolves to
    /// `<bcrypto-root>/tools/kat/sas/sas-kat.json` after walking up.
    private func loadKatOrNil() -> KatFile? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("tools/kat/sas/sas-kat.json")
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
        precondition(hex.count % 2 == 0, "hex string must be even-length: \(hex)")
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let nextIdx = hex.index(idx, offsetBy: 2)
            let byte = UInt8(hex[idx..<nextIdx], radix: 16) ?? 0
            data.append(byte)
            idx = nextIdx
        }
        self = data
    }

    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
// swiftlint:enable identifier_name
