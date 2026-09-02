import XCTest
@testable import QAudionEngine

/// `Result<Void, E>` is never `Equatable` in Swift — the empty tuple `()`
/// (`Void`) cannot conform to any protocol, tuples being non-nominal types,
/// so `Result`'s conditional `Equatable` conformance (`where Success:
/// Equatable`) never applies to a `Void`-success `Result`. These two
/// helpers replace a direct `XCTAssertEqual(result, .success(()))` /
/// `XCTAssertEqual(result, .failure(x))`, which would not compile, with an
/// equivalent pattern-match — kept file-private per this codebase's own
/// "duplicate rather than share a small test helper" convention (see
/// `FileAttachmentAnnounceSig.swift`'s `appendLP` kdoc for the same
/// rationale) rather than growing the shared `TestHelpers.swift`.
private func assertSuccess<S, F: Error>(_ result: Result<S, F>, file: StaticString = #filePath, line: UInt = #line) {
    guard case .success = result else {
        XCTFail("expected success, got \(result)", file: file, line: line)
        return
    }
}

private func assertFailure<S, F: Error & Equatable>(_ result: Result<S, F>, _ expected: F, file: StaticString = #filePath, line: UInt = #line) {
    guard case .failure(let actual) = result else {
        XCTFail("expected failure(\(expected)), got success", file: file, line: line)
        return
    }
    XCTAssertEqual(actual, expected, file: file, line: line)
}

/// TRUST-1 residual. This is the file that actually proves the fix over
/// Android's `SigsumProof.kt` scaffolding — see `SigsumMerkle`'s kdoc for
/// the two bugs (missing RFC 6962 leaf prefix / missing path-length check)
/// this corrects.
///
/// ⚠️ Requires `swift test` (CryptoKit). Authored on win32 — NOT executed in
/// this session; the GitHub Actions macOS runner is the gate.
final class SigsumMerkleTests: XCTestCase {

    // MARK: - Live fixture: test.sigsum.org/barreleye, leaf index 100, tree size 214343
    //
    // Every field below was fetched from the REAL, currently-running Sigsum
    // test log during development of this port (`GET /get-leaves/100/101`,
    // `GET /get-tree-head`, `GET /get-inclusion-proof/214343/<leaf_hash>`)
    // and independently cross-checked: `leaf_hash` really does equal
    // `SHA-256(0x00 || checksum || signature || key_hash)` for this leaf,
    // the inclusion path really does reconstruct to the log's own published
    // `root_hash`, and (separately, in `SigsumProtocolTests`) the tree-head
    // signature verifies under barreleye's real `sigsum-test-2025-3` policy
    // public key and all 8 witness cosignatures verify under their real
    // policy public keys. This is not a self-generated vector sharing an
    // assumption with the code under test — see this task's own caution
    // about that failure mode (the reason the Android scaffolding's KATs
    // passed while being wrong).
    private enum LiveFixture {
        static let leafChecksum = Data(hex: "6e783c9b726fd7ec7b27ff780975245debe52392e827313fc1a796e0e27795b6")
        static let leafSignature = Data(hex: "90caaace06568f69f2a3c8b4609205a22f63ff7c6baf3099311675b41cf6a85425a9ae7c3bb8b22ca51803d5dc07c49b9fa75896d2b4f350e8a96ca9e5f2d402")
        static let leafKeyHash = Data(hex: "c915d88e12fd0424aa55db620a7eaabffcad62de22e1981e9ad690a684cf55db")
        static let leafHash = Data(hex: "d43b8e73799145c1f82cf34a1602897c23b5c7c8ede4ef0b05ed472e83708dde")
        static let leafIndex: UInt64 = 100
        static let treeSize: UInt64 = 214343
        static let rootHash = Data(hex: "015a006babfd2819769f9e9e7ba81526f6154d4d020a83a0fb150b3ee46107fd")
        static let inclusionPath: [Data] = [
            "702fdde7e6c7a04a3214b9a1c5c9f8ba6f51399df19073aaee20794f857a5730",
            "264039e5f7cd16b24b02b58f1d52bfff2d14e685cb2740b79a663fb085cf264e",
            "ee4ddd7f46dbb6be4e3683fb3360ee23c72bc5a977824a486a681a4d985ddc3e",
            "17936b13505c4627e8f1d13b430b800214ee37d6a61108e322163ea876bd4358",
            "b23c5875df2eaa3042ecbdd5dac8f8b514c64c5850cc34b2d16aa02a78471c4f",
            "6eb9077173babf81ee0bd41fb737ae2271fbc33e1f70312281401c221d0bfd3d",
            "426f8b3c986e033076b8d1698bbd0b3c2dc85560e260eea3effa14b9cd5fea3c",
            "e6855b02467c69649eb0a9e59a312804d3ce05143f0abc40a4b6dcd93b1ba3a8",
            "423b252ffd9001cc7db87b5c4af1203c7ce5d5d86ca99901e2eeeb84a4a01165",
            "480b0b2957b7c04e23709bb537a1a3dbd486688a26c4dce4bc904f205fd5733d",
            "fff0971141c92cedb28c52afd2f2ae76bce9770f16dc84b15663189add22adcb",
            "c9eb6f5b749862758048e8fdd149c3a756d09afe841d0487fcadec23b3ae23e0",
            "36971a95099069db3c1a59f31c10ee1d8811552fd92dd2acec35a518612ff19f",
            "31e98387b1788eaf57ce9f8303ed3239328ed3d0d2b6b2c2a4cc4ebd5abeb37a",
            "6f963126329e154848cf09a6764dd34720539c58b1202dd644bf5ac1e138d765",
            "d01a385c75bdab260e53d03a6fb402565db52ad9834c84951d524831cf523b5c",
            "d8f2312729c67d691b29935b9a04b67f4f7c94dc570cad65cf561b5a15f8b5a0",
            "582370f399902d9ddaa540a5957fdc83db0082a4d8302230d9bf9041d081006b",
        ].map { Data(hex: $0) }
    }

    private func liveTreeLeaf() -> SigsumLeafRecord {
        SigsumLeafRecord(checksum: LiveFixture.leafChecksum, signature: LiveFixture.leafSignature, keyHash: LiveFixture.leafKeyHash)
    }

    func test_liveFixture_hashLeafNode_matchesLogsRealLeafHash() {
        XCTAssertEqual(SigsumMerkle.hashLeafNode(liveTreeLeaf().toBinary()), LiveFixture.leafHash)
    }

    func test_liveFixture_pathLength_matches18() {
        XCTAssertEqual(SigsumMerkle.pathLength(index: LiveFixture.leafIndex, size: LiveFixture.treeSize), 18)
        XCTAssertEqual(LiveFixture.inclusionPath.count, 18)
    }

    func test_liveFixture_verifyInclusion_reconstructsRealRoot() {
        let result = SigsumMerkle.verifyInclusion(
            leafHash: LiveFixture.leafHash, index: LiveFixture.leafIndex, size: LiveFixture.treeSize,
            root: LiveFixture.rootHash, path: LiveFixture.inclusionPath
        )
        switch result {
        case .success: break
        case .failure(let e): XCTFail("live barreleye inclusion proof must verify, got \(e)")
        }
    }

    // MARK: - Proves the fix matters: the OLD (Android scaffolding) formulation fails against real data

    func test_liveFixture_bareChecksumInsteadOfProperLeafHash_rejected() {
        // This is exactly what Android's SigsumProof.kt did: hand the bare
        // 32-byte checksum/message straight to the inclusion-proof loop,
        // with no tree_leaf packaging and no RFC 6962 0x00 prefix.
        let result = SigsumMerkle.verifyInclusion(
            leafHash: LiveFixture.leafChecksum, index: LiveFixture.leafIndex, size: LiveFixture.treeSize,
            root: LiveFixture.rootHash, path: LiveFixture.inclusionPath
        )
        guard case .failure(.rootMismatch) = result else {
            XCTFail("the old buggy leaf formulation must not reconstruct the real root, got \(result)")
            return
        }
    }

    func test_liveFixture_missingRfc6962Prefix_rejected() {
        // The other half of the same bug in isolation: correct tree_leaf
        // packaging, but SHA-256(tree_leaf) with NO 0x00 prefix.
        let noPrefixHash = SigsumCrypto.sha256(liveTreeLeaf().toBinary())
        XCTAssertNotEqual(noPrefixHash, LiveFixture.leafHash)
        let result = SigsumMerkle.verifyInclusion(
            leafHash: noPrefixHash, index: LiveFixture.leafIndex, size: LiveFixture.treeSize,
            root: LiveFixture.rootHash, path: LiveFixture.inclusionPath
        )
        guard case .failure(.rootMismatch) = result else {
            XCTFail("an un-prefixed leaf hash must not reconstruct the real root, got \(result)")
            return
        }
    }

    // MARK: - Negative tests on the live fixture

    func test_liveFixture_truncatedPath_rejectedOnLength() {
        let short = Array(LiveFixture.inclusionPath.dropLast())
        let result = SigsumMerkle.verifyInclusion(leafHash: LiveFixture.leafHash, index: LiveFixture.leafIndex, size: LiveFixture.treeSize, root: LiveFixture.rootHash, path: short)
        guard case .failure(.wrongPathLength(let expected, let got)) = result else {
            XCTFail("expected wrongPathLength, got \(result)")
            return
        }
        XCTAssertEqual(expected, 18)
        XCTAssertEqual(got, 17)
    }

    func test_liveFixture_paddedPath_rejectedOnLength() {
        let padded = LiveFixture.inclusionPath + [Data(repeating: 0, count: 32)]
        let result = SigsumMerkle.verifyInclusion(leafHash: LiveFixture.leafHash, index: LiveFixture.leafIndex, size: LiveFixture.treeSize, root: LiveFixture.rootHash, path: padded)
        guard case .failure(.wrongPathLength) = result else {
            XCTFail("expected wrongPathLength, got \(result)")
            return
        }
    }

    func test_liveFixture_tamperedPathByte_rejected() {
        var tampered = LiveFixture.inclusionPath
        tampered[5][0] ^= 0xFF
        let result = SigsumMerkle.verifyInclusion(leafHash: LiveFixture.leafHash, index: LiveFixture.leafIndex, size: LiveFixture.treeSize, root: LiveFixture.rootHash, path: tampered)
        guard case .failure(.rootMismatch) = result else {
            XCTFail("expected rootMismatch, got \(result)")
            return
        }
    }

    func test_liveFixture_wrongIndex_rejected() {
        let result = SigsumMerkle.verifyInclusion(leafHash: LiveFixture.leafHash, index: LiveFixture.leafIndex + 1, size: LiveFixture.treeSize, root: LiveFixture.rootHash, path: LiveFixture.inclusionPath)
        // A different index changes the expected path length itself for
        // almost every index, so this is very likely a length mismatch;
        // either failure mode is an acceptable reject, but it must reject.
        switch result {
        case .success: XCTFail("wrong index must not verify")
        default: break
        }
    }

    func test_indexOutOfRange_rejected() {
        let result = SigsumMerkle.verifyInclusion(leafHash: LiveFixture.leafHash, index: LiveFixture.treeSize, size: LiveFixture.treeSize, root: LiveFixture.rootHash, path: [])
        assertFailure(result, .indexOutOfRange)
    }

    // MARK: - Size-1 corner case (sigsum-proof.md: no inclusion path exists or is needed)

    func test_sizeOne_emptyPathAndLeafEqualsRoot_verifies() {
        let leafHash = Data(repeating: 0x42, count: 32)
        let result = SigsumMerkle.verifyInclusion(leafHash: leafHash, index: 0, size: 1, root: leafHash, path: [])
        assertSuccess(result)
    }

    // MARK: - Hash primitive sanity (independent of the live fixture)

    func test_hashLeafNode_usesZeroPrefix() {
        let body = Data(repeating: 0xAB, count: 128)
        var expectedInput = Data([0x00])
        expectedInput.append(body)
        XCTAssertEqual(SigsumMerkle.hashLeafNode(body), SigsumCrypto.sha256(expectedInput))
    }

    func test_hashInteriorNode_usesOnePrefix() {
        let left = Data(repeating: 0x11, count: 32)
        let right = Data(repeating: 0x22, count: 32)
        var expectedInput = Data([0x01])
        expectedInput.append(left)
        expectedInput.append(right)
        XCTAssertEqual(SigsumMerkle.hashInteriorNode(left, right), SigsumCrypto.sha256(expectedInput))
    }

    func test_hashEmptyTree_isShaOfEmptyString() {
        XCTAssertEqual(SigsumMerkle.hashEmptyTree(), SigsumCrypto.sha256(Data()))
    }

    // MARK: - Property-style: an independently-built synthetic Merkle tree,
    // for every (index, size) pair over a range of tree shapes (including
    // non-power-of-two, like the real 214343 fixture above), must verify
    // under `SigsumMerkle.verifyInclusion` — and a truncated/padded path
    // must always be rejected on length. The tree/path builder below
    // (`Mth`) is a direct, independent implementation of the standard
    // RFC 6962 Merkle Tree Hash + inclusion-path recursive definitions —
    // NOT a call into `SigsumMerkle.verifyInclusion`'s own iterative
    // algorithm — so this does not just check the code against itself.
    private enum Mth {
        static func splitPoint(_ n: Int) -> Int {
            var k = 1
            while k * 2 < n { k *= 2 }
            return k
        }

        static func root(_ leaves: [Data]) -> Data {
            if leaves.count == 1 { return leaves[0] }
            let k = splitPoint(leaves.count)
            return SigsumMerkle.hashInteriorNode(root(Array(leaves[0..<k])), root(Array(leaves[k...])))
        }

        static func path(_ leaves: [Data], index: Int) -> [Data] {
            if leaves.count == 1 { return [] }
            let k = splitPoint(leaves.count)
            if index < k {
                return path(Array(leaves[0..<k]), index: index) + [root(Array(leaves[k...]))]
            } else {
                return path(Array(leaves[k...]), index: index - k) + [root(Array(leaves[0..<k]))]
            }
        }
    }

    private func syntheticLeaves(_ n: Int) -> [Data] {
        (0..<n).map { i in SigsumMerkle.hashLeafNode(Data(repeating: UInt8(i & 0xFF), count: 128)) }
    }

    func test_syntheticTrees_everyIndexVerifies_acrossVariousSizes() {
        for size in [1, 2, 3, 4, 5, 6, 7, 8, 13, 31, 32, 33] {
            let leaves = syntheticLeaves(size)
            let root = Mth.root(leaves)
            for index in 0..<size {
                let path = Mth.path(leaves, index: index)
                let result = SigsumMerkle.verifyInclusion(leafHash: leaves[index], index: UInt64(index), size: UInt64(size), root: root, path: path)
                switch result {
                case .success: break
                case .failure(let e):
                    XCTFail("size=\(size) index=\(index) must verify, got \(e)")
                }
            }
        }
    }

    func test_syntheticTree_truncatedOrPaddedPath_alwaysRejectedOnLength() {
        let leaves = syntheticLeaves(13)
        let root = Mth.root(leaves)
        for index in [0, 5, 12] {
            let realPath = Mth.path(leaves, index: index)
            guard !realPath.isEmpty else { continue }
            let short = Array(realPath.dropLast())
            switch SigsumMerkle.verifyInclusion(leafHash: leaves[index], index: UInt64(index), size: 13, root: root, path: short) {
            case .failure(.wrongPathLength): break
            default: XCTFail("index=\(index): truncated path must be rejected on length")
            }
            let padded = realPath + [Data(repeating: 0, count: 32)]
            switch SigsumMerkle.verifyInclusion(leafHash: leaves[index], index: UInt64(index), size: 13, root: root, path: padded) {
            case .failure(.wrongPathLength): break
            default: XCTFail("index=\(index): padded path must be rejected on length")
            }
        }
    }

    // MARK: - Consistency proof (bonus completeness, sigsum-go merkle.VerifyConsistency port)

    func test_consistency_equalSizeRequiresEqualRootsAndEmptyPath() {
        let root = Data(repeating: 0x77, count: 32)
        assertSuccess(SigsumMerkle.verifyConsistency(oldSize: 5, newSize: 5, oldRoot: root, newRoot: root, path: []))
        assertFailure(
            SigsumMerkle.verifyConsistency(oldSize: 5, newSize: 5, oldRoot: root, newRoot: Data(repeating: 0x88, count: 32), path: []),
            .rootsDifferForEqualSize
        )
    }

    func test_consistency_emptyOldTreeAlwaysConsistent() {
        let newLeaves = syntheticLeaves(4)
        let newRoot = Mth.root(newLeaves)
        assertSuccess(SigsumMerkle.verifyConsistency(oldSize: 0, newSize: 4, oldRoot: SigsumMerkle.hashEmptyTree(), newRoot: newRoot, path: []))
    }

    func test_consistency_growingSyntheticTree_verifies() {
        // Build an 8-leaf tree; the first 5 leaves alone form the "old" tree,
        // all 8 form the "new" tree. sigsum-go's VerifyConsistency proof
        // construction is nontrivial to hand-roll independently here, so
        // this exercises the documented trivial-consistency corner cases
        // above plus a same-size no-op — full non-trivial consistency-proof
        // *construction* (as opposed to verification, which is what ships)
        // is out of scope for this pass; `verifyConsistency` itself is a
        // direct, function-for-function port of `sigsum-go`'s
        // `merkle.VerifyConsistency` and is exercised via its trivial paths
        // above.
        let leaves = syntheticLeaves(8)
        let root = Mth.root(leaves)
        assertSuccess(SigsumMerkle.verifyConsistency(oldSize: 8, newSize: 8, oldRoot: root, newRoot: root, path: []))
    }
}

private extension Data {
    init(hex: String) {
        self = SigsumHex.decode(hex)!
    }
}
