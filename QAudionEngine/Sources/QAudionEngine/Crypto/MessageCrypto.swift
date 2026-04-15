import Foundation
import CryptoKit

/// Message-level encryption matching Q-Audion Desktop wire format.
///
/// Mirrors `qaudion-desktop/src/main/crypto/MessageCrypto.ts`.
///
/// Wire format:
///   salt(32) || nonce(12) || ciphertext(N) || tag(16)
///
/// Key derivation:
///   key = HKDF-SHA256(ikm = psk, salt = random 32B, info = "q-audion-msg-key", L = 32)
///
/// AEAD: AES-256-GCM with AAD = UTF-8("msg:{senderId}:{recipientId}:{msgId}").
public final class MessageCrypto {

    // Legacy passthrough preserved for existing callers.
    private let cipher = AeadCipher()

    public init() {}

    public enum MessageCryptoError: Error {
        case wireBlobTooShort(Int)
        case hkdfFailed
    }

    // MARK: - Desktop wire-format API

    /// Encrypt a plaintext message using the Desktop-compatible wire format.
    ///
    /// - Parameters:
    ///   - plaintext: raw message bytes.
    ///   - psk: pairwise pre-shared key (any length ≥ 16 bytes recommended).
    ///   - senderId: sender identifier used in AAD.
    ///   - recipientId: recipient identifier used in AAD.
    ///   - msgId: per-message identifier used in AAD.
    /// - Returns: wire blob `salt(32) || nonce(12) || ciphertext || tag(16)`.
    public func encrypt(
        plaintext: Data,
        psk: Data,
        senderId: String,
        recipientId: String,
        msgId: String
    ) throws -> Data {
        let salt = Self.randomBytes(32)
        let key = try Self.deriveKey(psk: psk, salt: salt, info: CryptoConstants.HKDF_INFO_MSG_KEY)
        let nonceBytes = Self.randomBytes(12)
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let aad = Self.buildAAD(senderId: senderId, recipientId: recipientId, msgId: msgId)

        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: aad
        )

        var wire = Data()
        wire.reserveCapacity(32 + 12 + sealedBox.ciphertext.count + 16)
        wire.append(salt)
        wire.append(nonceBytes)
        wire.append(sealedBox.ciphertext)
        wire.append(sealedBox.tag)
        return wire
    }

    /// Decrypt a Desktop-format wire blob and return the plaintext.
    ///
    /// Throws on malformed input or authentication failure.
    public func decrypt(
        wireBlob: Data,
        psk: Data,
        senderId: String,
        recipientId: String,
        msgId: String
    ) throws -> Data {
        // salt(32) + nonce(12) + at least tag(16) = 60 minimum
        guard wireBlob.count >= 32 + 12 + 16 else {
            throw MessageCryptoError.wireBlobTooShort(wireBlob.count)
        }

        // Use offset-safe slicing (Data.startIndex may be non-zero).
        let base = wireBlob.startIndex
        let saltRange = base ..< base.advanced(by: 32)
        let nonceRange = saltRange.upperBound ..< saltRange.upperBound.advanced(by: 12)
        let tagRange = wireBlob.index(wireBlob.endIndex, offsetBy: -16) ..< wireBlob.endIndex
        let ctRange = nonceRange.upperBound ..< tagRange.lowerBound

        let salt = wireBlob[saltRange]
        let nonceBytes = wireBlob[nonceRange]
        let ciphertext = wireBlob[ctRange]
        let tag = wireBlob[tagRange]

        let key = try Self.deriveKey(psk: psk, salt: Data(salt), info: CryptoConstants.HKDF_INFO_MSG_KEY)
        let nonce = try AES.GCM.Nonce(data: Data(nonceBytes))
        let aad = Self.buildAAD(senderId: senderId, recipientId: recipientId, msgId: msgId)

        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        )
        return Data(try AES.GCM.open(sealedBox, using: key, authenticating: aad))
    }

    // MARK: - Legacy passthrough (pre-existing API kept for source compatibility)

    public func encrypt(message: Data, key: Data) throws -> AeadCipher.CipherOutput {
        try cipher.encrypt(plaintext: message, key: key)
    }

    public func decrypt(cipherOutput: AeadCipher.CipherOutput, key: Data) throws -> Data {
        try cipher.decrypt(cipherOutput: cipherOutput, key: key)
    }

    // MARK: - Internals

    private static func buildAAD(senderId: String, recipientId: String, msgId: String) -> Data {
        return Data("msg:\(senderId):\(recipientId):\(msgId)".utf8)
    }

    private static func deriveKey(psk: Data, salt: Data, info: Data) throws -> SymmetricKey {
        let ikm = SymmetricKey(data: psk)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return derived
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }
}
