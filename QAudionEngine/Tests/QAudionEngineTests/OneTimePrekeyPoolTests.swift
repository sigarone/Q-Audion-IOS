import XCTest
import CryptoKit
@testable import QAudionEngine

/// The two things a prekey must get right to be usable by anyone else: the
/// signature convention the server verifies, and the upload shape it accepts.
final class OneTimePrekeyPoolTests: XCTestCase {

    func testGeneratedPrekeysVerifyUnderTheServersRule() throws {
        let identity = Curve25519.Signing.PrivateKey()
        let now: Int64 = 1_700_000_000_000
        let pool = OneTimePrekeyPool()
        let keys = try pool.generate(count: 2, identityEd25519Priv: identity.rawRepresentation, nowMs: now)
        XCTAssertEqual(keys.count, 2)

        for key in keys {
            XCTAssertEqual(key.pqPub.count, 1568)
            XCTAssertEqual(key.pqPriv.count, 3168)
            XCTAssertEqual(key.x25519Pub.count, 32)
            XCTAssertEqual(key.x25519Priv.count, 32)
            XCTAssertEqual(key.sig.count, 64)
            // The server verifies Ed25519 over SHA256(pq || x || be64(ts)) —
            // NOT over the raw preimage, which is what the identity bundle's
            // self-signature uses. Both fail with the same opaque 400.
            let digest = OneTimePrekeyPool.signingDigest(
                pqPub: key.pqPub, x25519Pub: key.x25519Pub, createdAtMs: key.createdAtMs
            )
            XCTAssertTrue(identity.publicKey.isValidSignature(key.sig, for: digest))
        }
    }

    func testIdsAreRandomAcrossTheFullRangeNotACounter() throws {
        // The server keys a prekey by user_id || id with no device component,
        // so two devices counting from 1 would silently overwrite each other.
        let identity = Curve25519.Signing.PrivateKey()
        let keys = try OneTimePrekeyPool().generate(
            count: 8, identityEd25519Priv: identity.rawRepresentation, nowMs: 1
        )
        let ids = Set(keys.map { $0.prekeyId })
        XCTAssertEqual(ids.count, keys.count, "ids must not repeat within a batch")
        XCTAssertFalse(ids.contains(0), "0 is not a valid prekey id")
        XCTAssertTrue(ids.contains { $0 > 1000 }, "ids look like a counter, not random draws")
    }

    func testUploadBodyMatchesTheServerContract() throws {
        let identity = Curve25519.Signing.PrivateKey()
        let keys = try OneTimePrekeyPool().generate(
            count: 1, identityEd25519Priv: identity.rawRepresentation, nowMs: 42
        )
        let body = try OneTimePrekeyPool.uploadBody(keys)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let items = try XCTUnwrap(obj["prekeys"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        for field in ["prekey_id", "pq_pub_b64", "x25519_pub_b64", "created_at_ms", "sig_b64"] {
            XCTAssertNotNil(item[field], "missing \(field) — the server rejects the whole batch")
        }
        // Standard padded base64, not the URL alphabet.
        let pq = try XCTUnwrap(item["pq_pub_b64"] as? String)
        XCTAssertNotNil(Data(base64Encoded: pq))
        XCTAssertFalse(pq.contains("-") || pq.contains("_"))
        XCTAssertEqual(item["created_at_ms"] as? Int64 ?? Int64(item["created_at_ms"] as? Int ?? 0), 42)
    }

    func testPoolThresholdsMatchAndroid() {
        // Same numbers on both platforms, under the server's 200-per-batch and
        // 1000-per-user caps.
        XCTAssertEqual(OneTimePrekeyPool.poolTarget, 100)
        XCTAssertEqual(OneTimePrekeyPool.poolLowWater, 20)
        XCTAssertEqual(OneTimePrekeyPool.maxBatch, 200)
    }
}
