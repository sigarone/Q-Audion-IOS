import XCTest
import CryptoKit
@testable import QAudionEngine

/// `Result<Void, E>` is never `Equatable` (the empty tuple `()`/`Void`
/// cannot conform to any protocol, tuples being non-nominal types), so a
/// direct `XCTAssertEqual` against `SigsumVerifier.verify`'s
/// `Result<Void, FailureReason>` return value would not compile. These two
/// helpers do the equivalent pattern-match instead — see the identical
/// helper (and its rationale) at the top of `SigsumMerkleTests.swift`; kept
/// as a file-private duplicate here rather than shared, matching this
/// codebase's own convention for small test-only helpers.
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

/// TRUST-1 residual. End-to-end tests for `SigsumVerifier.verify`'s full
/// accept decision (`sigsum-proof.md` §"Verifying a proof", steps 1-6, all
/// of them — see `SigsumVerifier`'s kdoc for why a partial pass is
/// meaningless).
///
/// The log side of this scenario (log/witness keys, tree, tree-head
/// signature, cosignatures) is a self-contained SYNTHETIC fixture built
/// with this file's own tiny Merkle-tree builder — NOT `SigsumMerkleTests`'
/// real `test.sigsum.org/barreleye` snapshot, because that snapshot's real
/// leaf entry (index 100) was submitted by an unknown third party: the log
/// only ever publishes that submitter's KEY HASH, never their public key,
/// so there is no way to obtain a real, verifiable (submitter_pubkey,
/// leaf_signature) pair to test the submitter-identity half of this
/// verifier against. `SigsumMerkleTests`/`SigsumProtocolTests` already
/// cover the log-side primitives (leaf-hash chain, tree-head signature,
/// cosignatures) against that real data; this file instead builds every
/// layer itself with its own keys so the FULL orchestration — including
/// the submitter-identity binding, which is the actual point of TRUST-1 —
/// is exercised end-to-end. This is the same "no cross-platform KAT yet,
/// self-contained round-trip + negative tests" pattern
/// `FileAttachmentAnnounceSigTests` already uses in this codebase for a
/// brand-new scheme with no real-world fixture available.
///
/// ⚠️ Requires `swift test` (CryptoKit). Authored on win32 — NOT executed in
/// this session; the GitHub Actions macOS runner is the gate.
final class SigsumVerifierTests: XCTestCase {

    // MARK: - Tiny independent Merkle-tree builder (4 leaves, power of two —
    // exhaustive tree-shape coverage already lives in SigsumMerkleTests;
    // this only needs ONE concrete tree to hang the orchestration test on).

    private func buildFourLeafTree(leaves: [Data]) -> (root: Data, pathFor: (Int) -> [Data]) {
        precondition(leaves.count == 4)
        let left = SigsumMerkle.hashInteriorNode(leaves[0], leaves[1])
        let right = SigsumMerkle.hashInteriorNode(leaves[2], leaves[3])
        let root = SigsumMerkle.hashInteriorNode(left, right)
        func path(_ index: Int) -> [Data] {
            switch index {
            case 0: return [leaves[1], right]
            case 1: return [leaves[0], right]
            case 2: return [leaves[3], left]
            case 3: return [leaves[2], left]
            default: preconditionFailure("index out of range")
            }
        }
        return (root, path)
    }

    // MARK: - Fixture scaffolding

    private struct Scenario {
        let policy: SigsumPolicy
        let logSeed: Data
        let logPub: Data
        let witnessSeeds: [String: Data] // name -> seed
        let witnessPubs: [String: Data]
        let submitterSeed: Data
        let submitterPub: Data
        let message: Data
        let checksum: Data
        let leafSignature: Data
        let leafKeyHash: Data
        let leafHash: Data
        let treeSize: UInt64
        let rootHash: Data
        let leafIndex: UInt64
        let path: [Data]
        let treeHeadSignature: Data
        let origin: String
    }

    private func makeScenario() throws -> Scenario {
        let logSeed = Data(repeating: 0x01, count: 32)
        let logKey = try Curve25519.Signing.PrivateKey(rawRepresentation: logSeed)
        let logPub = logKey.publicKey.rawRepresentation

        let witnessNames = ["w1", "w2", "w3"]
        var witnessSeeds: [String: Data] = [:]
        var witnessPubs: [String: Data] = [:]
        for (i, name) in witnessNames.enumerated() {
            let seed = Data(repeating: UInt8(0x10 + i), count: 32)
            witnessSeeds[name] = seed
            witnessPubs[name] = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        }

        let submitterSeed = Data(repeating: 0x02, count: 32)
        let submitterKey = try Curve25519.Signing.PrivateKey(rawRepresentation: submitterSeed)
        let submitterPub = submitterKey.publicKey.rawRepresentation

        let message = try SigsumLeaf.computeLeaf(userUuidRaw: Data(repeating: 0x03, count: 16), ed25519Pub: submitterPub, createdAtMs: 1_700_000_000_000)
        let checksum = SigsumCrypto.sha256(message)
        let leafSignature = try SigsumCrypto.signLeafChecksum(submitterPrivateKeySeed: submitterSeed, checksum: checksum)
        let leafKeyHash = SigsumCrypto.sha256(submitterPub)
        let ourLeaf = SigsumLeafRecord(checksum: checksum, signature: leafSignature, keyHash: leafKeyHash)
        let leafHash = SigsumMerkle.hashLeafNode(ourLeaf.toBinary())

        // 3 filler leaves + our real one at index 2.
        let filler0 = SigsumMerkle.hashLeafNode(Data(repeating: 0xF0, count: 128))
        let filler1 = SigsumMerkle.hashLeafNode(Data(repeating: 0xF1, count: 128))
        let filler3 = SigsumMerkle.hashLeafNode(Data(repeating: 0xF3, count: 128))
        let leaves = [filler0, filler1, leafHash, filler3]
        let tree = buildFourLeafTree(leaves: leaves)
        let leafIndex: UInt64 = 2
        let path = tree.pathFor(2)

        let origin = SigsumCrypto.checkpointOrigin(logPublicKey: logPub)
        let checkpoint = SigsumCrypto.formatCheckpoint(origin: origin, size: 4, rootHash: tree.root)
        let treeHeadSignature = try logKey.signature(for: checkpoint)

        let policy = SigsumPolicy(
            name: "test-scenario",
            logs: [SigsumLog(name: "L", publicKey: logPub, url: nil)],
            witnesses: witnessNames.map { SigsumWitness(name: $0, publicKey: witnessPubs[$0]!, url: nil) },
            groups: [SigsumQuorumGroup(name: "q", threshold: 2, members: witnessNames.map { .witness($0) })],
            quorumGroupName: "q"
        )

        return Scenario(
            policy: policy, logSeed: logSeed, logPub: logPub, witnessSeeds: witnessSeeds, witnessPubs: witnessPubs,
            submitterSeed: submitterSeed, submitterPub: submitterPub, message: message, checksum: checksum,
            leafSignature: leafSignature, leafKeyHash: leafKeyHash, leafHash: leafHash,
            treeSize: 4, rootHash: tree.root, leafIndex: leafIndex, path: path,
            treeHeadSignature: treeHeadSignature, origin: origin
        )
    }

    /// Cosign with `count` of the 3 witnesses (in declaration order), each
    /// at `timestamp`.
    private func cosign(_ scenario: Scenario, count: Int, timestamp: UInt64 = 1_700_000_001) throws -> [SigsumCosignature] {
        var out: [SigsumCosignature] = []
        for name in ["w1", "w2", "w3"].prefix(count) {
            let seed = scenario.witnessSeeds[name]!
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            let data = SigsumCrypto.cosignedData(origin: scenario.origin, timestamp: timestamp, size: scenario.treeSize, rootHash: scenario.rootHash)
            let sig = try key.signature(for: data)
            out.append(SigsumCosignature(witnessKeyHash: SigsumCrypto.sha256(scenario.witnessPubs[name]!), timestamp: timestamp, signature: sig))
        }
        return out
    }

    private func makeBundle(_ scenario: Scenario, cosigs: [SigsumCosignature], overrideLeafKeyHash: Data? = nil, overrideLeafSignature: Data? = nil, overrideTreeHeadSignature: Data? = nil, overrideLogKeyHash: Data? = nil, overridePath: [Data]? = nil) -> SigsumProofBundle {
        SigsumProofBundle(
            version: 2,
            logKeyHash: overrideLogKeyHash ?? SigsumCrypto.sha256(scenario.logPub),
            leafKeyHash: overrideLeafKeyHash ?? scenario.leafKeyHash,
            leafSignature: overrideLeafSignature ?? scenario.leafSignature,
            cosignedTreeHead: SigsumCosignedTreeHead(
                signedTreeHead: SigsumSignedTreeHead(
                    treeHead: SigsumTreeHead(size: scenario.treeSize, rootHash: scenario.rootHash),
                    signature: overrideTreeHeadSignature ?? scenario.treeHeadSignature
                ),
                cosignatures: cosigs
            ),
            inclusionProof: SigsumInclusionProof(leafIndex: scenario.leafIndex, path: overridePath ?? scenario.path)
        )
    }

    // MARK: - Happy path

    func test_fullAccept_allStepsValid_succeeds() throws {
        let s = try makeScenario()
        let bundle = makeBundle(s, cosigs: try cosign(s, count: 2))
        let result = SigsumVerifier.verify(message: s.message, submitterPublicKey: s.submitterPub, bundle: bundle, policy: s.policy)
        switch result {
        case .success: break
        case .failure(let reason): XCTFail("expected success, got \(reason)")
        }
    }

    func test_fullAccept_allThreeCosignatures_stillSucceeds() throws {
        let s = try makeScenario()
        let bundle = makeBundle(s, cosigs: try cosign(s, count: 3))
        assertSuccess(SigsumVerifier.verify(message: s.message, submitterPublicKey: s.submitterPub, bundle: bundle, policy: s.policy))
    }

    // MARK: - Step 1/2: message/checksum + key-hash checks

    func test_wrongMessage_rejected() throws {
        let s = try makeScenario()
        let bundle = makeBundle(s, cosigs: try cosign(s, count: 2))
        let wrongMessage = Data(repeating: 0x99, count: 32)
        let result = SigsumVerifier.verify(message: wrongMessage, submitterPublicKey: s.submitterPub, bundle: bundle, policy: s.policy)
        // A different message -> a different recomputed checksum -> the
        // bundle's leaf signature (made over the ORIGINAL checksum) no
        // longer verifies. This is caught at step 3 (leaf signature),
        // before ever reaching the inclusion-proof check — exactly the
        // "recompute the message locally, never trust the wire" contract:
        // a proof for the wrong binding fails as an invalid SIGNATURE, not
        // merely a root mismatch several steps later.
        assertFailure(result, .leafSignatureInvalid)
    }

    func test_unknownLog_rejected() throws {
        let s = try makeScenario()
        let bundle = makeBundle(s, cosigs: try cosign(s, count: 2), overrideLogKeyHash: Data(repeating: 0xEE, count: 32))
        assertFailure(SigsumVerifier.verify(message: s.message, submitterPublicKey: s.submitterPub, bundle: bundle, policy: s.policy), .unknownLog)
    }

    func test_leafKeyHashMismatch_rejected() throws {
        let s = try makeScenario()
        let bundle = makeBundle(s, cosigs: try cosign(s, count: 2))
        let wrongSubmitterPub = Data(repeating: 0x77, count: 32)
        let result = SigsumVerifier.verify(message: s.message, submitterPublicKey: wrongSubmitterPub, bundle: bundle, policy: s.policy)
        assertFailure(result, .leafKeyHashMismatch)
    }

    // MARK: - Step 3: leaf signature

    func test_tamperedLeafSignature_rejected() throws {
        let s = try makeScenario()
        var tamperedSig = s.leafSignature
        tamperedSig[0] ^= 0xFF
        let bundle = makeBundle(s, cosigs: try cosign(s, count: 2), overrideLeafSignature: tamperedSig)
        assertFailure(SigsumVerifier.verify(message: s.message, submitterPublicKey: s.submitterPub, bundle: bundle, policy: s.policy), .leafSignatureInvalid)
    }

    // MARK: - Step 4: tree-head signature

    func test_tamperedTreeHeadSignature_rejected() throws {
        let s = try makeScenario()
        var tamperedSig = s.treeHeadSignature
        tamperedSig[0] ^= 0xFF
        let bundle = makeBundle(s, cosigs: try cosign(s, count: 2), overrideTreeHeadSignature: tamperedSig)
        assertFailure(SigsumVerifier.verify(message: s.message, submitterPublicKey: s.submitterPub, bundle: bundle, policy: s.policy), .treeHeadSignatureInvalid)
    }

    // MARK: - Step 5: cosignature quorum

    func test_insufficientCosignatures_rejected() throws {
        let s = try makeScenario()
        let bundle = makeBundle(s, cosigs: try cosign(s, count: 1))
        guard case .failure(.quorumNotMet(let count)) = SigsumVerifier.verify(message: s.message, submitterPublicKey: s.submitterPub, bundle: bundle, policy: s.policy) else {
            XCTFail("expected quorumNotMet")
            return
        }
        XCTAssertEqual(count, 1)
    }

    func test_zeroCosignatures_rejected() throws {
        let s = try makeScenario()
        let bundle = makeBundle(s, cosigs: [])
        assertFailure(SigsumVerifier.verify(message: s.message, submitterPublicKey: s.submitterPub, bundle: bundle, policy: s.policy), .quorumNotMet(verifiedWitnessCount: 0))
    }

    func test_cosignaturesWithTamperedSignatures_notCountedTowardQuorum() throws {
        let s = try makeScenario()
        var cosigs = try cosign(s, count: 3)
        // Corrupt 2 of the 3 signatures — only 1 genuinely verifies, below
        // the threshold of 2.
        cosigs[0] = SigsumCosignature(witnessKeyHash: cosigs[0].witnessKeyHash, timestamp: cosigs[0].timestamp, signature: Data(repeating: 0x00, count: 64))
        cosigs[1] = SigsumCosignature(witnessKeyHash: cosigs[1].witnessKeyHash, timestamp: cosigs[1].timestamp, signature: Data(repeating: 0x00, count: 64))
        let bundle = makeBundle(s, cosigs: cosigs)
        guard case .failure(.quorumNotMet(let count)) = SigsumVerifier.verify(message: s.message, submitterPublicKey: s.submitterPub, bundle: bundle, policy: s.policy) else {
            XCTFail("expected quorumNotMet")
            return
        }
        XCTAssertEqual(count, 1)
    }

    func test_cosignaturesFromUnknownWitnesses_ignoredNotFatal() throws {
        let s = try makeScenario()
        var cosigs = try cosign(s, count: 2)
        cosigs.append(SigsumCosignature(witnessKeyHash: Data(repeating: 0xDD, count: 32), timestamp: 1, signature: Data(repeating: 0x00, count: 64)))
        let bundle = makeBundle(s, cosigs: cosigs)
        assertSuccess(SigsumVerifier.verify(message: s.message, submitterPublicKey: s.submitterPub, bundle: bundle, policy: s.policy))
    }

    // MARK: - Step 6: inclusion proof

    func test_tamperedInclusionPath_rejected() throws {
        let s = try makeScenario()
        var tamperedPath = s.path
        tamperedPath[0][0] ^= 0xFF
        let bundle = makeBundle(s, cosigs: try cosign(s, count: 2), overridePath: tamperedPath)
        guard case .failure(.inclusionProofInvalid(.rootMismatch)) = SigsumVerifier.verify(message: s.message, submitterPublicKey: s.submitterPub, bundle: bundle, policy: s.policy) else {
            XCTFail("expected inclusionProofInvalid(.rootMismatch)")
            return
        }
    }

    func test_truncatedInclusionPath_rejectedOnLength() throws {
        let s = try makeScenario()
        let bundle = makeBundle(s, cosigs: try cosign(s, count: 2), overridePath: Array(s.path.dropLast()))
        guard case .failure(.inclusionProofInvalid(.wrongPathLength)) = SigsumVerifier.verify(message: s.message, submitterPublicKey: s.submitterPub, bundle: bundle, policy: s.policy) else {
            XCTFail("expected inclusionProofInvalid(.wrongPathLength)")
            return
        }
    }

    func test_missingInclusionProofForSizeGreaterThanOne_rejected() throws {
        let s = try makeScenario()
        var bundle = makeBundle(s, cosigs: try cosign(s, count: 2))
        bundle = SigsumProofBundle(version: bundle.version, logKeyHash: bundle.logKeyHash, leafKeyHash: bundle.leafKeyHash, leafSignature: bundle.leafSignature, cosignedTreeHead: bundle.cosignedTreeHead, inclusionProof: nil)
        guard case .failure(.malformedInput) = SigsumVerifier.verify(message: s.message, submitterPublicKey: s.submitterPub, bundle: bundle, policy: s.policy) else {
            XCTFail("expected malformedInput")
            return
        }
    }

    // MARK: - size == 1 (direct leaf==root, no inclusion proof)

    func test_sizeOne_leafEqualsRoot_succeeds() throws {
        let logSeed = Data(repeating: 0x05, count: 32)
        let logKey = try Curve25519.Signing.PrivateKey(rawRepresentation: logSeed)
        let logPub = logKey.publicKey.rawRepresentation
        let submitterSeed = Data(repeating: 0x06, count: 32)
        let submitterKey = try Curve25519.Signing.PrivateKey(rawRepresentation: submitterSeed)
        let submitterPub = submitterKey.publicKey.rawRepresentation

        let message = Data(repeating: 0x07, count: 32)
        let checksum = SigsumCrypto.sha256(message)
        let leafSig = try SigsumCrypto.signLeafChecksum(submitterPrivateKeySeed: submitterSeed, checksum: checksum)
        let leafKeyHash = SigsumCrypto.sha256(submitterPub)
        let leafRecord = SigsumLeafRecord(checksum: checksum, signature: leafSig, keyHash: leafKeyHash)
        let leafHash = SigsumMerkle.hashLeafNode(leafRecord.toBinary())

        let origin = SigsumCrypto.checkpointOrigin(logPublicKey: logPub)
        let checkpoint = SigsumCrypto.formatCheckpoint(origin: origin, size: 1, rootHash: leafHash)
        let thSig = try logKey.signature(for: checkpoint)

        let policy = SigsumPolicy(name: "size1", logs: [SigsumLog(name: "L", publicKey: logPub, url: nil)], witnesses: [], groups: [SigsumQuorumGroup(name: "none", threshold: 0, members: [])], quorumGroupName: "none")
        let bundle = SigsumProofBundle(
            version: 2, logKeyHash: SigsumCrypto.sha256(logPub), leafKeyHash: leafKeyHash, leafSignature: leafSig,
            cosignedTreeHead: SigsumCosignedTreeHead(signedTreeHead: SigsumSignedTreeHead(treeHead: SigsumTreeHead(size: 1, rootHash: leafHash), signature: thSig), cosignatures: []),
            inclusionProof: nil
        )
        assertSuccess(SigsumVerifier.verify(message: message, submitterPublicKey: submitterPub, bundle: bundle, policy: policy))
    }

    func test_sizeOne_leafDoesNotEqualRoot_rejected() throws {
        let logSeed = Data(repeating: 0x08, count: 32)
        let logKey = try Curve25519.Signing.PrivateKey(rawRepresentation: logSeed)
        let logPub = logKey.publicKey.rawRepresentation
        let submitterSeed = Data(repeating: 0x09, count: 32)
        let submitterPub = try Curve25519.Signing.PrivateKey(rawRepresentation: submitterSeed).publicKey.rawRepresentation

        let message = Data(repeating: 0x0A, count: 32)
        let checksum = SigsumCrypto.sha256(message)
        let leafSig = try SigsumCrypto.signLeafChecksum(submitterPrivateKeySeed: submitterSeed, checksum: checksum)
        let leafKeyHash = SigsumCrypto.sha256(submitterPub)

        // A root that is NOT this leaf's hash — e.g. a differently-signed tree head.
        let wrongRoot = Data(repeating: 0xBB, count: 32)
        let origin = SigsumCrypto.checkpointOrigin(logPublicKey: logPub)
        let checkpoint = SigsumCrypto.formatCheckpoint(origin: origin, size: 1, rootHash: wrongRoot)
        let thSig = try logKey.signature(for: checkpoint)

        let policy = SigsumPolicy(name: "size1", logs: [SigsumLog(name: "L", publicKey: logPub, url: nil)], witnesses: [], groups: [SigsumQuorumGroup(name: "none", threshold: 0, members: [])], quorumGroupName: "none")
        let bundle = SigsumProofBundle(
            version: 2, logKeyHash: SigsumCrypto.sha256(logPub), leafKeyHash: leafKeyHash, leafSignature: leafSig,
            cosignedTreeHead: SigsumCosignedTreeHead(signedTreeHead: SigsumSignedTreeHead(treeHead: SigsumTreeHead(size: 1, rootHash: wrongRoot), signature: thSig), cosignatures: []),
            inclusionProof: nil
        )
        assertFailure(SigsumVerifier.verify(message: message, submitterPublicKey: submitterPub, bundle: bundle, policy: policy), .singleLeafRootMismatch)
    }

    // MARK: - size == 0 (always invalid per sigsum-proof.md)

    func test_sizeZero_rejected() throws {
        // Every OTHER step (leaf key-hash, leaf signature, tree-head
        // signature, quorum) is made to pass honestly here, so that only
        // `size == 0` itself is what triggers the failure — the leaf
        // key-hash check (step 2) runs before the size check and would
        // otherwise mask what this test is trying to isolate.
        let logSeed = Data(repeating: 0x0B, count: 32)
        let logKey = try Curve25519.Signing.PrivateKey(rawRepresentation: logSeed)
        let logPub = logKey.publicKey.rawRepresentation
        let submitterSeed = Data(repeating: 0x0C, count: 32)
        let submitterPub = try Curve25519.Signing.PrivateKey(rawRepresentation: submitterSeed).publicKey.rawRepresentation

        let message = Data(repeating: 0x0D, count: 32)
        let checksum = SigsumCrypto.sha256(message)
        let leafSig = try SigsumCrypto.signLeafChecksum(submitterPrivateKeySeed: submitterSeed, checksum: checksum)
        let leafKeyHash = SigsumCrypto.sha256(submitterPub)

        let origin = SigsumCrypto.checkpointOrigin(logPublicKey: logPub)
        let emptyRoot = SigsumMerkle.hashEmptyTree()
        let checkpoint = SigsumCrypto.formatCheckpoint(origin: origin, size: 0, rootHash: emptyRoot)
        let thSig = try logKey.signature(for: checkpoint)
        let policy = SigsumPolicy(name: "size0", logs: [SigsumLog(name: "L", publicKey: logPub, url: nil)], witnesses: [], groups: [SigsumQuorumGroup(name: "none", threshold: 0, members: [])], quorumGroupName: "none")
        let bundle = SigsumProofBundle(
            version: 2, logKeyHash: SigsumCrypto.sha256(logPub), leafKeyHash: leafKeyHash, leafSignature: leafSig,
            cosignedTreeHead: SigsumCosignedTreeHead(signedTreeHead: SigsumSignedTreeHead(treeHead: SigsumTreeHead(size: 0, rootHash: emptyRoot), signature: thSig), cosignatures: []),
            inclusionProof: nil
        )
        assertFailure(SigsumVerifier.verify(message: message, submitterPublicKey: submitterPub, bundle: bundle, policy: policy), .emptyTree)
    }

    // MARK: - Malformed input at the boundary

    func test_wrongLengthSubmitterKey_rejected() throws {
        let s = try makeScenario()
        let bundle = makeBundle(s, cosigs: try cosign(s, count: 2))
        guard case .failure(.malformedInput) = SigsumVerifier.verify(message: s.message, submitterPublicKey: Data(repeating: 0, count: 31), bundle: bundle, policy: s.policy) else {
            XCTFail("expected malformedInput")
            return
        }
    }
}
