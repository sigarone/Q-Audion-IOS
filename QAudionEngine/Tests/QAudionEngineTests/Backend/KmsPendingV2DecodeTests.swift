import XCTest
@testable import QAudionEngine

/// §3.1 v2 transport-field decode. The `PendingKey` DTO must carry the
/// v2 fields (key_type/earbud_id/key_class/key_epoch/slot_id/txn_id/
/// supersedes/server_nonce/user_id/device_id/proto_version) AND remain
/// version-tolerant: a legacy v1 entry (none of the new fields) must
/// still decode, with `proto_version` defaulting to 1.
final class KmsPendingV2DecodeTests: XCTestCase {
    func testDecodesV2Entry() throws {
        let json = """
        {"keys":[{
          "key_id":"11111111-1111-1111-1111-111111111111",
          "key_name":"slot-a","fingerprint":"ab","status":"delivered",
          "encrypted_package":"AAAA","ephemeral_pubkey":"","nonce":"",
          "key_type":"sovereign",
          "earbud_id":"22222222-2222-2222-2222-222222222222",
          "key_class":"hw_only","key_epoch":"42",
          "slot_id":"33333333-3333-3333-3333-333333333333",
          "txn_id":"44444444-4444-4444-4444-444444444444",
          "supersedes":"55555555-5555-5555-5555-555555555555",
          "server_nonce":"AAECAwQFBgcICQoLDA0ODw==",
          "user_id":"66666666-6666-6666-6666-666666666666",
          "device_id":"77777777-7777-7777-7777-777777777777",
          "proto_version":2
        }]}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(PendingKeysResponse_TestProxy.self, from: json)
        let k = resp.keys[0]
        XCTAssertEqual(k.keyType, "sovereign")
        XCTAssertEqual(k.keyClass, "hw_only")
        XCTAssertEqual(k.keyEpoch, "42")
        XCTAssertEqual(k.slotId, "33333333-3333-3333-3333-333333333333")
        XCTAssertEqual(k.txnId, "44444444-4444-4444-4444-444444444444")
        XCTAssertEqual(k.earbudId, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(k.supersedes, "55555555-5555-5555-5555-555555555555")
        XCTAssertEqual(k.userId, "66666666-6666-6666-6666-666666666666")
        XCTAssertEqual(k.deviceId, "77777777-7777-7777-7777-777777777777")
        XCTAssertEqual(k.protoVersion, 2)
        XCTAssertNotNil(k.serverNonce)
    }

    func testDecodesLegacyV1EntryWithDefaults() throws {
        let json = """
        {"keys":[{
          "key_id":"11111111-1111-1111-1111-111111111111",
          "key_name":"slot-a","fingerprint":"ab","status":"pending",
          "encrypted_package":"AAAA","ephemeral_pubkey":"","nonce":""
        }]}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(PendingKeysResponse_TestProxy.self, from: json)
        let k = resp.keys[0]
        XCTAssertNil(k.keyClass)
        XCTAssertNil(k.keyEpoch)
        XCTAssertNil(k.txnId)
        XCTAssertNil(k.userId)
        XCTAssertNil(k.deviceId)
        XCTAssertEqual(k.protoVersion, 1, "absent proto_version defaults to 1")
    }
}

// Test proxy mirrors the private PendingKeysResponse so the test can decode the wrapper.
struct PendingKeysResponse_TestProxy: Codable { let keys: [PendingKey] }
