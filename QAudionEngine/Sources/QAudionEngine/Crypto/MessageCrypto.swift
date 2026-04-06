import Foundation

public final class MessageCrypto {
    private let cipher = AeadCipher()

    public init() {}

    public func encrypt(message: Data, key: Data) throws -> AeadCipher.CipherOutput {
        try cipher.encrypt(plaintext: message, key: key)
    }

    public func decrypt(cipherOutput: AeadCipher.CipherOutput, key: Data) throws -> Data {
        try cipher.decrypt(cipherOutput: cipherOutput, key: key)
    }
}
