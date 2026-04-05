import Foundation
import CryptoKit

public struct AeadCipher {
    public struct CipherOutput: Equatable {
        public var nonce: Data
        public var ciphertext: Data
        public var tag: Data
        public init(nonce: Data, ciphertext: Data, tag: Data) {
            self.nonce = nonce; self.ciphertext = ciphertext; self.tag = tag
        }
    }
    public init() {}

    public func encrypt(plaintext: Data, key: Data, associatedData: Data? = nil) throws -> CipherOutput {
        guard key.count == CryptoConstants.keySizeBytes else { throw AeadCipherError.invalidKeySize(key.count) }
        let symmetricKey = SymmetricKey(data: key)
        let nonce = AES.GCM.Nonce()
        let sealedBox: AES.GCM.SealedBox
        if let ad = associatedData {
            sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce, authenticating: ad)
        } else {
            sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)
        }
        return CipherOutput(nonce: Data(sealedBox.nonce), ciphertext: Data(sealedBox.ciphertext), tag: Data(sealedBox.tag))
    }

    public func decrypt(cipherOutput: CipherOutput, key: Data, associatedData: Data? = nil) throws -> Data {
        guard key.count == CryptoConstants.keySizeBytes else { throw AeadCipherError.invalidKeySize(key.count) }
        guard cipherOutput.tag.count == CryptoConstants.tagSize else { throw AeadCipherError.invalidTagSize(cipherOutput.tag.count) }
        let symmetricKey = SymmetricKey(data: key)
        let nonce = try AES.GCM.Nonce(data: cipherOutput.nonce)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherOutput.ciphertext, tag: cipherOutput.tag)
        if let ad = associatedData {
            return Data(try AES.GCM.open(sealedBox, using: symmetricKey, authenticating: ad))
        } else {
            return Data(try AES.GCM.open(sealedBox, using: symmetricKey))
        }
    }
}
public enum AeadCipherError: Error { case invalidKeySize(Int); case invalidTagSize(Int) }
