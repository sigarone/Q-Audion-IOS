import XCTest
import CryptoKit
@testable import QAudionEngine

// This file's Decodable structs mirror KAT JSON fixture keys verbatim
// (snake_case, no CodingKeys) — renaming would silently break decoding
// against the shared cross-platform fixture.
// swiftlint:disable identifier_name

/// §3.4 qa-kms-pop-v1. Authoritative generator: firmware
/// tools/kat/kms-v2/gen_kms_v2_kat.py. Vectors include one
/// app-classical (32B secret), one app-hybrid (64B), one earbud (64B),
/// each with a DISTINCT expected pop_hex.
///
/// As with the psk-v2 KAT, the canonical pop KAT carries identity fields
/// as RAW *_hex (device_id_hex/txn_id_hex/key_id_hex/server_nonce_hex/
/// server_id_hex/delivery_wrap_secret_hex). This consumer parses the
/// `_hex` fields directly.
final class KmsPoPV1KatTests: XCTestCase {

    private struct Vector: Decodable {
        let origin: String
        let delivery_wrap_secret_hex: String
        let device_id_hex: String
        let server_id_hex: String       // 32B SHA-256
        let txn_id_hex: String
        let key_id_hex: String
        let key_epoch: String
        let server_nonce_hex: String    // 16B
        let pop_key_hex: String
        let pop_hex: String
    }
    private struct File: Decodable { let schema: String; let vectors: [Vector] }

    func testSelfConsistency() throws {
        // Deterministic local round-trip independent of the KAT file.
        let secret = Data(repeating: 0x11, count: 64)
        // Hardcoded well-formed UUID literal — always decodes.
        // swiftlint:disable:next force_unwrapping
        let did = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let serverId = Data(repeating: 0x22, count: 32)
        // Hardcoded well-formed UUID literal — always decodes.
        // swiftlint:disable:next force_unwrapping
        let txn = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        // Hardcoded well-formed UUID literal — always decodes.
        // swiftlint:disable:next force_unwrapping
        let kid = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let nonce = Data(repeating: 0x55, count: 16)
        let pop = KmsPoPV1.compute(wrapSecret: secret, deviceId: did,
                                   serverId: serverId, txnId: txn, keyId: kid,
                                   keyEpoch: 9, serverNonce: nonce)
        XCTAssertEqual(pop.count, 32)
    }

    func testEveryPoPVector() throws {
        guard let file = loadKat() else {
            print("[KmsPoPV1KatTests] KAT not present — skipping (pre-freeze)"); return
        }
        XCTAssertEqual(file.schema, "kms-pop-v1-kat:1")
        XCTAssertGreaterThan(file.vectors.count, 0)
        for v in file.vectors {
            let did = KmsKatHex.uuid(fromRawHex: v.device_id_hex)
            let key = KmsPoPV1.deriveKey(
                wrapSecret: Data(hexString: v.delivery_wrap_secret_hex),
                deviceId: did)
            XCTAssertEqual(key.hexLower(), v.pop_key_hex, "[\(v.origin)] pop_key drift")
            let pop = KmsPoPV1.compute(
                wrapSecret: Data(hexString: v.delivery_wrap_secret_hex),
                deviceId: did,
                serverId: Data(hexString: v.server_id_hex),
                txnId: KmsKatHex.uuid(fromRawHex: v.txn_id_hex),
                keyId: KmsKatHex.uuid(fromRawHex: v.key_id_hex),
                // key_epoch is a frozen KAT decimal uint64 string, generator-guaranteed parseable.
                // swiftlint:disable:next force_unwrapping
                keyEpoch: UInt64(v.key_epoch)!,
                serverNonce: Data(hexString: v.server_nonce_hex))
            XCTAssertEqual(pop.hexLower(), v.pop_hex, "[\(v.origin)] pop drift")
        }
    }

    private func loadKat() -> File? {
        if let url = Bundle.module.url(forResource: "kms-pop-v1-kat", withExtension: "json"),
           let d = try? Data(contentsOf: url),
           let f = try? JSONDecoder().decode(File.self, from: d) { return f }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<6 {
            let c = dir.appendingPathComponent("tools/kat/kms-v2/kms-pop-v1-kat.json")
            if fm.fileExists(atPath: c.path),
               let d = try? Data(contentsOf: c),
               let f = try? JSONDecoder().decode(File.self, from: d) { return f }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
// swiftlint:enable identifier_name
