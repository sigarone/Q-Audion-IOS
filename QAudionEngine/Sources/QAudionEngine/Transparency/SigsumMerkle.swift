import Foundation
import CryptoKit

/// RFC 6962 / Sigsum Merkle-tree hashing and proof verification — TRUST-1
/// residual. Ported from `sigsum.org/sigsum-go`'s `pkg/merkle` (functions
/// `HashLeafNode`/`HashInteriorNode`/`HashEmptyTree` in `merkle.go`,
/// `VerifyInclusion`/`VerifyConsistency`/`pathLength` in `verify.go`) — the
/// Go package is the reference implementation this file is checked against,
/// fetched and cross-read while building this port (not reconstructed from
/// memory).
///
/// ## The bug this corrects (Android `SigsumProof.kt`)
///
/// Android's scaffolding verifier hands its `leaf` parameter (in practice,
/// the bare 32-byte `SigsumLeaf.computeLeaf` message) directly to the
/// inclusion-proof reconstruction loop, as if it were already the tree's
/// leaf hash. Two things are missing:
///
/// 1. **The RFC 6962 leaf-hash prefix.** A Sigsum leaf hash is
///    `SHA-256(0x00 || tree_leaf)`, where `tree_leaf` is the 128-byte
///    `checksum(32B) || signature(64B) || key_hash(32B)` structure — not
///    the bare 32-byte checksum/message. Skipping the packaging step AND
///    the `0x00` prefix means Android's verifier is checking inclusion of
///    the wrong 32 bytes entirely; it would reject every real Sigsum
///    inclusion proof and, worse, could theoretically be fooled by a
///    coincidental collision between a raw message and some unrelated
///    tree's actual leaf hash.
/// 2. **No path-length check.** RFC 6962 §2.1.1 defines an exact expected
///    proof length for a given `(index, size)` pair (`pathLength` below).
///    A verifier that walks the supplied path blindly and only compares
///    the *final* reconstructed hash to the root accepts a proof that is
///    too short (silently promoting through levels it should have
///    consumed a sibling for) or too long (extra trailing garbage) as long
///    as the attacker can still land on the right root through some other
///    combination — this is exactly the "most common KT-verifier bug"
///    Android's own kdoc flags, and Android's `verifyInclusion` does not
///    actually implement the check its comment claims to.
///
/// Both are fixed here: `SigsumLeafRecord.toBinary()` in `SigsumProtocol`
/// builds the real 128-byte `tree_leaf`, `hashLeafNode` applies the `0x00`
/// prefix, and `verifyInclusion` rejects on `path.count != pathLength(...)`
/// before ever touching the reconstruction loop.
///
/// ## Live cross-check
///
/// This algorithm (index/size walk, `0x00`/`0x01` domain separation,
/// `pathLength` formula) was verified byte-for-byte against a REAL
/// inclusion proof fetched from `https://test.sigsum.org/barreleye`
/// (leaf index 100, tree size 214343) during development — see
/// `SigsumMerkleTests.testLiveBarreleyeFixture_*` for the frozen vector.
public enum SigsumMerkle {

    /// SHA-256 digest length.
    public static let hashSize = 32

    /// RFC 6962 §2.1 domain-separation prefixes.
    private static let leafPrefix: UInt8 = 0x00
    private static let interiorPrefix: UInt8 = 0x01

    /// `H(0x00 || tree_leaf)` — `tree_leaf` MUST already be the 128-byte
    /// `checksum || signature || key_hash` structure (`SigsumLeafRecord.toBinary()`),
    /// never a bare checksum/message.
    public static func hashLeafNode(_ treeLeaf: Data) -> Data {
        var input = Data(capacity: treeLeaf.count + 1)
        input.append(leafPrefix)
        input.append(treeLeaf)
        return Data(SHA256.hash(data: input))
    }

    /// `H(0x01 || left || right)`.
    public static func hashInteriorNode(_ left: Data, _ right: Data) -> Data {
        var input = Data(capacity: 1 + left.count + right.count)
        input.append(interiorPrefix)
        input.append(left)
        input.append(right)
        return Data(SHA256.hash(data: input))
    }

    /// Root hash of the empty tree — `H("")`.
    public static func hashEmptyTree() -> Data {
        Data(SHA256.hash(data: Data()))
    }

    /// RFC 6962 §2.1.1 expected inclusion-path length for `index` in a tree
    /// of `size` leaves. Direct port of `sigsum-go`'s `pathLength`:
    /// `k := bits.Len64(index ^ (size-1)); k + bits.OnesCount64(index >> k)`.
    /// `size` MUST be >= 1 (an empty tree has no leaves to prove).
    static func pathLength(index: UInt64, size: UInt64) -> Int {
        let x = index ^ (size - 1)
        let k = 64 - x.leadingZeroBitCount // Swift's UInt64 bit-length; 0 when x == 0
        // index >> 64 would trap; k can only reach 64 when x's top bit is
        // set, which cannot happen for any tree size this app will ever
        // see, but guard it anyway rather than assume.
        let shifted: UInt64 = k >= 64 ? 0 : (index >> UInt64(k))
        return k + shifted.nonzeroBitCount
    }

    public enum InclusionError: Error, Equatable {
        case indexOutOfRange
        case wrongPathLength(expected: Int, got: Int)
        case malformedHash(field: String)
        case rootMismatch
    }

    /// Verify that `leafHash` (already RFC-6962-prefixed — see
    /// `hashLeafNode`) is included at `index` in a tree of `size` leaves
    /// with root `root`, via sibling `path` (leaf-to-root order, as
    /// returned by `GET /get-inclusion-proof`). Equivalent to `sigsum-go`'s
    /// `merkle.VerifyInclusion`.
    ///
    /// `index == 0, size == 1` with an EMPTY path is the one degenerate
    /// valid case — the caller does not need to call this at all for that
    /// case (a size-1 tree's root IS its single leaf hash), but it is
    /// handled correctly here too.
    public static func verifyInclusion(
        leafHash: Data,
        index: UInt64,
        size: UInt64,
        root: Data,
        path: [Data]
    ) -> Result<Void, InclusionError> {
        guard leafHash.count == hashSize else { return .failure(.malformedHash(field: "leafHash")) }
        guard root.count == hashSize else { return .failure(.malformedHash(field: "root")) }
        guard size >= 1 else { return .failure(.indexOutOfRange) }
        guard index < size else { return .failure(.indexOutOfRange) }
        for p in path where p.count != hashSize {
            return .failure(.malformedHash(field: "path"))
        }

        // Load-bearing check Android's scaffolding skipped — see file kdoc.
        let wantLength = pathLength(index: index, size: size)
        guard path.count == wantLength else {
            return .failure(.wrongPathLength(expected: wantLength, got: path.count))
        }

        var r = leafHash
        var fn = index
        var sn = size - 1
        var next = 0
        while sn > 0 {
            if fn & 1 == 1 {
                // Node on path is left sibling.
                r = hashInteriorNode(path[next], r)
                next += 1
            } else if fn < sn {
                // Node on path is right sibling.
                r = hashInteriorNode(r, path[next])
                next += 1
            }
            // else: fn == sn and fn is even — this node is the rightmost
            // orphan for this level, promoted with no sibling consumed.
            fn >>= 1
            sn >>= 1
        }
        // The path-length check above guarantees `next == path.count` here;
        // this is a defensive belt-and-suspenders assertion, not a second
        // independent gate.
        guard next == path.count else {
            return .failure(.wrongPathLength(expected: next, got: path.count))
        }
        guard r == root else { return .failure(.rootMismatch) }
        return .success(())
    }

    public enum ConsistencyError: Error, Equatable {
        case nonEmptyPathForEqualSize
        case rootsDifferForEqualSize
        case nonEmptyPathForEmptyOldTree
        case wrongEmptyTreeRoot
        case wrongPathLength(expected: Int, got: Int)
        case malformedHash(field: String)
        case oldRootMismatch
        case newRootMismatch
    }

    /// Verify that a tree of `newSize` leaves with root `newRoot` is a
    /// consistent extension of a tree of `oldSize` leaves with root
    /// `oldRoot`, via `path` (as returned by `GET /get-consistency-proof`).
    /// Direct port of `sigsum-go`'s `merkle.VerifyConsistency` (RFC 9162
    /// §2.1.4.2 / RFC 6962-equivalent proof technique).
    ///
    /// Not required by `SigsumVerifier`'s single-proof accept decision —
    /// provided for completeness (a future high-water-mark `tree_size`
    /// cache, per Android `SigsumProof.kt`'s own kdoc, would use this to
    /// confirm a log never rewrote history between two observations).
    public static func verifyConsistency(
        oldSize: UInt64,
        newSize: UInt64,
        oldRoot: Data,
        newRoot: Data,
        path: [Data]
    ) -> Result<Void, ConsistencyError> {
        guard oldRoot.count == hashSize, newRoot.count == hashSize else {
            return .failure(.malformedHash(field: "root"))
        }
        for p in path where p.count != hashSize {
            return .failure(.malformedHash(field: "path"))
        }

        if oldSize == newSize {
            guard path.isEmpty else { return .failure(.nonEmptyPathForEqualSize) }
            guard oldRoot == newRoot else { return .failure(.rootsDifferForEqualSize) }
            return .success(())
        }
        if oldSize == 0 {
            guard path.isEmpty else { return .failure(.nonEmptyPathForEmptyOldTree) }
            guard oldRoot == hashEmptyTree() else { return .failure(.wrongEmptyTreeRoot) }
            return .success(())
        }

        let trimBits = oldSize.trailingZeroBitCount
        var fn = (oldSize - 1) >> trimBits
        var sn = (newSize - 1) >> trimBits

        let wantLength = pathLength(index: fn, size: sn + 1) + (fn > 0 ? 1 : 0)
        guard path.count == wantLength else {
            return .failure(.wrongPathLength(expected: wantLength, got: path.count))
        }

        var cursor = 0
        var fr: Data
        if fn == 0 {
            fr = oldRoot
        } else {
            fr = path[cursor]
            cursor += 1
        }
        var sr = fr

        while sn > 0 {
            if fn & 1 == 1 {
                fr = hashInteriorNode(path[cursor], fr)
                sr = hashInteriorNode(path[cursor], sr)
                cursor += 1
            } else if fn < sn {
                sr = hashInteriorNode(sr, path[cursor])
                cursor += 1
            }
            fn >>= 1
            sn >>= 1
        }

        guard fr == oldRoot else { return .failure(.oldRootMismatch) }
        guard sr == newRoot else { return .failure(.newRootMismatch) }
        return .success(())
    }
}
