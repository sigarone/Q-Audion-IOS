import Foundation
#if canImport(Security)
import Security
#endif

public final class DeviceKeyManager {
    private static let tag = "com.bcrypto.qaudion.devicekey"

    public init() {}

    public func generateDeviceKey() throws -> Data {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Self.tag.data(using: .utf8)!
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw DeviceKeyError.generationFailed(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw DeviceKeyError.exportFailed
        }
        return publicKeyData
    }

    public func getPublicKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.tag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        let privateKey = item as! SecKey
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
        return data
    }
}

public enum DeviceKeyError: Error { case generationFailed(String); case exportFailed }
