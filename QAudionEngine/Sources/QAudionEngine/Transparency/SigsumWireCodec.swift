import Foundation

/// TRUST-1 residual — ASCII `Key=Value\n` wire codec for the Sigsum log
/// HTTP protocol (`log.md` §3) and the packaged "sigsum proof" bundle
/// format (`sigsum-proof.md`). Byte formats below (field order, hex vs.
/// decimal, the double-newline block separators in the proof-bundle
/// format, the `size <= 1` omitted-last-block corner case) were read
/// directly off those two spec documents fetched during this port, with
/// the `get-tree-head`/`get-inclusion-proof` shapes additionally
/// cross-checked against a REAL response from
/// `https://test.sigsum.org/barreleye` — see `SigsumWireCodecTests`.
public enum SigsumWireError: Error, Equatable {
    case malformed(String)
}

public enum SigsumWireCodec {

    /// Split raw ASCII wire text into `(key, value)` pairs, one per line,
    /// preserving order and duplicate keys (`cosignature`/`node_hash`/`leaf`
    /// all repeat). A line with no `=` is dropped rather than treated as an
    /// error — matches the reference parser's tolerance of a trailing blank
    /// line used as an explicit block/list terminator.
    static func splitLines(_ raw: String) -> [(key: String, value: String)] {
        raw.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            guard let eq = line.firstIndex(of: "=") else { return nil }
            return (String(line[line.startIndex..<eq]), String(line[line.index(after: eq)...]))
        }
    }

    // MARK: - GET /get-tree-head (uncosigned shape — size + root_hash only)

    public static func parseTreeHead(_ raw: String) throws -> SigsumTreeHead {
        var size: UInt64?
        var root: Data?
        for (key, value) in splitLines(raw) {
            switch key {
            case "size": size = UInt64(value)
            case "root_hash": root = SigsumHex.decode(value)
            default: break
            }
        }
        guard let s = size, let r = root, r.count == SigsumCrypto.hashSize else {
            throw SigsumWireError.malformed("get-tree-head: missing/invalid size or root_hash")
        }
        return SigsumTreeHead(size: s, rootHash: r)
    }

    // MARK: - GET /get-tree-head (full cosigned response, log.md §3.1)

    public static func parseCosignedTreeHead(_ raw: String) throws -> SigsumCosignedTreeHead {
        var size: UInt64?
        var root: Data?
        var sig: Data?
        var cosigs: [SigsumCosignature] = []
        for (key, value) in splitLines(raw) {
            switch key {
            case "size": size = UInt64(value)
            case "root_hash": root = SigsumHex.decode(value)
            case "signature": sig = SigsumHex.decode(value)
            case "cosignature":
                let parts = value.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count == 3,
                      let keyHash = SigsumHex.decode(String(parts[0])), keyHash.count == SigsumCrypto.hashSize,
                      let timestamp = UInt64(parts[1]),
                      let cosig = SigsumHex.decode(String(parts[2])), cosig.count == SigsumCrypto.signatureSize
                else { throw SigsumWireError.malformed("cosignature line: \(value)") }
                cosigs.append(SigsumCosignature(witnessKeyHash: keyHash, timestamp: timestamp, signature: cosig))
            default: break
            }
        }
        guard let s = size, let r = root, r.count == SigsumCrypto.hashSize,
              let sg = sig, sg.count == SigsumCrypto.signatureSize
        else { throw SigsumWireError.malformed("get-tree-head: missing/invalid size, root_hash or signature") }

        // log.md §3.1: "cosignature lines must carry distinct key hashes, no duplicates."
        let hashes = cosigs.map { $0.witnessKeyHash }
        guard Set(hashes).count == hashes.count else {
            throw SigsumWireError.malformed("get-tree-head: duplicate cosignature key hash")
        }
        return SigsumCosignedTreeHead(
            signedTreeHead: SigsumSignedTreeHead(treeHead: SigsumTreeHead(size: s, rootHash: r), signature: sg),
            cosignatures: cosigs
        )
    }

    // MARK: - GET /get-inclusion-proof/<size>/<leaf_hash>

    public static func parseInclusionProof(_ raw: String) throws -> SigsumInclusionProof {
        var index: UInt64?
        var path: [Data] = []
        for (key, value) in splitLines(raw) {
            switch key {
            case "leaf_index": index = UInt64(value)
            case "node_hash":
                guard let h = SigsumHex.decode(value), h.count == SigsumCrypto.hashSize else {
                    throw SigsumWireError.malformed("node_hash: \(value)")
                }
                path.append(h)
            default: break
            }
        }
        guard let i = index else { throw SigsumWireError.malformed("get-inclusion-proof: missing leaf_index") }
        return SigsumInclusionProof(leafIndex: i, path: path)
    }

    // MARK: - GET /get-consistency-proof/<old_size>/<new_size>

    public static func parseConsistencyProof(_ raw: String) throws -> SigsumConsistencyProof {
        var path: [Data] = []
        for (key, value) in splitLines(raw) where key == "node_hash" {
            guard let h = SigsumHex.decode(value), h.count == SigsumCrypto.hashSize else {
                throw SigsumWireError.malformed("node_hash: \(value)")
            }
            path.append(h)
        }
        return SigsumConsistencyProof(path: path)
    }

    // MARK: - GET /get-leaves/<start>/<end>

    public static func parseLeaves(_ raw: String) throws -> [SigsumLeafRecord] {
        var out: [SigsumLeafRecord] = []
        for (key, value) in splitLines(raw) where key == "leaf" {
            let parts = value.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let checksum = SigsumHex.decode(String(parts[0])), checksum.count == SigsumCrypto.hashSize,
                  let signature = SigsumHex.decode(String(parts[1])), signature.count == SigsumCrypto.signatureSize,
                  let keyHash = SigsumHex.decode(String(parts[2])), keyHash.count == SigsumCrypto.hashSize
            else { throw SigsumWireError.malformed("leaf line: \(value)") }
            out.append(SigsumLeafRecord(checksum: checksum, signature: signature, keyHash: keyHash))
        }
        guard !out.isEmpty else { throw SigsumWireError.malformed("get-leaves: no leaves") }
        return out
    }

    // MARK: - POST /add-leaf request body

    public static func encodeAddLeafRequest(message: Data, signature: Data, publicKey: Data) -> Data {
        let text = "message=\(SigsumHex.encode(message))\nsignature=\(SigsumHex.encode(signature))\npublic_key=\(SigsumHex.encode(publicKey))\n"
        return Data(text.utf8)
    }

    // MARK: - Packaged "sigsum proof" bundle (sigsum-proof.md, version 2)
    //
    // ```
    // version=2
    // log=KEYHASH
    // leaf=KEYHASH SIGNATURE
    //
    // size=NUMBER
    // root_hash=HASH
    // signature=SIGNATURE
    // cosignature=KEYHASH TIMESTAMP SIGNATURE
    // ...
    //
    // leaf_index=NUMBER
    // node_hash=HASH
    // ...
    // ```
    // Blocks are separated by a blank line (`\n\n`). The last block is
    // OMITTED entirely when `size <= 1` (sigsum-proof.md: "for size = 1,
    // it is implied that leaf_index = 0 and there is no inclusion path" —
    // a proof with size = 0 is always invalid).

    public static func parseProofBundle(_ raw: String) throws -> SigsumProofBundle {
        let blocks = raw.trimmingCharacters(in: .newlines).components(separatedBy: "\n\n")
        guard blocks.count == 2 || blocks.count == 3 else {
            throw SigsumWireError.malformed("proof bundle: expected 2 or 3 blocks, got \(blocks.count)")
        }

        var version: Int?
        var logKeyHash: Data?
        var leafKeyHash: Data?
        var leafSignature: Data?
        for (key, value) in splitLines(blocks[0]) {
            switch key {
            case "version": version = Int(value)
            case "log":
                guard let h = SigsumHex.decode(value), h.count == SigsumCrypto.hashSize else {
                    throw SigsumWireError.malformed("proof bundle: log key hash")
                }
                logKeyHash = h
            case "leaf":
                let parts = value.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count == 2,
                      let kh = SigsumHex.decode(String(parts[0])), kh.count == SigsumCrypto.hashSize,
                      let sg = SigsumHex.decode(String(parts[1])), sg.count == SigsumCrypto.signatureSize
                else { throw SigsumWireError.malformed("proof bundle: leaf line") }
                leafKeyHash = kh
                leafSignature = sg
            default: break
            }
        }
        guard version == 2 else { throw SigsumWireError.malformed("proof bundle: unsupported/missing version") }
        guard let lkh = logKeyHash else { throw SigsumWireError.malformed("proof bundle: missing log line") }
        guard let fkh = leafKeyHash, let fsig = leafSignature else {
            throw SigsumWireError.malformed("proof bundle: missing leaf line")
        }

        let cth = try parseCosignedTreeHead(blocks[1])

        var inclusion: SigsumInclusionProof?
        if blocks.count == 3 {
            inclusion = try parseInclusionProof(blocks[2])
        } else {
            guard cth.signedTreeHead.treeHead.size <= 1 else {
                throw SigsumWireError.malformed("proof bundle: missing inclusion-proof block for size > 1")
            }
        }

        return SigsumProofBundle(
            version: 2,
            logKeyHash: lkh,
            leafKeyHash: fkh,
            leafSignature: fsig,
            cosignedTreeHead: cth,
            inclusionProof: inclusion
        )
    }

    /// Inverse of `parseProofBundle` — mainly for round-trip tests, but
    /// also usable by a future submitter path to serialize a bundle it
    /// assembled itself for local storage/distribution.
    public static func encodeProofBundle(_ bundle: SigsumProofBundle) -> String {
        var out = "version=\(bundle.version)\n"
        out += "log=\(SigsumHex.encode(bundle.logKeyHash))\n"
        out += "leaf=\(SigsumHex.encode(bundle.leafKeyHash)) \(SigsumHex.encode(bundle.leafSignature))\n"
        out += "\n"
        let sth = bundle.cosignedTreeHead.signedTreeHead
        out += "size=\(sth.treeHead.size)\n"
        out += "root_hash=\(SigsumHex.encode(sth.treeHead.rootHash))\n"
        out += "signature=\(SigsumHex.encode(sth.signature))\n"
        for cs in bundle.cosignedTreeHead.cosignatures {
            out += "cosignature=\(SigsumHex.encode(cs.witnessKeyHash)) \(cs.timestamp) \(SigsumHex.encode(cs.signature))\n"
        }
        if let proof = bundle.inclusionProof {
            out += "\n"
            out += "leaf_index=\(proof.leafIndex)\n"
            for node in proof.path {
                out += "node_hash=\(SigsumHex.encode(node))\n"
            }
        }
        return out
    }
}

/// A packaged, self-contained Sigsum proof (`sigsum-proof.md` version 2) —
/// everything a verifier needs about the LOG side of an accept decision.
/// The checksum is deliberately NOT a field here: `sigsum-proof.md` §"Verifying
/// a proof" step 1 requires it be recomputed locally from the `message` the
/// caller already has out-of-band, never trusted from the wire — see
/// `SigsumVerifier.verify`.
public struct SigsumProofBundle: Equatable {
    public let version: Int
    public let logKeyHash: Data
    public let leafKeyHash: Data
    public let leafSignature: Data
    public let cosignedTreeHead: SigsumCosignedTreeHead
    /// `nil` only legally when `cosignedTreeHead.signedTreeHead.treeHead.size <= 1`.
    public let inclusionProof: SigsumInclusionProof?

    public init(
        version: Int,
        logKeyHash: Data,
        leafKeyHash: Data,
        leafSignature: Data,
        cosignedTreeHead: SigsumCosignedTreeHead,
        inclusionProof: SigsumInclusionProof?
    ) {
        self.version = version
        self.logKeyHash = logKeyHash
        self.leafKeyHash = leafKeyHash
        self.leafSignature = leafSignature
        self.cosignedTreeHead = cosignedTreeHead
        self.inclusionProof = inclusionProof
    }
}
