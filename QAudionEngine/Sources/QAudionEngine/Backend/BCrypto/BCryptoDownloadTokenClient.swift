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
        let data = try await rest.post("/api/v1/files/issue-token", body: body)
        return try IssuedDownloadToken.decode(data)
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
        try await rest.get(
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
