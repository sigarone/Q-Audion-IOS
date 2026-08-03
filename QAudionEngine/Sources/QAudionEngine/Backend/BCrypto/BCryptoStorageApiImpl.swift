import Foundation

public final class BCryptoStorageApiImpl: StorageApi {
    private let rest: BCryptoRestClient
    init(rest: BCryptoRestClient) { self.rest = rest }

    // MARK: - Backup (matches server /api/v1/backup/*)

    public func uploadBackup(data: Data, key: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["key": key, "data": data.base64EncodedString()])
        let response = try await rest.post("/api/v1/backup/upload", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let id = json["id"] as? String else { throw BCryptoError.decodingError }
        return id
    }

    public func downloadBackup(key: String) async throws -> Data {
        let data = try await rest.get("/api/v1/backup/download/\(key)")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = json["data"] as? String, let decoded = Data(base64Encoded: b64) else { throw BCryptoError.decodingError }
        return decoded
    }

    public func deleteBackup(key: String) async throws {
        _ = try await rest.delete("/api/v1/backup/\(key)")
    }

    public func listBackups() async throws -> [String] {
        let data = try await rest.get("/api/v1/backup/list")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keys = json["keys"] as? [String] else { throw BCryptoError.decodingError }
        return keys
    }

    // MARK: - File Upload/Download (matches server /api/v1/files/*)

    public func uploadFile(data: Data, filename: String) async throws -> String {
        try await uploadFile(data: data, filename: filename, onProgress: nil)
    }

    /// W446 — same upload pipeline as ``uploadFile(data:filename:)`` with an
    /// optional progress callback for the TUS (chunked) path. Not part of
    /// the `StorageApi` protocol (mirrors the pattern already used by
    /// ``AvatarUploader`` for calling this impl directly) — callers that
    /// want progress reporting go through `BCryptoStorageApiImpl` /
    /// `BCryptoBackendProvider.storageApi` cast, not the protocol type.
    ///
    /// - Parameter onProgress: forwarded verbatim to
    ///   ``TusUploadClient/upload(data:onProgress:onCreated:)`` for
    ///   files that take the >1 MB chunked path. Never called for the
    ///   small-file multipart fast-path (single atomic POST — no
    ///   intermediate progress to report). Purely local UI state; not
    ///   part of any wire schema.
    public func uploadFile(
        data: Data,
        filename: String,
        onProgress: ((Int64, Int64) -> Void)?
    ) async throws -> String {
        try await uploadFile(data: data, filename: filename, onProgress: onProgress, resumeContext: nil)
    }

    /// W-TUSRESUME — same as ``uploadFile(data:filename:onProgress:)`` with
    /// an optional resume-breadcrumb context. `resumeContext.
    /// onFileIdMinted` is wired to `TusUploadClient.upload(onCreated:)` —
    /// fired right after `create()` succeeds, before the chunk loop starts
    /// — so the caller (ultimately `FileTransfer.upload`, see
    /// `onResumeStateReady` there) can persist a `TusResumeState` for a
    /// future cross-launch resume instead of re-uploading from byte zero.
    ///
    /// W-STORAGESPLIT (2026-08-03): this used to branch on a 1 MB
    /// threshold — payloads at or under it went to the LEGACY multipart
    /// endpoint `POST /api/v1/files/upload`, which writes only into the
    /// server's separate legacy `bucketFiles`/`FileMeta` record (`main.go
    /// handleFileUpload` → `StoreFileMetaTagged`). Every 1:1 attachment/
    /// voice-note/photo send calls `issueToken` immediately after upload
    /// (`ChatVoiceNoteSender`, `ChatAttachAnnounceSender`,
    /// `GroupAttachmentSender`), and the server's issue-token handler
    /// (`files_tus.go HandleIssueToken` → `loadRecord`) reads ONLY the
    /// tus.io record store — a completely disjoint bucket the legacy
    /// endpoint never writes to. So any payload at or under 1 MB — which
    /// is virtually every voice note (5-minute cap, typical AAC bitrate)
    /// and most photos — 404'd on `issueToken` deterministically, every
    /// time. That is the confirmed root cause of "invio sempre fallito":
    /// not intermittent, not content-type-specific, a hard split between
    /// two storage systems that never reconcile.
    ///
    /// Always routing through `TusUploadClient` closes the gap outright
    /// rather than teaching the legacy endpoint about capability tokens
    /// (which would mean maintaining two parallel storage/auth models
    /// forever): tus already has no minimum-size requirement — `create()`
    /// takes whatever `data.count` is — and is already the mandatory path
    /// for avatars (`AvatarAnnounceSender`, migrated 2026-07-30 for the
    /// identical class of bug, W-AVATAR404) and every attachment sender.
    /// Matches Android exactly: `FileAttachmentSender.kt` has no size
    /// threshold at all and always uses `TusUploader`.
    public func uploadFile(
        data: Data,
        filename: String,
        onProgress: ((Int64, Int64) -> Void)?,
        resumeContext: (clientMsgId: String, sourceBytes: Data, onFileIdMinted: (String) -> Void)?
    ) async throws -> String {
        let capturedRest = rest
        let tusClient = TusUploadClient(
            session: capturedRest.urlSession,
            serverUrl: capturedRest.serverUrl,
            getToken: { capturedRest.accessToken }
        )
        return try await tusClient.upload(
            data: data,
            onProgress: onProgress,
            onCreated: resumeContext?.onFileIdMinted
        )
    }

    /// W-STORAGESPLIT (2026-08-03): mirrors the upload-side fix — was
    /// `GET /api/v1/files/{fileId}`, the LEGACY owner-only route
    /// (`main.go handleFileDownload`), which 404s for anyone who isn't
    /// the uploader and has no concept of a recipient capability token at
    /// all. A recipient downloading a peer's attachment is never the
    /// uploader, so this 404'd unconditionally for every cross-user
    /// receive that reached it. Routes through the tus recipient-token
    /// endpoint instead, matching every other cross-user download path in
    /// this codebase (`AvatarAnnounceReceiver`, `ChatVoiceNoteReceiver`).
    ///
    /// `StorageApi.downloadFile(fileId:)` (the protocol requirement this
    /// satisfies) has no token parameter, so this overload only serves
    /// SELF-owned downloads (log export, own-backup-adjacent reads) where
    /// no recipient token exists or is needed — a genuine cross-user
    /// attachment/voice-note download goes through
    /// `downloadTokenClient.downloadCiphertext(fileId:claim:)` directly,
    /// never through this method.
    public func downloadFile(fileId: String) async throws -> Data {
        return try await rest.get("/api/v1/files/tus/\(fileId)")
    }

    /// W-TUSRESUME — expose the TUS resume primitives (`head`/`resume`)
    /// for `ChatContainer.retryFailedMessage()`'s tier-1 resume attempt.
    /// Not part of `StorageApi` (same rationale as the progress-reporting
    /// overloads above) — the caller already casts to this concrete type
    /// to reach `uploadFile(...:resumeContext:)`, so exposing a
    /// ready-to-use `TusUploadClient` here avoids duplicating its
    /// construction (session/serverUrl/getToken wiring) at the call site.
    public func makeTusClient() -> TusUploadClient {
        let capturedRest = rest
        return TusUploadClient(
            session: capturedRest.urlSession,
            serverUrl: capturedRest.serverUrl,
            getToken: { capturedRest.accessToken }
        )
    }

    // MARK: - Client Config

    /// Fetch server-side client configuration.
    /// GET /api/v1/config/client
    public func getClientConfig() async throws -> [String: Any] {
        let data = try await rest.get("/api/v1/config/client")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BCryptoError.decodingError
        }
        return json
    }

    // MARK: - Helpers

    private func createMultipartBody(boundary: String, fieldName: String, fileName: String, data: Data) -> Data {
        // Data(_:) over .utf8 rather than .data(using: .utf8)! — same
        // reasoning as BCryptoRestClient.postMultipart: UTF-8 can encode
        // any valid Swift String regardless of interpolated content, so
        // this can never actually fail.
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
