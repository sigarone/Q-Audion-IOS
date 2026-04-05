import Foundation

/// ML-KEM-1024 key exchange. Phase 1 stub: generates random keys for testing.
/// Real liboqs integration in Phase 1b.
public struct PqcKeyExchange {
    public struct KeyPair { public let publicKey: Data; public let privateKey: Data }
    public struct EncapsulationResult { public let ciphertext: Data; public let sharedSecret: Data }
    public init() {}

    public func generateKeyPair() -> KeyPair {
        KeyPair(publicKey: randomData(count: 1568), privateKey: randomData(count: 3168))
    }
    public func encapsulate(remotePublicKey: Data) throws -> EncapsulationResult {
        guard !remotePublicKey.isEmpty else { throw PqcKeyExchangeError.emptyPublicKey }
        return EncapsulationResult(ciphertext: randomData(count: 1088), sharedSecret: randomData(count: 32))
    }
    public func decapsulate(ciphertext: Data, privateKey: Data) throws -> Data {
        guard !ciphertext.isEmpty else { throw PqcKeyExchangeError.emptyCiphertext }
        guard !privateKey.isEmpty else { throw PqcKeyExchangeError.emptyPrivateKey }
        return randomData(count: 32)
    }
    private func randomData(count: Int) -> Data {
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
public enum PqcKeyExchangeError: Error { case emptyPublicKey; case emptyCiphertext; case emptyPrivateKey }
