import Foundation
import CryptoKit
import QAudionEngine

/// Poll-only client for bcrypto-server's service-notice channel.
///
/// The server side of this was already fully built and already had a
/// consumer — Android's `NoticeRepository.kt` polls the identical endpoint
/// and runs the identical decrypt on every launch. iOS simply never got a
/// reader. This is a port of that repository, not a new subsystem: the
/// wire contract, crypto parameters and even the Settings-row copy below
/// are all pinned to what ships today (`cmd/bcrypto-lite/notice_routes.go`,
/// `internal/notices/` in bcrypto-server).
///
/// Endpoint: `GET /api/v1/notices/inbox` (bearer token) →
/// `{"v":1,"notices":[NoticeEnvelope]}`. Each envelope carries a plaintext
/// `title` and an X25519-ECIES-sealed `body`:
///   1. ECDH: sharedSecret = myDeviceX25519Priv.ECDH(envelope.ephemeralPub)
///   2. HKDF-SHA256(sharedSecret, salt="bcrypto-notices-v1",
///      info="bcrypto-notices-v1", L=32) → AES key
///   3. AES-256-GCM open, no AAD. Wire ciphertext = nonce(12) || ct || tag(16).
/// Byte-for-byte what `internal/notices/encrypt.go`'s `DecryptForDevice`
/// documents and what Android's `NoticeRepository.decryptEnvelope` already
/// implements — the device key is the SAME long-term X25519 identity key
/// this app already registers via `DeviceKeyManager` for the KMS pipeline
/// and the file-attachment receiver, not a new key.
///
/// Ack: `POST /api/v1/notices/{id}/ack`, empty body. Flips `read` locally
/// regardless of the response, same optimistic-update shape Android uses —
/// the ack is a courtesy to the server (stops re-fanning-out a push for an
/// already-seen notice on some future push-enabled revision), not something
/// the UI needs to wait on.
///
/// Same primitives-only API constraint as `FeedbackService`/`SelfTestService`
/// in this file's neighbourhood (CLAUDE.md "Hard-won lesson 16" — an
/// `AppState`-typed parameter on a singleton's boot method exhausts the
/// Swift type-checker's Sendable inference and fails the build silently).
@MainActor
public final class NoticeService: ObservableObject {

    public static let shared = NoticeService()

    public typealias TokenProvider = @MainActor () -> String?

    public struct ServiceNotice: Identifiable, Equatable {
        public let id: String
        public let kind: String
        public let priority: String
        public let title: String
        public let body: String
        public let createdMs: Int64
        public let expiresMs: Int64
        public var read: Bool
    }

    @Published public private(set) var notices: [ServiceNotice] = []
    @Published public private(set) var unreadCount: Int = 0

    private var serverUrl: String = ""
    private var getToken: TokenProvider?
    private var pollTask: Task<Void, Never>?

    private init() {}

    // ─── Lifecycle ─────────────────────────────────────────────────

    /// Wire the service. Mirrors `FeedbackService.start` exactly, including
    /// its poll cadence (60 s, 5 s initial delay so launch bandwidth isn't
    /// split three ways with login and WS connect) — Android polls the same
    /// endpoint every 60 s too, gated to foreground via
    /// `onResume`/`onPause`; the Swift Task here gets the same effective
    /// gating for free, since a suspended app simply stops advancing a
    /// sleeping Task's clock rather than needing an explicit scenePhase
    /// hook.
    public func start(serverUrl: String, getToken: @escaping TokenProvider) {
        self.serverUrl = serverUrl
        self.getToken = getToken
        startPollingIfNeeded()
    }

    public func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // ─── Wire types ────────────────────────────────────────────────

    private struct NoticeEnvelope: Codable {
        let id: String
        let kind: String
        let priority: String
        let title: String
        let ephemeral_pub: String
        let ciphertext: String
        let created_ms: Int64
        let expires_ms: Int64
    }

    private struct InboxResponse: Codable {
        let notices: [NoticeEnvelope]?
    }

    // ─── Public API ────────────────────────────────────────────────

    /// Fetch the inbox, drop anything expired, decrypt the rest, and
    /// publish. `read` is carried over from the in-memory list by id so a
    /// re-poll never un-reads a notice the user already opened — the same
    /// thing `NoticeRepository.pollOnce`'s `existing?.read ?: false` does.
    /// Best-effort: any failure (offline, decode error, missing device key)
    /// leaves `notices`/`unreadCount` at their last known value rather than
    /// clearing the inbox.
    public func pollOnce() async {
        guard !serverUrl.isEmpty, let url = URL(string: serverUrl + "/api/v1/notices/inbox") else { return }
        guard let tok = getToken?(), !tok.isEmpty else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              ((resp as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2,
              let decoded = try? JSONDecoder().decode(InboxResponse.self, from: data) else { return }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // uniquingKeysWith rather than uniqueKeysWithValues: a duplicate id
        // must never crash the poll, even though it should not occur.
        let previousById = Dictionary(notices.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })

        let incoming: [ServiceNotice] = (decoded.notices ?? [])
            .filter { $0.expires_ms > now }
            .compactMap { env in
                guard let body = decryptBody(env) else { return nil }
                return ServiceNotice(
                    id: env.id,
                    kind: env.kind,
                    priority: env.priority,
                    title: env.title,
                    body: body,
                    createdMs: env.created_ms,
                    expiresMs: env.expires_ms,
                    read: previousById[env.id]?.read ?? false
                )
            }
        self.notices = incoming
        self.unreadCount = incoming.filter { !$0.read }.count
    }

    /// Mark a notice read, server-side and locally. The local flip happens
    /// regardless of the network result — same optimistic shape as
    /// `FeedbackService.ack` and Android's `NoticeRepository.ack`.
    public func ack(id: String) async {
        if !notices.isEmpty {
            notices = notices.map { $0.id == id ? withRead($0) : $0 }
            unreadCount = notices.filter { !$0.read }.count
        }
        guard !serverUrl.isEmpty, let url = URL(string: serverUrl + "/api/v1/notices/\(id)/ack") else { return }
        guard let tok = getToken?(), !tok.isEmpty else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.data(for: req)
    }

    private func withRead(_ n: ServiceNotice) -> ServiceNotice {
        var copy = n
        copy.read = true
        return copy
    }

    // ─── Decrypt ───────────────────────────────────────────────────

    private static let hkdfSaltInfo = Data("bcrypto-notices-v1".utf8)
    private static let nonceLen = 12
    private static let tagLen = 16

    /// X25519 + HKDF-SHA256 + AES-256-GCM, matching
    /// `internal/notices/encrypt.go`'s `DecryptForDevice` and Android's
    /// `NoticeRepository.decryptEnvelope` parameter-for-parameter. Returns
    /// nil (not throws) on any failure — a malformed or undecryptable
    /// envelope is dropped from the inbox rather than surfacing an error to
    /// the whole poll.
    private func decryptBody(_ env: NoticeEnvelope) -> String? {
        // Built fresh per call rather than cached: cheap (lazy vars, no
        // network at construction) and avoids holding a provider across
        // token refreshes — same shape ChatFileAttachmentReceiver already
        // uses for the identical "read my own device X25519 priv key" need.
        guard let tok = getToken?(), !tok.isEmpty else { return nil }
        let config = BackendConfig.pinned(serverUrl: serverUrl, accessToken: tok)
        let provider = BCryptoBackendProvider(config: config)
        let deviceKeyManager = DeviceKeyManager(vault: SovereignKeyVault(), kmsClient: provider.kmsClient)
        guard let privBytes = try? deviceKeyManager.currentKeys()?.x25519Priv, privBytes.count == 32 else {
            return nil
        }
        guard let ephPubBytes = DeviceRenewBlob.hexDecode(env.ephemeral_pub),
              let wire = Data(base64Encoded: env.ciphertext),
              wire.count > Self.nonceLen + Self.tagLen else {
            return nil
        }

        guard let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privBytes),
              let ephPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephPubBytes),
              let shared = try? priv.sharedSecretFromKeyAgreement(with: ephPub) else {
            return nil
        }
        let sharedRaw = shared.withUnsafeBytes { Data($0) }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedRaw),
            salt: Self.hkdfSaltInfo,
            info: Self.hkdfSaltInfo,
            outputByteCount: 32
        )

        let nonceBytes = wire.prefix(Self.nonceLen)
        let ctAndTag = wire.suffix(from: Self.nonceLen)
        let ct = ctAndTag.prefix(ctAndTag.count - Self.tagLen)
        let tag = ctAndTag.suffix(Self.tagLen)

        guard let nonce = try? AES.GCM.Nonce(data: nonceBytes),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag),
              let plaintext = try? AES.GCM.open(box, using: key) else {
            return nil
        }
        return String(decoding: plaintext, as: UTF8.self)
    }
}
