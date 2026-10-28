import Foundation
import CryptoKit

/// Opens the sealed message-alert envelope (`qn`) a notification extension receives (WIRE_SPEC.md section 15).
///
/// Foundation and CryptoKit only, so the notification extension compiles this very file instead of linking the engine.
/// The blob is `0x01 || ephemeral public key (32) || nonce (12) || AES-256-GCM ciphertext + tag (16)`; the key is
/// `HKDF-SHA256(X25519(device private, ephemeral public), salt = ephemeral || device public, info = label, 32)` and the
/// additional data is `label || ephemeral public`. Nothing here logs the blob, the key or the plaintext.
public enum NotifyEnvelope {

    /// HKDF info and AEAD label.
    public static let label = "qaudion-notify-v1"
    /// Algorithm string registered with the server next to the public key.
    public static let algorithm = "x25519-hkdf-sha256-aes256gcm-v1"
    /// An envelope older than this is not used (the generic alert stays).
    public static let maxAge: TimeInterval = 7 * 24 * 3600

    static let versionByte: UInt8 = 0x01
    static let ephemeralLength = 32
    static let nonceLength = 12
    static let tagLength = 16
    /// Longest base64 text accepted (an APNs payload is far smaller than this anyway).
    static let maxBlobText = 4096
    static let maxIdLength = 256

    public enum Kind: String, Sendable {
        case dm
        case grp
    }

    public struct Plaintext: Equatable, Sendable {
        public let kind: Kind
        public let senderID: String
        /// Present exactly for a group message.
        public let groupID: String?
        /// Server time in unix seconds.
        public let timestamp: Int64

        public init(kind: Kind, senderID: String, groupID: String?, timestamp: Int64) {
            self.kind = kind
            self.senderID = senderID
            self.groupID = groupID
            self.timestamp = timestamp
        }

        /// False when the envelope is older than `maxAge`.
        public func isFresh(now: Date = Date()) -> Bool {
            now.timeIntervalSince1970 - Double(timestamp) <= NotifyEnvelope.maxAge
        }
    }

    public enum OpenError: Error, Equatable, Sendable {
        case malformedBlob
        case unsupportedVersion
        case invalidKey
        case keyAgreement
        case decryption
        case malformedPlaintext
    }

    /// Decodes, opens and parses a `qn` value with the device's raw X25519 private key.
    public static func open(blobBase64: String, devicePrivateKey: Data) throws -> Plaintext {
        try parse(openToBytes(blobBase64: blobBase64, devicePrivateKey: devicePrivateKey))
    }

    /// Opens a `qn` value and returns the plaintext bytes (before parsing).
    static func openToBytes(blobBase64: String, devicePrivateKey: Data) throws -> Data {
        guard blobBase64.utf8.count <= maxBlobText, let blob = Data(base64Encoded: blobBase64) else {
            throw OpenError.malformedBlob
        }
        guard blob.count >= 1 + ephemeralLength + nonceLength + tagLength else { throw OpenError.malformedBlob }
        let bytes = [UInt8](blob)
        guard bytes[0] == versionByte else { throw OpenError.unsupportedVersion }
        let ephemeralPublic = Data(bytes[1..<(1 + ephemeralLength)])
        let nonceBytes = Data(bytes[(1 + ephemeralLength)..<(1 + ephemeralLength + nonceLength)])
        let sealed = Data(bytes[(1 + ephemeralLength + nonceLength)...])
        let ciphertext = sealed.prefix(sealed.count - tagLength)
        let tag = sealed.suffix(tagLength)

        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let ephemeralKey: Curve25519.KeyAgreement.PublicKey
        do {
            privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: devicePrivateKey)
            ephemeralKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublic)
        } catch {
            throw OpenError.invalidKey
        }
        let shared: SharedSecret
        do {
            shared = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralKey)
        } catch {
            throw OpenError.keyAgreement
        }
        // A low-order ephemeral key gives the all-zero secret: refuse it, whatever CryptoKit did.
        let allZero = shared.withUnsafeBytes { raw in raw.allSatisfy { $0 == 0 } }
        guard !allZero else { throw OpenError.keyAgreement }

        let devicePublic = privateKey.publicKey.rawRepresentation
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeralPublic + devicePublic,
            sharedInfo: Data(label.utf8),
            outputByteCount: 32)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceBytes), ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: Data(label.utf8) + ephemeralPublic)
        } catch {
            throw OpenError.decryption
        }
    }

    /// Strict parse of the plaintext: compact JSON of exactly `v`, `k`, `s`, (`g` for a group) and `t`.
    static func parse(_ data: Data) throws -> Plaintext {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OpenError.malformedPlaintext
        }
        guard let version = integer(object["v"]), version == 1 else { throw OpenError.malformedPlaintext }
        guard let kindText = object["k"] as? String, let kind = Kind(rawValue: kindText) else {
            throw OpenError.malformedPlaintext
        }
        guard let sender = object["s"] as? String, isUsableID(sender) else { throw OpenError.malformedPlaintext }
        guard let timestamp = integer(object["t"]), timestamp >= 0 else { throw OpenError.malformedPlaintext }
        var allowed: Set<String> = ["v", "k", "s", "t"]
        var group: String?
        switch kind {
        case .dm:
            guard object["g"] == nil else { throw OpenError.malformedPlaintext }
        case .grp:
            guard let g = object["g"] as? String, isUsableID(g) else { throw OpenError.malformedPlaintext }
            group = g
            allowed.insert("g")
        }
        guard Set(object.keys).isSubset(of: allowed) else { throw OpenError.malformedPlaintext }
        return Plaintext(kind: kind, senderID: sender, groupID: group, timestamp: timestamp)
    }

    private static func isUsableID(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= maxIdLength
    }

    /// A JSON number that is a whole number (not a boolean, not a fraction).
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 9.0e15 else { return nil }
        return number.int64Value
    }
}
