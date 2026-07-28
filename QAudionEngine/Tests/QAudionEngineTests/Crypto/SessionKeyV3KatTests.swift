import XCTest
import CryptoKit
@testable import QAudionEngine

// This file's Decodable structs mirror KAT JSON fixture keys verbatim
// (snake_case, no CodingKeys) — renaming would silently break decoding
// against the shared cross-platform fixture.
// swiftlint:disable identifier_name

/// KMS-rotation-v2 Phase-1 (D6) — schema:3 session-KDF KAT verifier (iOS).
///
/// FROZEN contract `tools/kat/kms-v2/session-key-v3-kat.json` (vendored byte-for-byte
/// into the test bundle). Schema:3 extends the schema:2 ct-binding KDF by appending the
/// negotiated fingerprint to the HKDF `info`:
///
///   ct_bind            = HMAC-SHA256("q-audion-ct-bind-v1", mlkem_ct)              [32B]
///   selected_fp_or_z32 = SHA-256(selected_PSK)   when a PSK was negotiated
///                        else 32 × 0x00                                            [32B]
///   ikm                = mlkem_ss(32) || x25519_ss(32)                             [64B]
///   salt               = selected_PSK   when present, else "q-audion-hybrid-pqc-v1"
///   info_v3            = "q-audion-session-key"(20) || ct_bind(32) || selected_fp_or_z32(32) [84B]
///   session_key        = HKDF-SHA256(ikm, salt, info_v3, 32)
///
/// Byte-identical to Android `HybridPqcKeyExchange.deriveSessionKeyV3`, Desktop
/// `deriveHybridSessionKeyV3`, firmware in-SE `psa_mac_compute` HKDF-Extract path.
///
/// Bytes are FROZEN: if this test fails, the Swift code is wrong, never the vector.
///
/// ⚠️ Requires `swift test` (CryptoKit) — authored on win32 which cannot run CryptoKit.
/// The byte construction was hand-verified offline against the JSON (Python stdlib HKDF):
/// no-psk/K1/K2 session_key + the 18-byte SAS all match. CI is the gate.
final class SessionKeyV3KatTests: XCTestCase {

    private struct Vector: Decodable {
        let name: String
        let schema: Int
        let mlkem_ss_hex: String
        let x25519_ss_hex: String
        let mlkem_ct_hex: String
        let psk_hex: String?
        let selected_fp_hex: String
        let ct_bind_hex: String
        let info_hex: String
        let session_key_hex: String
        let sas_hex: String
    }
    private struct File: Decodable {
        let schema: String
        let vectors: [Vector]
    }

    func testEverySessionKeyV3VectorMatches() throws {
        guard let kat = loadKat() else {
            XCTFail("session-key-v3-kat.json not found (Bundle.module + fs fallback both missed)")
            return
        }
        XCTAssertEqual(kat.schema, "session-key-v3-kat:1")
        XCTAssertGreaterThan(kat.vectors.count, 0)

        for v in kat.vectors {
            XCTAssertEqual(v.schema, 3, "[\(v.name)] not a schema:3 vector")
            let psk = v.psk_hex.map { Data(hexV3: $0) }

            // 1. selected_fp_or_zero32 derivation (SHA-256(PSK) or 32×0x00).
            let selFp = QAudionCallIntegration.selectedFpOrZero32(selectedPsk: psk)
            XCTAssertEqual(selFp.hexV3(), v.selected_fp_hex,
                           "[\(v.name)] selected_fp_or_zero32 drift")

            // 2. the full schema:3 session key, via the PRODUCTION path.
            let key = QAudionCallIntegration.deriveHybridSessionKeyV3(
                pqcSs: Data(hexV3: v.mlkem_ss_hex),
                x25519Ss: Data(hexV3: v.x25519_ss_hex),
                pqcCiphertext: Data(hexV3: v.mlkem_ct_hex),
                psk: psk
            )
            XCTAssertEqual(key.hexV3(), v.session_key_hex,
                           "[\(v.name)] schema:3 session_key drift — info_v3 = "
                           + "label||ct_bind||selected_fp_or_zero32")

            // 3. SAS binds whatever is in session_key — pin the raw 18-byte HKDF
            //    output (qaudion-sas-v1 / sas-words-v1, L=18).
            let sasRaw = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: key),
                salt: SasConstants.saltBytes,
                info: SasConstants.infoWordsBytes,
                outputByteCount: ComputeSasUseCase.hkdfOutputBytes
            ).withUnsafeBytes { Data($0) }
            XCTAssertEqual(sasRaw.hexV3(), v.sas_hex, "[\(v.name)] SAS raw-bytes drift")
        }
    }

    /// schema:2 (no fp tail) and schema:3 with NO psk MUST differ — the appended
    /// 32×0x00 tail is still 32 bytes of `info`, so v2≠v3 even when no PSK is mixed.
    /// This is the on-purpose schema bump (a v2 peer and a v3 peer must NOT silently
    /// derive the same key; they negotiate down to v2 instead — see negotiate test).
    func testSchema2AndSchema3DifferEvenWithoutPsk() {
        let pqcSs = Data(hexV3: "ac59c1fd9bc063f6fc59ad275aa5ebb6932b30e8a23ee3a751be614c8774dc7b")
        let x25519 = Data(repeating: 0x42, count: 32)
        let ct = Data(repeating: 0xAB, count: 1568)
        let v2 = QAudionCallIntegration.deriveHybridSessionKey(
            pqcSs: pqcSs, x25519Ss: x25519, pqcCiphertext: ct, psk: nil)
        let v3 = QAudionCallIntegration.deriveHybridSessionKeyV3(
            pqcSs: pqcSs, x25519Ss: x25519, pqcCiphertext: ct, psk: nil)
        XCTAssertNotEqual(v2.hexV3(), v3.hexV3(),
                          "schema:2 and schema:3 must NOT collide (info length differs)")
    }

    private func loadKat() -> File? {
        if let url = Bundle.module.url(forResource: "session-key-v3-kat", withExtension: "json"),
           let d = try? Data(contentsOf: url),
           let f = try? JSONDecoder().decode(File.self, from: d) { return f }
        // Filesystem fallback — walk up to the firmware repo's frozen source.
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<8 {
            for rel in ["tools/kat/kms-v2/session-key-v3-kat.json",
                        "QAudionEngine/Tests/QAudionEngineTests/Resources/kat/session-key-v3-kat.json"] {
                let c = dir.appendingPathComponent(rel)
                if fm.fileExists(atPath: c.path),
                   let d = try? Data(contentsOf: c),
                   let f = try? JSONDecoder().decode(File.self, from: d) { return f }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

private extension Data {
    init(hexV3 hex: String) {
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            data.append(UInt8(hex[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        self = data
    }
    func hexV3() -> String { map { String(format: "%02x", $0) }.joined() }
}
// swiftlint:enable identifier_name
