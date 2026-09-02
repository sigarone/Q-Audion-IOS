import XCTest
@testable import QAudionEngine

/// TRUST-1 residual. Parsing tests for `SigsumWireCodec` against REAL,
/// literal HTTP response bodies fetched from `https://test.sigsum.org/barreleye`
/// during development of this port (`curl`, not reconstructed) — this
/// pins the codec against the actual wire format, not just a description
/// of it in `log.md`.
///
/// ⚠️ Requires `swift test`. Authored on win32 — NOT executed in this
/// session; the GitHub Actions macOS runner is the gate.
final class SigsumWireCodecTests: XCTestCase {

    // MARK: - Literal real responses (curl https://test.sigsum.org/barreleye/..., 2026-09-02)

    private let realTreeHeadResponse = """
    size=214344
    root_hash=c007c17d03306cc6e2e4a0021d9b2db2530c12fe6404d3fae2a77c514fe37be8
    signature=0324dceafc9e1ba375f561315c584a2c78552e0bb76a6c7f43dc0c6725ef774c58b781a6863a5de6d8f18aa3e1c2fac3f4b12fb866534a0bb00e7800fa0e8b05
    cosignature=1c997261f16e6e81d13f420900a2542a4b6a049c2d996324ee5d82a90ca3360c 1788328329 3b63a4e7f76af229883a215dfd2fc146dde3c434a1207b5f146e619b503ddba1a879ae08bfad4f6c6c24dea0d2cfd55515eff02351e612b4e7538fa20c6f500c
    cosignature=f308ac5bf00ef954f70fbe5e769258203cc792469154a1b9cf3003a6286a138d 1788328329 0503c711caac5760538bd6b84d7c6051d029f64c9fcc8df99fa1190e7d47d394263a0e408488647b4f899c131df22c1e3523818b1598add127d878cdd1546a0b
    cosignature=70b861a010f25030de6ff6a5267e0b951e70c04b20ba4a3ce41e7fba7b9b7dfc 1788328329 088754c53d5d799e7b7dd8bc7e62a566e4de1306e10a3d9e2f9721b9a41f575db6bb487fe1156960372efb21a70a1ada9ef74997ed80302441d781532ff3c301
    cosignature=86b5414ae57f45c2953a074640bb5bedebad023925d4dc91a31de1350b710089 1788328329 8fef0589df49e2ef54e77126e90bd2677c13efe76ba42f3b34f6ed166ac4de01cd8610533a7bcbd177329d6cba8df5e4bab29a610ec9c4de2dff75daa412a104
    cosignature=c1d2d6935c2fb43bef395792b1f3c1dfe4072d4c6cadd05e0cc90b28d7141ed3 1788328329 2fe938244f9ae1d58ab776f7d8bd2a78fef5d1462a884cec9f6142c17e0e3f3d7c39cf3b0fe822210c70e2c8c42b1e18c15c1973feadf711edd4149908d5e109
    cosignature=3a7ad8eedc64df9e19f0d04b46b824e584281deb876cd614895b3fd9a6382f9f 1788328329 afb165f7fca815975280cf9f1fae5795f8f310e260e302164992e1e6241fba8fc4db415c7d6a4de83788ef7594903b657482eff274d7ae6316b8c2fbd90a540c
    cosignature=49c4cd6124b7c572f3354d854d50b2a4b057a750f786cf03103c09de339c4ea3 1788328329 8e5ef4f98b6036705a13cb4e053e8e4940a826d9bc66221a45317d68197533213f0753590024fcd104ab85c52222d1fc132908bfe7d7e8ed5c9c6a79cbe0cf0c
    cosignature=42351ad474b29c04187fd0c8c7670656386f323f02e9a4ef0a0055ec061ecac8 1788328329 f63058131ad2b68c1b03663d147de11cd9649b2621f34cd618a076afbef5f3329ce2a078040ff2bd3d273a98d0364d8195f50db445dd083d378b3cf11d975303
    cosignature=26983895bdf491838dd4885848670562e7b728b6efa15fd9047b5b97a9a0618f 1788328329 f09c5f14176f2d9d174d1241f3d0e0515c11bfcf5327a5ec68c5074773fa323a0dc04a61f9adc54d053bef71de6532e6894f3a7d37cd451274e25404eb0d6f0c
    cosignature=439f934edb3ca3c8f114f26ab2f728be77ed8e06289734813d2bd53484688545 1788328329 e444696726c8a7737fcdaa781e7e34492be42bd0af78c509c73a14f871a25a9fa3fd005432017e80f1e6f247969549271be9da14120f8115a84d30f735b59507
    cosignature=d960fcff859a34d677343e4789c6843e897c9ff195ea7140a6ef382566df3b65 1788328329 672296a95c46d131d0e44a1609ef5a0f8a0365c2c4d2caeb59399c64c2f77b2d82c9b23a199a4797a0175d3ebd3dc362a5d269a34bdda6359760fbe997f5e000
    cosignature=e4a6a1e4657d8d7a187cc0c20ed51055d88c72f340d29534939aee32d86b4021 1788328329 8dbd5b8d556f6b03dbc3312d6571d7b15456593dad57ad40b3ef4a2ed0b88bc46a20a1fe56a7cad0d7090338448d34cb08876ccef96bab56518eb8b99a229e0c
    """

    private let realInclusionProofResponse = """
    leaf_index=100
    node_hash=702fdde7e6c7a04a3214b9a1c5c9f8ba6f51399df19073aaee20794f857a5730
    node_hash=264039e5f7cd16b24b02b58f1d52bfff2d14e685cb2740b79a663fb085cf264e
    node_hash=ee4ddd7f46dbb6be4e3683fb3360ee23c72bc5a977824a486a681a4d985ddc3e
    """

    private let realLeavesResponse = """
    leaf=825f96ed3836785c1b5c6a274b63cca13f6aa9386bc4d02cb8e20f943490538e 6a1025ff652ca0802b34feb869c5e004943631804b185684fd10b390afe8b29ffeedc85a1d8840f46e0733979a6e483a212d3d83cbdadbdd46352bffa124e10e a7e70536317c934a2bf33a39ff6b40355c262b83dcde957a9fecc2ea6e7d9782
    leaf=32f812ab62666fb5e4d4a23fea62ad5eeef4a88b4525cb74e91e581f0f3cf762 844034ae9e8a6ebc035f6182e3828ac11c754d0dc08ab2ccc323cb70881d290e1f214eb06c39091748f742efd64c588023a24cedef34f71c994013184342860e ea1b02925c1e1daa72d7b4c6ea17f4433bc4683efe9c69ce7d29bea74887a480
    """

    private let realConsistencyProofResponse = """
    node_hash=ee4ddd7f46dbb6be4e3683fb3360ee23c72bc5a977824a486a681a4d985ddc3e
    node_hash=929c8d69656ad137399de5ad563940ba70760b532e78e3346b55a5363a6bcf33
    node_hash=17936b13505c4627e8f1d13b430b800214ee37d6a61108e322163ea876bd4358
    node_hash=b23c5875df2eaa3042ecbdd5dac8f8b514c64c5850cc34b2d16aa02a78471c4f
    node_hash=6eb9077173babf81ee0bd41fb737ae2271fbc33e1f70312281401c221d0bfd3d
    node_hash=426f8b3c986e033076b8d1698bbd0b3c2dc85560e260eea3effa14b9cd5fea3c
    node_hash=92a69743006bfb3f404e0a7f6f26699d8715012de70623ecf8203046450e7a51
    """

    // MARK: - get-tree-head (cosigned)

    func test_parseCosignedTreeHead_realResponse() throws {
        let cth = try SigsumWireCodec.parseCosignedTreeHead(realTreeHeadResponse)
        XCTAssertEqual(cth.signedTreeHead.treeHead.size, 214_344)
        XCTAssertEqual(SigsumHex.encode(cth.signedTreeHead.treeHead.rootHash), "c007c17d03306cc6e2e4a0021d9b2db2530c12fe6404d3fae2a77c514fe37be8")
        XCTAssertEqual(cth.signedTreeHead.signature.count, 64)
        XCTAssertEqual(cth.cosignatures.count, 12)
        for cs in cth.cosignatures {
            XCTAssertEqual(cs.witnessKeyHash.count, 32)
            XCTAssertEqual(cs.signature.count, 64)
            XCTAssertEqual(cs.timestamp, 1_788_328_329)
        }
    }

    func test_parseCosignedTreeHead_rejectsDuplicateKeyHash() {
        let duplicated = realTreeHeadResponse + "\ncosignature=1c997261f16e6e81d13f420900a2542a4b6a049c2d996324ee5d82a90ca3360c 1788328329 3b63a4e7f76af229883a215dfd2fc146dde3c434a1207b5f146e619b503ddba1a879ae08bfad4f6c6c24dea0d2cfd55515eff02351e612b4e7538fa20c6f500c"
        XCTAssertThrowsError(try SigsumWireCodec.parseCosignedTreeHead(duplicated))
    }

    func test_parseTreeHead_uncosignedShape() throws {
        let th = try SigsumWireCodec.parseTreeHead("size=42\nroot_hash=" + String(repeating: "ab", count: 32))
        XCTAssertEqual(th.size, 42)
        XCTAssertEqual(th.rootHash.count, 32)
    }

    func test_parseTreeHead_rejectsMissingField() {
        XCTAssertThrowsError(try SigsumWireCodec.parseTreeHead("size=42"))
    }

    // MARK: - get-inclusion-proof

    func test_parseInclusionProof_realResponse() throws {
        let proof = try SigsumWireCodec.parseInclusionProof(realInclusionProofResponse)
        XCTAssertEqual(proof.leafIndex, 100)
        XCTAssertEqual(proof.path.count, 3)
        XCTAssertEqual(SigsumHex.encode(proof.path[0]), "702fdde7e6c7a04a3214b9a1c5c9f8ba6f51399df19073aaee20794f857a5730")
    }

    // MARK: - get-consistency-proof

    func test_parseConsistencyProof_realResponse() throws {
        let proof = try SigsumWireCodec.parseConsistencyProof(realConsistencyProofResponse)
        XCTAssertEqual(proof.path.count, 7)
    }

    // MARK: - get-leaves

    func test_parseLeaves_realResponse() throws {
        let leaves = try SigsumWireCodec.parseLeaves(realLeavesResponse)
        XCTAssertEqual(leaves.count, 2)
        for leaf in leaves {
            XCTAssertTrue(leaf.isWellFormed)
            XCTAssertEqual(leaf.toBinary().count, 128)
        }
        XCTAssertEqual(SigsumHex.encode(leaves[0].checksum), "825f96ed3836785c1b5c6a274b63cca13f6aa9386bc4d02cb8e20f943490538e")
    }

    func test_parseLeaves_rejectsEmptyResponse() {
        XCTAssertThrowsError(try SigsumWireCodec.parseLeaves(""))
    }

    // MARK: - add-leaf request encoding

    func test_encodeAddLeafRequest_layout() {
        let message = Data(repeating: 0x11, count: 32)
        let signature = Data(repeating: 0x22, count: 64)
        let publicKey = Data(repeating: 0x33, count: 32)
        let body = SigsumWireCodec.encodeAddLeafRequest(message: message, signature: signature, publicKey: publicKey)
        let text = String(data: body, encoding: .utf8)!
        XCTAssertTrue(text.contains("message=" + String(repeating: "11", count: 32)))
        XCTAssertTrue(text.contains("signature=" + String(repeating: "22", count: 64)))
        XCTAssertTrue(text.contains("public_key=" + String(repeating: "33", count: 32)))
    }

    // MARK: - Proof-bundle round trip (size > 1: three blocks)

    func test_proofBundle_roundTrip_sizeGreaterThanOne() throws {
        let bundle = SigsumProofBundle(
            version: 2,
            logKeyHash: Data(repeating: 0xA1, count: 32),
            leafKeyHash: Data(repeating: 0xA2, count: 32),
            leafSignature: Data(repeating: 0xA3, count: 64),
            cosignedTreeHead: SigsumCosignedTreeHead(
                signedTreeHead: SigsumSignedTreeHead(treeHead: SigsumTreeHead(size: 4, rootHash: Data(repeating: 0xA4, count: 32)), signature: Data(repeating: 0xA5, count: 64)),
                cosignatures: [SigsumCosignature(witnessKeyHash: Data(repeating: 0xA6, count: 32), timestamp: 123, signature: Data(repeating: 0xA7, count: 64))]
            ),
            inclusionProof: SigsumInclusionProof(leafIndex: 2, path: [Data(repeating: 0xA8, count: 32), Data(repeating: 0xA9, count: 32)])
        )
        let encoded = SigsumWireCodec.encodeProofBundle(bundle)
        let decoded = try SigsumWireCodec.parseProofBundle(encoded)
        XCTAssertEqual(decoded, bundle)
    }

    // MARK: - Proof-bundle: size <= 1 omits the third block

    func test_proofBundle_roundTrip_sizeOne_noInclusionBlock() throws {
        let bundle = SigsumProofBundle(
            version: 2,
            logKeyHash: Data(repeating: 0xB1, count: 32),
            leafKeyHash: Data(repeating: 0xB2, count: 32),
            leafSignature: Data(repeating: 0xB3, count: 64),
            cosignedTreeHead: SigsumCosignedTreeHead(
                signedTreeHead: SigsumSignedTreeHead(treeHead: SigsumTreeHead(size: 1, rootHash: Data(repeating: 0xB4, count: 32)), signature: Data(repeating: 0xB5, count: 64)),
                cosignatures: []
            ),
            inclusionProof: nil
        )
        let encoded = SigsumWireCodec.encodeProofBundle(bundle)
        XCTAssertFalse(encoded.contains("leaf_index="))
        let decoded = try SigsumWireCodec.parseProofBundle(encoded)
        XCTAssertEqual(decoded, bundle)
    }

    func test_proofBundle_missingInclusionBlockForSizeGreaterThanOne_rejected() {
        let malformed = """
        version=2
        log=\(String(repeating: "c1", count: 32))
        leaf=\(String(repeating: "c2", count: 32)) \(String(repeating: "c3", count: 64))

        size=4
        root_hash=\(String(repeating: "c4", count: 32))
        signature=\(String(repeating: "c5", count: 64))
        """
        XCTAssertThrowsError(try SigsumWireCodec.parseProofBundle(malformed))
    }

    func test_proofBundle_rejectsUnsupportedVersion() {
        let wrongVersion = """
        version=1
        log=\(String(repeating: "c1", count: 32))
        leaf=\(String(repeating: "c2", count: 32)) \(String(repeating: "c3", count: 64))

        size=1
        root_hash=\(String(repeating: "c4", count: 32))
        signature=\(String(repeating: "c5", count: 64))
        """
        XCTAssertThrowsError(try SigsumWireCodec.parseProofBundle(wrongVersion))
    }
}
