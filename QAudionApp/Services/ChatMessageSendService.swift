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
/// When no pairwise PSK is yet bound for the contact (e.g. unverified
/// contacts without a completed `ContactKeyExchange` handshake) the send
/// is REFUSED — it returns `.failed(reason: .pskMissing)` and triggers a
/// `ContactKeyExchange` OFFER so a real X25519-derived PSK is negotiated.
/// We never fall back to a server-derivable key (FIX H1): there is no
/// silent confidentiality downgrade. The user retries once the exchange
/// completes.
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

        // ── Phase 18 — v4 native PQ ratchet gate (checked BEFORE the PSK) ──
        // SYNCHRONOUS, fail-closed: route v4 ONLY when a persisted v4 session
        // already exists for this peer (which implies the v4 path is enabled AND
        // a negotiated+verified handshake bootstrapped it — `hasV4Session` is the
        // per-peer v4 capability proof). This MUST be resolved BEFORE the
        // ContactKeyExchange PSK resolution because the v4 path uses the v4
        // SESSION, NOT that PSK — a v4-capable peer with no ContactKeyExchange
        // PSK must NOT be wrongly refused with `.pskMissing` (BUG 1 / parity with
        // Android `MessageCrypto.kt` which dispatches on `ratchetVersion == 4`
        // before any v3/v2 PSK lookup). The 0xE5 frame is OPAQUE — emitted by the
        // engine-routed method; we never build it here.
        let useV4 = AppState.sharedV4Ratchet.hasV4Session(peerUserId)
        print("[PQC_DIAG_V4] send peer=\(peerUserId) useV4=\(useV4) hasV4Session=\(useV4)")

        let wireBlob: Data
        if useV4 {
            // v4 path: independent of the ContactKeyExchange PSK. FAIL CLOSED —
            // if the engine returns nil (disabled mid-flight, deserialize/
            // encrypt/persist error) we refuse the send rather than silently
            // re-encrypting under a weaker v3/v2 epoch.
            guard let frame = AppState.sharedV4Ratchet.encryptV4Routed(
                peerId: peerUserId, plaintext: plaintextData
            ), let first = frame.first, first == MessageRatchet.magicV4 else {
                print("[ChatSend] v4 selected but encrypt failed/unroutable — failing closed (no downgrade)")
                return .failed(reason: .cryptoFailure)
            }
            wireBlob = frame
        } else {
            // ── No v4 session: v3/v2 path, which DOES need a pairwise PSK. ──
            // Resolve PSK. Only a real pairwise PSK from the vault (populated by
            // `ContactKeyExchange` after the QR/NFC/auto handshake) is acceptable.
            // If none exists, we REFUSE to send and trigger a key exchange — we
            // never derive a server-guessable fallback key (FIX H1).
            let psk: Data
            do {
                // W77: ContactKeyExchange persists pairwise PSKs under the
                // `auto:<peerIdPrefix>:<peerId>` name (see
                // `ContactKeyExchange.keyName(for:)`). Check that first,
                // then the bare peerId (legacy / manually-bound); if neither
                // exists, refuse the send and kick off a key exchange.
                let prefix = peerUserId.count > 8 ? String(peerUserId.prefix(8)) : peerUserId
                let autoName = "auto:\(prefix):\(peerUserId)"
                if let stored = try vault.loadPsk(name: autoName), !stored.isEmpty {
                    psk = stored
                } else if let stored = try vault.loadPsk(name: peerUserId), !stored.isEmpty {
                    psk = stored
                } else {
                    // FIX H1: refuse to send when no pairwise PSK exists. The old
                    // deterministic SHA-256(sorted(peer,self)) fallback was
                    // derivable by the server (and anyone who knows the two public
                    // userIds), so it gave NO confidentiality. Instead, kick off a
                    // ContactKeyExchange OFFER (W566 auto-identity) so a real
                    // X25519-derived PSK gets bound under `auto:<prefix>:<peerId>`,
                    // and fail this send. Once the peer's ACCEPT lands, the user's
                    // Retry succeeds against the real PSK (resolved above).
                    print("[ChatSend] PSK not found for \(peerUserId) — refusing to send, triggering key exchange")
                    appState.triggerKeyExchange(with: peerUserId)
                    return .failed(reason: .pskMissing)
                }
            } catch {
                // Vault failure is hard — keychain refusing access.
                print("[ChatSend] PSK vault load failed: \(error.localizedDescription)")
                return .failed(reason: .cryptoFailure)
            }

            // W365: per-peer v3 capability gate. The global UserDefaults
            // flag still works as a kill-switch — but normally we now flip
            // to v3 automatically the first time we observe a v3 inbound
            // from this peer (PeerCapabilityRegistry.probeInbound writes
            // the flag). This means v3 lights up incrementally as peers
            // upgrade, without any manual coordination per device.
            let useV3 = PeerCapabilityRegistry.shared.shouldUseV3Outbound(for: peerUserId)
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
        }

        // Ship via the shared, already-authenticated persistent WS
        // (appState.liveProvider). Building a fresh BCryptoBackendProvider
        // per send opened a SECOND WebSocket authenticating with the same
        // JWT → same server deviceID; the server then "replaced" the
        // persistent socket ("replacing stale ws device"), driving a
        // reconnect storm that left the device intermittently unreachable.
        // Only fall back to a transient provider if the shared one isn't up.
        do {
            // FIX: pass messageId.uuidString as clientMsgId so the server
            // echoes the exact same UUID the recipient uses to reconstruct
            // the AAD for AEAD verification. Previously BCryptoMessageApiImpl
            // generated a NEW UUID here → AAD mismatch → every decrypt failed.
            // W-ONESOCKET: always send over the persistent WS. The old
            // fallback opened a throwaway `BCryptoBackendProvider` +
            // `initialize()` for this one message — a second `/ws` with the
            // same JWT/deviceID, which made the server replace the live socket
            // ("replacing stale ws device") → reconnect storm + a re-POSTed
            // apns-voip-token. `ensurePersistentProviderConnected()` brings up
            // (or reuses) the single long-lived provider instead.
            guard let live = await appState.ensurePersistentProviderConnected() else {
                print("[ChatSend] no persistent WS available — deferring send")
                return .failed(reason: .networkError)
            }
            let serverMsgId = try await live.messageApi.sendMessage(
                recipientId: peerUserId,
                content: wireBlob,
                clientMsgId: messageId.uuidString
            )
            return .delivered(serverMessageId: serverMsgId)
        } catch {
            // Most likely: WS not connected, 401 token expired, or
            // server-side validation rejected the wire. Map to network.
            print("[ChatSend] WS send failed: \(error.localizedDescription)")
            return .failed(reason: .networkError)
        }
    }

    // MARK: - Internals

    // MARK: - W352: v3 outbound ratchet

    /// W357: Keychain-backed vault — same persistence surface AppState
    /// uses for inbound, so chain state survives process death on both
    /// directions of the chain.
    private static let ratchetVault: RatchetVault = KeychainRatchetVault()
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
