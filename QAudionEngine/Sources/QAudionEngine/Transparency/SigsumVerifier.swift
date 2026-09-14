import Foundation

/// TRUST-1 residual — the complete Sigsum proof accept decision
/// (`sigsum-proof.md` §"Verifying a proof", steps 1-6), for a Q-Audion
/// Key-Transparency identity binding.
///
/// ## Scaffolding-only — NOT wired to any live trust decision
///
/// This verifier is built, tested, and correct, but it is **not** consulted
/// by `PeerTrustEvaluator`/`IdentitySelfCheckPolicy` or any other accept/
/// reject path in this app yet. That wiring is deliberately a follow-up:
/// the server-side submitter this verifier's proofs would come from is
/// being built in parallel (a different agent, same batch) and is not live
/// either. Calling `SigsumVerifier.verify` today is a no-op with respect to
/// this app's actual trust decisions — it exists so that follow-up wiring
/// has a correct, tested primitive to call, per the TRUST-1 finding:
/// "only key transparency ... removes the server from this decision for
/// TOFU peers."
///
/// ## Why every step below is load-bearing
///
/// A partial checker is not a weaker verifier, it is a broken one that
/// *looks* like it works:
///
/// - Skipping the message/checksum recomputation means the "proof" is a
///   proof that *something* was logged, not that *this* identity binding
///   was — an attacker who can get literally anything logged (e.g. a
///   throwaway self-submission) could hand a victim a syntactically valid,
///   cryptographically self-consistent bundle for the WRONG binding.
/// - Skipping the key-hash bitwise checks (submitter, log) opens exactly
///   the multiple-representation confusion `sigsum-proof.md` calls out —
///   two different byte strings that a looser equality might treat as "the
///   same key".
/// - Skipping the leaf-signature check means any `checksum` could be
///   packaged into a `tree_leaf` and logged by *anyone* holding *any*
///   Ed25519 key, not specifically the pinned identity's key — the log
///   would faithfully include it, and inclusion alone proves nothing about
///   who vouched for the binding.
/// - Skipping the tree-head-signature check means the entire cosignature
///   and inclusion-proof machinery is being run against a `root_hash` that
///   could be anything an active network attacker fabricated — cosignature
///   verification and inclusion-proof verification are only meaningful
///   once the root they both refer to is known to be the LOG's own.
/// - Skipping (or under-counting) the cosignature quorum means a single
///   compromised or coerced log operator can present a locally-consistent
///   but globally-forked view with no other party ever able to detect it —
///   the entire point of witness cosigning.
/// - Skipping the corrected inclusion-proof check (RFC 6962 prefix byte +
///   path-length) — see `SigsumMerkle`'s kdoc — means the "proof" step
///   Android's scaffolding shipped never actually checked inclusion in the
///   real tree at all.
///
/// Any one of these being silently skipped turns "verified" into "looked
/// at some bytes that were shaped like a proof." `verify` below runs every
/// one and returns the FIRST failure reason, never a partial pass.
public enum SigsumVerifier {

    public enum FailureReason: Error, Equatable {
        case malformedInput(String)
        /// The bundle's `log=` key hash does not match any log in `policy`.
        case unknownLog
        /// `SHA-256(submitterPublicKey) != bundle.leafKeyHash`.
        case leafKeyHashMismatch
        /// The Ed25519 leaf signature does not verify under `submitterPublicKey`.
        case leafSignatureInvalid
        /// The tree-head signature does not verify under the resolved log's
        /// real (policy-pinned) public key.
        case treeHeadSignatureInvalid
        /// Fewer valid, policy-known witness cosignatures than the policy's
        /// quorum requires. `verifiedWitnessCount` is informational only —
        /// the pass/fail decision itself is `SigsumPolicy.quorumSatisfied`,
        /// which can require more than a flat count (nested groups).
        case quorumNotMet(verifiedWitnessCount: Int)
        /// `size == 0`, which `sigsum-proof.md` states is always invalid.
        case emptyTree
        /// `size == 1` case: the leaf hash does not equal the root hash
        /// directly (no inclusion proof exists or is needed for a
        /// single-leaf tree).
        case singleLeafRootMismatch
        case inclusionProofInvalid(SigsumMerkle.InclusionError)
    }

    /// Full accept decision.
    ///
    /// - Parameters:
    ///   - message: the 32-byte Key-Transparency binding — e.g.
    ///     `SigsumLeaf.computeLeaf(...)`'s output, recomputed by the caller
    ///     from the peer's identity-bundle fields it already has, NEVER
    ///     taken from anything inside `bundle` (there is nothing to take —
    ///     `SigsumProofBundle` deliberately carries no checksum field; see
    ///     that type's kdoc).
    ///   - submitterPublicKey: the pinned identity key the binding is
    ///     claimed to be signed by. This MUST be a key the caller already
    ///     trusts through some other channel (this app's own
    ///     identity-key-publish/pinning flow) — a `SigsumProofBundle`
    ///     alone never establishes trust in a submitter key, only that
    ///     *some* key matching `bundle.leafKeyHash` signed `checksum` and
    ///     that entry is included in a real, witnessed tree.
    ///   - bundle: the packaged proof (`SigsumWireCodec.parseProofBundle`,
    ///     or assembled directly from `get-tree-head`/`get-inclusion-proof`
    ///     responses).
    ///   - policy: which logs/witnesses/quorum to trust —
    ///     `SigsumPolicy.sigsumTest2025_3` or (once wired)
    ///     `SigsumPolicy.sigsumGeneric2025_1`.
    public static func verify(
        message: Data,
        submitterPublicKey: Data,
        bundle: SigsumProofBundle,
        policy: SigsumPolicy
    ) -> Result<Void, FailureReason> {
        guard submitterPublicKey.count == SigsumCrypto.publicKeySize else {
            return .failure(.malformedInput("submitterPublicKey must be \(SigsumCrypto.publicKeySize) bytes"))
        }
        guard bundle.version == 2 else {
            return .failure(.malformedInput("unsupported proof bundle version \(bundle.version)"))
        }

        // Step 1 (sigsum-proof.md): "Compute checksum = H(message)." Recomputed
        // locally, from the caller's own `message` — never trusted from the wire.
        let checksum = SigsumCrypto.sha256(message)

        // Step 2: bitwise key-hash checks — submitter and log.
        guard let log = policy.log(withKeyHash: bundle.logKeyHash) else {
            return .failure(.unknownLog)
        }
        let submitterKeyHash = SigsumCrypto.sha256(submitterPublicKey)
        guard submitterKeyHash == bundle.leafKeyHash else {
            return .failure(.leafKeyHashMismatch)
        }

        // Step 3: leaf signature, over the checksum WE computed, under the
        // caller's already-pinned submitter key.
        guard SigsumCrypto.verifyLeafSignature(submitterPublicKey: submitterPublicKey, checksum: checksum, signature: bundle.leafSignature) else {
            return .failure(.leafSignatureInvalid)
        }

        // Step 4: tree-head signature, under the RESOLVED log's real pubkey
        // (never a bare claim in the bundle).
        let sth = bundle.cosignedTreeHead.signedTreeHead
        let treeHead = sth.treeHead
        guard SigsumCrypto.verifyTreeHeadSignature(logPublicKey: log.publicKey, size: treeHead.size, rootHash: treeHead.rootHash, signature: sth.signature) else {
            return .failure(.treeHeadSignatureInvalid)
        }

        guard treeHead.size >= 1 else {
            // sigsum-proof.md: "A proof with size = 0 is always invalid."
            return .failure(.emptyTree)
        }

        // Step 5: cosignatures + quorum. Unknown witness key hashes are
        // ignored (not fatal) — a policy that trusts fewer witnesses than
        // the log happens to have collected cosignatures from is normal,
        // not an attack; what matters is whether the ones THIS policy does
        // know about, and that verify, clear its quorum.
        let origin = SigsumCrypto.checkpointOrigin(logPublicKey: log.publicKey)
        var verifiedWitnessNames = Set<String>()
        for cosig in bundle.cosignedTreeHead.cosignatures {
            guard let witness = policy.witness(withKeyHash: cosig.witnessKeyHash) else { continue }
            let ok = SigsumCrypto.verifyCosignature(
                witnessPublicKey: witness.publicKey, origin: origin, timestamp: cosig.timestamp,
                size: treeHead.size, rootHash: treeHead.rootHash, signature: cosig.signature
            )
            if ok { verifiedWitnessNames.insert(witness.name) }
        }
        guard policy.quorumSatisfied(by: verifiedWitnessNames) else {
            return .failure(.quorumNotMet(verifiedWitnessCount: verifiedWitnessNames.count))
        }

        // Step 6: the real Sigsum leaf hash — checksum || signature || key_hash,
        // RFC-6962-prefixed (SigsumMerkle.hashLeafNode) — NOT the bare checksum
        // Android's scaffolding fed straight into its (also broken) inclusion loop.
        let leafRecord = SigsumLeafRecord(checksum: checksum, signature: bundle.leafSignature, keyHash: bundle.leafKeyHash)
        let leafHash = SigsumMerkle.hashLeafNode(leafRecord.toBinary())

        if treeHead.size == 1 {
            guard bundle.inclusionProof == nil || bundle.inclusionProof?.path.isEmpty == true else {
                return .failure(.malformedInput("inclusion proof present for a size-1 tree"))
            }
            guard leafHash == treeHead.rootHash else { return .failure(.singleLeafRootMismatch) }
            return .success(())
        }

        guard let proof = bundle.inclusionProof else {
            return .failure(.malformedInput("missing inclusion proof for size > 1"))
        }
        switch SigsumMerkle.verifyInclusion(leafHash: leafHash, index: proof.leafIndex, size: treeHead.size, root: treeHead.rootHash, path: proof.path) {
        case .success:
            return .success(())
        case .failure(let error):
            return .failure(.inclusionProofInvalid(error))
        }
    }
}
