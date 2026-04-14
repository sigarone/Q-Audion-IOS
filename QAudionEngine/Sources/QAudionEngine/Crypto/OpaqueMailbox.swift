import Foundation
import CommonCrypto
import CryptoKit

/// Derives opaque mailbox identifiers for blind relay messaging.
/// Mirrors Android OpaqueMailbox exactly for cross-platform interop.
///
/// Two users who share a secret derive the same mailbox_id via HMAC-SHA256.
/// The server routes by mailbox_id but cannot identify the users or link
/// mailbox_id back to any identity.
///
/// Inner envelopes are encrypted with AES-256-GCM using a key derived from
/// the shared secret, ensuring the relay server cannot read message contents.
public enum OpaqueMailbox {

    // MARK: - Constants (match Android exactly)

    private static let mailboxContext = "qaudion-mailbox-v1"
    private static let callContext = "qaudion-call-v1"
    private static let envelopeKeyContext = "qaudion-envelope-key-v1"
    private static let envelopeVersion: UInt8 = 0x01

    // MARK: - Decoded Envelope

    public struct DecodedEnvelope {
        public let senderId: String
        public let recipientId: String
        public let msgType: String
        public let payload: Data
        public let timestamp: UInt64  // Unix epoch millis
    }

    // MARK: - Mailbox ID Derivation

    /// Derive mailbox ID from shared secret.
    /// mailbox_id = HMAC-SHA256(shared_secret, "qaudion-mailbox-v1") as hex
    public static func deriveMailboxId(sharedSecret: Data) -> String {
        let key = SymmetricKey(data: sharedSecret)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(mailboxContext.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Derive call-specific mailbox ID.
    /// call_mailbox = HMAC-SHA256(shared_secret, "qaudion-call-v1" || call_id) as hex
    public static func deriveCallMailboxId(sharedSecret: Data, callId: String) -> String {
        let key = SymmetricKey(data: sharedSecret)
        var context = Data(callContext.utf8)
        context.append(Data(callId.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: context, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Envelope Encryption

    /// Encrypt inner envelope with AES-256-GCM.
    /// Output: [nonce:12] [ciphertext+tag]
    public static func encryptEnvelope(
        sharedKey: Data,
        senderId: String,
        recipientId: String,
        msgType: String,
        payload: Data
    ) throws -> Data {
        let plaintext = encodeEnvelope(senderId: senderId, recipientId: recipientId, msgType: msgType, payload: payload)
        let envelopeKey = deriveEnvelopeKey(sharedSecret: sharedKey)
        defer { envelopeKey.withUnsafeBytes { ptr in if let base = ptr.baseAddress { memset(UnsafeMutableRawPointer(mutating: base), 0, ptr.count) } } }

        let symmetricKey = SymmetricKey(data: envelopeKey)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)

        var output = Data()
        output.append(contentsOf: nonce)
        output.append(sealed.ciphertext)
        output.append(sealed.tag)
        return output
    }

    /// Decrypt inner envelope.
    public static func decryptEnvelope(sharedKey: Data, encryptedEnvelope: Data) -> DecodedEnvelope? {
        guard encryptedEnvelope.count > 12 + 16 else { return nil } // nonce + tag minimum
        let envelopeKey = deriveEnvelopeKey(sharedSecret: sharedKey)
        defer { envelopeKey.withUnsafeBytes { ptr in if let base = ptr.baseAddress { memset(UnsafeMutableRawPointer(mutating: base), 0, ptr.count) } } }

        do {
            let nonce = try AES.GCM.Nonce(data: encryptedEnvelope[0..<12])
            let ciphertextAndTag = encryptedEnvelope[12...]
            let tagStart = ciphertextAndTag.endIndex - 16
            let ciphertext = ciphertextAndTag[ciphertextAndTag.startIndex..<tagStart]
            let tag = ciphertextAndTag[tagStart...]

            let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let symmetricKey = SymmetricKey(data: envelopeKey)
            let plaintext = try AES.GCM.open(sealed, using: symmetricKey)
            return decodeEnvelope(plaintext)
        } catch {
            return nil
        }
    }

    // MARK: - Private Helpers

    /// Derive AES-256 envelope key: HMAC-SHA256(sharedSecret, "qaudion-envelope-key-v1")
    private static func deriveEnvelopeKey(sharedSecret: Data) -> Data {
        let key = SymmetricKey(data: sharedSecret)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(envelopeKeyContext.utf8), using: key)
        return Data(mac)
    }

    /// Encode envelope plaintext matching Android wire format:
    /// [version:1][timestamp:8BE][senderIdLen:2BE][senderId:N]
    /// [recipientIdLen:2BE][recipientId:M][msgTypeLen:2BE][msgType:T][payload...]
    private static func encodeEnvelope(senderId: String, recipientId: String, msgType: String, payload: Data) -> Data {
        let senderBytes = Data(senderId.utf8)
        let recipientBytes = Data(recipientId.utf8)
        let typeBytes = Data(msgType.utf8)

        var data = Data()
        data.append(envelopeVersion)
        var timestamp = UInt64(Date().timeIntervalSince1970 * 1000).bigEndian
        data.append(Data(bytes: &timestamp, count: 8))
        appendUInt16BE(&data, UInt16(senderBytes.count))
        data.append(senderBytes)
        appendUInt16BE(&data, UInt16(recipientBytes.count))
        data.append(recipientBytes)
        appendUInt16BE(&data, UInt16(typeBytes.count))
        data.append(typeBytes)
        data.append(payload)
        return data
    }

    /// Decode envelope from plaintext.
    private static func decodeEnvelope(_ data: Data) -> DecodedEnvelope? {
        guard data.count >= 1 + 8 + 2 else { return nil }
        var offset = 0
        let version = data[offset]; offset += 1
        guard version == envelopeVersion else { return nil }

        let timestamp = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt64.self).bigEndian }; offset += 8

        guard data.count >= offset + 2 else { return nil }
        let senderLen = Int(readUInt16BE(data, offset: offset)); offset += 2
        guard data.count >= offset + senderLen + 2 else { return nil }
        let senderId = String(data: data[offset..<(offset + senderLen)], encoding: .utf8) ?? ""; offset += senderLen

        let recipientLen = Int(readUInt16BE(data, offset: offset)); offset += 2
        guard data.count >= offset + recipientLen + 2 else { return nil }
        let recipientId = String(data: data[offset..<(offset + recipientLen)], encoding: .utf8) ?? ""; offset += recipientLen

        let typeLen = Int(readUInt16BE(data, offset: offset)); offset += 2
        guard data.count >= offset + typeLen else { return nil }
        let msgType = String(data: data[offset..<(offset + typeLen)], encoding: .utf8) ?? ""; offset += typeLen

        let payload = data[offset...]

        return DecodedEnvelope(senderId: senderId, recipientId: recipientId, msgType: msgType, payload: Data(payload), timestamp: timestamp)
    }

    private static func appendUInt16BE(_ data: inout Data, _ value: UInt16) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 2))
    }

    private static func readUInt16BE(_ data: Data, offset: Int) -> UInt16 {
        data.withUnsafeBytes { UInt16(bigEndian: $0.load(fromByteOffset: offset, as: UInt16.self)) }
    }
}
