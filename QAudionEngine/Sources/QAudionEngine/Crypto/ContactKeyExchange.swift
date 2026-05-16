import Foundation
import CryptoKit

/// Pairwise first-contact PSK negotiation — Desktop/Android parity.
///
/// Mirrors `qaudion-desktop/src/main/calling/ContactKeyExchange.ts`
/// and `qaudion-android-new/.../crypto/ContactKeyExchange.kt`.
///
///   PSK = HKDF-SHA256(
///           ikm  = X25519_ECDH(my_priv, peer_pub),
///           salt = "qaudion-pairwise-v1",
///           info = "psk-first-contact",
///           L    = 32,
///         )
///
/// Wire protocol: exactly TWO frames over `opaque_message` in QUAD binary:
///   KEY_EXCHANGE_OFFER  (0x09): initiator → responder, carries initiator's X25519 pub.
///   KEY_EXCHANGE_ACCEPT (0x0a): responder → initiator, carries responder's X25519 pub.
///
/// Both sides independently run ECDH(my_priv, peer_pub) and derive the SAME
/// PSK — no CONFIRM/DONE frames exist in this protocol. The handshake is
/// complete after the ACCEPT is received. The receive-side dispatch in
/// AppState.wireOpaqueMessageHandler and QAudionCallIntegration
/// .onCapabilityMessageReceived routes both frame types correctly (verified
/// 2026-05-16 against Android QuadCapabilityFrame + ContactKeyExchange.kt).
///
/// Once exchanged, both sides store an identical PSK in the sovereign vault
/// bound to the counterparty's userId.
public final class ContactKeyExchange: @unchecked Sendable {

    // MARK: - Events

    /// Fired when a new PSK has been derived and persisted for a contact.
    public var onKeyExchanged: ((_ contactId: String, _ keyName: String, _ fingerprint: String) -> Void)?
    /// Fired on unrecoverable error (bad peer pubkey length, missing identity, etc.).
    public var onError: ((_ contactId: String, _ error: Error) -> Void)?

    // MARK: - Dependencies

    private let identity: SovereignIdentityManager
    private let vault: SovereignKeyVault
    private let sendOpaque: (_ recipientId: String, _ wire: Data) async throws -> Void

    /// - Parameters:
    ///   - identity: sovereign identity manager (provides this device's X25519 keypair).
    ///   - vault: PSK key vault (keychain-backed).
    ///   - sendOpaque: closure that sends a QUAD wire blob to `recipientId`
    ///     wrapped in a BCrypto `opaque_message` envelope.
    public init(
        identity: SovereignIdentityManager,
        vault: SovereignKeyVault,
        sendOpaque: @escaping (_ recipientId: String, _ wire: Data) async throws -> Void
    ) {
        self.identity = identity
        self.vault = vault
        self.sendOpaque = sendOpaque
    }

    // MARK: - Public API

    /// Fire a `KEY_EXCHANGE_OFFER` to `contactId` carrying our X25519 pubkey.
    ///
    /// - Parameters:
    ///   - contactId: target user id.
    ///   - force: when true, delete any previously-bound PSK for `contactId`
    ///     before sending. Used to recover from desync.
    /// - Returns: true when an OFFER was queued for send.
    @discardableResult
    public func initiate(contactId: String, force: Bool = false) async throws -> Bool {
        if force {
            removeBoundPsk(contactId: contactId)
        }

        guard let myPub = myX25519PublicKey() else {
            throw ContactKeyExchangeError.missingLocalIdentity
        }

        let wire = QAudionCapabilityExchange.createKeyExchangeOffer(payload: myPub)
        try await sendOpaque(contactId, wire)
        return true
    }

    /// Handle a `KEY_EXCHANGE_OFFER` received from `senderId`.
    /// Derives + stores the PSK, then replies with `KEY_EXCHANGE_ACCEPT`.
    public func handleOffer(senderId: String, peerPubKey: Data) async {
        do {
            try deriveAndStore(contactId: senderId, peerPub: peerPubKey)
            guard let myPub = myX25519PublicKey() else { return }
            let wire = QAudionCapabilityExchange.createKeyExchangeAccept(payload: myPub)
            try await sendOpaque(senderId, wire)
        } catch {
            onError?(senderId, error)
        }
    }

    /// Handle a `KEY_EXCHANGE_ACCEPT` received from `senderId`. Symmetric
    /// with `handleOffer` but does not send a reply.
    public func handleAccept(senderId: String, peerPubKey: Data) async {
        do {
            try deriveAndStore(contactId: senderId, peerPub: peerPubKey)
        } catch {
            onError?(senderId, error)
        }
    }

    // MARK: - Internals

    private func myX25519PublicKey() -> Data? {
        return identity.loadIdentity()?.encryptionPublic
    }

    private func myX25519PrivateKey() -> Data? {
        return identity.loadIdentity()?.encryptionPrivate
    }

    /// Vault binding uses the account name `"auto:<contactIdPrefix>"`.
    /// This mirrors the Desktop `contactId` linkage without adding a
    /// dedicated schema field to the Keychain wrapper.
    private func keyName(for contactId: String) -> String {
        let prefix = contactId.count > 8 ? String(contactId.prefix(8)) : contactId
        return "auto:\(prefix):\(contactId)"
    }

    private func removeBoundPsk(contactId: String) {
        let name = keyName(for: contactId)
        try? vault.deletePsk(name: name)
    }

    private func deriveAndStore(contactId: String, peerPub: Data) throws {
        guard peerPub.count == 32 else {
            throw ContactKeyExchangeError.invalidPeerPubKey(peerPub.count)
        }
        guard let myPriv = myX25519PrivateKey() else {
            throw ContactKeyExchangeError.missingLocalIdentity
        }

        // ECDH on Curve25519 via CryptoKit.
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: myPriv)
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPub)
        let shared = try priv.sharedSecretFromKeyAgreement(with: pub)

        // PSK = HKDF-SHA256(shared, salt="qaudion-pairwise-v1", info="psk-first-contact", 32)
        let pskKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: CryptoConstants.HKDF_SALT_PAIRWISE,
            sharedInfo: CryptoConstants.HKDF_INFO_PAIRWISE,
            outputByteCount: 32
        )
        let pskData = pskKey.withUnsafeBytes { Data($0) }

        // Fingerprint = hex(SHA256(psk)).
        let fingerprint = SHA256.hash(data: pskData)
            .map { String(format: "%02x", $0) }
            .joined()

        let name = keyName(for: contactId)

        // If an existing PSK has the same fingerprint, no-op.
        if let existingFp = vault.getFingerprint(name: name), existingFp == fingerprint {
            return
        }

        // Otherwise store (create-or-replace is handled inside storePsk).
        try vault.storePsk(name: name, key: pskData, fingerprint: fingerprint)
        onKeyExchanged?(contactId, name, fingerprint)
    }
}

public enum ContactKeyExchangeError: Error {
    case invalidPeerPubKey(Int)
    case missingLocalIdentity
}
