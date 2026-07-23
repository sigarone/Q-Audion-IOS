import XCTest
import CryptoKit
@testable import QAudionEngine

/// Cross-platform PskMix v1 KAT verifier. Loads `psk-mix-v1-kat.json` (byte-copy of
/// `apps/qaudion-desktop/tools/kat/psk-mix/psk-mix-v1-kat.json` — the shared, cross-repo
/// contract for shipOrder step 7) from the test bundle and asserts `PskMix` reproduces
/// every pinned hex value byte-for-byte.
///
/// Sister: qaudion-desktop test/kat/pskMix.kat.spec.ts, Android PskMixKatTest.kt.
///
/// The JSON is the immutable cross-platform contract — DO NOT modify it. If this test
/// disagrees with a vector, fix `PskMix.swift`, never the vector.
final class PskMixKatTests: XCTestCase {

    private func loadVectors() throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: "psk-mix-v1-kat", withExtension: "json") else {
            XCTFail("psk-mix-v1-kat.json not found in Bundle.module")
            return [:]
        }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vectors = json["vectors"] as? [String: Any] else {
            XCTFail("KAT JSON missing top-level 'vectors' object"); return [:]
        }
        return vectors
    }

    private func hexData(_ s: String) -> Data {
        var out = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            out.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return out
    }

    private func hexString(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    func testMixN1Identity() throws {
        let vectors = try loadVectors()
        guard let vec = vectors["mix_n1_identity"] as? [String: Any],
              let secretsHex = vec["secrets_hex"] as? [String] else {
            XCTFail("missing mix_n1_identity"); return
        }
        let s1 = hexData(secretsHex[0])
        let kMix = PskMix.deriveKMix([s1])
        XCTAssertEqual(hexString(kMix), vec["expected_K_mix_hex"] as? String)
        XCTAssertEqual(kMix, s1)
    }

    func testMixN2Basic() throws {
        let vectors = try loadVectors()
        guard let vec = vectors["mix_n2_basic"] as? [String: Any],
              let secretsHex = vec["secrets_hex"] as? [String] else {
            XCTFail("missing mix_n2_basic"); return
        }
        let secrets = secretsHex.map { hexData($0) }
        let fps = secrets.map { PskMix.fingerprint($0) }

        let ikm = PskMix.ikmMix(fps, secrets)
        XCTAssertEqual(hexString(ikm), vec["expected_ikm_mix_hex"] as? String)
        XCTAssertEqual(ikm.count, vec["expected_ikm_mix_len"] as? Int)

        let mid = PskMix.mixId(fps)
        XCTAssertEqual(hexString(mid), vec["expected_mix_id_hex"] as? String)

        let prk = PskMix.prkMix(secrets[0], ikm)
        XCTAssertEqual(hexString(prk), vec["expected_PRK_mix_hex"] as? String)

        let kMix = PskMix.deriveKMix(secrets)
        XCTAssertEqual(hexString(kMix), vec["expected_K_mix_hex"] as? String)
    }

    func testMixSwapRole() throws {
        let vectors = try loadVectors()
        guard let vec = vectors["mix_swap_role"] as? [String: Any],
              let fwdHex = vec["secrets_hex_forward"] as? [String],
              let swappedHex = vec["secrets_hex_swapped"] as? [String] else {
            XCTFail("missing mix_swap_role"); return
        }
        let fwd = fwdHex.map { hexData($0) }
        let swapped = swappedHex.map { hexData($0) }

        let kFwd = PskMix.deriveKMix(fwd)
        let kSwapped = PskMix.deriveKMix(swapped)
        XCTAssertEqual(hexString(kFwd), vec["expected_K_mix_forward_hex"] as? String)
        XCTAssertEqual(hexString(kSwapped), vec["expected_K_mix_swapped_hex"] as? String)
        XCTAssertNotEqual(kFwd, kSwapped)
    }

    func testMixN3() throws {
        let vectors = try loadVectors()
        guard let vec = vectors["mix_n3"] as? [String: Any],
              let secretsHex = vec["secrets_hex"] as? [String] else {
            XCTFail("missing mix_n3"); return
        }
        let secrets = secretsHex.map { hexData($0) }
        let kMix = PskMix.deriveKMix(secrets)
        XCTAssertEqual(kMix.count, 32)
        XCTAssertEqual(hexString(kMix), vec["expected_K_mix_hex"] as? String)
    }

    func testMixN4() throws {
        let vectors = try loadVectors()
        guard let vec = vectors["mix_n4"] as? [String: Any],
              let secretsHex = vec["secrets_hex"] as? [String] else {
            XCTFail("missing mix_n4"); return
        }
        let secrets = secretsHex.map { hexData($0) }
        let kMix = PskMix.deriveKMix(secrets)
        XCTAssertEqual(kMix.count, 32)
        XCTAssertEqual(hexString(kMix), vec["expected_K_mix_hex"] as? String)
    }

    func testMixLenDisjoint() throws {
        let vectors = try loadVectors()
        guard let vec = vectors["mix_len_disjoint"] as? [String: Any],
              let lens = vec["ikm_mix_lengths"] as? [String: Int],
              let earbudLen = vec["earbud_ikm_pp_len"] as? Int else {
            XCTFail("missing mix_len_disjoint"); return
        }
        XCTAssertEqual(lens["2"], 112)
        XCTAssertEqual(lens["3"], 178)
        XCTAssertEqual(lens["4"], 244)
        for (_, len) in lens {
            XCTAssertNotEqual(len, earbudLen)
        }
    }
}
