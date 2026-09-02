import XCTest
import CryptoKit
@testable import QAudionEngine

/// TRUST-1 residual. Mirrors Android's
/// `SigsumProofTest.computeLeafIsDeterministicAndDomainSeparated` (the same
/// preimage layout, ported byte-for-byte — see `SigsumLeaf`'s kdoc) plus a
/// hand-computed byte-layout KAT so the field order/length is pinned, not
/// just "changes when inputs change".
///
/// ⚠️ Requires `swift test` (CryptoKit). Authored on win32, which cannot run
/// CryptoKit locally — NOT executed in this session; the GitHub Actions
/// macOS runner is the gate (see `ios-preflight`/`engine-tests.yml`), same
/// as every other Crypto test in this target.
final class SigsumLeafTests: XCTestCase {

    private func fixedBytes(_ n: Int, seed: UInt8) -> Data {
        Data((0..<n).map { UInt8((Int($0) + Int(seed)) & 0xFF) })
    }

    // MARK: - Determinism + domain separation (mirrors Android's KAT-guard test)

    func test_computeLeaf_deterministicForSameInput() throws {
        let uuid = fixedBytes(16, seed: 0x01)
        let pubA = fixedBytes(32, seed: 0x02)
        let a1 = try SigsumLeaf.computeLeaf(userUuidRaw: uuid, ed25519Pub: pubA, createdAtMs: 1_745_000_000_000)
        let a2 = try SigsumLeaf.computeLeaf(userUuidRaw: uuid, ed25519Pub: pubA, createdAtMs: 1_745_000_000_000)
        XCTAssertEqual(a1, a2, "computeLeaf must be a pure function of its inputs")
        XCTAssertEqual(a1.count, 32)
    }

    func test_computeLeaf_differsWhenPubKeyDiffers() throws {
        let uuid = fixedBytes(16, seed: 0x01)
        let pubA = fixedBytes(32, seed: 0x02)
        let pubB = fixedBytes(32, seed: 0x03)
        let a = try SigsumLeaf.computeLeaf(userUuidRaw: uuid, ed25519Pub: pubA, createdAtMs: 1_745_000_000_000)
        let b = try SigsumLeaf.computeLeaf(userUuidRaw: uuid, ed25519Pub: pubB, createdAtMs: 1_745_000_000_000)
        XCTAssertNotEqual(a, b)
    }

    func test_computeLeaf_differsWhenCreatedAtDiffers() throws {
        let uuid = fixedBytes(16, seed: 0x01)
        let pub = fixedBytes(32, seed: 0x02)
        let a = try SigsumLeaf.computeLeaf(userUuidRaw: uuid, ed25519Pub: pub, createdAtMs: 1_745_000_000_000)
        let b = try SigsumLeaf.computeLeaf(userUuidRaw: uuid, ed25519Pub: pub, createdAtMs: 1_745_000_000_001)
        XCTAssertNotEqual(a, b, "a no-op republish at a different timestamp must hash to a fresh message")
    }

    func test_computeLeaf_differsWhenUuidDiffers() throws {
        let uuidA = fixedBytes(16, seed: 0x01)
        let uuidB = fixedBytes(16, seed: 0x09)
        let pub = fixedBytes(32, seed: 0x02)
        let a = try SigsumLeaf.computeLeaf(userUuidRaw: uuidA, ed25519Pub: pub, createdAtMs: 1_745_000_000_000)
        let b = try SigsumLeaf.computeLeaf(userUuidRaw: uuidB, ed25519Pub: pub, createdAtMs: 1_745_000_000_000)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Byte-layout KAT (pins field order/length, independent of CryptoKit's SHA-256 being trusted blindly)

    func test_computeLeaf_matchesHandComputedPreimage() throws {
        let uuid = fixedBytes(16, seed: 0x10)
        let pub = fixedBytes(32, seed: 0x20)
        let createdAtMs: Int64 = 1_700_000_000_123

        var expectedPreimage = Data("qaudion-kt-leaf-v1 ".utf8)
        XCTAssertEqual(expectedPreimage.count, 19, "domain tag must be exactly 19 bytes (18 ASCII + trailing space)")
        expectedPreimage.append(uuid)
        expectedPreimage.append(pub)
        var be = UInt64(bitPattern: createdAtMs).bigEndian
        expectedPreimage.append(withUnsafeBytes(of: &be) { Data($0) })
        XCTAssertEqual(expectedPreimage.count, 75)

        let expected = Data(SHA256.hash(data: expectedPreimage))
        let actual = try SigsumLeaf.computeLeaf(userUuidRaw: uuid, ed25519Pub: pub, createdAtMs: createdAtMs)
        XCTAssertEqual(actual, expected)
    }

    // MARK: - Length validation (fail-closed on malformed input)

    func test_computeLeaf_rejectsWrongLengthUuid() {
        XCTAssertThrowsError(try SigsumLeaf.computeLeaf(userUuidRaw: fixedBytes(15, seed: 0), ed25519Pub: fixedBytes(32, seed: 0), createdAtMs: 0)) { error in
            XCTAssertEqual(error as? SigsumLeaf.LeafError, .wrongLength(field: "userUuidRaw", expected: 16, got: 15))
        }
    }

    func test_computeLeaf_rejectsWrongLengthPubKey() {
        XCTAssertThrowsError(try SigsumLeaf.computeLeaf(userUuidRaw: fixedBytes(16, seed: 0), ed25519Pub: fixedBytes(31, seed: 0), createdAtMs: 0)) { error in
            XCTAssertEqual(error as? SigsumLeaf.LeafError, .wrongLength(field: "ed25519Pub", expected: 32, got: 31))
        }
    }

    // MARK: - Foundation.UUID convenience overload agrees with the raw-bytes primary API

    func test_uuidOverload_matchesRawBytesOverload() throws {
        // A UUID whose canonical string form makes the expected byte layout
        // easy to eyeball: 00010203-0405-0607-0809-0A0B0C0D0E0F.
        let uuid = UUID(uuidString: "00010203-0405-0607-0809-0A0B0C0D0E0F")!
        let expectedRaw = Data((0..<16).map { UInt8($0) })
        XCTAssertEqual(SigsumLeaf.rawBytes(of: uuid), expectedRaw)

        let pub = fixedBytes(32, seed: 0x40)
        let viaUuid = try SigsumLeaf.computeLeaf(userUuid: uuid, ed25519Pub: pub, createdAtMs: 42)
        let viaRaw = try SigsumLeaf.computeLeaf(userUuidRaw: expectedRaw, ed25519Pub: pub, createdAtMs: 42)
        XCTAssertEqual(viaUuid, viaRaw)
    }
}
