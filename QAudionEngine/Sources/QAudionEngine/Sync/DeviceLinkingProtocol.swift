import Foundation
import CryptoKit

/// Protocol for linking a new device to an existing Q-Audion account.
/// Direct port of Android's `qaudion-engine/.../sync/DeviceLinkingProtocol.kt`.
///
/// Flow:
/// 1. Existing device shows QR code:
///    `qaudion://link/<base64url(devicePub + userId + oneTimeCode)>`
/// 2. New device scans QR, extracts link data.
/// 3. New device sends device_register to server with its own keys.
/// 4. Server notifies the existing device of the new device.
/// 5. Both devices derive a shared sync key via X25519 DH + HKDF.
/// 6. Existing device encrypts and sends a full state snapshot.
/// 7. New device decrypts and restores state.
///
/// All devices are peers — the "existing" device is only special during
/// the linking ceremony. After linking, no master device exists.
///
/// **Cross-platform contract:**
/// - QR scheme (`qaudion://link/`) and base64url payload layout are
///   byte-identical to Android.
/// - Sync key = HKDF-SHA256(X25519(localPriv, remotePub),
///                          salt="qaudion-link-salt",
///                          info="qaudion-device-link-v1", L=32).
/// - State snapshot wire = `nonce(12) || AES-GCM(ct||tag(16))`.
public final class DeviceLinkingProtocol {

    public static let qrScheme = "qaudion://link/"
    public static let oneTimeCodeSize = 16
    public static let syncKeySize = 32
    public static let gcmNonceSize = 12
    public static let hkdfInfo = Data("qaudion-device-link-v1".utf8)
    public static let hkdfSalt = Data("qaudion-link-salt".utf8)

    public init() {}

    // MARK: - QR data

    public struct LinkQrData: Equatable {
        public let devicePubKey: Data    // 32-byte X25519 public key
        public let userId: String
        public let oneTimeCode: Data     // 16 random bytes

        public init(devicePubKey: Data, userId: String, oneTimeCode: Data) {
            self.devicePubKey = devicePubKey
            self.userId = userId
            self.oneTimeCode = oneTimeCode
        }
    }

    public enum LinkError: Error, Equatable {
        case invalidScheme
        case payloadTooShort(Int)
        case invalidUserIdLength(Int)
        case base64DecodeFailed
        case invalidPubKeyLength(Int)
        case ciphertextTooShort
        case decryptFailed
        case decodeJsonFailed
    }

    // MARK: - Generate / encode / decode QR

    /// Generate a QR payload on the EXISTING device. Mints a random
    /// 16-byte one-time code so each scan is unique.
    public func generateLinkQr(userId: String, devicePubKey: Data) -> LinkQrData {
        var code = Data(count: Self.oneTimeCodeSize)
        _ = code.withUnsafeMutableBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, Self.oneTimeCodeSize, base) == errSecSuccess ? 0 : -1
        }
        return LinkQrData(devicePubKey: devicePubKey, userId: userId, oneTimeCode: code)
    }

    /// Encode `LinkQrData` into a `qaudion://link/<base64url>` URI.
    /// Layout: `[32 pub][4 BE userIdLen][N userId UTF-8][16 oneTimeCode]`.
    public func encodeLinkQr(_ data: LinkQrData) -> String {
        let userIdBytes = Data(data.userId.utf8)
        var payload = Data(capacity: 32 + 4 + userIdBytes.count + Self.oneTimeCodeSize)
        payload.append(data.devicePubKey.prefix(32))
        let len = UInt32(userIdBytes.count)
        // Java ByteBuffer default is BIG_ENDIAN — match that.
        payload.append(UInt8((len >> 24) & 0xFF))
        payload.append(UInt8((len >> 16) & 0xFF))
        payload.append(UInt8((len >> 8) & 0xFF))
        payload.append(UInt8(len & 0xFF))
        payload.append(userIdBytes)
        payload.append(data.oneTimeCode.prefix(Self.oneTimeCodeSize))
        return Self.qrScheme + Self.base64URLEncode(payload)
    }

    /// Decode a `qaudion://link/...` URI back to `LinkQrData`.
    public func decodeLinkQr(_ link: String) throws -> LinkQrData {
        guard link.hasPrefix(Self.qrScheme) else { throw LinkError.invalidScheme }
        let encoded = String(link.dropFirst(Self.qrScheme.count))
        guard let raw = Self.base64URLDecode(encoded) else {
            throw LinkError.base64DecodeFailed
        }
        let minLen = 32 + 4 + Self.oneTimeCodeSize
        guard raw.count >= minLen else {
            throw LinkError.payloadTooShort(raw.count)
        }
        let base = raw.startIndex
        let pubKey = raw.subdata(in: base..<(base + 32))
        var off = base + 32
        let len = (Int(raw[off]) << 24) |
                  (Int(raw[off + 1]) << 16) |
                  (Int(raw[off + 2]) << 8) |
                  Int(raw[off + 3])
        guard len > 0, len <= 256 else {
            throw LinkError.invalidUserIdLength(len)
        }
        off += 4
        guard raw.count >= (off - base) + len + Self.oneTimeCodeSize else {
            throw LinkError.payloadTooShort(raw.count)
        }
        guard let userId = String(data: raw.subdata(in: off..<(off + len)), encoding: .utf8) else {
            throw LinkError.payloadTooShort(raw.count)
        }
        off += len
        let oneTimeCode = raw.subdata(in: off..<(off + Self.oneTimeCodeSize))
        return LinkQrData(devicePubKey: pubKey, userId: userId, oneTimeCode: oneTimeCode)
    }

    // MARK: - Sync key derivation (X25519 + HKDF-SHA256)

    /// Derive the 32-byte shared sync key. The local key uses CryptoKit's
    /// `Curve25519.KeyAgreement` — wire-compatible with BouncyCastle's
    /// `X25519Agreement`.
    public func deriveSyncKey(
        localPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePubKey: Data
    ) throws -> Data {
        guard remotePubKey.count == 32 else {
            throw LinkError.invalidPubKeyLength(remotePubKey.count)
        }
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePubKey)
        let shared = try localPrivateKey.sharedSecretFromKeyAgreement(with: remote)
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Self.hkdfSalt,
            sharedInfo: Self.hkdfInfo,
            outputByteCount: Self.syncKeySize
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    // MARK: - Encrypted state snapshot

    /// Serialize a state snapshot dictionary, AES-GCM-seal it under
    /// `syncKey`, and return base64-encoded `nonce || ciphertext || tag`.
    /// The dictionary structure matches Android: `{version, timestamp,
    /// contacts, settings, trust}`.
    public func createStateSnapshot(
        syncKey: Data,
        contacts: Any,
        settings: Any,
        trustData: Any
    ) throws -> String {
        let snapshot: [String: Any] = [
            "version": 1,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
            "contacts": contacts,
            "settings": settings,
            "trust": trustData,
        ]
        let plaintext = try JSONSerialization.data(withJSONObject: snapshot)
        let bytes = try Self.aesGcmEncrypt(key: syncKey, plaintext: plaintext)
        return bytes.base64EncodedString()
    }

    /// Decrypt and parse a snapshot.
    public func restoreFromSnapshot(_ encryptedBase64: String, syncKey: Data) throws -> [String: Any] {
        guard let encrypted = Data(base64Encoded: encryptedBase64) else {
            throw LinkError.base64DecodeFailed
        }
        let plaintext: Data
        do {
            plaintext = try Self.aesGcmDecrypt(key: syncKey, data: encrypted)
        } catch {
            throw LinkError.decryptFailed
        }
        guard let obj = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw LinkError.decodeJsonFailed
        }
        return obj
    }

    // MARK: - Internal AES-GCM helpers

    private static func aesGcmEncrypt(key: Data, plaintext: Data) throws -> Data {
        let symKey = SymmetricKey(data: key)
        let sealed = try AES.GCM.seal(plaintext, using: symKey)
        // Android wire = nonce(12) || ciphertext+tag.
        var out = Data(capacity: gcmNonceSize + sealed.ciphertext.count + sealed.tag.count)
        out.append(sealed.nonce.withUnsafeBytes { Data($0) })
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    private static func aesGcmDecrypt(key: Data, data: Data) throws -> Data {
        guard data.count >= gcmNonceSize + 16 else {
            throw LinkError.ciphertextTooShort
        }
        let nonceBytes = data.prefix(gcmNonceSize)
        let rest = data.suffix(from: data.startIndex + gcmNonceSize)
        let ct = rest.prefix(rest.count - 16)
        let tag = rest.suffix(16)
        let symKey = SymmetricKey(data: key)
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try AES.GCM.open(box, using: symKey)
    }

    // MARK: - base64url helpers (URL_SAFE | NO_WRAP equivalent)

    public static func base64URLEncode(_ data: Data) -> String {
        let std = data.base64EncodedString()
        return std
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func base64URLDecode(_ s: String) -> Data? {
        var t = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-pad to a multiple of 4.
        let mod = t.count % 4
        if mod == 2 { t += "==" }
        else if mod == 3 { t += "=" }
        else if mod == 1 { return nil }
        return Data(base64Encoded: t)
    }
}
