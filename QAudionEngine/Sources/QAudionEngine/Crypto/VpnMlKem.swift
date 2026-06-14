import Foundation
import CryptoKit
import CLiboqs

/// Ephemeral ML-KEM-768 (FIPS 203) key exchange for the WireGuard VPN
/// preshared-key (PSK) handshake.
///
/// WHY A DEDICATED HELPER (not `PqcKeyExchange`):
/// `PqcKeyExchange` hardcodes `OQS_KEM_new("ML-KEM-1024")` for long-term DEVICE
/// identity keys (1568-byte pubkey). The bcrypto VPN server speaks **ML-KEM-768**
/// (1184-byte pubkey, 1088-byte ciphertext) and rejects a 1024 key. So the VPN
/// must use a FRESH EPHEMERAL ML-KEM-768 keypair per connection — never the
/// device's 1024 identity key. This helper provides exactly that, plus the
/// HKDF-SHA256 step that turns the decapsulated secret into the WG PresharedKey.
///
/// AVAILABILITY GATE (`isSupported`):
/// The vendored `CLiboqs` SPM target is currently a single-parameter build
/// (`MLK_CONFIG_PARAMETER_SET == 1024`); its `OQS_KEM_new` dispatcher only
/// matches "ML-KEM-1024" and returns NULL for "ML-KEM-768". Until a namespaced
/// ML-KEM-768 backend is added to `CLiboqs`, `OQS_KEM_new("ML-KEM-768")` yields
/// NULL and `isSupported` is `false`. Callers MUST check `isSupported` before
/// offering an `mlkem_pubkey` to the server: when unsupported, the VPN simply
/// omits the field and falls back to the classical `psk`, exactly as the server
/// contract specifies for an absent ciphertext. This fails CLOSED — it never
/// fabricates key material — so the handshake stays correct either way.
public enum VpnMlKem {

    /// liboqs algorithm identifier for ML-KEM-768 (FIPS 203).
    private static let algorithm = "ML-KEM-768"

    /// HKDF info label shared with the server. The PSK contract is:
    ///   PSK = HKDF-SHA256(IKM = sharedSecret, salt = <empty>,
    ///                     info = "bcrypto-wg-psk-v1", L = 32)
    /// Must match bcrypto-server and the Android client byte-for-byte.
    private static let hkdfInfo = Data("bcrypto-wg-psk-v1".utf8)

    /// Expected ML-KEM-768 sizes (FIPS 203). Used only for defensive
    /// validation of the liboqs-reported lengths — never to fabricate data.
    private static let publicKeySize = 1184
    private static let ciphertextSize = 1088

    /// A freshly generated ephemeral ML-KEM-768 keypair.
    ///
    /// `secretKey` is private decapsulation material — keep its lifetime as
    /// short as possible and do not log or persist it.
    public struct EphemeralKeyPair {
        /// 1184-byte ML-KEM-768 encapsulation (public) key, raw (no ASN.1).
        public let publicKey: Data
        /// 2400-byte ML-KEM-768 decapsulation (secret) key, raw.
        public let secretKey: Data
    }

    /// `true` when the linked liboqs build registers ML-KEM-768. When `false`,
    /// the VPN must not advertise a PQC pubkey and uses the classical PSK path.
    public static var isSupported: Bool {
        guard let kem = OQS_KEM_new(algorithm) else { return false }
        OQS_KEM_free(kem)
        return true
    }

    /// Generate a fresh ephemeral ML-KEM-768 keypair.
    ///
    /// Fails CLOSED: if liboqs has no ML-KEM-768 or keygen fails, this throws
    /// rather than returning random bytes (which would silently produce a PSK
    /// the server can never reproduce). Mirrors the C-9 hardening in
    /// `PqcKeyExchange.generateKeyPair`.
    public static func generateKeyPair() throws -> EphemeralKeyPair {
        guard let kem = OQS_KEM_new(algorithm) else {
            throw VpnMlKemError.kemUnavailable
        }
        defer { OQS_KEM_free(kem) }

        let pkSize = Int(kem.pointee.length_public_key)
        let skSize = Int(kem.pointee.length_secret_key)
        guard pkSize == publicKeySize else {
            throw VpnMlKemError.unexpectedKeySize
        }

        var publicKey = Data(count: pkSize)
        var secretKey = Data(count: skSize)

        let result = publicKey.withUnsafeMutableBytes { pkBuf in
            secretKey.withUnsafeMutableBytes { skBuf in
                OQS_KEM_keypair(kem,
                    pkBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    skBuf.baseAddress!.assumingMemoryBound(to: UInt8.self))
            }
        }

        guard result == OQS_SUCCESS else {
            throw VpnMlKemError.keypairGenerationFailed
        }

        return EphemeralKeyPair(publicKey: publicKey, secretKey: secretKey)
    }

    /// Decapsulate the server's ML-KEM-768 ciphertext into the 32-byte shared
    /// secret, then derive the WireGuard PSK via HKDF-SHA256.
    ///
    /// - Parameters:
    ///   - ciphertext: 1088-byte ML-KEM-768 ciphertext from the server.
    ///   - secretKey: the ephemeral secret key from `generateKeyPair`.
    /// - Returns: 32-byte preshared key (raw); base64-encode for WireGuard.
    ///
    /// A failure here is FATAL by design — when the server returned a
    /// ciphertext, the caller must NOT silently fall back to the classical
    /// `psk`. This throws so the caller fails closed.
    public static func derivePsk(ciphertext: Data, secretKey: Data) throws -> Data {
        let sharedSecret = try decapsulate(ciphertext: ciphertext, secretKey: secretKey)
        return deriveWgPsk(fromSharedSecret: sharedSecret)
    }

    /// PSK = HKDF-SHA256(IKM = sharedSecret, salt = EMPTY, info = label, L = 32).
    ///
    /// Split out from `derivePsk` so the HKDF step is unit-testable against a
    /// frozen cross-platform vector WITHOUT needing a live ML-KEM-768 KEM (the
    /// vendored liboqs may be 1024-only). Matches `CallSessionKeyBroker`'s
    /// CryptoKit HKDF usage and the bcrypto-server / Android client byte-for-byte.
    static func deriveWgPsk(fromSharedSecret sharedSecret: Data) -> Data {
        let psk = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: Data(),
            info: hkdfInfo,
            outputByteCount: 32
        )
        return psk.withUnsafeBytes { Data($0) }
    }

    /// Decapsulate ciphertext → 32-byte ML-KEM shared secret. Internal step of
    /// `derivePsk`; exposed `internal` for unit testing the wiring.
    static func decapsulate(ciphertext: Data, secretKey: Data) throws -> Data {
        guard ciphertext.count == ciphertextSize else {
            throw VpnMlKemError.invalidCiphertext
        }
        guard !secretKey.isEmpty else { throw VpnMlKemError.emptySecretKey }

        guard let kem = OQS_KEM_new(algorithm) else {
            throw VpnMlKemError.kemUnavailable
        }
        defer { OQS_KEM_free(kem) }

        let ssSize = Int(kem.pointee.length_shared_secret)
        var sharedSecret = Data(count: ssSize)

        let result = sharedSecret.withUnsafeMutableBytes { ssBuf in
            ciphertext.withUnsafeBytes { ctBuf in
                secretKey.withUnsafeBytes { skBuf in
                    OQS_KEM_decaps(kem,
                        ssBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ctBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        skBuf.baseAddress!.assumingMemoryBound(to: UInt8.self))
                }
            }
        }

        guard result == OQS_SUCCESS else {
            throw VpnMlKemError.decapsulationFailed
        }
        return sharedSecret
    }
}

public enum VpnMlKemError: Error, Equatable {
    /// liboqs has no ML-KEM-768 registered in this build (single-param 1024
    /// CLiboqs). The caller must use the classical PSK path instead.
    case kemUnavailable
    /// `OQS_KEM_keypair` returned non-success. No random fallback.
    case keypairGenerationFailed
    /// liboqs reported a public-key length other than 1184 for ML-KEM-768.
    case unexpectedKeySize
    /// Server ciphertext was not 1088 bytes (ML-KEM-768).
    case invalidCiphertext
    /// Empty decapsulation secret key supplied.
    case emptySecretKey
    /// `OQS_KEM_decaps` failed — FATAL, never fall back to classical PSK.
    case decapsulationFailed
}
