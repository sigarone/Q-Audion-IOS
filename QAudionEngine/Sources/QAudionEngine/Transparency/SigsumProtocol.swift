import Foundation
import CryptoKit

/// TRUST-1 residual — core Sigsum wire types plus the namespace-separated
/// Ed25519 signing/verification primitives from `sigsum.org/sigsum-go`'s
/// `pkg/types` (`leaf.go`, `tree_head.go`) and `pkg/crypto` (`crypto.go`,
/// `AttachNamespace`). Every constant and byte layout below was read
/// directly off that reference source (fetched via the GitHub API while
/// building this port), not reconstructed from memory or from the
/// Android scaffolding, which never implemented most of this.
public enum SigsumCrypto {

    public static let hashSize = 32
    public static let signatureSize = 64
    public static let publicKeySize = 32

    /// `sigsum-go/pkg/types/leaf.go`: `TreeLeafNamespace`.
    static let treeLeafNamespace = "sigsum.org/v1/tree-leaf"
    /// `sigsum-go/pkg/types/tree_head.go`: `CosignatureNamespace`.
    static let cosignatureNamespace = "cosignature/v1"
    /// `sigsum-go/pkg/types/tree_head.go`: `CheckpointNamePrefix`.
    static let checkpointOriginPrefix = "sigsum.org/v1/tree/"
    /// `log.md` §4.1: the rate-limit submit-token namespace.
    static let submitTokenNamespace = "sigsum.org/v1/submit-token"

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// `AttachNamespace(namespace, msg) = namespace (ASCII) || 0x00 || msg`
    /// — `sigsum-go/pkg/crypto/crypto.go`'s `AttachNamespace`. Every signed
    /// statement in the Sigsum protocol (leaf, submit-token) uses this
    /// wrapper; tree-head/cosignature statements use the related
    /// three/four-line checkpoint text format instead (`formatCheckpoint`/
    /// `cosignedData` below), not `AttachNamespace` — kept as two separate
    /// helpers rather than unifying them, matching the reference
    /// implementation's own split.
    public static func attachNamespace(_ namespace: String, _ message: Data) -> Data {
        var out = Data(namespace.utf8)
        out.append(0x00)
        out.append(message)
        return out
    }

    /// Fail-closed Ed25519 verify: malformed key/signature or a bad
    /// signature all return `false`, never throw — same discipline as
    /// `FileAttachmentAnnounceSig.verify`/`WipeCommandVerifier.verify`
    /// elsewhere in this codebase.
    public static func verifyEd25519(publicKey: Data, message: Data, signature: Data) -> Bool {
        guard publicKey.count == publicKeySize, signature.count == signatureSize else { return false }
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return pub.isValidSignature(signature, for: message)
    }

    /// Signs with a raw 32-byte Ed25519 seed. Only used by this app when
    /// acting as a *submitter* (or when building test fixtures) — the
    /// verifier itself never signs anything.
    public static func signEd25519(privateKeySeed: Data, message: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeySeed)
        return try key.signature(for: message)
    }

    // MARK: - Leaf signing (sigsum-go leaf.go: leafSignedData / SignLeafChecksum / VerifyLeafChecksum)

    /// The exact 56 bytes an Ed25519 leaf signature covers:
    /// `"sigsum.org/v1/tree-leaf"` (23 ASCII bytes) `|| 0x00 || checksum` (32 bytes).
    public static func leafSignedData(checksum: Data) -> Data {
        attachNamespace(treeLeafNamespace, checksum)
    }

    public static func signLeafChecksum(submitterPrivateKeySeed: Data, checksum: Data) throws -> Data {
        try signEd25519(privateKeySeed: submitterPrivateKeySeed, message: leafSignedData(checksum: checksum))
    }

    public static func verifyLeafSignature(submitterPublicKey: Data, checksum: Data, signature: Data) -> Bool {
        verifyEd25519(publicKey: submitterPublicKey, message: leafSignedData(checksum: checksum), signature: signature)
    }

    // MARK: - Checkpoint / tree head (sigsum-go tree_head.go: FormatCheckpoint / SigsumCheckpointOrigin)

    /// `"sigsum.org/v1/tree/" + lowercase_hex(SHA-256(logPublicKey))`.
    public static func checkpointOrigin(logPublicKey: Data) -> String {
        checkpointOriginPrefix + SigsumHex.encode(sha256(logPublicKey))
    }

    /// The checkpoint body a log signs (and witnesses cosign, wrapped —
    /// see `cosignedData`): `origin || "\n" || size || "\n" || base64(root_hash) || "\n"`.
    public static func formatCheckpoint(origin: String, size: UInt64, rootHash: Data) -> Data {
        Data("\(origin)\n\(size)\n\(rootHash.base64EncodedString())\n".utf8)
    }

    /// Verify a log's tree-head signature under its own (policy-pinned)
    /// public key — NEVER under a key hash the proof itself claims; the
    /// caller must have already resolved `logPublicKey` from a trusted
    /// policy by matching `SHA256(logPublicKey)` against the proof's
    /// claimed log key hash (`SigsumPolicy.log(withKeyHash:)`).
    public static func verifyTreeHeadSignature(logPublicKey: Data, size: UInt64, rootHash: Data, signature: Data) -> Bool {
        let origin = checkpointOrigin(logPublicKey: logPublicKey)
        return verifyEd25519(publicKey: logPublicKey, message: formatCheckpoint(origin: origin, size: size, rootHash: rootHash), signature: signature)
    }

    // MARK: - Cosignature (sigsum-go tree_head.go: toCosignedData / Cosign / Verify)

    /// `"cosignature/v1" || "\n" || "time " || timestamp || "\n" || checkpoint`.
    public static func cosignedData(origin: String, timestamp: UInt64, size: UInt64, rootHash: Data) -> Data {
        var out = Data("\(cosignatureNamespace)\ntime \(timestamp)\n".utf8)
        out.append(formatCheckpoint(origin: origin, size: size, rootHash: rootHash))
        return out
    }

    public static func verifyCosignature(
        witnessPublicKey: Data, origin: String, timestamp: UInt64, size: UInt64, rootHash: Data, signature: Data
    ) -> Bool {
        verifyEd25519(publicKey: witnessPublicKey, message: cosignedData(origin: origin, timestamp: timestamp, size: size, rootHash: rootHash), signature: signature)
    }

    // MARK: - Submit token / rate limiting (log.md §4)
    //
    // NOT part of the verifier's accept decision — this is the submitter
    // side of rate limiting. Implemented per the research spec because the
    // production path needs it regardless of today's TEST-log posture
    // ("no rate-limit token needed for reasonable test volume"). See
    // `SigsumPolicy`'s production-policy doc comment for the DNS TXT record
    // this depends on and who has to publish it.

    /// The 59 octets a rate-limit key signs: `"sigsum.org/v1/submit-token"`
    /// (26 ASCII bytes) `|| 0x00 || log_public_key` (32 bytes).
    public static func submitTokenSignedData(logPublicKey: Data) -> Data {
        attachNamespace(submitTokenNamespace, logPublicKey)
    }

    public static func signSubmitToken(rateLimitPrivateKeySeed: Data, logPublicKey: Data) throws -> Data {
        try signEd25519(privateKeySeed: rateLimitPrivateKeySeed, message: submitTokenSignedData(logPublicKey: logPublicKey))
    }

    public static func verifySubmitToken(rateLimitPublicKey: Data, logPublicKey: Data, signature: Data) -> Bool {
        verifyEd25519(publicKey: rateLimitPublicKey, message: submitTokenSignedData(logPublicKey: logPublicKey), signature: signature)
    }

    /// The `sigsum-token` HTTP request header value: `"<domain> <hex signature>"`.
    /// `domain` is the registered domain WITHOUT the `_sigsum_v1.` label
    /// (the label is implicit — log.md §4.2).
    public static func submitTokenHeaderValue(domain: String, signature: Data) -> String {
        "\(domain) \(SigsumHex.encode(signature))"
    }
}

// MARK: - Wire value types

/// One `tree_leaf` record as the log stores/returns it:
/// `checksum(32B) || signature(64B) || key_hash(32B)` = 128 bytes.
public struct SigsumLeafRecord: Equatable {
    public let checksum: Data
    public let signature: Data
    public let keyHash: Data

    public init(checksum: Data, signature: Data, keyHash: Data) {
        self.checksum = checksum
        self.signature = signature
        self.keyHash = keyHash
    }

    public var isWellFormed: Bool {
        checksum.count == SigsumCrypto.hashSize
            && signature.count == SigsumCrypto.signatureSize
            && keyHash.count == SigsumCrypto.hashSize
    }

    /// The 128-byte binary `tree_leaf` structure fed to `SigsumMerkle.hashLeafNode`.
    public func toBinary() -> Data {
        var out = Data(capacity: 128)
        out.append(checksum)
        out.append(signature)
        out.append(keyHash)
        return out
    }
}

public struct SigsumTreeHead: Equatable {
    public let size: UInt64
    public let rootHash: Data

    public init(size: UInt64, rootHash: Data) {
        self.size = size
        self.rootHash = rootHash
    }
}

public struct SigsumSignedTreeHead: Equatable {
    public let treeHead: SigsumTreeHead
    public let signature: Data

    public init(treeHead: SigsumTreeHead, signature: Data) {
        self.treeHead = treeHead
        self.signature = signature
    }
}

public struct SigsumCosignature: Equatable {
    public let witnessKeyHash: Data
    public let timestamp: UInt64
    public let signature: Data

    public init(witnessKeyHash: Data, timestamp: UInt64, signature: Data) {
        self.witnessKeyHash = witnessKeyHash
        self.timestamp = timestamp
        self.signature = signature
    }
}

public struct SigsumCosignedTreeHead: Equatable {
    public let signedTreeHead: SigsumSignedTreeHead
    public let cosignatures: [SigsumCosignature]

    public init(signedTreeHead: SigsumSignedTreeHead, cosignatures: [SigsumCosignature]) {
        self.signedTreeHead = signedTreeHead
        self.cosignatures = cosignatures
    }
}

public struct SigsumInclusionProof: Equatable {
    public let leafIndex: UInt64
    public let path: [Data]

    public init(leafIndex: UInt64, path: [Data]) {
        self.leafIndex = leafIndex
        self.path = path
    }
}

public struct SigsumConsistencyProof: Equatable {
    public let path: [Data]

    public init(path: [Data]) {
        self.path = path
    }
}

/// Small hex codec shared by the wire codec and the policy/KAT constants —
/// kept dependency-free (no Foundation `Scanner`/regex) and constant in
/// behaviour: lowercase output, strict even-length lowercase-or-uppercase
/// hex input, `nil` on anything else.
public enum SigsumHex {
    public static func encode(_ data: Data) -> String {
        var out = String()
        out.reserveCapacity(data.count * 2)
        for b in data { out += String(format: "%02x", b) }
        return out
    }

    public static func decode(_ hex: String) -> Data? {
        if hex.isEmpty { return Data() }
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }
}
