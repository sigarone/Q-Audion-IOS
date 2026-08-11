import Foundation
import CryptoKit

/// This file is an original Swift port of the *behavior* described in
/// Q-Audion Android's BLE-mesh functional spec
/// (`docs/ble-mesh/BLE_MESH_ARCHITECTURE_STUDY.md` in the Android repo,
/// branch `claude/ble-mesh-cleanroom-spike`). No source code, identifiers,
/// or comments were copied from that (or any third-party) implementation —
/// this is original Swift expressing the same wire semantics idiomatically.
///
/// Every type in this `Mesh/` directory is framework-free: no `CoreBluetooth`,
/// no `UIKit`, no app-level `AppState` import. That is what makes it
/// unit-testable on the plain `swift test` CI path (`engine-tests.yml`)
/// without a device or simulator — BLE itself has no reliable emulator, but
/// packet framing, fragmentation, relay policy, and topology bookkeeping are
/// pure data transforms and can be pinned with real `XCTest`s.
///
/// Non-negotiable invariant carried by every file in this directory (see
/// ``MeshChatMessage`` for where it matters most): the mesh layer is ALWAYS
/// an opaque envelope around ciphertext already produced by the app's
/// EXISTING message encryption (`QAudionEngine/Crypto/MessageCrypto.swift`
/// and friends). Nothing here ever sees plaintext, and nothing here invents
/// a KDF/AEAD/handshake of its own.

/// 8-byte mesh node identity, canonicalized as lowercase hex (16 chars).
///
/// Backed by a `String`, not a `Data`/`[UInt8]` wrapper — Swift's `Data`
/// and `Array` both already get correct value-type `Equatable`/`Hashable`
/// (unlike Kotlin's `ByteArray`, which is reference-equal), but the hex
/// `String` is still the friendlier canonical form for wire-adjacent code
/// (JSON control payloads, log lines, dictionary keys) and this type is on
/// that boundary constantly.
public struct MeshNodeId: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {

    public static let sizeBytes = 8
    public static let hexLength = sizeBytes * 2

    public let hex: String

    public enum MeshNodeIdError: Error, Equatable {
        case wrongLength(Int)
        case notLowercaseHex(String)
    }

    /// Fails (rather than trapping) on malformed input — a node id can
    /// originate from the network (an ANNOUNCE payload, a decoded packet
    /// header), so validation must be recoverable, not a `precondition`.
    public init(hex: String) throws {
        guard hex.count == Self.hexLength else {
            throw MeshNodeIdError.wrongLength(hex.count)
        }
        guard hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            throw MeshNodeIdError.notLowercaseHex(hex)
        }
        self.hex = hex
    }

    /// Sentinel recipient meaning "every reachable node". A packet's
    /// recipient field is always populated on the wire (never absent) so a
    /// receiver can tell "explicitly broadcast" apart from "malformed" —
    /// see ``MeshPacket``.
    public static let broadcast = try! MeshNodeId(hex: String(repeating: "f", count: hexLength))

    public static func fromBytes(_ bytes: Data) -> MeshNodeId? {
        guard bytes.count == sizeBytes else { return nil }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return try? MeshNodeId(hex: hex)
    }

    public func toBytes() -> Data {
        var out = Data(capacity: Self.sizeBytes)
        var idx = hex.startIndex
        for _ in 0..<Self.sizeBytes {
            let next = hex.index(idx, offsetBy: 2)
            out.append(UInt8(hex[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        return out
    }

    public static func random() -> MeshNodeId {
        var bytes = Data(count: sizeBytes)
        _ = bytes.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, sizeBytes, base)
        }
        return fromBytes(bytes) ?? broadcast
    }

    /// Derive a stable 8-byte node id from a peer's long-term identity
    /// public key by truncating SHA-256(key) to the first 8 bytes.
    /// Observer-independent — the same key always yields the same node id
    /// on every device — so it is safe to broadcast (in an ANNOUNCE) and to
    /// match against a locally-stored contact key, unlike a pairwise
    /// fingerprint.
    ///
    /// Deliberate iOS adaptation, documented in `docs/ble-mesh/`: Android's
    /// contact model caches a raw Ed25519 public key per contact
    /// (`ContactEntity.identityKeyEd25519PubB64`) and derives from that.
    /// iOS's `ContactsStore.StoredContact.pubkey` is the equivalent
    /// long-term identity key field (populated by the QR-pairing flow); this
    /// function is format-agnostic (any raw key bytes in, SHA-256 truncate)
    /// so it works unchanged against that field.
    public static func from(identityKeyRaw raw: Data) -> MeshNodeId? {
        guard !raw.isEmpty else { return nil }
        let digest = SHA256.hash(data: raw)
        let truncated = Data(digest.prefix(sizeBytes))
        return fromBytes(truncated)
    }

    public var description: String { hex }
}
