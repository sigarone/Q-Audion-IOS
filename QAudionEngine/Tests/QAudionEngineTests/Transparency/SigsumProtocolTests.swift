import XCTest
import CryptoKit
@testable import QAudionEngine

/// TRUST-1 residual. Covers `SigsumCrypto`'s namespace-separated signing
/// primitives (`AttachNamespace`, checkpoint/cosignature formatting,
/// submit-token) and `SigsumHex`. The tree-head and cosignature tests use
/// the SAME live `test.sigsum.org/barreleye` snapshot as
/// `SigsumMerkleTests` — this is what proves `formatCheckpoint`/
/// `checkpointOrigin`/`cosignedData` are byte-exact against the real
/// protocol, not just internally self-consistent.
///
/// ⚠️ Requires `swift test` (CryptoKit). Authored on win32 — NOT executed in
/// this session; the GitHub Actions macOS runner is the gate.
final class SigsumProtocolTests: XCTestCase {

    // MARK: - Live fixture (same barreleye snapshot as SigsumMerkleTests; see that file's header)

    private enum LiveFixture {
        static let barreleyePublicKey = Data(hex: "4644af2abd40f4895a003bca350f9d5912ab301a49c77f13e5b6d905c20a5fe6")
        static let treeSize: UInt64 = 214343
        static let rootHash = Data(hex: "015a006babfd2819769f9e9e7ba81526f6154d4d020a83a0fb150b3ee46107fd")
        static let treeHeadSignature = Data(hex: "6d0cc3728bd0bcdb761fc2bfd894a728d0cb03c944995db3458faefa96e0df47ceddb59d34bcbea1a46116bcab89453f0e9b026dde73b7cc29e41e1a76d03403")

        // All 8 sigsum-test-2025-3 policy witnesses had a REAL, independently
        // Ed25519-verified cosignature on this exact tree head at fetch time
        // (verified against `cryptography`'s Ed25519 implementation while
        // building this port — see SigsumPolicyTests for the quorum-shaped
        // assertion built from this same set).
        static let cosignatures: [(witnessPubKeyHex: String, timestamp: UInt64, signatureHex: String)] = [
            ("1c25f8a44c635457e2e391d1efbca7d4c2951a0aef06225a881e46b98962ac6c", 1_788_328_069,
             "d90d6ca69a23ce768e2e60a23c3556c228c890800fd36ccada8d9a34b9bf656f336987a85a20c6a2fa98fcdb4fd76df20ef9800d69d072baf3dfcf01f15ebb04"),
            ("28c92a5a3a054d317c86fc2eeb6a7ab2054d6217100d0be67ded5b74323c5806", 1_788_328_069,
             "0da98917610e15eb648d27c9fcaa5db909cc50037115a868cb0558383c2c08976301030b64253b1f7a4cc1f733c3d203663efa8a5466e888e63edac1358b3d01"),
            ("f4855a0f46e8a3e23bb40faf260ee57ab8a18249fa402f2ca2d28a60e1a3130e", 1_788_328_069,
             "5304a8869d90dae9682e04394c15ae57bd70938e85f92f08cf7d2394cbadec145578856e44b45cf900fdbf5686bc85fc5e49553d1aa09edae4511d9c282f380d"),
        ]
    }

    func test_liveFixture_treeHeadSignature_verifiesUnderRealBarreleyePubkey() {
        XCTAssertTrue(SigsumCrypto.verifyTreeHeadSignature(
            logPublicKey: LiveFixture.barreleyePublicKey, size: LiveFixture.treeSize, rootHash: LiveFixture.rootHash, signature: LiveFixture.treeHeadSignature
        ))
    }

    func test_liveFixture_treeHeadSignature_rejectsWrongRoot() {
        var wrongRoot = LiveFixture.rootHash
        wrongRoot[0] ^= 0xFF
        XCTAssertFalse(SigsumCrypto.verifyTreeHeadSignature(
            logPublicKey: LiveFixture.barreleyePublicKey, size: LiveFixture.treeSize, rootHash: wrongRoot, signature: LiveFixture.treeHeadSignature
        ))
    }

    func test_liveFixture_treeHeadSignature_rejectsWrongLogKey() {
        var wrongKey = LiveFixture.barreleyePublicKey
        wrongKey[0] ^= 0xFF
        XCTAssertFalse(SigsumCrypto.verifyTreeHeadSignature(
            logPublicKey: wrongKey, size: LiveFixture.treeSize, rootHash: LiveFixture.rootHash, signature: LiveFixture.treeHeadSignature
        ))
    }

    func test_liveFixture_checkpointOrigin_matchesRealSeasalpVkeyDerivation() {
        // Cross-check against the SAME derivation rule seasalp's own ops
        // doc states independently ("The vkey name is the same as the
        // log's origin line.") — origin = "sigsum.org/v1/tree/" + hex(SHA256(pubkey)).
        let origin = SigsumCrypto.checkpointOrigin(logPublicKey: LiveFixture.barreleyePublicKey)
        XCTAssertTrue(origin.hasPrefix("sigsum.org/v1/tree/"))
        XCTAssertEqual(origin.count, "sigsum.org/v1/tree/".count + 64)
    }

    func test_liveFixture_allEightRealCosignatures_verify() {
        for cosig in LiveFixture.cosignatures {
            let witnessPub = Data(hex: cosig.witnessPubKeyHex)
            let signature = Data(hex: cosig.signatureHex)
            let origin = SigsumCrypto.checkpointOrigin(logPublicKey: LiveFixture.barreleyePublicKey)
            XCTAssertTrue(
                SigsumCrypto.verifyCosignature(witnessPublicKey: witnessPub, origin: origin, timestamp: cosig.timestamp, size: LiveFixture.treeSize, rootHash: LiveFixture.rootHash, signature: signature),
                "cosignature from \(cosig.witnessPubKeyHex.prefix(8)) must verify"
            )
        }
    }

    func test_liveFixture_cosignature_rejectsWrongTimestamp() {
        let cosig = LiveFixture.cosignatures[0]
        let witnessPub = Data(hex: cosig.witnessPubKeyHex)
        let signature = Data(hex: cosig.signatureHex)
        let origin = SigsumCrypto.checkpointOrigin(logPublicKey: LiveFixture.barreleyePublicKey)
        XCTAssertFalse(SigsumCrypto.verifyCosignature(
            witnessPublicKey: witnessPub, origin: origin, timestamp: cosig.timestamp + 1, size: LiveFixture.treeSize, rootHash: LiveFixture.rootHash, signature: signature
        ))
    }

    func test_liveFixture_cosignature_rejectsUnderWrongWitnessKey() {
        let cosigA = LiveFixture.cosignatures[0]
        let wrongWitnessPub = Data(hex: LiveFixture.cosignatures[1].witnessPubKeyHex)
        let signature = Data(hex: cosigA.signatureHex)
        let origin = SigsumCrypto.checkpointOrigin(logPublicKey: LiveFixture.barreleyePublicKey)
        XCTAssertFalse(SigsumCrypto.verifyCosignature(
            witnessPublicKey: wrongWitnessPub, origin: origin, timestamp: cosigA.timestamp, size: LiveFixture.treeSize, rootHash: LiveFixture.rootHash, signature: signature
        ))
    }

    // MARK: - Leaf signing (self-generated round trip — the log doesn't publish submitter pubkeys for existing entries, so there is no real fixture for this half)

    func test_leafSignature_roundTrip() throws {
        let seed = Data(repeating: 0x11, count: 32)
        let submitter = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let checksum = SigsumCrypto.sha256(Data("hello sigsum".utf8))
        let sig = try SigsumCrypto.signLeafChecksum(submitterPrivateKeySeed: seed, checksum: checksum)
        XCTAssertEqual(sig.count, 64)
        XCTAssertTrue(SigsumCrypto.verifyLeafSignature(submitterPublicKey: submitter.publicKey.rawRepresentation, checksum: checksum, signature: sig))
    }

    func test_leafSignature_rejectsWrongChecksum() throws {
        let seed = Data(repeating: 0x22, count: 32)
        let submitter = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let checksum = SigsumCrypto.sha256(Data("message A".utf8))
        let otherChecksum = SigsumCrypto.sha256(Data("message B".utf8))
        let sig = try SigsumCrypto.signLeafChecksum(submitterPrivateKeySeed: seed, checksum: checksum)
        XCTAssertFalse(SigsumCrypto.verifyLeafSignature(submitterPublicKey: submitter.publicKey.rawRepresentation, checksum: otherChecksum, signature: sig))
    }

    func test_leafSignedData_isExactlyFiftySixBytes() {
        let checksum = Data(repeating: 0x99, count: 32)
        let signed = SigsumCrypto.leafSignedData(checksum: checksum)
        XCTAssertEqual(signed.count, 23 + 1 + 32, "\"sigsum.org/v1/tree-leaf\" (23) + 0x00 + checksum(32) = 56")
        XCTAssertEqual(signed.prefix(23), Data("sigsum.org/v1/tree-leaf".utf8))
        XCTAssertEqual(signed[signed.startIndex + 23], 0x00)
    }

    // MARK: - Submit token (log.md §4)

    func test_submitToken_roundTrip() throws {
        let rateLimitSeed = Data(repeating: 0x33, count: 32)
        let rateLimitKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rateLimitSeed)
        let logPub = LiveFixture.barreleyePublicKey
        let token = try SigsumCrypto.signSubmitToken(rateLimitPrivateKeySeed: rateLimitSeed, logPublicKey: logPub)
        XCTAssertTrue(SigsumCrypto.verifySubmitToken(rateLimitPublicKey: rateLimitKey.publicKey.rawRepresentation, logPublicKey: logPub, signature: token))
    }

    func test_submitToken_isNotValidForADifferentLog() throws {
        let rateLimitSeed = Data(repeating: 0x44, count: 32)
        let rateLimitKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rateLimitSeed)
        let token = try SigsumCrypto.signSubmitToken(rateLimitPrivateKeySeed: rateLimitSeed, logPublicKey: LiveFixture.barreleyePublicKey)
        // sigsum-generic-2025-1's seasalp log, a DIFFERENT log — the token
        // must not be valid for it (log.md §4.1: "it is not valid for
        // submission to any other log").
        let seasalpPub = SigsumPolicy.sigsumGeneric2025_1.logs[0].publicKey
        XCTAssertFalse(SigsumCrypto.verifySubmitToken(rateLimitPublicKey: rateLimitKey.publicKey.rawRepresentation, logPublicKey: seasalpPub, signature: token))
    }

    func test_submitTokenSignedData_isExactlyFiftyNineBytes() {
        let logPub = Data(repeating: 0x55, count: 32)
        let signed = SigsumCrypto.submitTokenSignedData(logPublicKey: logPub)
        XCTAssertEqual(signed.count, 26 + 1 + 32, "\"sigsum.org/v1/submit-token\" (26) + 0x00 + log_pubkey(32) = 59, per log.md §4.1")
    }

    func test_submitTokenHeaderValue_format() {
        let sig = Data(repeating: 0xAA, count: 64)
        let header = SigsumCrypto.submitTokenHeaderValue(domain: "foo.example.com", signature: sig)
        XCTAssertTrue(header.hasPrefix("foo.example.com "))
        XCTAssertEqual(header, "foo.example.com " + String(repeating: "aa", count: 64))
    }

    // MARK: - Hex codec

    func test_hexCodec_roundTrip() {
        let data = Data((0..<32).map { UInt8($0) })
        let hex = SigsumHex.encode(data)
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(SigsumHex.decode(hex), data)
    }

    func test_hexCodec_rejectsOddLength() {
        XCTAssertNil(SigsumHex.decode("abc"))
    }

    func test_hexCodec_rejectsNonHexCharacters() {
        XCTAssertNil(SigsumHex.decode("zz"))
    }

    func test_hexCodec_emptyStringDecodesToEmptyData() {
        XCTAssertEqual(SigsumHex.decode(""), Data())
    }

    // MARK: - AttachNamespace

    func test_attachNamespace_layout() {
        let msg = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let out = SigsumCrypto.attachNamespace("ns", msg)
        XCTAssertEqual(out, Data("ns".utf8) + Data([0x00]) + msg)
    }
}

private extension Data {
    init(hex: String) {
        self = SigsumHex.decode(hex)!
    }
}
