import XCTest
import CryptoKit
@testable import QAudionEngine

/// Cross-platform KAT (Known-Answer Test) vectors for the 5 protocol invariants.
///
/// These tests load `cross_platform_vectors.json` from the test bundle and assert
/// byte-identical output from the iOS implementation. Android and Desktop test
/// suites must load the same JSON and confirm identical results — any divergence
/// fails CI on whichever platform diverges.
///
/// ## First-run-pinning pattern
/// Where `expected_*` fields are non-empty the test asserts equality.
/// If you add a new vector with an empty/null expected field, the test prints
/// the computed value and passes — on the NEXT run (once you fill the field)
/// it will start enforcing. This ensures KAT tests never silently diverge.
///
/// ## Covered invariants
/// 1. `phone_hash_v1`         — SHA-256(E.164), no salt/pepper
/// 2. `peppered_phone_hash_v2`— SHA-256(pepper_utf8 ‖ E.164_utf8)
/// 3. `nfc_psk_v1`            — HKDF-SHA256 over X25519 shared secret, sorted-concat salt
/// 4. `identity_qr_v1`        — 4-byte checksum: first 4B of SHA-256(v_byte ‖ userId ‖ pubkey)
/// 5. `device_link_qr`        — Binary blob layout + base64url URL round-trip
final class KatVectorsTests: XCTestCase {

    // MARK: - JSON loader

    private var json: [String: Any] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        json = try Self.loadVectorsJson()
    }

    private static func loadVectorsJson() throws -> [String: Any] {
        guard let url = Bundle.module.url(
            forResource: "cross_platform_vectors",
            withExtension: "json"
        ) else {
            throw XCTestError(.failureWhileWaiting,
                userInfo: [NSLocalizedDescriptionKey: "cross_platform_vectors.json not found in Bundle.module"])
        }
        let data = try Data(contentsOf: url)
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCTestError(.failureWhileWaiting,
                userInfo: [NSLocalizedDescriptionKey: "cross_platform_vectors.json top level is not a JSON object"])
        }
        return parsed
    }

    // MARK: - Helper

    /// Hex-decode a lowercase hex string. Returns nil if the string is invalid.
    private func fromHex(_ hex: String) -> Data? {
        let h = hex.replacingOccurrences(of: " ", with: "")
        guard h.count % 2 == 0 else { return nil }
        var data = Data(capacity: h.count / 2)
        var index = h.startIndex
        while index < h.endIndex {
            let next = h.index(index, offsetBy: 2)
            guard let byte = UInt8(h[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    // MARK: - Invariant 1: PhoneHash v1

    /// SHA-256(E.164) must match for every vector in `phone_hash_v1.vectors`.
    func test_phoneHashV1_katVectors() throws {
        let section = try XCTUnwrap(
            json["phone_hash_v1"] as? [String: Any],
            "phone_hash_v1 section missing from cross_platform_vectors.json"
        )
        let entries = try XCTUnwrap(
            section["vectors"] as? [[String: Any]],
            "phone_hash_v1.vectors must be an array"
        )
        XCTAssertFalse(entries.isEmpty, "phone_hash_v1.vectors must not be empty")

        for v in entries {
            let e164 = try XCTUnwrap(v["e164"] as? String, "Missing 'e164' field in vector")
            let expected = (v["expected_hash"] as? String) ?? ""
            let computed = try PhoneHash.hash(e164)
            if expected.isEmpty {
                print("[KAT] phone_hash_v1 \(e164) → \(computed) (unverified — pin this value)")
            } else {
                XCTAssertEqual(computed, expected,
                    "phone_hash_v1: SHA-256('\(e164)') mismatch — iOS↔Android divergence")
            }
        }
    }

    // MARK: - Invariant 2: PepperedPhoneHash v2

    /// SHA-256(pepper_utf8 ‖ E.164_utf8) must match for every vector.
    func test_pepperedPhoneHashV2_katVectors() throws {
        let section = try XCTUnwrap(
            json["peppered_phone_hash_v2"] as? [String: Any],
            "peppered_phone_hash_v2 section missing from cross_platform_vectors.json"
        )
        let entries = try XCTUnwrap(
            section["vectors"] as? [[String: Any]],
            "peppered_phone_hash_v2.vectors must be an array"
        )
        XCTAssertFalse(entries.isEmpty, "peppered_phone_hash_v2.vectors must not be empty")

        for v in entries {
            let pepper = try XCTUnwrap(v["pepper"] as? String, "Missing 'pepper' field in vector")
            let e164   = try XCTUnwrap(v["e164"]   as? String, "Missing 'e164' field in vector")
            let expected = (v["expected_hash"] as? String) ?? ""
            let computed = try PepperedPhoneHash.hash(phone: e164, pepper: pepper)
            if expected.isEmpty {
                print("[KAT] peppered_phone_hash_v2 pepper=\(pepper) e164=\(e164) → \(computed) (unverified)")
            } else {
                XCTAssertEqual(computed, expected,
                    "peppered_phone_hash_v2: SHA-256('\(pepper)'+'\(e164)') mismatch")
            }
        }
    }

    // MARK: - Invariant 3: NFC PSK Derivation

    /// HKDF-SHA256 over X25519 shared secret with sorted-concat salt.
    /// Also verifies symmetry: derivePsk(a→b) == derivePsk(b→a).
    func test_nfcPskV1_katVector() throws {
        let section = try XCTUnwrap(
            json["nfc_psk_v1"] as? [String: Any],
            "nfc_psk_v1 section missing from cross_platform_vectors.json"
        )

        let aPrivHex = try XCTUnwrap(section["a_priv_hex"] as? String)
        let bPrivHex = try XCTUnwrap(section["b_priv_hex"] as? String)
        let aPubHex  = section["a_pub_hex"] as? String ?? ""
        let bPubHex  = section["b_pub_hex"] as? String ?? ""

        let aPrivBytes = try XCTUnwrap(fromHex(aPrivHex), "a_priv_hex is not valid hex")
        let bPrivBytes = try XCTUnwrap(fromHex(bPrivHex), "b_priv_hex is not valid hex")

        let aPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: aPrivBytes)
        let bPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bPrivBytes)

        // Verify published public keys match what CryptoKit derives
        if !aPubHex.isEmpty {
            let expectedAPub = try XCTUnwrap(fromHex(aPubHex), "a_pub_hex is not valid hex")
            XCTAssertEqual(aPriv.publicKey.rawRepresentation, expectedAPub,
                "a_pub from CryptoKit must match a_pub_hex in JSON (X25519 public key)")
        }
        if !bPubHex.isEmpty {
            let expectedBPub = try XCTUnwrap(fromHex(bPubHex), "b_pub_hex is not valid hex")
            XCTAssertEqual(bPriv.publicKey.rawRepresentation, expectedBPub,
                "b_pub from CryptoKit must match b_pub_hex in JSON (X25519 public key)")
        }

        // Derive PSK from both sides and verify symmetry
        let pskA = try NfcPskDerivation.derivePsk(myPriv: aPriv, peerPub: bPriv.publicKey)
        let pskB = try NfcPskDerivation.derivePsk(myPriv: bPriv, peerPub: aPriv.publicKey)
        XCTAssertEqual(pskA, pskB, "NFC PSK must be symmetric: derivePsk(a→b) == derivePsk(b→a)")
        XCTAssertEqual(pskA.count, 32, "NFC PSK must be 32 bytes")

        let computedHex = pskA.map { String(format: "%02x", $0) }.joined()
        let expectedHex = (section["expected_psk_hex"] as? String) ?? ""
        if expectedHex.isEmpty {
            print("[KAT] nfc_psk_v1 → \(computedHex) (unverified — pin this value)")
        } else {
            XCTAssertEqual(computedHex, expectedHex,
                "nfc_psk_v1: HKDF output mismatch — iOS↔Android divergence for fixed seed keys")
        }

        // Verify HKDF info label byte-for-byte
        XCTAssertEqual(
            NfcPskDerivation.hkdfInfo,
            "Q-Audion NFC Collaborative PSK v1".data(using: .utf8)!,
            "hkdfInfo must be exact UTF-8 of the spec string"
        )
    }

    // MARK: - Invariant 4: IdentityQrCode v1 checksum

    /// first 4 bytes of SHA-256(0x01 ‖ userId_utf8 ‖ pubkey).
    func test_identityQrV1_checksumKatVector() throws {
        let section = try XCTUnwrap(
            json["identity_qr_v1"] as? [String: Any],
            "identity_qr_v1 section missing from cross_platform_vectors.json"
        )
        let entries = try XCTUnwrap(
            section["vectors"] as? [[String: Any]],
            "identity_qr_v1.vectors must be an array"
        )
        XCTAssertFalse(entries.isEmpty, "identity_qr_v1.vectors must not be empty")

        for v in entries {
            let userId   = try XCTUnwrap(v["user_id"]    as? String, "Missing user_id")
            let pubkeyHex = try XCTUnwrap(v["pubkey_hex"] as? String, "Missing pubkey_hex")
            let pubkey   = try XCTUnwrap(fromHex(pubkeyHex), "pubkey_hex not valid hex")

            let identity = IdentityQrCode.Identity(userId: userId, pubkey: pubkey)

            // Encode → decode round-trip verifies the checksum internally
            let encoded = try IdentityQrCode.encode(identity: identity)
            let decoded = try IdentityQrCode.decode(string: encoded)
            XCTAssertEqual(decoded, identity, "IdentityQrCode round-trip failed for userId=\(userId)")

            // Additionally verify the encoded checksum against the JSON vector
            let expectedChecksumHex = (v["expected_checksum_hex"] as? String) ?? ""
            if !expectedChecksumHex.isEmpty {
                // Extract checksum from encoded string: "QAUDION:1:<userId>:<b64pub>:<b64cksum>"
                let parts = encoded.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
                XCTAssertEqual(parts.count, 5, "Encoded QR must have 5 colon-separated parts")
                let cksumB64 = String(parts[4])
                let cksumBytes = try XCTUnwrap(Data(base64Encoded: cksumB64),
                    "Checksum part is not valid base64: \(cksumB64)")
                let computedChecksumHex = cksumBytes.map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(computedChecksumHex, expectedChecksumHex,
                    "identity_qr_v1: checksum hex mismatch for userId=\(userId) — iOS↔Android divergence")
            } else {
                // Extract and print for pinning
                let parts = encoded.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
                if parts.count == 5, let cksumBytes = Data(base64Encoded: String(parts[4])) {
                    let computedChecksumHex = cksumBytes.map { String(format: "%02x", $0) }.joined()
                    print("[KAT] identity_qr_v1 userId=\(userId) → checksum=\(computedChecksumHex) (unverified)")
                }
            }
        }
    }

    // MARK: - Invariant 5: DeviceLinkBinaryQR blob layout

    /// Verifies [32B pubkey ‖ 4B BE length ‖ userId UTF-8 ‖ 16B auth code] layout
    /// and round-trip with deterministic inputs.
    func test_deviceLinkQR_blobLayoutAndRoundTrip() throws {
        let section = try XCTUnwrap(
            json["device_link_qr"] as? [String: Any],
            "device_link_qr section missing from cross_platform_vectors.json"
        )
        let entries = try XCTUnwrap(
            section["vectors"] as? [[String: Any]],
            "device_link_qr.vectors must be an array"
        )
        XCTAssertFalse(entries.isEmpty, "device_link_qr.vectors must not be empty")

        for v in entries {
            let pubkeyHex   = try XCTUnwrap(v["pubkey_hex"]    as? String, "Missing pubkey_hex")
            let userId      = try XCTUnwrap(v["user_id"]       as? String, "Missing user_id")
            let authCodeHex = try XCTUnwrap(v["auth_code_hex"] as? String, "Missing auth_code_hex")

            let pubkey   = try XCTUnwrap(fromHex(pubkeyHex), "pubkey_hex not valid hex")
            let authCode = try XCTUnwrap(fromHex(authCodeHex), "auth_code_hex not valid hex")

            // 1. Encode blob
            let blob = try DeviceLinkBinaryQR.encodeBlob(pubkey: pubkey, userId: userId, authCode: authCode)

            // 2. Verify expected blob hex
            let expectedBlobHex = (v["expected_blob_hex"] as? String) ?? ""
            let computedBlobHex = blob.map { String(format: "%02x", $0) }.joined()
            if expectedBlobHex.isEmpty {
                print("[KAT] device_link_qr blob=\(computedBlobHex) (unverified)")
            } else {
                XCTAssertEqual(computedBlobHex, expectedBlobHex,
                    "device_link_qr: blob hex mismatch for userId=\(userId) — layout divergence")
            }

            // 3. Verify expected blob length
            if let expectedLen = v["expected_blob_length"] as? Int {
                XCTAssertEqual(blob.count, expectedLen,
                    "device_link_qr: blob length \(blob.count) != expected \(expectedLen)")
            }

            // 4. Verify expected URL
            let url = try DeviceLinkBinaryQR.encode(pubkey: pubkey, userId: userId, authCode: authCode)
            let expectedUrl = (v["expected_url"] as? String) ?? ""
            if expectedUrl.isEmpty {
                print("[KAT] device_link_qr url=\(url.absoluteString) (unverified)")
            } else {
                XCTAssertEqual(url.absoluteString, expectedUrl,
                    "device_link_qr: URL mismatch for userId=\(userId)")
            }

            // 5. Round-trip decode
            let decoded = try DeviceLinkBinaryQR.decode(url: url)
            XCTAssertEqual(decoded.pubkey, pubkey, "DeviceLinkBinaryQR round-trip: pubkey mismatch")
            XCTAssertEqual(decoded.userId, userId, "DeviceLinkBinaryQR round-trip: userId mismatch")
            XCTAssertEqual(decoded.authCode, authCode, "DeviceLinkBinaryQR round-trip: authCode mismatch")

            // 6. Verify exact blob layout bytes
            let userIdData = Data(userId.utf8)
            XCTAssertEqual(blob.prefix(32), pubkey,
                "DeviceLinkBinaryQR: first 32 bytes must be pubkey")
            let lengthBytes = blob.subdata(in: 32..<36)
            let encodedLen = (UInt32(lengthBytes[0]) << 24) |
                             (UInt32(lengthBytes[1]) << 16) |
                             (UInt32(lengthBytes[2]) << 8)  |
                              UInt32(lengthBytes[3])
            XCTAssertEqual(Int(encodedLen), userIdData.count,
                "DeviceLinkBinaryQR: 4-byte BE length field must equal userId UTF-8 byte count")
            XCTAssertEqual(blob.suffix(16), authCode,
                "DeviceLinkBinaryQR: last 16 bytes must be auth code")
        }
    }
}
