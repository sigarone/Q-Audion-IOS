import Foundation
import CryptoKit

/// Long-term device-key lifecycle for the iOS KMS pipeline.
///
/// Closes the WIRE_SPEC §5 P1 gap "iOS KMS device-key persistence".
/// Without this, every app launch generated fresh X25519 + ML-KEM
/// keypairs and registered them with the server — but server-emitted
/// KMS packages were sealed against a previous, now-discarded
/// pubkey, so AES-GCM auth always failed.
///
/// Mirror of Android `DeviceKeyProvisioner.kt` + `KmsTransport.kt`'s
/// device-key accessors. Cross-platform contract: WIRE_SPEC §2.6.
///
/// ## Storage model
///
/// Three private keys + two public keys persist in the iOS Keychain
/// via `SovereignKeyVault` reuse, namespaced under fixed labels so
/// they don't collide with KMS-issued PSKs (which are namespaced by
/// the server's keyId UUID):
///   - `__device.x25519.priv`  : 32-byte raw X25519 private key
///   - `__device.x25519.pub`   : 32-byte raw X25519 public key
///   - `__device.mlkem.priv`   : 3168-byte raw ML-KEM-1024 private
///   - `__device.mlkem.pub`    : 1568-byte raw ML-KEM-1024 public
///
/// ## Lifecycle
///
/// - `ensureProvisioned()`: fetches existing keys from the vault;
///   if absent, generates fresh keypairs, persists them, and
///   registers the public keys via `BCryptoKmsClient.registerPublicKey`.
///   Idempotent — safe to call on every app launch.
/// - `currentKeys()`: reads the persisted keys for use by
///   `KmsPollerService.pollOnce`. Returns nil for ML-KEM if the
///   keys have never been generated (e.g. fresh install on iOS 13
///   target where ML-KEM might be unavailable — currently liboqs
///   covers all our supported targets).
/// `@unchecked Sendable` because the type is final + reads/writes go
/// through the `SovereignKeyVault` (Keychain-backed, thread-safe). The
/// only mutable state is the cached keypair, mutated under the
/// vault's lock indirectly. Safe to capture inside @Sendable closures
/// (e.g. the device-renew fallback installed in BCryptoRestClient).
public final class DeviceKeyManager: @unchecked Sendable {

    public enum Error: Swift.Error {
        case keychainCorrupt
        case mlkemUnavailable
        case registrationFailed(underlying: Swift.Error)
    }

    private static let LABEL_X25519_PRIV = "__device.x25519.priv"
    private static let LABEL_X25519_PUB  = "__device.x25519.pub"
    private static let LABEL_MLKEM_PRIV  = "__device.mlkem.priv"
    private static let LABEL_MLKEM_PUB   = "__device.mlkem.pub"
    // 2026-05-06 session-renewal Phase 2 — Ed25519 device signing key
    // for /auth/device-renew. Stored in the same SovereignKeyVault as
    // the KMS keys; the private scalar lives under
    // `__device.ed25519.priv` (32-byte raw seed). The public key is
    // published via `BCryptoKmsClient.registerPublicKey(ed25519PubKey:)`.
    private static let LABEL_ED25519_PRIV = "__device.ed25519.priv"
    private static let LABEL_ED25519_PUB  = "__device.ed25519.pub"
    private static let DEVICE_FP_LABEL   = "device-key"

    private let vault: SovereignKeyVault
    private let kmsClient: BCryptoKmsClient
    private let pqc = PqcKeyExchange()

    public init(vault: SovereignKeyVault, kmsClient: BCryptoKmsClient) {
        self.vault = vault
        self.kmsClient = kmsClient
    }

    /// Ensure the device has long-term X25519 + ML-KEM keypairs in
    /// the Keychain, AND that the public keys are registered on the
    /// server. Idempotent: re-publishes the registered pubkeys on
    /// every call so a server-side data loss (e.g. bbolt rebuild)
    /// can be papered over by the next app launch.
    @discardableResult
    public func ensureProvisioned() async throws -> KmsPollerService.DeviceKeys {
        // 1. Load OR generate the X25519 keypair.
        let x25519Priv: Data
        let x25519Pub: Data
        if let existingPriv = try vault.loadPsk(name: Self.LABEL_X25519_PRIV),
           let existingPub  = try vault.loadPsk(name: Self.LABEL_X25519_PUB),
           existingPriv.count == 32, existingPub.count == 32 {
            x25519Priv = existingPriv
            x25519Pub  = existingPub
        } else {
            let priv = Curve25519.KeyAgreement.PrivateKey()
            x25519Priv = Data(priv.rawRepresentation)
            x25519Pub  = Data(priv.publicKey.rawRepresentation)
            try vault.storePsk(name: Self.LABEL_X25519_PRIV, key: x25519Priv,
                               fingerprint: Self.DEVICE_FP_LABEL)
            try vault.storePsk(name: Self.LABEL_X25519_PUB, key: x25519Pub,
                               fingerprint: Self.DEVICE_FP_LABEL)
        }

        // 2. Load OR generate the ML-KEM keypair. ML-KEM keypair
        //    generation goes through liboqs which is bundled in the
        //    Sources/CLiboqs target — should be available on every
        //    iOS target the engine builds for. Failure is treated as
        //    "ML-KEM unavailable" → fall back to classical-only KMS
        //    (server will emit 60-byte packages until the device
        //    re-registers with a real ML-KEM pubkey).
        let mlkemPriv: Data?
        let mlkemPub: Data?
        if let existingPriv = try vault.loadPsk(name: Self.LABEL_MLKEM_PRIV),
           let existingPub  = try vault.loadPsk(name: Self.LABEL_MLKEM_PUB),
           !existingPriv.isEmpty, !existingPub.isEmpty {
            mlkemPriv = existingPriv
            mlkemPub  = existingPub
        } else {
            // pqc.generateKeyPair returns (pubKey, privKey) per the
            // PqcKeyExchange.KeyPair contract documented in that
            // file's header.
            let kp = try pqc.generateKeyPair()
            let priv = kp.privateKey
            let pub  = try PqcKeyExchange.extractRawPublicKey(kp.publicKey)
            try vault.storePsk(name: Self.LABEL_MLKEM_PRIV, key: priv,
                               fingerprint: Self.DEVICE_FP_LABEL)
            try vault.storePsk(name: Self.LABEL_MLKEM_PUB, key: pub,
                               fingerprint: Self.DEVICE_FP_LABEL)
            mlkemPriv = priv
            mlkemPub  = pub
        }

        // 2b. Phase 2 session-renewal — load OR generate the Ed25519
        //     signing keypair. Stored alongside the KMS keys; never
        //     deleted on logout (mirrors Android's Ed25519DeviceSigner
        //     contract). Used to sign /auth/device-renew blobs.
        let ed25519Pub: Data
        if let existingEdPriv = try vault.loadPsk(name: Self.LABEL_ED25519_PRIV),
           let existingEdPub  = try vault.loadPsk(name: Self.LABEL_ED25519_PUB),
           existingEdPriv.count == 32, existingEdPub.count == 32 {
            ed25519Pub = existingEdPub
        } else {
            let priv = Curve25519.Signing.PrivateKey()
            let privData = Data(priv.rawRepresentation)
            let pubData = Data(priv.publicKey.rawRepresentation)
            try vault.storePsk(name: Self.LABEL_ED25519_PRIV, key: privData,
                               fingerprint: Self.DEVICE_FP_LABEL)
            try vault.storePsk(name: Self.LABEL_ED25519_PUB, key: pubData,
                               fingerprint: Self.DEVICE_FP_LABEL)
            ed25519Pub = pubData
        }

        // 3. Register the public keys with the server. We re-publish
        //    even when the keys came from the vault — the server
        //    might have lost the row (bbolt rebuild, devices_pub_keys
        //    bucket reset etc.) and keeping the call idempotent makes
        //    recovery automatic.
        do {
            try await kmsClient.registerPublicKey(
                publicKey: x25519Pub,
                mlkemEncapKey: mlkemPub,
                keyType: "x25519",
                ed25519PubKey: ed25519Pub
            )
        } catch {
            // Non-fatal — the local keys still work for any package
            // already pre-encrypted to them. Log and surface as an
            // explicit error so the caller can decide whether to
            // retry. We do NOT delete the local keys on registration
            // failure — they may already match what the server has.
            print("[DeviceKeyManager] registerPublicKey failed (local keys retained): \(error)")
            throw Error.registrationFailed(underlying: error)
        }

        return KmsPollerService.DeviceKeys(
            x25519Priv: x25519Priv,
            mlkemPub: mlkemPub,
            mlkemPriv: mlkemPriv
        )
    }

    /// Read-only accessor for the stashed keys. Returns nil when the
    /// device hasn't been provisioned yet (caller should invoke
    /// `ensureProvisioned()` first). Used by `KmsPollerService` on
    /// the WS `kms_key_available` event hot-path so we don't make a
    /// network round-trip when the keys are already on disk.
    public func currentKeys() throws -> KmsPollerService.DeviceKeys? {
        guard let x25519Priv = try vault.loadPsk(name: Self.LABEL_X25519_PRIV),
              x25519Priv.count == 32 else { return nil }
        let mlkemPriv = try vault.loadPsk(name: Self.LABEL_MLKEM_PRIV)
        let mlkemPub  = try vault.loadPsk(name: Self.LABEL_MLKEM_PUB)
        return KmsPollerService.DeviceKeys(
            x25519Priv: x25519Priv,
            mlkemPub: mlkemPub,
            mlkemPriv: mlkemPriv
        )
    }

    /// 2026-05-06 session-renewal Phase 2 — Ed25519 signing accessor.
    /// Returns the per-device 32-byte raw private seed needed to sign
    /// /auth/device-renew blobs. The caller is responsible for keeping
    /// the seed in memory only as long as needed. nil if the device
    /// hasn't been provisioned yet.
    public func currentEd25519Priv() throws -> Data? {
        let priv = try vault.loadPsk(name: Self.LABEL_ED25519_PRIV)
        guard let priv, priv.count == 32 else { return nil }
        return priv
    }

    /// Public-only counterpart of `currentEd25519Priv` for places that
    /// only need the pubkey (e.g. re-publishing on /device/publickey).
    public func currentEd25519Pub() throws -> Data? {
        let pub = try vault.loadPsk(name: Self.LABEL_ED25519_PUB)
        guard let pub, pub.count == 32 else { return nil }
        return pub
    }

    /// gap A2 / ADR-014a — public-only counterpart of the device's own
    /// X25519 identity public key. `currentKeys()` only surfaces
    /// `x25519Priv` (needed for the classical KMS PSK-decrypt hot path);
    /// the KMS-prebootstrap receive path (`AppState.decodeKmsPreBootstrapEnvelope`)
    /// additionally needs the PUBLIC half so it can rebuild the same
    /// `receiverIkX25519PubOrZeros` transcript field the sender hashed in
    /// (which must match whatever this device's identity bundle publishes
    /// as its X25519 leg). Mirrors the `currentEd25519Pub` accessor above.
    public func currentX25519Pub() throws -> Data? {
        let pub = try vault.loadPsk(name: Self.LABEL_X25519_PUB)
        guard let pub, pub.count == 32 else { return nil }
        return pub
    }
}
