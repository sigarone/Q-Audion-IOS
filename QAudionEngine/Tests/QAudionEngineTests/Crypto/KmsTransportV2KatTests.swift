import XCTest
import CryptoKit
@testable import QAudionEngine

// This file's Decodable structs mirror KAT JSON fixture keys verbatim
// (snake_case, no CodingKeys) — renaming would silently break decoding
// against the shared cross-platform fixture.
// swiftlint:disable identifier_name

/// Cross-platform KAT consumer for kms-psk-v2 (§4). Authoritative
/// generator: firmware tools/kat/kms-v2/gen_kms_v2_kat.py. iOS MUST
/// reproduce every vector's recovered K AND match the pinned
/// aad_hex / ikm_hex byte-for-byte.
///
/// NOTE on field shapes: the FROZEN canonical KAT carries the identity
/// fields as RAW 16-byte hex (`key_id_hex`, `user_id_hex`,
/// `device_id_hex`, `txn_id_hex`) — NOT as UUID strings. The KAT is the
/// source of truth, so this consumer parses the `_hex` fields and feeds
/// the raw bytes (via a UUID round-trip) into `buildAadV2` /
/// `decryptPackageV2`. (`UUID(uuidBytes:)` → `KmsTransport.uuidBytes`
/// round-trips the exact 16 bytes.)
final class KmsTransportV2KatTests: XCTestCase {

    private struct Vector: Decodable {
        let tier: String                 // "classical" | "hybrid"
        let device_x25519_priv_hex: String
        let device_mlkem_priv_hex: String?
        let device_mlkem_pub_hex: String?
        let key_id_hex: String
        let user_id_hex: String
        let device_id_hex: String
        let key_epoch: String            // decimal uint64 string
        let txn_id_hex: String
        let key_class: String            // shared|hw_only|sw_only
        let encrypted_package_b64: String
        let aad_hex: String
        let ikm_hex: String
        let aead_key_hex: String
        let expected_psk_hex: String     // == recovered K
    }
    private struct File: Decodable { let schema: String; let vectors: [Vector] }

    func testEveryV2Vector() throws {
        guard let file = loadKat() else {
            print("[KmsTransportV2KatTests] KAT not present — skipping (pre-freeze)")
            return
        }
        XCTAssertEqual(file.schema, "kms-psk-v2-kat:1")
        XCTAssertGreaterThan(file.vectors.count, 0)
        for v in file.vectors {
            let kc = KmsTransport.KeyClassV2(wire: v.key_class)!
            let keyId  = KmsKatHex.uuid(fromRawHex: v.key_id_hex)
            let userId = KmsKatHex.uuid(fromRawHex: v.user_id_hex)
            let devId  = KmsKatHex.uuid(fromRawHex: v.device_id_hex)
            let txnId  = KmsKatHex.uuid(fromRawHex: v.txn_id_hex)
            let epoch  = UInt64(v.key_epoch)!

            // AAD byte-equality (independent of decrypt).
            let aad = KmsTransport.buildAadV2(
                keyId: keyId, userId: userId, deviceId: devId,
                keyEpoch: epoch, txnId: txnId, keyClass: kc)
            XCTAssertEqual(aad.hexLower(), v.aad_hex, "[\(v.tier)] AAD drift")

            let pkg = Data(base64Encoded: v.encrypted_package_b64)!
            let out = try KmsTransport.decryptPackageV2(
                pkg: pkg,
                x25519Priv: Data(hexString: v.device_x25519_priv_hex),
                mlkemPriv: v.device_mlkem_priv_hex.map { Data(hexString: $0) },
                mlkemPub: v.device_mlkem_pub_hex.map { Data(hexString: $0) },
                keyId: keyId, userId: userId, deviceId: devId,
                keyEpoch: epoch, txnId: txnId, keyClass: kc)
            XCTAssertEqual(out.psk.hexLower(), v.expected_psk_hex, "[\(v.tier)] K drift")
            XCTAssertEqual(out.wrapSecret.hexLower(), v.ikm_hex, "[\(v.tier)] wrap secret/IKM drift")
        }
    }

    private func loadKat() -> File? {
        if let url = Bundle.module.url(forResource: "kms-psk-v2-kat", withExtension: "json"),
           let d = try? Data(contentsOf: url),
           let f = try? JSONDecoder().decode(File.self, from: d) { return f }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<6 {
            let c = dir.appendingPathComponent("tools/kat/kms-v2/kms-psk-v2-kat.json")
            if fm.fileExists(atPath: c.path),
               let d = try? Data(contentsOf: c),
               let f = try? JSONDecoder().decode(File.self, from: d) { return f }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

/// Shared test-only helpers for the v2 KAT consumers. Declared once here
/// (NON-private) and reused by KmsPoPV1KatTests. The existing
/// `KmsRoundTripKatTests` hex helpers are `private` so there is no clash.
enum KmsKatHex {
    /// Build a UUID from 16 raw bytes (network order). `key_id_hex` etc.
    /// in the canonical KAT are raw bytes, not UUID strings;
    /// `KmsTransport.uuidBytes(uuid(fromRawHex:))` round-trips them.
    static func uuid(fromRawHex hex: String) -> UUID {
        let b = [UInt8](Data(hexString: hex))
        precondition(b.count == 16, "raw uuid hex must be 16 bytes")
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

extension Data {
    init(hexString: String) {
        var d = Data(capacity: hexString.count / 2)
        var i = hexString.startIndex
        while i < hexString.endIndex {
            let n = hexString.index(i, offsetBy: 2)
            d.append(UInt8(hexString[i..<n], radix: 16) ?? 0); i = n
        }
        self = d
    }
    func hexLower() -> String { map { String(format: "%02x", $0) }.joined() }
}
// swiftlint:enable identifier_name
