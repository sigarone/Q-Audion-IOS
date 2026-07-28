import XCTest
import CryptoKit
@testable import QAudionEngine

// This file's Decodable structs mirror KAT JSON fixture keys verbatim
// (snake_case, no CodingKeys) — renaming would silently break decoding
// against the shared cross-platform fixture.
// swiftlint:disable identifier_name

/// Cross-platform KMS round-trip KAT verifier (iOS side).
///
/// Loads `tools/kat/kms/kms-roundtrip-kat.json` (mirrored byte-equal
/// in all 4 BCRYPTO repos — `WIRE_SPEC §2`) and asserts the iOS
/// `KmsTransport.decryptPackage` decrypts every pinned vector back
/// to the original PSK byte-for-byte:
///   - classical: HKDF(salt='bcrypto-kms-salt-v1',
///                     info='bcrypto-kms-psk-v1') over ECDH
///   - binding-hybrid: HKDF(salt='bcrypto-kms-hybrid-salt-v1',
///                          info='bcrypto-kms-hybrid-pqc-v1') over
///                     ECDH || SHA-256(mlkemPub)
///
/// Sister tests:
///   apps/qaudion-android-new/.../KmsRoundTripKatTest.kt
///   apps/qaudion-desktop/test/KmsRoundTrip.kat.spec.ts
final class KmsRoundTripKatTests: XCTestCase {

    private struct KatVector: Decodable {
        let name: String
        let tier: String
        let device_x25519_priv_hex: String
        let device_x25519_pub_hex: String
        let ephemeral_x25519_pub_hex: String
        let nonce_hex: String
        let mlkem_pub_hex: String?
        let package_hex: String
        let expected_psk_hex: String
    }

    private struct KatFile: Decodable {
        let schema: String
        let vectors: [KatVector]
    }

    func testEveryKmsRoundTripVector() throws {
        guard let kat = loadKatOrNil() else { return }

        XCTAssertEqual(kat.schema, "qaudion-kms-roundtrip-kat:1")
        XCTAssertGreaterThan(kat.vectors.count, 0)

        for v in kat.vectors {
            let devPriv = Data(hex: v.device_x25519_priv_hex)
            let pkg = Data(hex: v.package_hex)

            let recovered: Data
            switch v.tier {
            case "classical":
                recovered = try KmsTransport.decryptPackage(
                    pkg: pkg,
                    x25519Priv: devPriv,
                    mlkemPub: nil,
                    mlkemPriv: nil
                )
            case "binding-hybrid":
                guard let mlkemHex = v.mlkem_pub_hex else {
                    XCTFail("[\(v.name)] binding-hybrid vector missing mlkem_pub_hex")
                    continue
                }
                let mlkemPub = Data(hex: mlkemHex)
                recovered = try KmsTransport.decryptPackage(
                    pkg: pkg,
                    x25519Priv: devPriv,
                    mlkemPub: mlkemPub,
                    mlkemPriv: nil
                )
            default:
                XCTFail("[\(v.name)] unknown tier: \(v.tier)")
                continue
            }

            XCTAssertEqual(
                recovered.hexEncodedString(), v.expected_psk_hex,
                "[\(v.name)] iOS KMS decrypt drift — tier=\(v.tier)"
            )
        }
    }

    private func loadKatOrNil() -> KatFile? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("tools/kat/kms/kms-roundtrip-kat.json")
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
        precondition(hex.count % 2 == 0)
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
// swiftlint:enable identifier_name
