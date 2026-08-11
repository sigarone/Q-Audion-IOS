import Foundation
import QAudionEngine

/// BLE-mesh feature gate + node-id derivation helpers for the app target.
///
/// **API design (CLAUDE.md section 16):** every function here takes only
/// primitives (`String`, `Data`) — never `AppState`. `MeshFeature` is a
/// stateless `enum` namespace (no stored/observable state of its own), so
/// nothing here needs a closure-based provider either; callers (e.g.
/// `ChatContainer`, `AppState`) already hold whatever context they need and
/// pass it in as plain values.
///
/// **Flag key:** `mesh_ble.enabled` — the SAME server-side flag key the
/// Android client (`New-Q-Audion-Android`, branch
/// `claude/ble-mesh-cleanroom-spike`) reads via its own `MeshFeatureGate`,
/// so one remote flag flip gates both apps identically. `FeatureFlags`
/// (this file's only dependency beyond `QAudionEngine`) already owns the
/// polling/caching/fail-safe-default machinery — this type adds no new
/// infrastructure, it just names the key and the compiled-in default
/// (`false`).
public enum MeshFeature {

    /// Master switch for the in-chat mesh entry point (antenna icon, sheet,
    /// and therefore the BLE radio, which is only ever touched from inside
    /// the sheet). Reads live off `FeatureFlags` on every call — cheap (an
    /// in-memory dictionary lookup), so there is no need to cache or poll
    /// separately the way Android's `MeshFeatureGate` bridges into a
    /// `StateFlow`. Defaults to `false`: a fresh install, or a build where
    /// the flag hasn't been fetched yet, never shows the entry point and
    /// never requests Bluetooth permissions.
    @MainActor
    public static var enabled: Bool {
        FeatureFlags.bool("mesh_ble.enabled", false)
    }

    /// Derive this device's own mesh node id from its long-term identity
    /// public key (raw bytes, whatever format the caller's identity/signing
    /// layer produces — the derivation is SHA-256 truncation, format
    /// agnostic). Returns a random-but-stable-for-this-call id when no
    /// identity key is available yet, mirroring
    /// `BleMeshTransportImpl.localNodeId`'s Android fallback, so a transport
    /// can still start (and simply be unreachable/unrecognized by anyone)
    /// before identity bootstrap completes.
    public static func localNodeId(identityKeyRaw raw: Data?) -> MeshNodeId {
        if let raw, let id = MeshNodeId.from(identityKeyRaw: raw) {
            return id
        }
        return MeshNodeId.random()
    }

    /// The mesh node id a given contact would advertise, derived from their
    /// stored long-term identity public key (`ContactsStore.StoredContact.pubkey`
    /// — the iOS analogue of Android's `ContactEntity.identityKeyEd25519PubB64`).
    /// `nil` when the contact's identity key isn't known locally yet (e.g.
    /// never paired via QR/NFC) — same caveat Android's `MeshNodeIdentity`
    /// carries: a genuinely offline-first contact may be exactly the one
    /// whose key isn't cached.
    public static func nodeId(forContactPubkey pubkey: Data?) -> MeshNodeId? {
        guard let pubkey, !pubkey.isEmpty else { return nil }
        return MeshNodeId.from(identityKeyRaw: pubkey)
    }
}
