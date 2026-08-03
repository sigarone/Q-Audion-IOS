import Foundation
import CryptoKit

/// SEC-WIREUNIFY (2026-08-03) — file-attachment ANNOUNCE envelope:
/// X25519 ECDH + HKDF-SHA256 + AES-256-GCM key-wrap, one wrapped
/// `contentKey` per recipient device.
///
/// Byte-exact port of Android `qaudion-engine/.../file/FileAttachmentAnnounce.kt`,
/// verified against that file's own KAT-vector generator — see
/// `FileAttachmentCipherKatTests.swift`. DEDICATED HKDF info / AAD / wrap-nonce
/// prefixes keep this pipeline isolated from the voice-note announce.
///
/// # Cryptographic shape
///
///   sender mints fresh ephemeral X25519 keypair (eph_priv, eph_pub).
///   For each recipient device d_i:
///     ss_i      = X25519(eph_priv, IK_X25519_pub_i)
///     wrapKey_i = HKDF-SHA256(
///                    ikm  = ss_i,
///                    salt = ∅,
///                    info = "qaudion-fa-v1-wrap|" || file_id || sender_id || device_id,
///                    L    = 32,
///                 )
///     aad_i     = "qaudion-fa-v1-wrap-aad|" || sender_id || device_id
///     wrap_i    = AES-256-GCM(wrapKey_i, FIXED_NONCE, aad_i, contentKey)
///
/// # Fixed wrap nonce — why it's safe
///
///   The wrap-key is unique per (eph_priv, recipient_device, file_id) —
///   eph_priv is fresh-per-file, so no two file attachments ever share a
///   wrap key. With unique keys, identical nonces are fine (NIST SP
///   800-38D §8.2) — same rationale Android's header documents.
public enum FileAttachmentAnnounce {

    private static let idLen = 16
    private static let contentKeyLen = 32
    private static let x25519PubLen = 32
    private static let x25519PrivLen = 32
    private static let wrapTagLen = 16
    private static let wrapNonceLen = 12

    /// Wrapped content key = 32 B plaintext + 16 B GCM tag.
    public static let wrappedContentKeyLen = contentKeyLen + wrapTagLen

    /// Fixed 12-B AES-GCM nonce. Safe under the unique-wrap-key invariant above.
    private static let wrapNonce: Data = {
        let raw = Data("qaudion-fa-wrap-v1-nonce!".utf8)
        precondition(raw.count >= wrapNonceLen)
        return raw.prefix(wrapNonceLen)
    }()

    private static let wrapInfoPrefix = Data("qaudion-fa-v1-wrap|".utf8)
    private static let wrapAadPrefix = Data("qaudion-fa-v1-wrap-aad|".utf8)

    public enum CryptoError: Error, Equatable {
        case badArgument(String)
        case openFailed
    }

    /// Recipient device descriptor.
    public struct RecipientDevice {
        public let deviceId: Data       // 16 B canonical device UUID
        public let identityPub: Data    // 32 B X25519 long-term identity public key

        public init(deviceId: Data, identityPub: Data) throws {
            guard deviceId.count == idLen else { throw CryptoError.badArgument("deviceId len") }
            guard identityPub.count == x25519PubLen else { throw CryptoError.badArgument("identityPub len") }
            self.deviceId = deviceId
            self.identityPub = identityPub
        }
    }

    /// Per-device wrap, ready to ship over the WS announce envelope.
    public struct DeviceWrap: Equatable {
        public let deviceId: Data
        public let wrappedContentKey: Data
    }

    /// Result of `seal`.
    public struct Sealed {
        public let senderEphPub: Data
        public let wraps: [DeviceWrap]
    }

    /// Generate a fresh sender ephemeral X25519 keypair and produce one
    /// AES-256-GCM-wrapped copy of `contentKey` per recipient device.
    public static func seal(
        contentKey: Data, fileId: Data, senderId: Data, recipientDevices: [RecipientDevice]
    ) throws -> Sealed {
        guard contentKey.count == contentKeyLen else { throw CryptoError.badArgument("contentKey len") }
        guard fileId.count == idLen else { throw CryptoError.badArgument("fileId len") }
        guard senderId.count == idLen else { throw CryptoError.badArgument("senderId len") }
        guard !recipientDevices.isEmpty else { throw CryptoError.badArgument("recipientDevices must not be empty") }

        let ephPriv = Curve25519.KeyAgreement.PrivateKey()
        let ephPub = Data(ephPriv.publicKey.rawRepresentation)

        var wraps: [DeviceWrap] = []
        wraps.reserveCapacity(recipientDevices.count)
        for recipient in recipientDevices {
            let peerPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.identityPub)
            let shared = try ephPriv.sharedSecretFromKeyAgreement(with: peerPub)
            let sharedRaw = shared.withUnsafeBytes { Data($0) }
            let wrapKey = deriveWrapKey(
                sharedSecret: sharedRaw, fileId: fileId, senderId: senderId, recipientDeviceId: recipient.deviceId)
            let aad = buildWrapAad(senderId: senderId, recipientDeviceId: recipient.deviceId)
            let wrapped = try aesGcmSeal(key: wrapKey, aad: aad, plaintext: contentKey)
            wraps.append(DeviceWrap(deviceId: recipient.deviceId, wrappedContentKey: wrapped))
        }
        return Sealed(senderEphPub: ephPub, wraps: wraps)
    }

    /// Recover `contentKey` from a single wrapped blob addressed to the
    /// calling device. Throws `.openFailed` on AEAD verify failure.
    public static func open(
        myIdentityPriv: Data, senderEphPub: Data, fileId: Data, senderId: Data,
        myDeviceId: Data, wrappedContentKey: Data
    ) throws -> Data {
        guard myIdentityPriv.count == x25519PrivLen else { throw CryptoError.badArgument("myIdentityPriv len") }
        guard senderEphPub.count == x25519PubLen else { throw CryptoError.badArgument("senderEphPub len") }
        guard fileId.count == idLen else { throw CryptoError.badArgument("fileId len") }
        guard senderId.count == idLen else { throw CryptoError.badArgument("senderId len") }
        guard myDeviceId.count == idLen else { throw CryptoError.badArgument("myDeviceId len") }
        guard wrappedContentKey.count == wrappedContentKeyLen else {
            throw CryptoError.badArgument("wrappedContentKey len")
        }

        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: myIdentityPriv)
        let ephPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderEphPub)
        let shared = try priv.sharedSecretFromKeyAgreement(with: ephPub)
        let sharedRaw = shared.withUnsafeBytes { Data($0) }
        let wrapKey = deriveWrapKey(
            sharedSecret: sharedRaw, fileId: fileId, senderId: senderId, recipientDeviceId: myDeviceId)
        let aad = buildWrapAad(senderId: senderId, recipientDeviceId: myDeviceId)
        do {
            return try aesGcmOpen(key: wrapKey, aad: aad, wrapped: wrappedContentKey)
        } catch {
            throw CryptoError.openFailed
        }
    }

    /// HKDF-SHA256(ikm = sharedSecret, salt = ∅,
    /// info = "qaudion-fa-v1-wrap|" || fileId || senderId || recipientDeviceId, L = 32).
    /// Takes the RAW ECDH output (not a `SharedSecret` box) — same
    /// `withUnsafeBytes` extraction pattern already used throughout this
    /// codebase (`KmsTransport.ecdh`, `SovereignIdentityManager.
    /// deriveSharedSecret`, `QAudionCallIntegration`) — so the KAT test can
    /// feed a fixed shared secret directly and this matches Android's
    /// `HKDFParameters(sharedSecret, null, info)` byte-for-byte.
    public static func deriveWrapKey(
        sharedSecret: Data, fileId: Data, senderId: Data, recipientDeviceId: Data
    ) -> Data {
        var info = wrapInfoPrefix
        info.append(fileId)
        info.append(senderId)
        info.append(recipientDeviceId)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: Data(),
            info: info,
            outputByteCount: contentKeyLen
        ).withUnsafeBytes { Data($0) }
    }

    public static func buildWrapAad(senderId: Data, recipientDeviceId: Data) -> Data {
        var aad = wrapAadPrefix
        aad.append(senderId)
        aad.append(recipientDeviceId)
        return aad
    }

    // MARK: - Internals

    private static func aesGcmSeal(key: Data, aad: Data, plaintext: Data) throws -> Data {
        let symKey = SymmetricKey(data: key)
        let nonce = try AES.GCM.Nonce(data: wrapNonce)
        let sealed = try AES.GCM.seal(plaintext, using: symKey, nonce: nonce, authenticating: aad)
        // Same zero-index footgun as ChaChaPoly — force a fresh, contiguous
        // copy at creation (see AttachmentEncryption.swift's own fix).
        return Data(sealed.ciphertext + sealed.tag)
    }

    private static func aesGcmOpen(key: Data, aad: Data, wrapped: Data) throws -> Data {
        let symKey = SymmetricKey(data: key)
        let nonce = try AES.GCM.Nonce(data: wrapNonce)
        let ct = wrapped.prefix(wrapped.count - wrapTagLen)
        let tag = wrapped.suffix(wrapTagLen)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try AES.GCM.open(box, using: symKey, authenticating: aad)
    }
}
