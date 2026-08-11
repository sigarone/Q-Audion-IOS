import Foundation
import CryptoKit

/// AES-256-GCM wrapping for the `MeshPacketType.announce` control payload,
/// so a generic BLE scanner/sniffer that connects to a Q-Audion GATT server
/// (or captures the notify/write traffic of an existing connection) sees
/// random bytes instead of a device's mesh node id, identity fingerprint,
/// and neighbor list. 1:1 port of the Android sibling's
/// `MeshDiscoveryCipher.kt` — same key derivation labels, same wire shape.
///
/// **What this is NOT — read before relying on it:** the key below is a
/// fixed constant, HKDF-derived from a public label, embedded identically
/// in every Q-Audion install (iOS and Android both). It is NOT a secret
/// between two users, and it does NOT protect against another Q-Audion
/// install (or anyone who extracts the key from the app binary) reading an
/// ANNOUNCE. It is an **app-recognition boundary**, not a user-privacy
/// boundary: it raises the bar from "any BLE scanner app can read this" to
/// "must possess/reverse a Q-Audion binary to read this". Genuine
/// per-relationship unlinkability is NOT implemented here: `MeshNodeId` is
/// the mesh's actual routing address (every packet's senderId/recipientId,
/// used for relay/topology), not a pure advertisement value, so rotating it
/// session-to-session would need a materially bigger redesign that this
/// change deliberately does not attempt.
///
/// AES-GCM's random-per-call nonce already means the on-the-wire ciphertext
/// bytes differ every time even for the identical plaintext, so this alone
/// also removes any *ciphertext-level* correlator for an observer who
/// cannot decrypt at all.
public enum MeshDiscoveryCipher {

    /// Fixed, non-secret, app-wide key. HKDF-derived from a public label
    /// (mirrors `HkdfLabels`' convention) rather than a literal byte array,
    /// purely so the provenance is documented and auditable — deriving it
    /// changes nothing about its security properties versus a hardcoded
    /// key, since the input keying material below is public.
    private static let key: SymmetricKey = {
        let ikm = SymmetricKey(data: Data("Q-Audion-Mesh-Discovery-Shared-Seed-v1".utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Data("q-audion-mesh-discovery-salt-v1".utf8),
            info: Data("q-audion-mesh-discovery-v1".utf8),
            outputByteCount: 32
        )
    }()

    /// Encrypts `plaintext` (a `MeshAnnounce.encode()` result) for the wire.
    /// Wire shape: `nonce(12) || ciphertext || tag(16)` — same as the
    /// Android sibling's manual layout, produced here by AES.GCM's
    /// `combined` representation.
    public static func encrypt(_ plaintext: Data) -> Data? {
        guard let sealed = try? AES.GCM.seal(plaintext, using: key) else { return nil }
        return sealed.combined
    }

    /// Decrypts an ANNOUNCE payload produced by `encrypt`. Returns `nil`
    /// (never throws) on anything that isn't a validly-shaped,
    /// validly-tagged Q-Audion mesh ANNOUNCE — malformed input, a
    /// non-Q-Audion sender, or a corrupted frame all collapse to the same
    /// "ignore it" outcome, exactly like `MeshPacket.decode`/
    /// `MeshAnnounce.decode`.
    public static func decrypt(_ wire: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: wire) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}
