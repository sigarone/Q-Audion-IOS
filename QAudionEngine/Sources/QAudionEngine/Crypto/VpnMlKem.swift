import Foundation
import CryptoKit
import CLiboqs

/// Ephemeral ML-KEM-1024 (FIPS 203, NIST category 5) key exchange for the
/// WireGuard VPN preshared-key (PSK) handshake.
///
/// WHY A DEDICATED HELPER (not `PqcKeyExchange`):
/// `PqcKeyExchange` uses `OQS_KEM_new("ML-KEM-1024")` for the device's LONG-TERM
/// identity keys. The VPN needs a FRESH EPHEMERAL keypair per connection (its own
/// forward secrecy), never the device identity key — so this helper provides
/// ephemeral ML-KEM-1024 keygen + decapsulation, plus the HKDF-SHA256 step that
/// turns the decapsulated secret into the WG PresharedKey. The whole VPN stack
/// (server, Android, desktop, iOS) shares the ML-KEM-1024 parameter set, so all
/// four interoperate with no extra liboqs vendoring.
///
/// AVAILABILITY GATE (`isSupported`):
/// `isSupported` defensively checks that the linked liboqs actually registers
/// ML-KEM-1024 (it does — the same backend the device identity keys already use).
/// If a future build ever dropped it, `isSupported` would be `false` and the
/// caller omits `mlkem_pubkey`, falling back to the classical `psk` exactly as
/// the server contract specifies for an absent ciphertext. This fails CLOSED —
/// it never fabricates key material — so the handshake stays correct either way.
public enum VpnMlKem {

    /// liboqs algorithm identifier for ML-KEM-1024 (FIPS 203).
    private static let algorithm = "ML-KEM-1024"

    /// HKDF info label shared with the server. The PSK contract is:
    ///   PSK = HKDF-SHA256(IKM = sharedSecret, salt = <empty>,
    ///                     info = "bcrypto-wg-psk-v1", L = 32)
    /// Must match bcrypto-server and the Android client byte-for-byte.
    private static let hkdfInfo = Data("bcrypto-wg-psk-v1".utf8)

    /// Expected ML-KEM-1024 sizes (FIPS 203). Used only for defensive
    /// validation of the liboqs-reported lengths — never to fabricate data.
    private static let publicKeySize = 1568
    private static let ciphertextSize = 1568

    /// A freshly generated ephemeral ML-KEM-1024 keypair.
    ///
    /// `secretKey` is private decapsulation material — keep its lifetime as
    /// short as possible and do not log or persist it.
    public struct EphemeralKeyPair {
        /// 1568-byte ML-KEM-1024 encapsulation (public) key, raw (no ASN.1).
        public let publicKey: Data
        /// 3168-byte ML-KEM-1024 decapsulation (secret) key, raw.
        public let secretKey: Data
    }

    /// `true` when the linked liboqs build registers ML-KEM-1024. When `false`,
    /// the VPN must not advertise a PQC pubkey and uses the classical PSK path.
    public static var isSupported: Bool {
        guard let kem = OQS_KEM_new(algorithm) else { return false }
        OQS_KEM_free(kem)
        return true
    }

    /// Generate a fresh ephemeral ML-KEM-1024 keypair.
    ///
    /// Fails CLOSED: if liboqs has no ML-KEM-1024 or keygen fails, this throws
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

        // force-unwraps below are safe: publicKey/secretKey were just allocated
        // with pkSize/skSize, liboqs's own reported (always non-zero for a
        // successfully-created ML-KEM-1024 kem) key sizes — baseAddress is
        // only nil for an empty buffer.
        let result = publicKey.withUnsafeMutableBytes { pkBuf in
            secretKey.withUnsafeMutableBytes { skBuf in
                OQS_KEM_keypair(kem,
                    // swiftlint:disable:next force_unwrapping
                    pkBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    // swiftlint:disable:next force_unwrapping
                    skBuf.baseAddress!.assumingMemoryBound(to: UInt8.self))
            }
        }

        guard result == OQS_SUCCESS else {
            throw VpnMlKemError.keypairGenerationFailed
        }

        return EphemeralKeyPair(publicKey: publicKey, secretKey: secretKey)
    }

    /// Decapsulate the server's ML-KEM-1024 ciphertext into the 32-byte shared
    /// secret, then derive the WireGuard PSK via HKDF-SHA256.
    ///
    /// - Parameters:
    ///   - ciphertext: 1568-byte ML-KEM-1024 ciphertext from the server.
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
    /// frozen cross-platform vector without exercising the KEM (the shared secret
    /// is 32 bytes regardless of parameter set). Matches `CallSessionKeyBroker`'s
    /// CryptoKit HKDF usage and the bcrypto-server / Android / desktop byte-for-byte.
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

        // force-unwraps below are safe: sharedSecret was just allocated with
        // liboqs's own reported (always non-zero) size; ciphertext/secretKey
        // are checked non-empty above — baseAddress is only nil for an empty
        // buffer.
        let result = sharedSecret.withUnsafeMutableBytes { ssBuf in
            ciphertext.withUnsafeBytes { ctBuf in
                secretKey.withUnsafeBytes { skBuf in
                    OQS_KEM_decaps(kem,
                        // swiftlint:disable:next force_unwrapping
                        ssBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        // swiftlint:disable:next force_unwrapping
                        ctBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        // swiftlint:disable:next force_unwrapping
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
    /// liboqs has no ML-KEM-1024 registered in this build (should not happen —
    /// the device-identity backend provides it). The caller falls back to the
    /// classical PSK path instead.
    case kemUnavailable
    /// `OQS_KEM_keypair` returned non-success. No random fallback.
    case keypairGenerationFailed
    /// liboqs reported a public-key length other than 1568 for ML-KEM-1024.
    case unexpectedKeySize
    /// Server ciphertext was not 1568 bytes (ML-KEM-1024).
    case invalidCiphertext
    /// Empty decapsulation secret key supplied.
    case emptySecretKey
    /// `OQS_KEM_decaps` failed — FATAL, never fall back to classical PSK.
    case decapsulationFailed
}
