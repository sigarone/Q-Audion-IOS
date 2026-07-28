import Foundation
import CryptoKit

/// KMS Transport — decrypts pre-shared keys (PSKs) delivered by the
/// BCrypto server's `/api/v1/kms/pending` endpoint.
///
/// Mirror of the Android `KmsTransport.kt` 3-tier classification +
/// the Desktop `KmsTransport.ts` decrypt path. Cross-platform contract
/// pinned in `WIRE_SPEC.md §2`.
///
/// Tier discrimination by package length:
///   - `pkg.count >= 1628` → legacy KEM-hybrid (full PQ confidentiality)
///   - `pkg.count >= 60`   → classical first, on AEAD auth fail AND
///                           mlkemPubkey on file → binding-hybrid retry
///   - else                → reject (too short)
///
/// ## Wire formats
///
///   Classical (60+ bytes):
///       ephPubKey(32) || nonce(12) || ciphertext+tag(N+16)
///       key = HKDF-SHA256(IKM = X25519-ECDH(devicePriv, ephPubKey),
///                         salt = "bcrypto-kms-salt-v1",
///                         info = "bcrypto-kms-psk-v1",
///                         L    = 32)
///
///   Binding-Hybrid (exactly 92 bytes):
///       ephPubKey(32) || nonce(12) || ciphertext+tag(48)
///       Same wire shape as classical; tier distinguished by the IKM:
///       key = HKDF-SHA256(IKM = X25519-ECDH(devicePriv, ephPubKey)
///                              || SHA-256(deviceMlkemPubKey),
///                         salt = "bcrypto-kms-hybrid-salt-v1",
///                         info = "bcrypto-kms-hybrid-pqc-v1",
///                         L    = 32)
///       Crypto note: SHA-256(pqPub) BINDS the ciphertext to the
///       ML-KEM key identity (defence in depth) but does NOT provide
///       post-quantum confidentiality (the X25519 ECDH is still the
///       only secrecy primitive). True PQ confidentiality lives in
///       legacy KEM-hybrid below.
///
///   Legacy KEM-Hybrid (1628+ bytes):
///       ephPubKey(32) || kemCT(1568) || nonce(12) || ciphertext+tag
///       key = HKDF-SHA256(IKM = X25519-ECDH(devicePriv, ephPubKey)
///                              || ML-KEM-1024-Decap(devicePriv, kemCT),
///                         salt = "bcrypto-kms-hybrid-salt-v1",
///                         info = "bcrypto-kms-hybrid-pqc-v1",
///                         L    = 32)
public enum KmsTransport {

    public enum Error: Swift.Error {
        case packageTooShort(actual: Int, minClassical: Int)
        case missingMlkemPublicKey
        case missingMlkemPrivateKey
        case malformedHeader
        case classicalDecryptFailed(underlying: Swift.Error)
        case bindingHybridDecryptFailed(underlying: Swift.Error)
        case legacyKemDecryptFailed(underlying: Swift.Error)
    }

    // MARK: - Constants (cross-platform contract — WIRE_SPEC §1)

    private static let CLASSICAL_INFO = Data("bcrypto-kms-psk-v1".utf8)
    private static let CLASSICAL_SALT = Data("bcrypto-kms-salt-v1".utf8)
    private static let HYBRID_INFO    = Data("bcrypto-kms-hybrid-pqc-v1".utf8)
    private static let HYBRID_SALT    = Data("bcrypto-kms-hybrid-salt-v1".utf8)

    private static let X25519_PUB_BYTES = 32
    private static let GCM_NONCE_BYTES  = 12
    private static let GCM_TAG_BYTES    = 16
    private static let ML_KEM_CT_BYTES  = 1568
    private static let CLASSICAL_HEADER = X25519_PUB_BYTES + GCM_NONCE_BYTES        // 44
    private static let LEGACY_HEADER    = X25519_PUB_BYTES + ML_KEM_CT_BYTES + GCM_NONCE_BYTES  // 1612
    private static let MIN_CLASSICAL    = CLASSICAL_HEADER + GCM_TAG_BYTES          // 60
    private static let MIN_LEGACY       = LEGACY_HEADER + GCM_TAG_BYTES             // 1628

    // MARK: - v2 constants (§3.2 frozen wire — KMS Rotation v2)

    static let V2_CLASSICAL_INFO = Data("bcrypto-kms-psk-v2".utf8)
    static let V2_CLASSICAL_SALT = Data("bcrypto-kms-salt-v1".utf8)
    static let V2_HYBRID_INFO    = Data("bcrypto-kms-hybrid-pqc-v2".utf8)
    static let V2_HYBRID_SALT    = Data("bcrypto-kms-hybrid-salt-v1".utf8)
    static let V2_AAD_PREFIX     = Data("qa-kms-psk-v2".utf8)   // 13 B

    /// §3.2 key_class wire byte. Used both as the AAD trailing byte and
    /// as the routing class for the v2 phone-held / sovereign split.
    public enum KeyClassV2: String {
        case shared = "shared"
        case hwOnly = "hw_only"
        case swOnly = "sw_only"
        public var byte: UInt8 {
            switch self {
            case .shared: return 0x01
            case .hwOnly: return 0x02
            case .swOnly: return 0x03
            }
        }
        public init?(wire: String?) {
            switch wire {
            case "shared":  self = .shared
            case "hw_only": self = .hwOnly
            case "sw_only": self = .swOnly
            default: return nil
            }
        }
    }

    /// RFC 4122 network-order 16 raw bytes (matches §3 "UUIDs encoded as
    /// raw 16 bytes"). Single source of truth for the v2 byte encoders;
    /// reused by `KmsPoPV1`. `internal` so same-module code can call it.
    static func uuidBytes(_ uuid: UUID) -> Data {
        let u = uuid.uuid
        return Data([u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
    }

    /// 8-byte big-endian uint64 (the `key_epoch(8 BE)` field).
    static func epochBE(_ epoch: UInt64) -> Data {
        var be = epoch.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    /// §3.2 AAD (identical for classical and hybrid v2):
    ///   "qa-kms-psk-v2"(13) || key_id(16) || user_id(16) || device_id(16)
    ///   || key_epoch(8 BE) || txn_id(16) || key_class_byte(1)   = 86 B
    public static func buildAadV2(
        keyId: UUID, userId: UUID, deviceId: UUID,
        keyEpoch: UInt64, txnId: UUID, keyClass: KeyClassV2
    ) -> Data {
        var aad = Data(capacity: 86)
        aad.append(V2_AAD_PREFIX)
        aad.append(uuidBytes(keyId))
        aad.append(uuidBytes(userId))
        aad.append(uuidBytes(deviceId))
        aad.append(epochBE(keyEpoch))
        aad.append(uuidBytes(txnId))
        aad.append(keyClass.byte)
        return aad
    }

    public struct V2Result {
        public let psk: Data
        /// The IKM fed to the wrap HKDF for THIS delivery — also fed to
        /// the qa-kms-pop-v1 PoP HKDF (§3.4). classical = 32B (ECDH),
        /// hybrid = 64B (ECDH || ss_pq).
        public let wrapSecret: Data
    }

    /// v2 decrypt (§3.2). Tier (classical vs hybrid) is selected by the
    /// presence of an ML-KEM private key AND the package length:
    ///   hybrid wire = ephPub(32) || ct_pq(1568) || nonce(12) || ct+tag
    ///   classical   = ephPub(32) || nonce(12) || ct+tag
    /// Returns the recovered PSK AND the per-delivery wrap secret (for PoP).
    public static func decryptPackageV2(
        pkg: Data,
        x25519Priv: Data,
        mlkemPriv: Data?,
        mlkemPub: Data?,
        keyId: UUID, userId: UUID, deviceId: UUID,
        keyEpoch: UInt64, txnId: UUID, keyClass: KeyClassV2
    ) throws -> V2Result {
        let aad = buildAadV2(keyId: keyId, userId: userId, deviceId: deviceId,
                             keyEpoch: keyEpoch, txnId: txnId, keyClass: keyClass)
        let hybridMin = X25519_PUB_BYTES + ML_KEM_CT_BYTES + GCM_NONCE_BYTES + GCM_TAG_BYTES // 1628
        if let priv = mlkemPriv, pkg.count >= hybridMin {
            let parts = try parseHeader(pkg, kemCtBytes: ML_KEM_CT_BYTES)
            var dh = try ecdh(priv: x25519Priv, peerPub: parts.ephPub)
            var ssPq: Data
            do {
                // force-unwrap safe: parseHeader was called with
                // kemCtBytes: ML_KEM_CT_BYTES (1568, > 0), which makes
                // parts.kemCt guaranteed non-nil (see parseHeader's ternary).
                // swiftlint:disable:next force_unwrapping
                ssPq = try PqcKeyExchange().decapsulate(ciphertext: parts.kemCt!, privateKey: priv)
            } catch {
                CryptoConstants.zeroize(&dh)
                throw Error.legacyKemDecryptFailed(underlying: error)
            }
            var ikm = Data(capacity: dh.count + ssPq.count)
            ikm.append(dh); ikm.append(ssPq)
            let aead = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: ikm),
                salt: V2_HYBRID_SALT, info: V2_HYBRID_INFO, outputByteCount: 32)
            let psk = try aeadOpenAad(nonce: parts.nonce, ctTag: parts.ctTag, key: aead, aad: aad)
            let wrap = Data(ikm)            // 64B copy for the PoP step
            CryptoConstants.zeroize(&ikm); CryptoConstants.zeroize(&ssPq); CryptoConstants.zeroize(&dh)
            return V2Result(psk: psk, wrapSecret: wrap)
        }
        // classical
        let parts = try parseHeader(pkg, kemCtBytes: 0)
        var dh = try ecdh(priv: x25519Priv, peerPub: parts.ephPub)
        let aead = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: dh),
            salt: V2_CLASSICAL_SALT, info: V2_CLASSICAL_INFO, outputByteCount: 32)
        let psk = try aeadOpenAad(nonce: parts.nonce, ctTag: parts.ctTag, key: aead, aad: aad)
        let wrap = Data(dh)                 // 32B copy for the PoP step
        CryptoConstants.zeroize(&dh)
        return V2Result(psk: psk, wrapSecret: wrap)
    }

    /// AEAD open with AAD (v2 binding). Mirrors `aeadOpen` but feeds AAD.
    private static func aeadOpenAad(nonce: Data, ctTag: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard ctTag.count >= GCM_TAG_BYTES else { throw Error.malformedHeader }
        let tag = ctTag.suffix(GCM_TAG_BYTES)
        let ct  = ctTag.prefix(ctTag.count - GCM_TAG_BYTES)
        let sealed = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: Data(ct), tag: Data(tag))
        return try AES.GCM.open(sealed, using: key, authenticating: aad)
    }

    // MARK: - Public entry point

    /// Decrypt a server-issued KMS package, auto-detecting the wire
    /// format. Returns the recovered 32-byte PSK on success.
    ///
    /// - Parameters:
    ///   - pkg: The full serialised wire blob from
    ///          `KmsKeyDto.encryptedPackage` (NOT the split eph/nonce
    ///          fields — those are convenience accessors; the blob is
    ///          authoritative).
    ///   - x25519Priv: The 32-byte raw X25519 private key registered
    ///                 via `BCryptoKmsClient.registerPublicKey`.
    ///   - mlkemPub: The 1568-byte raw ML-KEM-1024 public key the
    ///               device registered (server hashes this into the
    ///               IKM for the binding-hybrid tier — only required
    ///               when classical fails).
    ///   - mlkemPriv: The 3168-byte raw ML-KEM-1024 private key. Only
    ///                required for the legacy KEM-hybrid tier (1628+
    ///                bytes).
    public static func decryptPackage(
        pkg: Data,
        x25519Priv: Data,
        mlkemPub: Data?,
        mlkemPriv: Data?
    ) throws -> Data {
        if pkg.count >= MIN_LEGACY {
            guard let priv = mlkemPriv else { throw Error.missingMlkemPrivateKey }
            return try decryptLegacyKemHybrid(pkg: pkg, x25519Priv: x25519Priv, mlkemPriv: priv)
        }
        if pkg.count >= MIN_CLASSICAL {
            // Per OpenRouter glm-5.1 review 2026-05-06: narrow the
            // catch to AEAD auth failures specifically, otherwise
            // we'd retry as binding-hybrid on EVERY failure mode
            // (malformed nonce, garbage X25519 pub, etc.) and hide
            // the real diagnostic.
            do {
                return try decryptClassical(pkg: pkg, x25519Priv: x25519Priv)
            } catch CryptoKitError.authenticationFailure {
                // Auth tag mismatch on classical — try binding-hybrid
                // ONLY if the device has an ML-KEM pubkey registered
                // (otherwise the server can't have emitted binding-
                // hybrid). The "auth failed" signal here is the
                // authoritative tier discriminator because the wire
                // shape is identical between the two tiers.
                if let pub = mlkemPub {
                    do {
                        return try decryptBindingHybrid(
                            pkg: pkg, x25519Priv: x25519Priv, mlkemPub: pub)
                    } catch {
                        throw Error.bindingHybridDecryptFailed(underlying: error)
                    }
                }
                throw Error.classicalDecryptFailed(underlying: CryptoKitError.authenticationFailure)
            } catch {
                throw Error.classicalDecryptFailed(underlying: error)
            }
        }
        throw Error.packageTooShort(actual: pkg.count, minClassical: MIN_CLASSICAL)
    }

    // MARK: - UUID helpers

    /// Parse a UUID (dashed RFC 4122 or bare 32-hex) into raw 16 bytes (network order).
    /// Mirrors Android KmsTransport.uuid16().
    /// - Throws: `Error.invalidUuid` if the string is not 32 hex chars (after removing dashes).
    public static func uuid16(_ uuid: String) throws -> Data {
        let hex = uuid.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32 else {
            throw UuidError.invalidLength(hex.count)
        }
        var result = Data(count: 16)
        for i in 0..<16 {
            let lo = hex.index(hex.startIndex, offsetBy: i * 2)
            let hi = hex.index(lo, offsetBy: 2)
            guard let byte = UInt8(hex[lo..<hi], radix: 16) else {
                throw UuidError.invalidHex(position: i * 2)
            }
            result[i] = byte
        }
        return result
    }

    public enum UuidError: Swift.Error {
        case invalidLength(Int)
        case invalidHex(position: Int)
    }

    // MARK: - Tier impls

    private static func decryptClassical(
        pkg: Data,
        x25519Priv: Data
    ) throws -> Data {
        let parts = try parseHeader(pkg, kemCtBytes: 0)
        var dh = try ecdh(priv: x25519Priv, peerPub: parts.ephPub)
        defer { CryptoConstants.zeroize(&dh) }
        let aesKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: dh),
            salt: CLASSICAL_SALT,
            info: CLASSICAL_INFO,
            outputByteCount: 32
        )
        return try aeadOpen(nonce: parts.nonce, ctTag: parts.ctTag, key: aesKey)
    }

    private static func decryptBindingHybrid(
        pkg: Data,
        x25519Priv: Data,
        mlkemPub: Data
    ) throws -> Data {
        let parts = try parseHeader(pkg, kemCtBytes: 0)
        var dh = try ecdh(priv: x25519Priv, peerPub: parts.ephPub)
        var ikm = Data(capacity: 64)
        ikm.append(dh)
        ikm.append(contentsOf: SHA256.hash(data: mlkemPub))
        let aesKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: HYBRID_SALT,
            info: HYBRID_INFO,
            outputByteCount: 32
        )
        CryptoConstants.zeroize(&ikm)
        CryptoConstants.zeroize(&dh)
        return try aeadOpen(nonce: parts.nonce, ctTag: parts.ctTag, key: aesKey)
    }

    private static func decryptLegacyKemHybrid(
        pkg: Data,
        x25519Priv: Data,
        mlkemPriv: Data
    ) throws -> Data {
        let parts = try parseHeader(pkg, kemCtBytes: ML_KEM_CT_BYTES)
        var dh = try ecdh(priv: x25519Priv, peerPub: parts.ephPub)
        var kemSs: Data
        do {
            // force-unwrap safe: same as decryptHybrid above — parseHeader
            // called with kemCtBytes: ML_KEM_CT_BYTES (1568) guarantees
            // parts.kemCt is non-nil.
            // swiftlint:disable:next force_unwrapping
            kemSs = try PqcKeyExchange().decapsulate(
                ciphertext: parts.kemCt!,
                privateKey: mlkemPriv
            )
        } catch {
            CryptoConstants.zeroize(&dh)
            throw Error.legacyKemDecryptFailed(underlying: error)
        }
        var ikm = Data(capacity: dh.count + kemSs.count)
        ikm.append(dh)
        ikm.append(kemSs)
        let aesKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: HYBRID_SALT,
            info: HYBRID_INFO,
            outputByteCount: 32
        )
        CryptoConstants.zeroize(&ikm)
        CryptoConstants.zeroize(&kemSs)
        CryptoConstants.zeroize(&dh)
        return try aeadOpen(nonce: parts.nonce, ctTag: parts.ctTag, key: aesKey)
    }

    // MARK: - Helpers

    private struct Parts {
        let ephPub: Data
        let kemCt: Data?     // only legacy KEM-hybrid
        let nonce: Data
        let ctTag: Data
    }

    /// Parse the wire blob into its constituent slices. Uses a fresh
    /// Data copy for each slice so AES.GCM.open / AES.GCM.Nonce see
    /// 0-indexed buffers (Swift Data slices retain the parent
    /// startIndex which is fine for these CryptoKit constructors but
    /// gets brittle when downstream code does pointer arithmetic).
    private static func parseHeader(_ pkg: Data, kemCtBytes: Int) throws -> Parts {
        let minSize = X25519_PUB_BYTES + kemCtBytes + GCM_NONCE_BYTES + GCM_TAG_BYTES
        guard pkg.count >= minSize else {
            throw Error.malformedHeader
        }
        let ephPub = Data(pkg.prefix(X25519_PUB_BYTES))
        let kemCt: Data? = kemCtBytes > 0
            ? Data(pkg.dropFirst(X25519_PUB_BYTES).prefix(kemCtBytes))
            : nil
        let nonceStart = X25519_PUB_BYTES + kemCtBytes
        let nonce = Data(pkg.dropFirst(nonceStart).prefix(GCM_NONCE_BYTES))
        let ctTag = Data(pkg.dropFirst(nonceStart + GCM_NONCE_BYTES))
        return Parts(ephPub: ephPub, kemCt: kemCt, nonce: nonce, ctTag: ctTag)
    }

    private static func ecdh(priv: Data, peerPub: Data) throws -> Data {
        let privKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: priv)
        let pubKey  = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPub)
        let secret  = try privKey.sharedSecretFromKeyAgreement(with: pubKey)
        return secret.withUnsafeBytes { Data($0) }
    }

    private static func aeadOpen(nonce: Data, ctTag: Data, key: SymmetricKey) throws -> Data {
        guard ctTag.count >= GCM_TAG_BYTES else { throw Error.malformedHeader }
        let tag = ctTag.suffix(GCM_TAG_BYTES)
        let ct  = ctTag.prefix(ctTag.count - GCM_TAG_BYTES)
        let sealed = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: Data(ct),
            tag: Data(tag)
        )
        return try AES.GCM.open(sealed, using: key)
    }
}
