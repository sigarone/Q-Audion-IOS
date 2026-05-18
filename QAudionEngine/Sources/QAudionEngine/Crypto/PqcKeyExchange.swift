import Foundation
import CLiboqs

/// ML-KEM-1024 key exchange via liboqs C library.
/// Replaces the Phase 1 stub with real encapsulation/decapsulation.
public struct PqcKeyExchange {

    public struct KeyPair {
        public let publicKey: Data   // 1568 bytes (raw, no ASN.1)
        public let privateKey: Data  // 3168 bytes (raw, no ASN.1)
    }

    public struct EncapsulationResult {
        public let ciphertext: Data   // 1568 bytes
        public let sharedSecret: Data // 32 bytes
    }

    public init() {}

    /// Generate ML-KEM-1024 keypair using liboqs.
    ///
    /// SECURITY C-9: the previous implementation returned cryptographically
    /// RANDOM bytes when `OQS_KEM_new`/`OQS_KEM_keypair` failed. That made
    /// a private key with NO valid public counterpart — every subsequent
    /// encapsulation against it would silently produce a shared secret the
    /// peer can never reproduce, degrading the hybrid handshake to a
    /// non-PQC path without any error surfacing. The random fallback is
    /// removed entirely; failure now throws so callers fail closed.
    public func generateKeyPair() throws -> KeyPair {
        guard let kem = OQS_KEM_new("ML-KEM-1024") else {
            throw PqcKeyExchangeError.kemUnavailable
        }
        defer { OQS_KEM_free(kem) }

        let pkSize = Int(kem.pointee.length_public_key)
        let skSize = Int(kem.pointee.length_secret_key)

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
            throw PqcKeyExchangeError.keypairGenerationFailed
        }

        return KeyPair(publicKey: publicKey, privateKey: secretKey)
    }

    /// Encapsulate: generate ciphertext + shared secret from remote public key.
    public func encapsulate(remotePublicKey: Data) throws -> EncapsulationResult {
        guard !remotePublicKey.isEmpty else { throw PqcKeyExchangeError.emptyPublicKey }

        guard let kem = OQS_KEM_new("ML-KEM-1024") else {
            throw PqcKeyExchangeError.kemUnavailable
        }
        defer { OQS_KEM_free(kem) }

        let ctSize = Int(kem.pointee.length_ciphertext)
        let ssSize = Int(kem.pointee.length_shared_secret)

        var ciphertext = Data(count: ctSize)
        var sharedSecret = Data(count: ssSize)

        let result = ciphertext.withUnsafeMutableBytes { ctBuf in
            sharedSecret.withUnsafeMutableBytes { ssBuf in
                remotePublicKey.withUnsafeBytes { pkBuf in
                    OQS_KEM_encaps(kem,
                        ctBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ssBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        pkBuf.baseAddress!.assumingMemoryBound(to: UInt8.self))
                }
            }
        }

        guard result == OQS_SUCCESS else {
            throw PqcKeyExchangeError.encapsulationFailed
        }

        return EncapsulationResult(ciphertext: ciphertext, sharedSecret: sharedSecret)
    }

    /// Decapsulate: recover shared secret from ciphertext using private key.
    public func decapsulate(ciphertext: Data, privateKey: Data) throws -> Data {
        guard !ciphertext.isEmpty else { throw PqcKeyExchangeError.emptyCiphertext }
        guard !privateKey.isEmpty else { throw PqcKeyExchangeError.emptyPrivateKey }

        guard let kem = OQS_KEM_new("ML-KEM-1024") else {
            throw PqcKeyExchangeError.kemUnavailable
        }
        defer { OQS_KEM_free(kem) }

        let ssSize = Int(kem.pointee.length_shared_secret)
        var sharedSecret = Data(count: ssSize)

        let result = sharedSecret.withUnsafeMutableBytes { ssBuf in
            ciphertext.withUnsafeBytes { ctBuf in
                privateKey.withUnsafeBytes { skBuf in
                    OQS_KEM_decaps(kem,
                        ssBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ctBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        skBuf.baseAddress!.assumingMemoryBound(to: UInt8.self))
                }
            }
        }

        guard result == OQS_SUCCESS else {
            throw PqcKeyExchangeError.decapsulationFailed
        }

        // SECURITY L-14: no private-key copy is made here — `privateKey`
        // is read in place via `withUnsafeBytes` and never duplicated, so
        // there is nothing local to zeroize. Lifetime/scrubbing of the
        // caller's `privateKey` buffer is the caller's responsibility.
        return sharedSecret
    }

    // MARK: - Raw key interop (Android ASN.1 compatibility)

    /// ML-KEM-1024 raw public key length (bytes).
    private static let mlKem1024RawPublicKeySize = 1568
    /// BouncyCastle wraps the raw key in an ASN.1 `SubjectPublicKeyInfo`
    /// (SPKI). For ML-KEM-1024 the DER header observed from Android's
    /// `SubjectPublicKeyInfo.getInstance(...).getEncoded()` is 22 bytes
    /// (SEQUENCE { AlgorithmIdentifier (OID), BIT STRING }), so the total
    /// SPKI length is rawSize + 22. The first byte of any well-formed
    /// SPKI is 0x30 (ASN.1 SEQUENCE tag).
    private static let mlKem1024SpkiHeaderLen = 22

    /// Extract raw public key bytes (strip ASN.1 if present from Android
    /// Bouncy Castle). iOS liboqs uses raw format natively; this handles
    /// keys received from Android.
    ///
    /// SECURITY H-10: the previous `count > rawSize → suffix(rawSize)`
    /// branch accepted ANY oversized attacker-supplied blob and silently
    /// truncated it to 1568 bytes — a malformed/padded key would still be
    /// fed into encapsulation. Validation is now strict:
    ///   - exactly 1568 bytes  → raw key, returned as-is (the safe path).
    ///   - exactly 1568+22     → BouncyCastle SPKI; only accepted when the
    ///                            leading byte is 0x30 (SEQUENCE), then the
    ///                            trailing 1568 bytes are returned.
    ///   - anything else       → reject (`invalidPublicKey`).
    /// Heuristic note: we match on the exact SPKI length + the SEQUENCE
    /// tag rather than the full DER prefix to stay robust to minor
    /// AlgorithmIdentifier OID-encoding differences across BC versions
    /// while still rejecting arbitrary oversized blobs. Exact-length
    /// (1568) is the unambiguous, preferred input.
    public static func extractRawPublicKey(_ encodedKey: Data) throws -> Data {
        let rawSize = mlKem1024RawPublicKeySize
        if encodedKey.count == rawSize {
            return encodedKey
        }
        if encodedKey.count == rawSize + mlKem1024SpkiHeaderLen,
           let first = encodedKey.first, first == 0x30 {
            return encodedKey.suffix(rawSize)
        }
        throw PqcKeyExchangeError.invalidPublicKey
    }

    /// Wrap raw public key for Android Bouncy Castle consumption.
    /// Android's extractRawPublicKey() handles the reverse direction.
    public static func wrapRawPublicKey(_ rawKey: Data) -> Data {
        return rawKey
    }
}

public enum PqcKeyExchangeError: Error {
    case emptyPublicKey
    case emptyCiphertext
    case emptyPrivateKey
    case kemUnavailable
    case encapsulationFailed
    case decapsulationFailed
    /// SECURITY C-9: `OQS_KEM_keypair` returned non-success. No random
    /// fallback — the caller must fail closed.
    case keypairGenerationFailed
    /// SECURITY H-10: a remote public key was neither exactly 1568 bytes
    /// (raw ML-KEM-1024) nor a well-formed 1590-byte BouncyCastle SPKI.
    case invalidPublicKey
}
