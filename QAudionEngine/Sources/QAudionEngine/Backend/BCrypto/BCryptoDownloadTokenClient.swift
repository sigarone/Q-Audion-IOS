import Foundation

/// Client for the Wave 3-4 recipient capability-token flow.
///
/// Companion to bcrypto-server commit `576512d` (`download_token.go`)
/// and WIRE_SPEC §3.6.4 + §5.1.4. Two roles:
///
/// 1. **Sender** (`issueToken`): owner of a tus.io upload mints a
///    capability for a peer recipient by calling
///    `POST /api/v1/files/issue-token`. The token, expiry, and max_uses
///    are then bundled into the ``AttachAnnounceEnvelope`` shipped over
///    the 1:1 ratchet.
///
/// 2. **Recipient** (`downloadHeaders`): peer receives the envelope,
///    extracts the four fields, and applies them as the
///    `X-Download-Token` / `X-Download-Expires-Ms` / `X-Download-Max-Uses`
///    headers on `GET /api/v1/files/{id}`. Server reconstructs the HMAC
///    binding the JWT-authenticated bearer's UUID as `recipient_user_id`
///    (mitigation HIGH per NVIDIA review: a leaked envelope cannot be
///    redeemed by any other account).
public final class BCryptoDownloadTokenClient {

    private let rest: BCryptoRestClient

    public init(rest: BCryptoRestClient) {
        self.rest = rest
    }

    // MARK: - Sender side

    /// Mint a capability token for `recipientUserId` over `fileId`.
    ///
    /// Server enforces `claims.UserID == record.OwnerUserID`; if the
    /// caller is not the owner of the file the request returns 403.
    ///
    /// - Parameters:
    ///   - fileId: server-issued upload id from `POST /files/tus`.
    ///   - recipientUserId: peer UUID that the recipient will present in
    ///     their JWT when downloading. The HMAC binds this to the token,
    ///     so a leaked token can't be redeemed by any other user.
    ///   - ttlSeconds: token lifetime; default `nil` → server uses 7 days.
    ///   - maxUses: how many times the recipient can call GET /files/{id}
    ///     against this token. Default `nil` → server uses 10 (multi-
    ///     device headroom).
    public func issueToken(
        fileId: String,
        recipientUserId: String,
        ttlSeconds: Int? = nil,
        maxUses: Int? = nil
    ) async throws -> IssuedDownloadToken {
        var dict: [String: Any] = [
            "file_id": fileId,
            "recipient_user_id": recipientUserId,
        ]
        if let ttl = ttlSeconds { dict["ttl_seconds"] = ttl }
        if let m = maxUses { dict["max_uses"] = m }
        let body = try JSONSerialization.data(withJSONObject: dict)
        // Item G (2026-09-30 file-transfer plan) — issue-token exists only
        // on the node that stores `fileId`'s tus record. `rest.post` would
        // ride whatever `config.serverUrl` the node selector currently has
        // (a DR/failover host has no shared file storage and would 404/402
        // here even if the file upload itself somehow reached it), so this
        // pins the request to the certificate-pinned primary instead —
        // see `BCryptoRestClient.postToPrimary`'s own doc.
        let data = try await rest.postToPrimary("/api/v1/files/issue-token", body: body)
        return try IssuedDownloadToken.decode(data)
    }

    // MARK: - Item A-iOS (2026-09-30 file-transfer plan, phase 1a): max_uses sizing

    /// Retry attempts `BCryptoRestClient.getFileEndpoint` spends on ONE
    /// download GET before giving up. Kept as a literal (not shared via
    /// import) rather than referencing that default directly, mirroring
    /// Android's own `TusUploaderHttpImpl.computeMaxUses`, which keeps its
    /// mirrored chunk-size constant as a literal for the same reason: a
    /// stale value here only makes `max_uses` MORE generous, never
    /// under-provisioned.
    static let maxDownloadAttemptsPerFile: Int64 = 4

    /// One extra whole-file-download restart of headroom per this many
    /// 64 KiB chunks (`ChatFileAttachmentSender.defaultChunkSize`): a
    /// bigger file spends longer on the wire and is proportionally more
    /// likely to need a fresh whole-file GET beyond `getFileEndpoint`'s
    /// own in-call retry loop above — the app gets backgrounded and killed
    /// mid-download, the recipient taps "retry" on a failed chat bubble,
    /// or a second signed-in device opens the same attachment later. iOS
    /// has no chunk-level download RESUME yet (that's item E, phase 1b),
    /// so every one of those restarts re-spends the full attempt budget
    /// above, not just one more use. 64 chunks = 4 MiB.
    static let chunksPerExtraRestart: Int64 = 64

    /// Floor — matches the server's own `max_uses = 10` default intent for
    /// a small file needing its one download plus a couple of re-opens.
    static let minDownloadTokenMaxUses: Int32 = 10

    /// Ceiling — a safety backstop against a pathological/corrupted
    /// `totalChunks`, not a value normal traffic is expected to reach: the
    /// largest file this pipeline accepts (5 GiB — `ChatFileAttachmentReceiver`'s
    /// own DoS guard) is 81 920 chunks, giving `desired` = 5 124 by this
    /// formula — comfortably under this cap.
    static let maxDownloadTokenMaxUses: Int32 = 6_000

    /// Size a file-attachment download token's `max_uses` from the
    /// ciphertext's chunk count, instead of leaving it unset (server
    /// default of 10 — fine for one small file, wrong once a transfer
    /// needs retry/multi-device headroom). Mirrors Android's own
    /// `computeMaxUses` (`TusUploaderHttpImpl.kt`) rationale — size off
    /// the transfer, don't rely on the server's flat default — but NOT
    /// its exact per-chunk-ranged-read formula: iOS downloads the whole
    /// ciphertext blob in a SINGLE GET per attempt today
    /// (`ChatFileAttachmentReceiver.receive`), not two ranged reads per
    /// 64 KiB chunk like Android's streamed receiver, so the cost that
    /// actually scales here is repeated WHOLE-file restarts, not
    /// per-chunk reads. Returns `nil` (server default) when
    /// `totalChunks` is non-positive, matching Android leaving
    /// `max_uses` unset when the size is unknown.
    ///
    /// **Visible for tests** so the sizing is pinned by KAT — same
    /// convention as Android's own `computeMaxUses`.
    public static func computeMaxUses(totalChunks: Int) -> Int32? {
        guard totalChunks > 0 else { return nil }
        let extraRestarts = Int64(totalChunks) / chunksPerExtraRestart
        let restarts = 1 + extraRestarts
        let desired = restarts * maxDownloadAttemptsPerFile
        let capped = min(max(desired, Int64(minDownloadTokenMaxUses)), Int64(maxDownloadTokenMaxUses))
        return Int32(capped)
    }

    // MARK: - Recipient side

    /// Build the three required headers for `GET /api/v1/files/{id}`
    /// when the bearer is NOT the owner of the file (recipient flow).
    /// Caller passes these to ``BCryptoRestClient/get(_:headers:)``.
    public func downloadHeaders(claim: DownloadTokenClaim) -> [String: String] {
        return [
            "X-Download-Token": claim.tokenHex,
            "X-Download-Expires-Ms": String(claim.expiresAtMs),
            "X-Download-Max-Uses": String(claim.maxUses),
        ]
    }

    /// Convenience download. Performs the GET with the right headers
    /// and returns the (still-encrypted) blob bytes — caller is
    /// responsible for running the AEAD via the per-attachment key
    /// derived per WIRE_SPEC §5.1.3.
    ///
    /// 2026-07-30 fix (W-AVATAR404): this used to hit
    /// `/api/v1/files/{fileId}` — the LEGACY, uploader-only blob route
    /// (`cmd/bcrypto-lite/main.go handleFileDownload`), which is a
    /// completely separate storage record from a tus.io upload and
    /// ignores the `X-Download-*` headers entirely. Every call here goes
    /// through `TusUploadClient`, so the record only ever exists at
    /// `/api/v1/files/tus/{fileId}` (`TusHandler.HandleDownload`, the
    /// handler that actually validates the capability token). The old path
    /// 404'd unconditionally — even for the OWNER, since the legacy
    /// handler's `db.GetFileMeta` never finds a tus-created record.
    public func downloadCiphertext(
        fileId: String,
        claim: DownloadTokenClaim
    ) async throws -> Data {
        // Item A-iOS + G (2026-09-30 file-transfer plan) — `getFileEndpoint`
        // pins this GET to the primary node that actually stores `fileId`
        // (never a DR/failover host `config.serverUrl` might currently
        // point at) and retries a transient 429/5xx with backoff,
        // honouring the server's `Retry-After` — this used to be a single
        // request with no retry and no resume (the full streaming/ranged
        // rewrite is item E, phase 1b).
        try await rest.getFileEndpoint(
            "/api/v1/files/tus/\(fileId)",
            headers: downloadHeaders(claim: claim)
        )
    }
}

// MARK: - Wire types

/// Returned by `POST /api/v1/files/issue-token`. Symmetric with the
/// Go server's `storage.IssuedDownloadToken`.
public struct IssuedDownloadToken: Equatable {
    public let fileId: String
    public let recipientUserId: String
    public let expiresAtMs: Int64
    public let maxUses: Int32
    public let tokenHex: String

    public init(fileId: String, recipientUserId: String,
                expiresAtMs: Int64, maxUses: Int32, tokenHex: String) {
        self.fileId = fileId
        self.recipientUserId = recipientUserId
        self.expiresAtMs = expiresAtMs
        self.maxUses = maxUses
        self.tokenHex = tokenHex
    }

    /// Build the smaller ``DownloadTokenClaim`` carried by the envelope
    /// to the recipient (drops `recipient_user_id` because the recipient
    /// is the JWT bearer and the server re-derives it).
    public var claim: DownloadTokenClaim {
        DownloadTokenClaim(
            fileId: fileId,
            expiresAtMs: expiresAtMs,
            maxUses: maxUses,
            tokenHex: tokenHex
        )
    }

    public enum Error: Swift.Error, LocalizedError {
        case missingField(String)
        case invalidValue(String)
        public var errorDescription: String? {
            switch self {
            case .missingField(let k): return "missing \(k)"
            case .invalidValue(let k): return "invalid \(k)"
            }
        }
    }

    static func decode(_ data: Data) throws -> IssuedDownloadToken {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidValue("response not a JSON object")
        }
        guard let fileId = dict["file_id"] as? String, !fileId.isEmpty else {
            throw Error.missingField("file_id")
        }
        guard let recipientUserId = dict["recipient_user_id"] as? String, !recipientUserId.isEmpty else {
            throw Error.missingField("recipient_user_id")
        }
        guard let expires = dict["expires_at_ms"] as? Int64 ??
                            (dict["expires_at_ms"] as? NSNumber)?.int64Value else {
            throw Error.missingField("expires_at_ms")
        }
        let maxUsesAny = dict["max_uses"]
        guard let maxUses32 = (maxUsesAny as? Int32) ??
                              (maxUsesAny as? NSNumber)?.int32Value else {
            throw Error.missingField("max_uses")
        }
        guard let tokenHex = dict["token_hex"] as? String, !tokenHex.isEmpty else {
            throw Error.missingField("token_hex")
        }
        return IssuedDownloadToken(
            fileId: fileId, recipientUserId: recipientUserId,
            expiresAtMs: expires, maxUses: maxUses32, tokenHex: tokenHex
        )
    }
}

/// Trimmed claim payload that the SENDER bundles into the
/// ``AttachAnnounceEnvelope.AttachAnnounceMeta`` (extension TBD in a
/// future spec bump). The recipient redeems via the three headers in
/// ``BCryptoDownloadTokenClient/downloadHeaders(claim:)``.
///
/// Codable so it can ride inside the iOS-internal ``FileTransfer.FileMarker``
/// for voice-note delivery (W79 — iPhone↔iPhone send pipeline). Snake-case
/// JSON keys keep the wire interchangeable with the server-issued shape.
public struct DownloadTokenClaim: Equatable, Codable {
    public let fileId: String
    public let expiresAtMs: Int64
    public let maxUses: Int32
    public let tokenHex: String

    public init(fileId: String, expiresAtMs: Int64, maxUses: Int32, tokenHex: String) {
        self.fileId = fileId
        self.expiresAtMs = expiresAtMs
        self.maxUses = maxUses
        self.tokenHex = tokenHex
    }

    private enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case expiresAtMs = "expires_at_ms"
        case maxUses = "max_uses"
        case tokenHex = "token_hex"
    }
}
