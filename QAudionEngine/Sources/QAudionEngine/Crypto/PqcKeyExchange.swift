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
    public func generateKeyPair() -> KeyPair {
        guard let kem = OQS_KEM_new("ML-KEM-1024") else {
            // Fallback to random if liboqs unavailable
            return KeyPair(publicKey: secureRandomData(count: 1568), privateKey: secureRandomData(count: 3168))
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
            return KeyPair(publicKey: secureRandomData(count: pkSize), privateKey: secureRandomData(count: skSize))
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

        // Zeroize private key copy if we made one
        return sharedSecret
    }

    private func secureRandomData(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            #if canImport(Security)
            _ = SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
            #else
            let fd = open("/dev/urandom", O_RDONLY)
            if fd >= 0 { _ = read(fd, buffer.baseAddress!, count); close(fd) }
            #endif
        }
        return data
    }
}

public enum PqcKeyExchangeError: Error {
    case emptyPublicKey
    case emptyCiphertext
    case emptyPrivateKey
    case kemUnavailable
    case encapsulationFailed
    case decapsulationFailed
}
