import Foundation

/// Cryptographic constants for Q-Audion. All values match Android `CryptoConstants.kt` exactly.
public enum CryptoConstants {

    // MARK: - Algorithm Identifiers
    public static let mlKemAlgorithm = "ML-KEM-1024"
    public static let aeadAlgorithm = "AES-256-GCM"

    // MARK: - Key Sizes
    public static let keySizeBits = 256
    public static let keySizeBytes = keySizeBits / 8

    // MARK: - AEAD Parameters
    public static let nonceSize = 12
    public static let tagSize = 16

    // MARK: - Ratcheting Parameters
    public static let ratchetIntervalFrames = 100
    public static let ratchetIntervalMs: Int64 = 300_000

    // MARK: - Audio Frame Parameters
    public static let frameDurationMs = 20
    public static let sampleRate = 48000
    public static let samplesPerFrame = (sampleRate * frameDurationMs) / 1000

    // MARK: - HKDF Info Strings (UTF-8, byte-identical to Android)
    public static let hkdfInfoChain = Data("q-audion-frame-key".utf8)
    public static let hkdfInfoRoot = Data("q-audion-root-ratchet".utf8)
    public static let hkdfInfoPskMix = Data("q-audion-psk-mix".utf8)
    public static let hkdfInfoNextChain = Data("q-audion-next-chain".utf8)

    // MARK: - Video Chain HKDF Info Strings (separate crypto chain for video)
    public static let hkdfInfoVideoChain = Data("q-audion-video-frame-key".utf8)
    public static let hkdfInfoVideoRoot = Data("q-audion-video-root-ratchet".utf8)

    // MARK: - Desktop/Android Interop HKDF Labels
    // Match qaudion-desktop/src/main/crypto/MessageCrypto.ts and pairwise PSK derivation.
    public static let HKDF_INFO_MSG_KEY = "q-audion-msg-key".data(using: .utf8)!
    public static let HKDF_INFO_FILE_KEY = "q-audion-file-key".data(using: .utf8)!
    public static let HKDF_SALT_PAIRWISE = "qaudion-pairwise-v1".data(using: .utf8)!
    public static let HKDF_INFO_PAIRWISE = "psk-first-contact".data(using: .utf8)!

    // MARK: - Opaque Envelope
    /// HKDF salt for envelope key derivation (must match Android exactly).
    public static let hkdfEnvelopeSalt = Data("qaudion-envelope-salt".utf8)
    /// HKDF info for envelope key derivation.
    public static let hkdfEnvelopeKeyInfo = Data("qaudion-envelope-key-v1".utf8)

    // MARK: - NFC Collaborative PSK
    /// HKDF info for NFC collaborative X25519-only PSK derivation (must match Android NfcProtocol.kt).
    public static let hkdfNfcCollaborativePskInfo = Data("Q-Audion NFC Collaborative PSK v1".utf8)
    /// HKDF info for NFC hybrid PQC PSK derivation (X25519 + ML-KEM-1024).
    public static let hkdfNfcHybridPqcPskInfo = Data("Q-Audion NFC Hybrid PQC PSK v1".utf8)

    // MARK: - Certificate Pinning
    /// SHA-256 hashes (base64) of pinned server certificate SPKI data.
    /// Matches Android CryptoConstants.kt PINNED_CERT_HASHES.
    public static let pinnedCertHashes: [String] = [
        "Pppf8dGdb+O28sc86adx4xsrJbB9QQ4+m8a+TxyOKNw=", // voip.bcrypto.com TLS cert (primary)
        "7t5azCKj59xN8cxykT6V/YCoyEGaI0j4qswAokEx01Y=", // 217.160.65.35 TLS cert (direct IP)
    ]
    public static let pinningEnabled = true

    // MARK: - Forward Secrecy
    /// Generate a new X25519 ephemeral key pair every N frames.
    public static let ephemeralKeyRotationFrames = 50
    /// Maximum lifetime of a single chain key before forced rotation.
    public static let maxChainKeyAge: TimeInterval = 300  // 5 minutes
    /// Delay before old key material is scrubbed from memory.
    public static let keyErasureDelay: TimeInterval = 5

    // MARK: - Compliance & Hardware Crypto
    /// Use Apple Secure Enclave (SEP) for P-256 identity keys and ECDH when available.
    public static let useSecureEnclave = true
    /// Enable hybrid PQC key exchange: ML-KEM-1024 + X25519 + Secure Enclave P-256.
    public static let hybridPqcEnabled = true
    /// Enforce FIPS 140-3 validated crypto primitives (Apple corecrypto #4701).
    public static let fipsMode = true
    /// Minimum NIST security level required (Level 5 = 256-bit quantum security).
    public static let minimumSecurityLevel = 5

    // MARK: - Hybrid KEM
    /// HKDF salt for combining ML-KEM + X25519 + SEP shared secrets.
    public static let hybridKdfSalt = "q-audion-hybrid-pqc-v1"
    /// HKDF info string for hybrid session key derivation.
    public static let hybridKdfInfo = "q-audion-session-key"
    /// Keychain tag prefix for Secure Enclave identity keys.
    public static let enclaveKeyTag = "com.qaudion.identity.sep"

    // MARK: - Triple Hybrid KEM (ML-KEM + X25519 + X448 — matches Android)
    /// HKDF salt for triple-hybrid: ML-KEM-1024 + X25519 + X448.
    public static let tripleHybridKdfSalt = "qaudion-triple-hybrid-v1"
    /// HKDF info for triple-hybrid session key derivation.
    public static let tripleHybridKdfInfo = "session-key"
    /// Enable dual-curve (X25519 + X448) key agreement when available.
    public static let dualCurveEnabled = true
    /// Triple-hybrid combined secret size: 64 bytes (512-bit).
    public static let tripleHybridSecretSize = 64

    // MARK: - Threat Detection
    /// Maximum acceptable inter-frame jitter before a timing alert fires.
    public static let maxAcceptableJitter: TimeInterval = 0.5
    /// Number of recent sequence numbers retained for replay detection.
    public static let replayWindowSize: UInt32 = 256
    /// Alert threshold for unexpected gaps in the sequence counter.
    public static let maxSequenceGap: UInt32 = 1000

    /// Securely zeroize data to prevent memory leaks of sensitive material.
    public static func zeroize(_ data: inout Data) {
        data.withUnsafeMutableBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                memset(baseAddress, 0, buffer.count)
            }
        }
    }

    /// Constant-time byte comparison to prevent timing attacks.
    public static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[a.startIndex + i] ^ b[b.startIndex + i]
        }
        return result == 0
    }
}
