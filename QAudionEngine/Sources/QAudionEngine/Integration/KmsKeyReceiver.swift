import Foundation
import CryptoKit

public final class KmsKeyReceiver {
    public init() {}

    public func decryptPskPackage(encryptedPackage: Data, devicePrivateKey: Data) throws -> Data {
        // ECDH + HKDF + AES-GCM decryption
        // Format: [ephemeralPubKey(65)][nonce(12)][ciphertext(N)][tag(16)]
        guard encryptedPackage.count > 65 + 12 + 16 else { throw KmsError.packageTooSmall }
        let ephemeralPub = encryptedPackage.prefix(65)
        let nonce = encryptedPackage[65..<77]
        let ciphertext = encryptedPackage[77..<(encryptedPackage.count - 16)]
        let tag = encryptedPackage.suffix(16)

        // Derive shared secret via ECDH
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: devicePrivateKey)
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralPub)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)

        // HKDF derive AES key
        let aesKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(),
            sharedInfo: Data("q-audion-kms".utf8), outputByteCount: 32)

        // AES-GCM decrypt
        let sealedBox = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext, tag: tag)
        return Data(try AES.GCM.open(sealedBox, using: aesKey))
    }
}

public enum KmsError: Error { case packageTooSmall; case decryptionFailed }
