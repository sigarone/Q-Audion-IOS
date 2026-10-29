import Foundation
#if canImport(Security)
import Security
#endif

/// Persistence contract for the symmetric-ratchet engine (`MessageRatchet`).
///
/// **Threading**: implementations MUST be thread-safe. Concurrent calls
/// are expected from send and receive paths.
///
/// **Synchrony**: `save` MUST flush durably before returning. The
/// encrypt path persists `CK_{n+1}` BEFORE the network `send()` and
/// depends on this contract — an asynchronous flush would re-introduce
/// the catastrophic nonce-reuse hazard (spec §6).
///
/// **Trust boundary**: the snapshot contains live chain keys. Production
/// implementations MUST encrypt at rest (Keychain-wrapped AES key, the
/// equivalent of Android's `EncryptedSharedPreferences`).
public protocol RatchetVault: AnyObject {
    /// Load a previously persisted snapshot, or `nil` if none exists.
    func load(epochId: String, peerId: String) -> RatchetSnapshot?

    /// W-KCAFTERUNLOCK (2026-09-01) — `load` with the locked-store case
    /// surfaced: returns `nil` ONLY for "nothing persisted", and throws
    /// `VaultError.deviceLocked` when the store exists but cannot be decrypted
    /// right now (iOS -25308 on a locked device). The protocol default forwards
    /// to `load`, so in-memory and test vaults — which cannot be locked — need
    /// not override it; `KeychainRatchetVault` does. `MessageRatchet
    /// .ensureSession` bootstraps a FRESH chain on nil, which is exactly why
    /// this exists.
    func loadChecked(epochId: String, peerId: String) throws -> RatchetSnapshot?

    /// Persist a snapshot — synchronous durable flush required.
    ///
    /// SECURITY C-7: this MUST throw on persistence failure. The encrypt
    /// path depends on a durable `CK_{n+1}` write BEFORE returning the
    /// wire blob; a silently-dropped write re-introduces the catastrophic
    /// nonce-reuse hazard (spec §6). Callers MUST treat a throw as fatal
    /// and NOT transmit the ciphertext.
    func save(epochId: String, peerId: String, snapshot: RatchetSnapshot) throws

    /// Delete the snapshot for `(epochId, peerId)`. No-op if missing.
    func delete(epochId: String, peerId: String)

    // ── v4 PQ-ratchet session blob (WIRE-FORMAT §4) ──────────────────────────
    //
    // The v4 native session (``MessageRatchet/serializeV4Session(_:)``) is an
    // OPAQUE byte blob owned end-to-end by the Rust core — NOT a
    // ``RatchetSnapshot``. It is stored under a SEPARATE keyspace so it never
    // collides with the v3.1 snapshot for the same `(epochId, peerId)`. Default
    // no-op / nil bodies (see the protocol extension below) so test doubles and
    // non-v4 implementations need not override them; only the production vault
    // provides durable v4 storage. Same write-ahead + encrypt-at-rest contract
    // as the v3.1 methods. Mirrors Android `RatchetVault.loadV4/saveV4/deleteV4`.

    /// Load a persisted v4 session blob (opaque ``MessageRatchet/serializeV4Session(_:)``
    /// output) for `(epochId, peerId)`, or `nil` if none exists. Default returns
    /// `nil` so a non-v4 vault transparently forces a re-bootstrap.
    func loadV4(epochId: String, peerId: String) -> Data?

    /// Persist a v4 session blob. MUST flush synchronously before returning
    /// (same write-ahead contract as ``save(epochId:peerId:snapshot:)``).
    ///
    /// SECURITY: `throws` so a persistence failure is fatal on the encrypt path
    /// — ``MessageRatchet/encryptV4Routed(peerId:plaintext:)`` write-ahead-saves
    /// the advanced send chain BEFORE returning the frame; a silently-dropped
    /// write would re-introduce a nonce-reuse window on crash. Default no-op.
    func saveV4(epochId: String, peerId: String, blob: Data) throws

    /// Delete the v4 session blob for `(epochId, peerId)`. Default no-op.
    func deleteV4(epochId: String, peerId: String)
}

// SECURITY / back-compat: default v4 bodies so existing vaults (and test
// doubles) that only implement the v3.1 surface keep compiling and transparently
// force a v4 re-bootstrap (loadV4 → nil). Production vaults (``KeychainRatchetVault``)
// and the in-memory test vault override these with durable storage. Mirrors
// Android's `interface RatchetVault { fun loadV4(...) = null; ... }` defaults.
public extension RatchetVault {
    func loadV4(epochId: String, peerId: String) -> Data? { nil }
    func saveV4(epochId: String, peerId: String, blob: Data) throws {}
    func deleteV4(epochId: String, peerId: String) {}
    // W-KCAFTERUNLOCK — a vault that cannot be locked answers exactly what
    // `load` answers.
    func loadChecked(epochId: String, peerId: String) throws -> RatchetSnapshot? {
        load(epochId: epochId, peerId: peerId)
    }
}

/// SECURITY C-7: persistence failures the ratchet vault may surface.
public enum VaultError: Error, Equatable {
    /// Keychain `SecItemAdd`/`SecItemUpdate` returned a non-success status.
    case persistFailed(OSStatus)
    /// W-KCAFTERUNLOCK (2026-09-01) — Keychain read refused with
    /// `errSecInteractionNotAllowed` (-25308): the device is locked, the
    /// snapshot is NOT known to be absent. Transient; never bootstrap over it.
    case deviceLocked
}
