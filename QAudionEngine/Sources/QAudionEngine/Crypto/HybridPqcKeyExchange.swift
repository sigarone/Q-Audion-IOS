import Foundation
import CryptoKit

// MARK: - Hybrid Post-Quantum Key Exchange
// NIST-recommended hybrid approach combining three independent key agreements:
//   1. ML-KEM-1024 (FIPS 203, NIST Level 5) — quantum-resistant lattice KEM
//   2. X25519 (RFC 7748) — proven classical ECDH
//   3. P-256 via Secure Enclave (FIPS 186-4) — hardware-backed identity binding
//
// The combined shared secret is derived through HKDF-SHA-256 (SP 800-56C),
// meaning an attacker must break ALL THREE schemes to recover the session key.

public final class HybridPqcKeyExchange {

    // MARK: - Types

    /// Full hybrid key pair: PQC + classical + hardware.
    public struct HybridKeyPair {
        /// ML-KEM-1024 key pair (liboqs).
        public let pqcKeyPair: PqcKeyExchange.KeyPair
        /// X25519 ephemeral private key (CryptoKit).
        public let x25519Private: Curve25519.KeyAgreement.PrivateKey
        /// Secure Enclave P-256 key tag (nil if SEP unavailable).
        public let enclaveKeyTag: String?
    }

    /// Public keys sent to the remote peer during key exchange.
    public struct HybridPublicKeys {
        /// ML-KEM-1024 public key (1568 bytes).
        public let pqcPublicKey: Data
        /// X25519 public key (32 bytes).
        public let x25519PublicKey: Data
        /// P-256 public key from Secure Enclave (65 bytes, uncompressed), or nil.
        public let enclavePublicKey: Data?

        public init(pqcPublicKey: Data, x25519PublicKey: Data, enclavePublicKey: Data?) {
            self.pqcPublicKey = pqcPublicKey
            self.x25519PublicKey = x25519PublicKey
            self.enclavePublicKey = enclavePublicKey
        }
    }

    /// Ciphertext bundle sent back to the initiator after encapsulation.
    public struct HybridCiphertext {
        /// ML-KEM-1024 ciphertext (1568 bytes).
        public let pqcCiphertext: Data
        /// Ephemeral X25519 public key (32 bytes).
        public let x25519PublicKey: Data
        /// P-256 ephemeral public key from Secure Enclave (65 bytes), or nil.
        public let enclavePublicKey: Data?

        public init(pqcCiphertext: Data, x25519PublicKey: Data, enclavePublicKey: Data?) {
            self.pqcCiphertext = pqcCiphertext
            self.x25519PublicKey = x25519PublicKey
            self.enclavePublicKey = enclavePublicKey
        }
    }

    /// Result of a hybrid encapsulation, containing both the ciphertext and combined secret.
    public struct HybridEncapsulationResult {
        /// ML-KEM ciphertext to send to the remote peer.
        public let pqcCiphertext: Data
        /// Ephemeral X25519 public key to send to the remote peer.
        public let x25519PublicKey: Data
        /// Combined shared secret: HKDF(pqcSecret || x25519Secret || enclaveSecret).
        public let combinedSharedSecret: Data
    }

    // MARK: - Dependencies

    private let pqc = PqcKeyExchange()
    private let enclave = SecureEnclaveManager()

    public init() {}

    // MARK: - Key Generation

    /// Generate a full hybrid key pair: ML-KEM-1024 + X25519 + Secure Enclave P-256.
    /// If the Secure Enclave is unavailable, the P-256 component is omitted and security
    /// degrades gracefully to dual-hybrid (PQC + X25519), which is still quantum-safe.
    public func generateKeyPair() throws -> HybridKeyPair {
        // 1. ML-KEM-1024 (post-quantum)
        let pqcKeys = pqc.generateKeyPair()

        // 2. X25519 (classical)
        let x25519Key = Curve25519.KeyAgreement.PrivateKey()

        // 3. Secure Enclave P-256 (hardware)
        var enclaveTag: String? = nil
        if SecureEnclaveManager.isAvailable && CryptoConstants.useSecureEnclave {
            let tag = CryptoConstants.enclaveKeyTag + "." + UUID().uuidString
            do {
                _ = try enclave.generateEnclaveKey(tag: tag)
                enclaveTag = tag
            } catch {
                // Graceful degradation: proceed without SEP.
                enclaveTag = nil
            }
        }

        return HybridKeyPair(
            pqcKeyPair: pqcKeys,
            x25519Private: x25519Key,
            enclaveKeyTag: enclaveTag
        )
    }

    /// Extract the public keys from a hybrid key pair for transmission to the remote peer.
    public func publicKeys(from keyPair: HybridKeyPair) throws -> HybridPublicKeys {
        var enclavePublic: Data? = nil
        if let tag = keyPair.enclaveKeyTag {
            enclavePublic = try? enclave.getPublicKey(tag: tag)
        }

        return HybridPublicKeys(
            pqcPublicKey: keyPair.pqcKeyPair.publicKey,
            x25519PublicKey: Data(keyPair.x25519Private.publicKey.rawRepresentation),
            enclavePublicKey: enclavePublic
        )
    }

    // MARK: - Encapsulation (initiator side)

    /// Hybrid encapsulate: compute shared secrets from all three schemes and combine via HKDF.
    /// - Parameter remotePublicKeys: The remote peer's hybrid public keys.
    /// - Returns: Ciphertext to send + the combined shared secret for session key derivation.
    public func encapsulate(remotePublicKeys: HybridPublicKeys) throws -> HybridEncapsulationResult {
        // 1. ML-KEM-1024 encapsulation
        let pqcResult = try pqc.encapsulate(remotePublicKey: remotePublicKeys.pqcPublicKey)

        // 2. X25519 key agreement
        let ephemeralX25519 = Curve25519.KeyAgreement.PrivateKey()
        let remoteX25519Public = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: remotePublicKeys.x25519PublicKey
        )
        let x25519Shared = try ephemeralX25519.sharedSecretFromKeyAgreement(with: remoteX25519Public)
        let x25519SharedData = x25519Shared.withUnsafeBytes { Data($0) }

        // 3. Secure Enclave P-256 ECDH (if both sides support it)
        var enclaveShared = Data()
        if let remoteSepKey = remotePublicKeys.enclavePublicKey,
           SecureEnclaveManager.isAvailable && CryptoConstants.useSecureEnclave {
            let localTag = CryptoConstants.enclaveKeyTag + ".ephemeral." + UUID().uuidString
            do {
                _ = try enclave.generateEnclaveKey(tag: localTag)
                enclaveShared = try enclave.performKeyAgreement(
                    privateKeyTag: localTag,
                    publicKey: remoteSepKey
                )
            } catch {
                // Graceful degradation: proceed without SEP contribution.
                enclaveShared = Data()
            }
        }

        // 4. Combine all shared secrets via HKDF-SHA-256 (NIST SP 800-56C)
        let combinedIkm = pqcResult.sharedSecret + x25519SharedData + enclaveShared
        let combinedSecret = deriveHybridSecret(ikm: combinedIkm)

        return HybridEncapsulationResult(
            pqcCiphertext: pqcResult.ciphertext,
            x25519PublicKey: Data(ephemeralX25519.publicKey.rawRepresentation),
            combinedSharedSecret: combinedSecret
        )
    }

    // MARK: - Decapsulation (responder side)

    /// Hybrid decapsulate: recover shared secrets from all three schemes and combine via HKDF.
    /// - Parameters:
    ///   - ciphertext: The hybrid ciphertext received from the remote peer.
    ///   - privateKeys: The local hybrid private keys.
    /// - Returns: The combined shared secret (32 bytes).
    public func decapsulate(ciphertext: HybridCiphertext, privateKeys: HybridKeyPair) throws -> Data {
        // 1. ML-KEM-1024 decapsulation
        let pqcShared = try pqc.decapsulate(
            ciphertext: ciphertext.pqcCiphertext,
            privateKey: privateKeys.pqcKeyPair.privateKey
        )

        // 2. X25519 key agreement
        let remoteX25519Public = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: ciphertext.x25519PublicKey
        )
        let x25519Shared = try privateKeys.x25519Private.sharedSecretFromKeyAgreement(
            with: remoteX25519Public
        )
        let x25519SharedData = x25519Shared.withUnsafeBytes { Data($0) }

        // 3. Secure Enclave P-256 ECDH (if both sides have keys)
        var enclaveShared = Data()
        if let tag = privateKeys.enclaveKeyTag,
           let remoteSepKey = ciphertext.enclavePublicKey {
            do {
                enclaveShared = try enclave.performKeyAgreement(
                    privateKeyTag: tag,
                    publicKey: remoteSepKey
                )
            } catch {
                // Graceful degradation.
                enclaveShared = Data()
            }
        }

        // 4. Combine via HKDF-SHA-256
        let combinedIkm = pqcShared + x25519SharedData + enclaveShared
        return deriveHybridSecret(ikm: combinedIkm)
    }

    // MARK: - HKDF Derivation

    /// Derive the combined session key using HKDF-SHA-256 (NIST SP 800-56C).
    /// Salt and info strings are fixed protocol constants to ensure domain separation.
    private func deriveHybridSecret(ikm: Data) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: CryptoConstants.hybridKdfSalt,
            info: CryptoConstants.hybridKdfInfo,
            outputByteCount: CryptoConstants.keySizeBytes
        )

        return derived.withUnsafeBytes { Data($0) }
    }
}
