import CryptoKit
import XCTest
@testable import QAudionEngine

/// CL-5.5 — KAT guard for public earbud-exclusive v2 constants.
///
/// Pins client-COMPUTABLE public values against the frozen KAT vector
/// `earbud-excl-v2-kat.json` (byte-copy of
/// `apps/qaudion-firmware/portable/tests/kms-v2/earbud-excl-v2-kat.json`).
///
/// CLIENT-COMPUTABLE (tested here):
///   - server_id  = SHA-256("qa-kms-server-id-v1|qa-kms-test-server-2026-06-16")
///   - pair_id    = SHA-256("qa-earbud-excl-pair-v2" || eid_min || eid_max)
///   - key_class bytes: none=0, shared=1, hw_only=2
///
/// IN-SE ONLY — must NEVER appear here:
///   K'', PRK'', fp_adv, kc_mac, session_key, ss_ee, epoch_sig
///
/// Any change to labels, orderings, or sizes MUST be accompanied by a
/// cross-platform KAT update across firmware/Android/iOS in lockstep.
final class EarbudExclKatTests: XCTestCase {

    // MARK: - KAT JSON decoding (public fields only)

    /// Decodes only the public-facing fields from the `pairwise` array.
    /// Private in-SE fields (k_prime, ss_ee, prk_kpp, kpp, epoch_sig, etc.)
    /// are NOT decoded — decoding them would violate the blindness invariant.
    private struct KatPairwise: Decodable {
        let name: String
        let earbud_id_A_hex: String
        let earbud_id_B_hex: String
        let pair_id_hex: String
        let key_epoch: String
        // k_serv_hex, sk_se_A_hex, ss_ee_hex, prk_kpp_hex, kpp_hex etc. — NOT decoded.
    }

    /// Decodes only the public key_class byte constants from the top-level dict.
    private struct KatKeyClass: Decodable {
        let none: Int
        let shared: Int
        let hw_only: Int
    }

    private struct KatRoot: Decodable {
        let schema: String
        let pairwise: [KatPairwise]
        let key_class: KatKeyClass
        // fp_and_kc, session_v4, labels — NOT decoded (contain in-SE values).
    }

    private func loadKat() throws -> KatRoot {
        guard let url = Bundle.module.url(forResource: "earbud-excl-v2-kat", withExtension: "json") else {
            throw XCTestError(.timeoutWhileWaiting, userInfo: [
                NSLocalizedDescriptionKey: "earbud-excl-v2-kat.json not found in Bundle.module — " +
                    "check Package.swift testTarget resources declaration"
            ])
        }
        return try JSONDecoder().decode(KatRoot.self, from: Data(contentsOf: url))
    }

    // MARK: - Schema guard

    func testKatSchemaIsRecognised() throws {
        let kat = try loadKat()
        XCTAssertEqual("qa-earbud-excl-v2-kat:1", kat.schema,
                       "KAT schema version changed — verify all fields are still compatible")
    }

    // MARK: - key_class byte constants

    func testKeyClassNoneIsZero() throws {
        let kat = try loadKat()
        XCTAssertEqual(0, kat.key_class.none,
                       "key_class.none KAT byte mismatch")
    }

    func testKeyClassSharedIsOne() throws {
        let kat = try loadKat()
        XCTAssertEqual(1, kat.key_class.shared,
                       "key_class.shared KAT byte mismatch")
    }

    func testKeyClassHwOnlyIsTwo() throws {
        let kat = try loadKat()
        XCTAssertEqual(2, kat.key_class.hw_only,
                       "key_class.hw_only KAT byte changed — EarbudAckPopRelay uses \"hw_only\" string; " +
                       "the numeric constant is in the wire protocol and must not drift")
    }

    // MARK: - server_id

    func testServerIdMatchesKmsServerIdentity() {
        // SHA-256("qa-kms-server-id-v1|qa-kms-test-server-2026-06-16") — frozen label.
        // KmsServerIdentity.serverIdBytes must produce this exact 32 bytes.
        let expected = Data([
            0x94, 0xb4, 0x00, 0x0e, 0x40, 0xb5, 0xa7, 0x16,
            0xd3, 0xd8, 0x06, 0xbb, 0x79, 0xc5, 0x0f, 0x29,
            0x04, 0xa4, 0xc8, 0xd8, 0xfd, 0xc5, 0xf4, 0x29,
            0x38, 0x3d, 0x10, 0x5f, 0x61, 0x99, 0x7a, 0x7e
        ])
        XCTAssertEqual(32, KmsServerIdentity.serverIdBytes.count,
                       "serverIdBytes must be 32 bytes")
        XCTAssertEqual(expected, KmsServerIdentity.serverIdBytes,
                       "KmsServerIdentity.serverIdBytes drifted from earbud-excl-v2 KAT — label changed?")
    }

    // MARK: - pair_id from frozen KAT vector

    func testPairIdMatchesKatVector() throws {
        let kat = try loadKat()
        XCTAssertFalse(kat.pairwise.isEmpty, "KAT pairwise array must not be empty")
        let vec = kat.pairwise[0]

        let eidA     = Data(hex: vec.earbud_id_A_hex)
        let eidB     = Data(hex: vec.earbud_id_B_hex)
        let expected = Data(hex: vec.pair_id_hex)

        XCTAssertEqual(32, eidA.count, "earbud_id_A must be 32 bytes")
        XCTAssertEqual(32, eidB.count, "earbud_id_B must be 32 bytes")
        XCTAssertEqual(32, expected.count, "pair_id must be 32 bytes")

        let got = EarbudPairTranscript.pairId(eidA: eidA, eidB: eidB)
        XCTAssertEqual(expected, got,
                       "[\(vec.name)] EarbudPairTranscript.pairId(eidA:eidB:) drifted from KAT — " +
                       "label or ordering changed? pair_id = SHA-256(\"qa-earbud-excl-pair-v2\"||eid_min||eid_max)")
    }

    func testPairIdIsSymmetricOnKatVector() throws {
        let kat = try loadKat()
        let vec = kat.pairwise[0]
        let eidA = Data(hex: vec.earbud_id_A_hex)
        let eidB = Data(hex: vec.earbud_id_B_hex)

        let ab = EarbudPairTranscript.pairId(eidA: eidA, eidB: eidB)
        let ba = EarbudPairTranscript.pairId(eidA: eidB, eidB: eidA)
        XCTAssertEqual(ab, ba, "pairId must be symmetric: pairId(A,B) == pairId(B,A)")
    }

    func testPairIdReturns32BytesOnKatVector() throws {
        let kat = try loadKat()
        let vec = kat.pairwise[0]
        let eidA = Data(hex: vec.earbud_id_A_hex)
        let eidB = Data(hex: vec.earbud_id_B_hex)
        XCTAssertEqual(32, EarbudPairTranscript.pairId(eidA: eidA, eidB: eidB).count)
    }

    // MARK: - Negative: in-SE values must NOT be reproducible by the client

    // K''/PRK''/fp_adv/kc_mac/session_key/ss_ee are NOT decoded or asserted.
    // No test here reproduces those bytes — doing so would break the blindness invariant.
    // The KAT JSON contains those fields for firmware/server-side verification only.
}

// MARK: - Schema:4 session KDF KAT

/// CL-5.6 — KAT guard for the schema:4 session-key derivation primitives.
///
/// Pins `negDigest`, `sessionInfoV4`, and `deriveHybridSessionKeyV4` against
/// the frozen `session_v4` array in `earbud-excl-v2-kat.json` (3 entries:
/// none / shared-K / exclusive-Kpp).
///
/// These are CLIENT-COMPUTABLE values that the phone assembles before
/// forwarding to the earbud.  All three are tested here to catch any
/// byte-ordering or label drift early, before the full cross-platform
/// integration test on firmware.
final class SessionV4KatTests: XCTestCase {

    // MARK: - Decodable model for session_v4 entries

    private struct KatSessionV4: Decodable {
        let name: String
        let mlkem_ss_hex: String
        let x25519_ss_hex: String
        let mlkem_ct_hex: String
        let selected_key_hex: String?
        let key_class: Int
        let fp_set_init_hex: String
        let fp_set_resp_hex: String
        let neg_digest_hex: String
        let selected_fp_hex: String
        let ct_bind_hex: String
        let info_hex: String
        let session_key_hex: String
    }

    private struct KatSessionV4Root: Decodable {
        let session_v4: [KatSessionV4]
    }

    private func loadSessionV4Vectors() throws -> [KatSessionV4] {
        guard let url = Bundle.module.url(forResource: "earbud-excl-v2-kat", withExtension: "json") else {
            throw XCTestError(.timeoutWhileWaiting, userInfo: [
                NSLocalizedDescriptionKey: "earbud-excl-v2-kat.json not found in Bundle.module"
            ])
        }
        let root = try JSONDecoder().decode(KatSessionV4Root.self, from: Data(contentsOf: url))
        XCTAssertFalse(root.session_v4.isEmpty, "session_v4 array must not be empty")
        return root.session_v4
    }

    // MARK: - negDigest

    func testSessionV4NegDigest() throws {
        let vectors = try loadSessionV4Vectors()
        for vec in vectors {
            let fpInit     = Data(hex: vec.fp_set_init_hex)
            let fpResp     = Data(hex: vec.fp_set_resp_hex)
            let expected   = Data(hex: vec.neg_digest_hex)

            let got = QAudionCallIntegration.negDigest(fpSetInit: fpInit, fpSetResp: fpResp)
            XCTAssertEqual(expected, got,
                           "[\(vec.name)] negDigest mismatch — " +
                           "expected \(vec.neg_digest_hex)")
        }
    }

    // MARK: - sessionInfoV4

    func testSessionV4InfoHex() throws {
        let vectors = try loadSessionV4Vectors()
        for vec in vectors {
            let ctBind      = Data(hex: vec.ct_bind_hex)
            let selectedFp  = Data(hex: vec.selected_fp_hex)
            let keyClass    = UInt8(vec.key_class)
            let negDigest   = Data(hex: vec.neg_digest_hex)
            let expected    = Data(hex: vec.info_hex)

            let got = QAudionCallIntegration.sessionInfoV4(
                ctBind: ctBind,
                selectedFp: selectedFp,
                keyClass: keyClass,
                negDigest: negDigest
            )
            XCTAssertEqual(117, got.count,
                           "[\(vec.name)] info_v4 must be exactly 117 bytes, got \(got.count)")
            XCTAssertEqual(expected, got,
                           "[\(vec.name)] sessionInfoV4 mismatch — " +
                           "expected \(vec.info_hex)")
        }
    }

    // MARK: - deriveHybridSessionKeyV4

    func testSessionV4DeriveKey() throws {
        let vectors = try loadSessionV4Vectors()
        for vec in vectors {
            let pqcSs      = Data(hex: vec.mlkem_ss_hex)
            let x25519Ss   = Data(hex: vec.x25519_ss_hex)
            let pqcCt      = Data(hex: vec.mlkem_ct_hex)
            let psk: Data? = vec.selected_key_hex.map { Data(hex: $0) }
            let selectedFp = Data(hex: vec.selected_fp_hex)
            let keyClass   = UInt8(vec.key_class)
            let negDigest  = Data(hex: vec.neg_digest_hex)
            let expected   = Data(hex: vec.session_key_hex)

            let got = QAudionCallIntegration.deriveHybridSessionKeyV4(
                pqcSs: pqcSs,
                x25519Ss: x25519Ss,
                pqcCiphertext: pqcCt,
                psk: psk,
                selectedFp: selectedFp,
                keyClass: keyClass,
                negDigest: negDigest
            )
            XCTAssertEqual(32, got.count,
                           "[\(vec.name)] session key must be 32 bytes")
            XCTAssertEqual(expected, got,
                           "[\(vec.name)] deriveHybridSessionKeyV4 mismatch — " +
                           "expected \(vec.session_key_hex)")
        }
    }
}

// MARK: - Hex helper (file-private, same pattern as other KAT test files)

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
}
