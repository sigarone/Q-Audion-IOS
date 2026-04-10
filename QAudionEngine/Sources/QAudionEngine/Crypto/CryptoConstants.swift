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

    // MARK: - Certificate Pinning
    /// SHA-256 hashes (base64) of pinned server certificate SPKI data.
    /// Add production certificate hashes before release.
    public static let pinnedCertHashes: [String] = []
    public static let pinningEnabled = true

    // MARK: - Forward Secrecy
    /// Generate a new X25519 ephemeral key pair every N frames.
    public static let ephemeralKeyRotationFrames = 50
    /// Maximum lifetime of a single chain key before forced rotation.
    public static let maxChainKeyAge: TimeInterval = 300  // 5 minutes
    /// Delay before old key material is scrubbed from memory.
    public static let keyErasureDelay: TimeInterval = 5

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
