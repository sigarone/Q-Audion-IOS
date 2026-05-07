import XCTest
@testable import QAudionEngine

/// Phase 2 of the 2026-05-06 session-renewal design — iOS mirror of
/// the Android `DomainTagDisjointnessTest` and the Go server-side
/// `TestDomainTagDisjointness`. Adding a sixth use of the device
/// Ed25519 key REQUIRES extending the TAGS array here AND the
/// corresponding tests on every other client + server.
final class DeviceRenewBlobTests: XCTestCase {

    private let allTags = [
        "qaudion-device-link/v1",
        "qaudion-identity-bundle-v1",
        "qaudion-kms-prebootstrap-v1",
        DeviceRenewBlob.domainTagDeviceRenew,  // QAUDION-DEVICE-RENEW-v1
        DeviceRenewBlob.domainTagDeviceRevoke, // QAUDION-REVOKE-v1
    ]

    func testNoTagIsAPrefixOfAnother() {
        for i in 0..<allTags.count {
            for j in 0..<allTags.count where i != j {
                let a = allTags[i]
                let b = allTags[j]
                XCTAssertFalse(
                    a.hasPrefix(b) || b.hasPrefix(a),
                    "domain tag '\(b)' is a prefix of '\(a)' — cross-protocol forgery risk"
                )
            }
        }
    }

    func testRenewBlobStartsWithUppercaseTagThenNul() {
        let nonce = Data(count: 32)
        let blob = DeviceRenewBlob.buildRenew(
            serverId: "qaudion-prod",
            deviceId: "dev-1",
            nonce: nonce,
            epochMs: 0
        )
        let tag = Data(DeviceRenewBlob.domainTagDeviceRenew.utf8)
        XCTAssertEqual(blob.prefix(tag.count), tag)
        XCTAssertEqual(blob[tag.count], 0)
    }

    /// Same vector as the Go `TestBuildRenewBlob_HappyPath` and the
    /// Android `renew_blob_byte_layout_is_stable` and the Desktop
    /// `renew blob byte layout matches the Go server vector` —
    /// drift in any one of these means the wire is broken.
    func testRenewBlobByteVectorMatchesAllPlatforms() {
        let nonce = Data(repeating: 0xAB, count: 32)
        let blob = DeviceRenewBlob.buildRenew(
            serverId: "qaudion-prod",
            deviceId: "device-42",
            nonce: nonce,
            epochMs: 0x0123_4567_89ab_cdef
        )
        let expectedLen =
            DeviceRenewBlob.domainTagDeviceRenew.utf8.count + 1 +
            "qaudion-prod".utf8.count + 1 +
            "device-42".utf8.count + 1 +
            32 + 1 + 8
        XCTAssertEqual(blob.count, expectedLen)
        let tail = blob.suffix(8)
        XCTAssertEqual(Array(tail), [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef])
    }

    func testRevokeBlobStartsWithUppercaseTagThenNul() {
        let blob = DeviceRenewBlob.buildRevoke(
            requestingDeviceId: "dev-A",
            targetDeviceId: "dev-B",
            nonce: Data(count: 32),
            epochMs: 1
        )
        let tag = Data(DeviceRenewBlob.domainTagDeviceRevoke.utf8)
        XCTAssertEqual(blob.prefix(tag.count), tag)
        XCTAssertEqual(blob[tag.count], 0)
    }

    func testHexRoundtripIsLowercaseAndDeterministic() {
        let bytes: [UInt8] = [0xde, 0xad, 0xbe, 0xef]
        let hex = DeviceRenewBlob.hexEncode(Data(bytes))
        XCTAssertEqual(hex, "deadbeef")
        XCTAssertEqual(Array(DeviceRenewBlob.hexDecode(hex)!), bytes)
    }
}
