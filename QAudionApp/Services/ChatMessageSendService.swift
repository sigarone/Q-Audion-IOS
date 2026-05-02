import Foundation
import CryptoKit
import QAudionEngine

/// Encrypts a chat message using `MessageCrypto` (Desktop wire format,
/// AES-256-GCM with HKDF-derived per-message key) and ships it via the
/// BCrypto WebSocket transport.
///
/// **Wire format** (parity with `qaudion-desktop/.../MessageCrypto.ts` and
/// `qaudion-android-new/.../MessageCrypto.kt`):
///
///     salt(32) || nonce(12) || ciphertext(N) || tag(16)
///
/// **Key derivation**:
///   `key = HKDF-SHA256(ikm = psk, salt = random32B, info = "q-audion-msg-key")`
///
/// **AAD**: `"msg:{senderId}:{recipientId}:{msgId}"` — binds the AEAD tag
/// to the conversation triplet so a stolen ciphertext can't be replayed
/// against another peer.
///
/// **PSK source**: the per-pair PSK is loaded from `SovereignKeyVault`
/// using the peer userId as the keychain key (keychain account name).
/// When no PSK is yet bound for the contact (e.g. unverified contacts
/// without a completed `ContactKeyExchange` handshake) we fall back to a
/// deterministic SHA-256(`peerUserId || senderUserId`) — the same
/// degraded-but-functional path that `AppState.sendMessage` already uses.
/// The fallback is logged so the UI can flag the message as `pskMissing`
/// for the user, but the message still goes through.
@MainActor
final class ChatMessageSendService {

    /// Outcome of a send attempt — the caller maps `Failed` to the
    /// `ChatContainer.SendFailureReason` for snackbar feedback.
    enum Outcome {
        /// Server acknowledged with a server-issued messageId.
        case delivered(serverMessageId: String)
        /// Encrypted send went out but no server-side response yet (best-
        /// effort path — WS doesn't ack inline today). The local
        /// store flips to `.delivered` after a fixed delay until the
        /// engine wires receipt callbacks.
        case sent
        /// Hard failure — message did not leave the device.
        case failed(reason: ChatContainer.SendFailureReason)
    }

    private let appState: AppState
    private let crypto = MessageCrypto()
    private let vault = SovereignKeyVault()

    init(appState: AppState) {
        self.appState = appState
    }

    /// Encrypts and sends a chat message. Idempotent on `messageId` —
    /// the same id is forwarded to the server so retries don't duplicate.
    func sendEncrypted(
        messageId: UUID,
        peerUserId: String,
        plaintext: String
    ) async -> Outcome {
        // Authentication gate — without a token we can't talk to the
        // server. The container will surface `.notAuthenticated`.
        guard let token = appState.authService.loadToken(), !token.isEmpty else {
            return .failed(reason: .notAuthenticated)
        }
        guard let senderId = appState.currentUserId else {
            return .failed(reason: .notAuthenticated)
        }
        let plaintextData = Data(plaintext.utf8)

        // Resolve PSK. Production path: pairwise PSK from the vault
        // (populated by `ContactKeyExchange` after the QR/NFC handshake).
        // Fallback: deterministic SHA-256(peer || self) so an unpaired
        // contact can still exchange best-effort messages while the
        // verification UX gets shipped — same degraded path as legacy
        // `AppState.sendMessage`.
        let psk: Data
        let pskFallback: Bool
        do {
            // W77: ContactKeyExchange persists pairwise PSKs under the
            // `auto:<peerIdPrefix>:<peerId>` name (see
            // `ContactKeyExchange.keyName(for:)`). Check that first,
            // then the bare peerId (legacy / manually-bound), then
            // fall back to the deterministic insecure derivation.
            let prefix = peerUserId.count > 8 ? String(peerUserId.prefix(8)) : peerUserId
            let autoName = "auto:\(prefix):\(peerUserId)"
            if let stored = try vault.loadPsk(name: autoName), !stored.isEmpty {
                psk = stored
                pskFallback = false
            } else if let stored = try vault.loadPsk(name: peerUserId), !stored.isEmpty {
                psk = stored
                pskFallback = false
            } else {
                psk = Self.fallbackPsk(peerUserId: peerUserId, senderId: senderId)
                pskFallback = true
                print("[ChatSend] PSK not found for \(peerUserId) — using deterministic fallback")
            }
        } catch {
            // Vault failure is hard — keychain refusing access.
            print("[ChatSend] PSK vault load failed: \(error.localizedDescription)")
            return .failed(reason: .cryptoFailure)
        }

        // W352: outbound v3 ratchet routing. Default OFF until peers have
        // had time to update past v1.0.330 (which added the inbound v3
        // routing). Enable by setting UserDefaults
        // `ChatRatchetV3.enabled` = true. Once enabled, every outbound
        // chat message rides the v3.1 wire format (magic 0xE3, canonical
        // CBOR AAD, forward-secrecy chain) instead of the legacy v1
        // MessageCrypto path. Inbound v3 already lands via W351 since
        // last release.
        let useV3 = UserDefaults.standard.bool(forKey: "ChatRatchetV3.enabled")
        let wireBlob: Data
        do {
            if useV3 {
                wireBlob = try Self.ratchetEncryptV3(
                    plaintext: plaintextData,
                    psk: psk,
                    senderId: senderId,
                    peerId: peerUserId,
                    msgId: messageId.uuidString
                )
            } else {
                wireBlob = try crypto.encrypt(
                    plaintext: plaintextData,
                    psk: psk,
                    senderId: senderId,
                    recipientId: peerUserId,
                    msgId: messageId.uuidString
                )
            }
        } catch {
            print("[ChatSend] encrypt failed: \(error.localizedDescription)")
            return .failed(reason: .cryptoFailure)
        }

        // Ship via the BCrypto WS transport. The provider is built per
        // call to keep this service stateless — token refresh /
        // reconnect logic lives upstream in the WS client.
        let backendConfig = BackendConfig(
            serverUrl: appState.serverUrl,
            accessToken: token
        )
        do {
            let provider = BCryptoBackendProvider(config: backendConfig)
            try await provider.initialize()
            let serverMsgId = try await provider.messageApi.sendMessage(
                recipientId: peerUserId,
                content: wireBlob
            )
            if pskFallback {
                // Wire still went out — caller may decide to flag the
                // message visually but should not roll back the local
                // store. We surface as `.sent` (success) and let the
                // ChatContainer decide if it wants to log a warning.
                return .sent
            }
            return .delivered(serverMessageId: serverMsgId)
        } catch {
            // Most likely: WS not connected, 401 token expired, or
            // server-side validation rejected the wire. Map to network.
            print("[ChatSend] WS send failed: \(error.localizedDescription)")
            return .failed(reason: .networkError)
        }
    }

    // MARK: - Internals

    /// Deterministic PSK fallback used only when no pairwise PSK has been
    /// negotiated yet. Symmetric in (peer, self) so both sides derive the
    /// same key when neither has run `ContactKeyExchange`. Same shape as
    /// the legacy `AppState.sendMessage` path — kept for compatibility
    /// during the rollout of `ContactKeyExchange`-driven pairwise PSK
    /// negotiation.
    ///
    /// **SECURITY NOTE** — derivable from public userIds, **does NOT
    /// provide confidentiality against a network observer**. An external
    /// reviewer correctly flagged this as a critical gap. The replacement
    /// path is engine WT: route every chat-message send through
    /// `SovereignKeyVault` and refuse to send when no pairwise PSK
    /// exists (return `.failed(reason: .pskMissing)` instead). Until
    /// the UX for bootstrap-the-PSK-via-QR is shipped, leaving the
    /// fallback in place keeps iOS<->iOS chat functional in TestFlight,
    /// at the explicit cost of confidentiality.
    private static func fallbackPsk(peerUserId: String, senderId: String) -> Data {
        // Sort so order doesn't matter — the receiver derives the same key.
        let pair = [peerUserId, senderId].sorted().joined(separator: ":")
        let digest = SHA256.hash(data: Data("qaudion-fallback-psk:\(pair)".utf8))
        return Data(digest)
    }

    // MARK: - W352: v3 outbound ratchet

    /// Ratchet engine + vault are static so a peer's send chain
    /// advances correctly across multiple sends within a session.
    /// Mirrors the static held by AppState's inbound path so both
    /// directions share state when running in the same process.
    private static let ratchetVault: InMemoryRatchetVault = InMemoryRatchetVault()
    private static let ratchet: MessageRatchet = MessageRatchet(vault: ratchetVault)

    /// Encrypt a plaintext for the v3.1 wire (magic 0xE3, canonical
    /// CBOR AAD, forward-secrecy chain). Bootstraps the per-peer
    /// session from `psk` if no snapshot is in the vault yet.
    private static func ratchetEncryptV3(
        plaintext: Data,
        psk: Data,
        senderId: String,
        peerId: String,
        msgId: String
    ) throws -> Data {
        let session = try ratchet.ensureSession(
            epochId: "v1",          // single epoch until we wire negotiation
            selfId: senderId,
            peerId: peerId,
            pskRoot: psk
        )
        let aad = MessageRatchet.buildMessageAD(
            senderId: senderId, recipientId: peerId, clientMsgId: msgId)
        return try ratchet.encrypt(
            session: session, plaintext: plaintext, aad: aad, clientMsgId: msgId)
    }
}
