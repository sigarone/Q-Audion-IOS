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

    /// 2026-09-19 service-message root fix — what a payload IS, decided by the
    /// caller and never by sniffing: `.userContent` (chat text, attachment
    /// announces, forwards, resends) rides the CHAT ladder and never CONTROL;
    /// `.service` (control envelopes, group sender keys, nacks, avatar/timer/
    /// screenshot signals, mesh receipts, group-call control) rides the CONTROL
    /// channel ONLY and, with no CONTROL session, fails closed with
    /// `.noControlSession` — it is never sealed on v4/v3/v2/v1. Replaces the
    /// old `forceStatelessFormat` / `useControlChannel` booleans and the
    /// silent CONTROL → CHAT fallback they encoded.
    enum PayloadClass: Equatable {
        case userContent
        case service
    }

    /// Encrypts and sends a chat message. Idempotent on `messageId` —
    /// the same id is forwarded to the server so retries don't duplicate.
    /// - Parameter payloadClass: see `PayloadClass`. Service callers normally
    ///   use `sendService` (which holds and retries) rather than this directly.
    func sendEncrypted(
        messageId: UUID,
        peerUserId: String,
        plaintext: String,
        payloadClass: PayloadClass = .userContent
    ) async -> Outcome {
        // Authentication gate — without a token we can't talk to the
        // server. The container will surface `.notAuthenticated`.
        guard let token = appState.authService.loadToken(), !token.isEmpty else {
            return .failed(reason: .notAuthenticated)
        }
        // Ship via the shared, already-authenticated persistent WS
        // (appState.liveProvider). Building a fresh BCryptoBackendProvider
        // per send opened a SECOND WebSocket authenticating with the same
        // JWT → same server deviceID; the server then "replaced" the
        // persistent socket ("replacing stale ws device"), driving a
        // reconnect storm that left the device intermittently unreachable.
        // W-ONESOCKET: always send over the persistent WS — never a throwaway
        // provider. `ensurePersistentProviderConnected()` brings up (or
        // reuses) the single long-lived provider.
        //
        // 2026-09-19 (IOS-07) — resolved BEFORE sealing: the seal below and
        // the hand-off to `sendMessage` are then contiguous on the main actor,
        // so a session replacement (which also runs on the main actor) can
        // never land between "sealed under session N" and "shipped".
        guard let live = await appState.ensurePersistentProviderConnected() else {
            print("[ChatSend] no persistent WS available — deferring send")
            return .failed(reason: .networkError)
        }
        // `ensurePersistentProviderConnected` hands the provider back even when its
        // bounded wait for authentication timed out. Sealing then would burn a
        // ratchet step for a frame `sendMessage` is about to refuse (2026-09-19).
        guard live.persistentConnection.state == .authenticated else {
            print("[ChatSend] persistent WS not authenticated — deferring send (nothing sealed)")
            return .failed(reason: .networkError)
        }
        let wireBlob: Data
        switch await encryptForWire(
            messageId: messageId, peerUserId: peerUserId, plaintext: plaintext,
            payloadClass: payloadClass
        ) {
        case .success(let blob):
            wireBlob = blob
        case .failure(let reason):
            return .failed(reason: reason)
        }
        do {
            // FIX: pass messageId.uuidString as clientMsgId so the server
            // echoes the exact same UUID the recipient uses to reconstruct
            // the AAD for AEAD verification. Previously BCryptoMessageApiImpl
            // generated a NEW UUID here → AAD mismatch → every decrypt failed.
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

    // MARK: - Service payloads (2026-09-19 service-message root fix)

    /// How a service payload behaves when it cannot go out right now.
    enum ServiceDelivery {
        /// User-initiated operation (delete/edit/reaction/timer, sender keys,
        /// nack): held in the bounded per-peer queue and flushed in order once
        /// a CONTROL session exists and the socket is up.
        case hold
        /// Best-effort (avatar re-announce, mesh receipt): dropped instead.
        case bestEffort
    }

    /// The ONE entry point for service traffic. `.sent` — it left on CONTROL;
    /// `.held` — queued and will be flushed; `.dropped` — best-effort and could
    /// not go now. Never seals on anything but CONTROL.
    @discardableResult
    func sendService(
        peerUserId: String,
        plaintext: String,
        label: String,
        delivery: ServiceDelivery
    ) async -> ServiceSendCoordinator.Submission {
        let mapped: ServiceSendCoordinator.Delivery = (delivery == .hold) ? .hold : .bestEffort
        return await ServiceSendHub.shared.submit(
            peerId: peerUserId, plaintext: plaintext, label: label, delivery: mapped)
    }

    /// Seal-and-send of ONE service payload, as the coordinator's shipper.
    func shipServiceNow(messageId: UUID, peerUserId: String, plaintext: String) async -> ServiceSendCoordinator.SendResult {
        let outcome = await sendEncrypted(
            messageId: messageId, peerUserId: peerUserId, plaintext: plaintext, payloadClass: .service)
        switch outcome {
        case .delivered, .sent:
            return .sent
        case .failed(let reason):
            if reason == .noControlSession { return .noControlSession }
            if reason == .networkError { return .transportDown }
            return .failed
        }
    }

    /// W-MSGOUTBOX (2026-09-01) — outcome of the durable text send.
    /// `queued` is the one case `Outcome` cannot express: a retry entry is
    /// persisted in `ChatOutboxStore` and `ChatOutboxDrain` re-seals and
    /// re-sends the row's text with the same `client_msg_id`; the row stays
    /// `.sending`.
    enum DurableOutcome {
        case delivered(serverMessageId: String)
        case queued
        case failed(reason: ChatContainer.SendFailureReason)
    }

    /// W-MSGOUTBOX (2026-09-01) — `sendEncrypted` for the 1:1 TEXT path
    /// only (`ChatContainer.sendMessage`), with the transport failure
    /// re-routed into the durable outbox instead of `.failed`.
    ///
    /// Same steps, same order, same crypto as `sendEncrypted` (auth gate →
    /// `encryptForWire` → persistent WS → `messageApi.sendMessage`); the
    /// happy path returns what it returned before. The ONLY difference is
    /// the catch: when the socket is not there in time (`wsUnavailable`, no
    /// provider, send threw) a retry entry is written to `chat_outbox` —
    /// attempt 1 counted, first backoff armed — and the caller gets
    /// `.queued`. Crypto/PSK/auth failures still return `.failed` (the key
    /// exchange / login those trigger is the fix, not a retry). With
    /// `OutboxRetryPolicy.enabled == false` this collapses to the old
    /// `.failed(.networkError)`.
    ///
    /// 2026-09-19 (IOS-14, IOS-07) — the queued entry carries NO sealed bytes:
    /// the drain re-seals the row's text at transmit time, because a frame
    /// sealed under a session the peer has since replaced (call handshake,
    /// recovery) no longer opens on the far side. The transport is resolved
    /// before sealing so seal → ship is contiguous, and a send that has no
    /// transport does not burn a ratchet step.
    ///
    /// `sendEncrypted` itself keeps its contract for every other caller.
    func sendEncryptedDurable(
        messageId: UUID,
        conversationId: UUID,
        peerUserId: String,
        plaintext: String
    ) async -> DurableOutcome {
        guard let token = appState.authService.loadToken(), !token.isEmpty else {
            return .failed(reason: .notAuthenticated)
        }
        do {
            guard let live = await appState.ensurePersistentProviderConnected() else {
                throw BCryptoMessageError.wsUnavailable
            }
            // A provider that is not (yet) authenticated is no transport either:
            // sealing first would burn a ratchet step that the drain then burns
            // again when it re-seals. `.wsUnavailable` queues the row instead.
            guard live.persistentConnection.state == .authenticated else {
                throw BCryptoMessageError.wsUnavailable
            }
            let wireBlob: Data
            switch await encryptForWire(messageId: messageId, peerUserId: peerUserId, plaintext: plaintext) {
            case .success(let blob):
                wireBlob = blob
            case .failure(let reason):
                return .failed(reason: reason)
            }
            let serverMsgId = try await live.messageApi.sendMessage(
                recipientId: peerUserId,
                content: wireBlob,
                clientMsgId: messageId.uuidString
            )
            return .delivered(serverMessageId: serverMsgId)
        } catch {
            guard OutboxRetryPolicy.shouldQueue(isTransportFailure: true) else {
                print("[ChatSend] WS send failed: \(error.localizedDescription)")
                return .failed(reason: .networkError)
            }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let attempts = 1
            ChatOutboxStore().enqueueMessage(
                clientMsgId: messageId.uuidString,
                messageId: messageId,
                conversationId: conversationId,
                peerUserId: peerUserId,
                wireBlob: Data(),
                attempts: attempts,
                createdAtMs: nowMs,
                nextAttemptAtMs: nowMs + OutboxRetryPolicy.backoffMs(afterFailedAttempts: attempts)
            )
            RTLog.warn("chat", "send queued=1 attempts=\(attempts)")
            return .queued
        }
    }

    /// Encrypts `plaintext` the SAME way `sendEncrypted` does (v4 native
    /// ratchet -> v3.1 forward-secrecy ratchet -> legacy PSK-AEAD, chosen by
    /// per-peer capability) but stops short of the WebSocket network send.
    ///
    /// This is the ONE crypto entry point the BLE-mesh send path
    /// (`ChatContainer.sendViaMesh`) is allowed to call — the mesh transport
    /// never invents its own encryption; it wraps whatever opaque `Data`
    /// this method returns in a `MeshChatMessage` envelope and hands it to
    /// `MeshRuntime`. Extracted from `sendEncrypted` (which now calls this
    /// internally too) so both callers share one crypto-dispatch
    /// implementation instead of two copies that could drift.
    /// - Parameter aadOverride: associated data for the LEGACY v2 path only.
    ///   The mesh passes the public packet header here so a relay cannot
    ///   re-address a packet it forwards; v3.1 and v4 rebuild their own AAD
    ///   internally and ignore it, exactly as on Android.
    /// - Parameter payloadClass: 2026-09-19 service-message root fix — the
    ///   channel a payload rides is decided by WHAT it is, never by what
    ///   happens to be available:
    ///     `.userContent` — the CHAT ladder below (v4 → v3/v2/v1 PSK), never CONTROL.
    ///     `.service`     — the v5 CONTROL channel ONLY (`encryptV5Routed`); with no
    ///                      CONTROL session, or a failed v5 seal, the result is a
    ///                      typed failure and NOTHING is sealed on any other channel.
    ///   This replaces the old `forceStatelessFormat` (service payloads on the
    ///   stateless v1 PSK format, or on the v4 CHAT session when the peer had
    ///   one) and `useControlChannel` (CONTROL when present, CHAT otherwise)
    ///   booleans: both ladders let a control envelope land on a wire the peer
    ///   treats as user chat, where a failed open became a visible "Messaggio
    ///   non decifrabile" for a payload that was never user content (live
    ///   2026-09-19 08:49). Callers that must not lose the payload go through
    ///   `sendService`, which holds it until a CONTROL session exists.
    func encryptForWire(
        messageId: UUID,
        peerUserId: String,
        plaintext: String,
        aadOverride: Data? = nil,
        payloadClass: PayloadClass = .userContent
    ) async -> Result<Data, ChatContainer.SendFailureReason> {
        // 2026-09-19 service-message root fix — defence in depth: a payload that is
        // USER content by declaration can never be service-shaped. A caller that
        // forgot `.service`, or a user pasting `{"qa_ctl":1,...}`, must not put a
        // control envelope on the CHAT wire, where the peer refuses it
        // (channel-is-kind) and the send would just look lost. An attachment
        // announce is not `isService`, so the attachment pipeline is unaffected.
        if payloadClass == .userContent, ServicePayloadDetector.classify(plaintext).isService {
            RTLog.warn("chat", "send refused=1 reason=1 class=0")
            return .failure(.generic)
        }
        guard let senderId = appState.currentUserId else {
            return .failure(.notAuthenticated)
        }
        let plaintextData = Data(plaintext.utf8)

        // W-CTRLENSURESEND (2026-09-19) — mirrors Android's
        // `EnsureV4SessionUseCase.ensure`, called at the top of every send:
        // fire-and-forget check for a missing CHAT/CONTROL session with this
        // peer, so convergence no longer waits for either side to place a
        // call. See `AppState.ensureV4Session`'s doc for the full rationale.
        AppState.ensureV4Session(selfId: senderId, peerId: peerUserId, liveProvider: appState.liveProvider)

        // Service payloads: CONTROL or nothing. Never a downgrade.
        if payloadClass == .service {
            return sealOnControl(peerUserId: peerUserId, plaintext: plaintextData)
        }

        // ── userContent: the CHAT ladder ──
        let peerIsV4 = AppState.sharedV4Ratchet.hasV4Session(peerUserId)

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
        let useV4 = peerIsV4
        print("[PQC_DIAG_V4] send peer=\(peerUserId.prefix(8))… useV4=\(useV4) hasV4Session=\(peerIsV4)")

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
                return .failure(.cryptoFailure)
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
                // W-MSGPSKPICK (2026-08-02): send under the NEWEST PSK bound
                // to this contact, which is the rule Android decrypts by
                // (`SovereignKeyVault.findNewestForContact`). The fixed
                // `auto:` → bare ladder was the cross-platform break: Android
                // re-binds a call-derived PSK after every call, so after one
                // call the two platforms chose different keys and every
                // iOS→Android message died on the Android side with
                // "MessageCrypto.decrypt returned null — invalid key/payload"
                // (observed 23:09:15, at the exact second of an iOS send).
                // The avatar envelope rides inside those messages, so the
                // announce never reached Android's handler at all.
                //
                // Fail-closed is unchanged: `orderedPskCandidates` only ever
                // returns keys genuinely bound to this peer, and an empty
                // list still falls through to the key-exchange branch below —
                // never to a derivable fallback (FIX H1).
                if let newest = PairwiseChainKeyResolver
                    .orderedPskCandidates(peerId: peerUserId, vault: vault).first {
                    psk = newest
                } else if let stored = try vault.loadPsk(name: autoName), !stored.isEmpty {
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
                    print("[ChatSend] PSK not found for \(peerUserId.prefix(8))… — refusing to send, triggering key exchange")
                    appState.triggerKeyExchange(with: peerUserId)
                    return .failure(.pskMissing)
                }
            } catch {
                // Vault failure is hard — keychain refusing access.
                print("[ChatSend] PSK vault load failed: \(error.localizedDescription)")
                return .failure(.cryptoFailure)
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
                        msgId: messageId.uuidString,
                        aadOverride: aadOverride
                    )
                }
            } catch {
                print("[ChatSend] encrypt failed: \(error.localizedDescription)")
                return .failure(.cryptoFailure)
            }
        }

        return .success(wireBlob)
    }

    /// 2026-09-19 service-message root fix — the ONLY way a service payload is
    /// sealed: the v5 CONTROL channel, or a typed failure. No CHAT session, no
    /// PSK ladder, no stateless format is ever consulted here. The check and the
    /// seal are one synchronous step under the ratchet's own lock-protected
    /// primitives, so nothing can drop the session between them.
    private func sealOnControl(peerUserId: String, plaintext: Data) -> Result<Data, ChatContainer.SendFailureReason> {
        let ratchet = AppState.sharedV4Ratchet
        guard ratchet.hasChannelSession(epochId: MessageRatchet.v5ControlRoutingEpoch, peerId: peerUserId) else {
            return .failure(.noControlSession)
        }
        guard let frame = ratchet.encryptV5Routed(
            epochId: MessageRatchet.v5ControlRoutingEpoch, peerId: peerUserId, plaintext: plaintext
        ), let first = frame.first, first == MessageRatchet.magicV5 else {
            print("[ChatSend] CONTROL selected but v5 encrypt failed/unroutable — failing closed (no downgrade)")
            return .failure(.cryptoFailure)
        }
        return .success(frame)
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
