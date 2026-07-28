import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

// MARK: - Secure Enclave Manager
// Hardware-backed key operations using Apple's Secure Enclave Processor (SEP).
// The SEP is a discrete hardware coprocessor with its own encrypted memory;
// private keys generated inside it NEVER leave the hardware boundary.
// Apple SEP holds FIPS 140-3 Level 3 equivalent certification.

public final class SecureEnclaveManager {

    public enum SecureEnclaveError: Error {
        case notAvailable
        case keyGenerationFailed(OSStatus)
        case keyNotFound(String)
        case signingFailed(Error)
        case keyAgreementFailed(Error)
        case accessControlCreationFailed
        case invalidPublicKeyData
    }

    public init() {}

    // MARK: - Availability

    /// Check if the Secure Enclave is available on this device.
    /// All Apple devices with A7 chip or later (iPhone 5s+) have SEP.
    public static var isAvailable: Bool {
        return SecureEnclave.isAvailable
    }

    // MARK: - Key Generation

    /// Generate a P-256 key pair inside the Secure Enclave.
    /// The private key NEVER leaves the hardware — only a reference (SecKey) is returned.
    /// - Parameter tag: Application tag to identify this key in the Keychain.
    /// - Returns: A SecKey reference to the enclave-bound private key.
    public func generateEnclaveKey(tag: String) throws -> SecKey {
        guard Self.isAvailable else { throw SecureEnclaveError.notAvailable }

        let tagData = Data(tag.utf8)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tagData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ] as [String: Any]
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let cfErr = error?.takeRetainedValue()
            let code = cfErr.map { CFErrorGetCode($0) } ?? -1
            throw SecureEnclaveError.keyGenerationFailed(OSStatus(code))
        }

        return privateKey
    }

    /// Store a master identity key in the Secure Enclave, optionally protected by biometric.
    /// - Parameters:
    ///   - tag: Application tag for Keychain storage.
    ///   - requireBiometric: If `true`, every use of the key requires Face ID / Touch ID.
    /// - Returns: A SecKey reference to the enclave-bound private key.
    public func storeIdentityKey(tag: String, requireBiometric: Bool) throws -> SecKey {
        guard Self.isAvailable else { throw SecureEnclaveError.notAvailable }

        // Delete any existing key with this tag first.
        deleteKey(tag: tag)

        let tagData = Data(tag.utf8)
        let accessFlag: SecAccessControlCreateFlags = requireBiometric
            ? [.privateKeyUsage, .biometryCurrentSet]
            : [.privateKeyUsage]

        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            accessFlag,
            nil
        ) else {
            throw SecureEnclaveError.accessControlCreationFailed
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tagData,
                kSecAttrAccessControl as String: accessControl
            ] as [String: Any]
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let cfErr = error?.takeRetainedValue()
            let code = cfErr.map { CFErrorGetCode($0) } ?? -1
            throw SecureEnclaveError.keyGenerationFailed(OSStatus(code))
        }

        return privateKey
    }

    // MARK: - Signing (ECDSA P-256)

    /// Sign data using the Secure Enclave private key (ECDSA with SHA-256).
    /// The signing operation executes entirely within the SEP hardware.
    public func sign(data: Data, withKeyTag tag: String) throws -> Data {
        let privateKey = try loadKey(tag: tag)

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) else {
            throw SecureEnclaveError.signingFailed(
                error?.takeRetainedValue() ?? SecureEnclaveError.keyNotFound(tag)
            )
        }

        return signature as Data
    }

    // MARK: - ECDH Key Agreement

    /// Perform ECDH key agreement inside the Secure Enclave.
    /// The shared secret derivation happens in hardware; only the derived bytes leave the SEP.
    /// - Parameters:
    ///   - privateKeyTag: Tag of the Secure Enclave private key.
    ///   - publicKey: Raw P-256 public key bytes (65 bytes uncompressed, or 33 compressed).
    /// - Returns: 32-byte shared secret suitable for HKDF input.
    public func performKeyAgreement(privateKeyTag: String, publicKey: Data) throws -> Data {
        let privateKey = try loadKey(tag: privateKeyTag)

        // Import the remote public key as a SecKey.
        let pubKeyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256
        ]

        var error: Unmanaged<CFError>?
        guard let remotePublicKey = SecKeyCreateWithData(
            publicKey as CFData,
            pubKeyAttributes as CFDictionary,
            &error
        ) else {
            throw SecureEnclaveError.invalidPublicKeyData
        }

        // Perform the ECDH exchange — computation runs inside the SEP.
        let parameters: [String: Any] = [:]
        guard let sharedData = SecKeyCopyKeyExchangeResult(
            privateKey,
            .ecdhKeyExchangeStandard,
            remotePublicKey,
            parameters as CFDictionary,
            &error
        ) else {
            throw SecureEnclaveError.keyAgreementFailed(
                error?.takeRetainedValue() ?? SecureEnclaveError.keyNotFound(privateKeyTag)
            )
        }

        return sharedData as Data
    }

    // MARK: - Key Retrieval

    /// Retrieve the public key bytes for a Secure Enclave key pair.
    /// Returns the uncompressed P-256 public key (65 bytes: 0x04 || X || Y).
    public func getPublicKey(tag: String) throws -> Data {
        let privateKey = try loadKey(tag: tag)
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecureEnclaveError.keyNotFound(tag)
        }
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            throw SecureEnclaveError.keyNotFound(tag)
        }
        return publicKeyData as Data
    }

    // MARK: - Internal Helpers

    private func loadKey(tag: String) throws -> SecKey {
        let tagData = Data(tag.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let key = item else {
            throw SecureEnclaveError.keyNotFound(tag)
        }
        // Force-cast is safe: kSecReturnRef with kSecClassKey always yields SecKey.
        return (key as! SecKey)
    }

    private func deleteKey(tag: String) {
        let tagData = Data(tag.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
        ]
        SecItemDelete(query as CFDictionary)
    }
}
