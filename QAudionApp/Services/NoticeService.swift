import Foundation
import CryptoKit
import QAudionEngine

/// Poll-only client for the server's service-notice channel ("Messaggi di
/// servizio").
///
/// The server side of this channel is already live and the Android client
/// already reads it with the same endpoint and the same decrypt on every
/// launch. iOS simply never had a reader. This is a port of that reader, not
/// a new subsystem.
///
/// Endpoint: `GET /api/v1/notices/inbox` (bearer token) →
/// `{"v":1,"notices":[NoticeEnvelope]}`. Each envelope carries a plaintext
/// `title` and an X25519-ECIES-sealed `body`:
///   1. ECDH: sharedSecret = myDeviceX25519Priv.ECDH(envelope.ephemeralPub)
///   2. HKDF-SHA256(sharedSecret, salt="bcrypto-notices-v1",
///      info="bcrypto-notices-v1", L=32) → AES key
///   3. AES-256-GCM open, no AAD. Wire ciphertext = nonce(12) || ct || tag(16).
/// The device key is the SAME long-term X25519 identity key this app already
/// registers via `DeviceKeyManager` and already uses in
/// `ChatFileAttachmentReceiver`, not a new key.
///
/// Ack: `POST /api/v1/notices/{id}/ack`, empty body. Flips `read` locally
/// regardless of the response (optimistic, like `FeedbackService.ack`): the
/// ack is a courtesy to the server, not something the UI needs to wait on.
///
/// Network: every request goes through `PinnedURLSession.auxiliary` (the
/// certificate-pinned session, W-AUXPIN) and the 60 s poll honours the
/// server's `Retry-After` through `UploadPause` (W-RETRYAFTER), exactly as
/// `FeedbackService` does. A user-initiated `ack` is never blocked by the
/// pause, but its answer still feeds it.
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

    /// W-RETRYAFTER — while the server has asked this service to wait
    /// (429/503 `Retry-After`, or any other kept failure) the 60 s poll stays
    /// quiet instead of knocking on the per-IP bucket every minute.
    private var pause = UploadPause()

    /// Bumped by `resetForAccountChange()`. A poll remembers the value it
    /// started under and publishes only if it is unchanged: a request already
    /// in flight when the account leaves must not put the old account's
    /// notices back after the reset.
    private var generation: Int = 0

    /// Internal rather than private only so tests can build their own
    /// instance; the app uses `shared`.
    init() {}

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

    /// Internal, not private, so `assemble` can be exercised by tests.
    struct NoticeEnvelope: Codable {
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
    /// thing Android's `existing?.read ?: false` does.
    /// Best-effort: any failure (offline, decode error, missing device key)
    /// leaves `notices`/`unreadCount` at their last known value rather than
    /// clearing the inbox.
    public func pollOnce() async {
        if pause.isPaused(now: ProcessInfo.processInfo.systemUptime) { return }
        guard !serverUrl.isEmpty, let url = URL(string: serverUrl + "/api/v1/notices/inbox") else { return }
        guard let tok = getToken?(), !tok.isEmpty else { return }
        let startedUnder = generation

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")

        // W-AUXPIN: pinned session, not URLSession.shared — this carries a
        // bearer token.
        guard let (data, resp) = try? await PinnedURLSession.auxiliary(for: serverUrl).data(for: req) else { return }
        noteResponse(resp)
        guard ((resp as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2,
              let decoded = try? JSONDecoder().decode(InboxResponse.self, from: data) else { return }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let incoming = Self.assemble(
            envelopes: decoded.notices ?? [],
            nowMs: now,
            previous: notices,
            decrypt: decryptBody
        )
        publish(incoming, startedUnder: startedUnder)
    }

    /// The pure core of a poll: what the inbox shows, given what the server
    /// sent and what was already shown.
    ///   - an envelope whose `expires_ms` is not strictly after `nowMs` is
    ///     dropped, so a notice stops appearing the moment it expires;
    ///   - an envelope `decrypt` cannot open is dropped on its own, without
    ///     failing the rest;
    ///   - `read` is carried over by id from `previous`, so a re-poll never
    ///     un-reads a notice the user already opened; a new id starts unread.
    /// Order is the server's.
    static func assemble(
        envelopes: [NoticeEnvelope],
        nowMs: Int64,
        previous: [ServiceNotice],
        decrypt: (NoticeEnvelope) -> String?
    ) -> [ServiceNotice] {
        // uniquingKeysWith rather than uniqueKeysWithValues: a duplicate id
        // must never crash the poll, even though it should not occur.
        let previousById = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        return envelopes
            .filter { $0.expires_ms > nowMs }
            .compactMap { env in
                guard let body = decrypt(env) else { return nil }
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
    }

    /// Replaces the shown list and the unread count together. Does nothing
    /// when the account changed since `startedUnder` was read (see
    /// `generation`). Internal so tests can drive it without a network.
    func publish(_ incoming: [ServiceNotice], startedUnder: Int) {
        guard startedUnder == generation else { return }
        notices = incoming
        unreadCount = incoming.filter { !$0.read }.count
    }

    /// The value a poll reads when it starts and hands back to `publish`.
    /// Internal for the same reason.
    var currentGeneration: Int { generation }

    /// Empties the inbox. Called when the account leaves (logout, remote
    /// wipe, account deletion — `AppState.resetAccountScopedRuntimeState`):
    /// this is a singleton, so without it the next account to sign in on the
    /// device would see the previous one's notices and unread dot until its
    /// own first poll replaced them, and an old poll still in flight could
    /// put them back afterwards. Polling itself keeps running; with no token
    /// it does nothing until the next sign-in.
    func resetForAccountChange() {
        generation += 1
        notices = []
        unreadCount = 0
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
        if let (_, resp) = try? await PinnedURLSession.auxiliary(for: serverUrl).data(for: req) {
            noteResponse(resp)
        }
    }

    private func withRead(_ n: ServiceNotice) -> ServiceNotice {
        var copy = n
        copy.read = true
        return copy
    }

    /// Success clears the pause; a failure that keeps its payload (see
    /// `UploadRetryPolicy`) extends it from the server's `Retry-After`.
    /// Mirrors `FeedbackService.noteResponse`. Only a real HTTP answer feeds
    /// it: a transport error leaves the pause as it was.
    private func noteResponse(_ resp: URLResponse) {
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        switch UploadRetryPolicy.verdict(status: status) {
        case .success:
            pause.recordSuccess()
        case .reject:
            break
        case .keep:
            let delay = pause.recordFailure(status: status,
                                            retryAfterHeader: http?.value(forHTTPHeaderField: "Retry-After"),
                                            now: ProcessInfo.processInfo.systemUptime,
                                            wallClock: Date(),
                                            jitterUnit: Double.random(in: 0...1))
            RTLog.warn("notice", "requests paused status=" + String(status)
                       + " pause=" + String(Int(delay.rounded())))
        }
    }

    // ─── Decrypt ───────────────────────────────────────────────────

    private static let hkdfSaltInfo = Data("bcrypto-notices-v1".utf8)
    private static let nonceLen = 12
    private static let tagLen = 16

    /// X25519 + HKDF-SHA256 + AES-256-GCM, matching the server's envelope
    /// sealing and Android's `NoticeRepository.decryptEnvelope`
    /// parameter-for-parameter. Returns nil (not throws) on any failure — a
    /// malformed or undecryptable envelope is dropped from the inbox rather
    /// than surfacing an error to the whole poll.
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
