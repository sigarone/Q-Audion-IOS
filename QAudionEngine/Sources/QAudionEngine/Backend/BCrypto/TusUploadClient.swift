import Foundation

/// W443 — tus.io v1.0.0 resumable upload client for bcrypto-server.
///
/// Protocol overview (subset implemented here):
///   POST  {serverUrl}/api/v1/files/tus
///     Headers: Tus-Resumable: 1.0.0, Upload-Length: <totalBytes>
///     Response: 201 Created, Location: /api/v1/files/tus/{fileId}
///
///   HEAD  {serverUrl}/api/v1/files/tus/{fileId}
///     Headers: Tus-Resumable: 1.0.0
///     Response: 200 + Upload-Offset / Upload-Length headers, owner-only.
///     404 if the record was never created or has been purged (see
///     W-TUSRESUME below — the server retains an abandoned/incomplete
///     upload for 24h then deletes it).
///
///   PATCH {serverUrl}/api/v1/files/tus/{fileId}
///     Headers: Tus-Resumable: 1.0.0, Upload-Offset: <offset>,
///              Content-Type: application/offset+octet-stream
///     Body: raw bytes slice (≤ chunkSize)
///     Response: 204 No Content + Upload-Offset: <newOffset>
///
/// Design choices (mirrored from Android `TusUploaderHttpImpl`):
///   - The caller owns the URLSession (same TLS config as the rest client).
///   - `getToken` is a closure so the client always reads the freshest
///     access token without holding a reference to AppState.
///
/// **W-TUSRESUME — cross-launch resume (2026-07-02).** Previously, any
/// chunk PATCH failure meant recreating the upload from byte zero — HEAD-
/// based resume was explicitly out of scope. That's no longer true: the
/// server's `storage.RetentionWorker` keeps an abandoned/incomplete
/// upload resumable for 24h (then purges it), and `resume(fileId:...)`
/// below uses `HEAD /files/tus/{id}` to pick up an interrupted upload —
/// e.g. after the OS fully kills the app mid-transfer (not just
/// backgrounds it — see `BackgroundUploadTask` for the in-process grace
/// period that covers the backgrounding case). Product decision (verbatim,
/// translated): "keep an abandoned upload pending server-side for max 24h;
/// on retry, if the file isn't corrupted, try to resume; if a specific
/// part failed, retry just that part; as a last resort, restart from
/// scratch." That's the 3-tier retry implemented here + in
/// `ChatContainer.retryFailedMessage()`:
///   - Tier 1 (resume): `resume(fileId:data:fromOffset:)`, offset from
///     `head(fileId:)`.
///   - Tier 2 (retransmit what's wrong): bounded per-chunk retry inside
///     `runChunkLoop`, shared by both `upload()` and `resume()`.
///   - Tier 3 (restart from scratch): today's `upload()` — unchanged
///     behavior, kept as the guaranteed-to-work fallback when tier 1/2
///     don't apply or exhaust.
public final class TusUploadClient {

    // MARK: - Error

    public enum TusError: Error, LocalizedError {
        case createFailed(Int)
        case missingLocation
        case badFileId(String)
        case patchFailed(Int)
        case headFailed(Int)
        /// W-TUSRESUME: HEAD returned 404 — the fileId no longer exists
        /// server-side (most likely purged by the 24h abandoned-upload
        /// retention window, or the record never existed). This is the
        /// specific signal tier-1/tier-2 callers use to fall through to
        /// tier 3 (fresh upload) rather than a generic failure — see
        /// `ChatContainer.retryFailedMessage()`.
        case uploadNotFound(fileId: String)

        public var errorDescription: String? {
            switch self {
            case .createFailed(let code):
                return "TUS create failed: HTTP " + String(describing: code)
            case .missingLocation:
                return "TUS create: missing Location header"
            case .badFileId(let loc):
                return "TUS create: cannot parse fileId from: " + loc
            case .patchFailed(let code):
                return "TUS patch failed: HTTP " + String(describing: code)
            case .headFailed(let code):
                return "TUS head failed: HTTP " + String(describing: code)
            case .uploadNotFound(let fileId):
                return "TUS upload not found (purged or never existed): " + fileId
            }
        }
    }

    // MARK: - State

    private let session: URLSession
    private let serverUrl: String
    private let getToken: () -> String?
    let chunkSize: Int

    static let defaultChunkSize = 512 * 1024   // 512 KB

    /// W-TUSRESUME: bounded per-chunk retry — tier 2 of the 3-tier retry
    /// design. A transient failure on ONE chunk (network blip, transient
    /// 5xx, a 409 offset-mismatch from a race) retries just that chunk
    /// before giving up on the whole fileId.
    static let maxChunkAttempts = 3
    /// Escalating backoff between chunk attempts: 500ms, 1s, 2s (indices
    /// 0, 1, 2 — only the first `maxChunkAttempts - 1` gaps are ever used
    /// since there's no sleep after the final attempt).
    private static let chunkRetryBackoffNanos: [UInt64] = [
        500_000_000, 1_000_000_000, 2_000_000_000
    ]

    // MARK: - Init

    init(
        session: URLSession,
        serverUrl: String,
        getToken: @escaping () -> String?,
        chunkSize: Int = TusUploadClient.defaultChunkSize
    ) {
        self.session = session
        self.serverUrl = serverUrl
        self.getToken = getToken
        self.chunkSize = chunkSize
    }

    // MARK: - Public API

    /// Full pipeline: POST create + PATCH all chunks. Returns the fileId
    /// the server assigned to this upload (same UUID used by download
    /// and attach_announce envelope).
    ///
    /// - Parameter onProgress: optional callback invoked on the calling
    ///   task after each chunk PATCH completes, with
    ///   `(bytesUploaded, totalBytes)`. Purely local UI feedback — never
    ///   serialized, never sent over the wire. Defaults to `nil` so
    ///   existing callers keep compiling unchanged.
    /// - Parameter onCreated: W-TUSRESUME — optional callback invoked
    ///   exactly once, right after `create()` succeeds (before the chunk
    ///   loop starts), with the newly-minted `fileId`. This is the hook
    ///   `FileTransfer.upload()` uses to persist a `TusResumeState`
    ///   breadcrumb — deliberately a bare `(String) -> Void` rather than
    ///   this client reaching into `TusResumeStateStore` directly, so
    ///   `TusUploadClient` stays a pure ciphertext/HTTP transport with no
    ///   knowledge of chat-layer concepts (`clientMsgId`, salt/nonce,
    ///   recipientId — all `FileTransfer`/crypto-layer state). `nil` by
    ///   default so existing callers (avatar upload, backup, etc.) keep
    ///   compiling and behaving unchanged; no breadcrumb is written for
    ///   those uploads.
    public func upload(
        data: Data,
        onProgress: ((Int64, Int64) -> Void)? = nil,
        onCreated: ((String) -> Void)? = nil
    ) async throws -> String {
        let fileId = try await create(totalBytes: data.count)
        onCreated?(fileId)
        let total = Int64(data.count)
        try await runChunkLoop(fileId: fileId, data: data, startOffset: 0, total: total, onProgress: onProgress)
        return fileId
    }

    /// W-TUSRESUME — tier 1 of the 3-tier retry: continue an existing
    /// upload from a confirmed server-side offset instead of re-sending
    /// bytes the server already has. Skips `create()` entirely — the
    /// caller already has `fileId` (from a persisted `TusResumeState`)
    /// and `fromOffset` (from a preceding `head(fileId:)` call).
    ///
    /// `data` must be the FULL ciphertext for this upload (same bytes
    /// `upload()` would have PATCHed from byte 0); only the slice at/after
    /// `fromOffset` is actually sent — both the byte offset into `data`
    /// AND the initial `Upload-Offset` header value start there.
    ///
    /// Shares the exact same bounded-retry chunk loop as `upload()` (see
    /// `runChunkLoop`) — a chunk failure here follows the identical
    /// tier-2 retransmit-then-give-up behavior.
    public func resume(
        fileId: String,
        data: Data,
        fromOffset: Int64,
        onProgress: ((Int64, Int64) -> Void)? = nil
    ) async throws -> String {
        let total = Int64(data.count)
        try await runChunkLoop(fileId: fileId, data: data, startOffset: fromOffset, total: total, onProgress: onProgress)
        return fileId
    }

    /// W-TUSRESUME — `HEAD /files/tus/{fileId}`. Returns the server's
    /// confirmed `(offset, totalLength)` for an existing upload. Throws
    /// `.uploadNotFound(fileId:)` on 404 (the specific, expected-to-happen
    /// signal for "purged by the 24h retention window, or never existed")
    /// so callers can distinguish it from a genuine transient failure and
    /// fall through to tier 3 (fresh upload) instead of surfacing a
    /// generic error.
    public func head(fileId: String) async throws -> (offset: Int64, totalLength: Int64) {
        let base = serverUrl.hasSuffix("/") ? serverUrl : serverUrl + "/"
        let urlStr = base + "api/v1/files/tus/" + fileId
        guard let url = URL(string: urlStr) else {
            throw TusError.headFailed(0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        if let tok = getToken() {
            req.setValue("Bearer " + tok, forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TusError.headFailed(0)
        }
        if http.statusCode == 404 {
            throw TusError.uploadNotFound(fileId: fileId)
        }
        guard http.statusCode == 200 else {
            throw TusError.headFailed(http.statusCode)
        }
        guard let offsetStr = http.value(forHTTPHeaderField: "Upload-Offset"),
              let offset = Int64(offsetStr),
              let lengthStr = http.value(forHTTPHeaderField: "Upload-Length"),
              let length = Int64(lengthStr) else {
            throw TusError.headFailed(http.statusCode)
        }
        return (offset, length)
    }

    // MARK: - Private steps

    private func create(totalBytes: Int) async throws -> String {
        let base = serverUrl.hasSuffix("/") ? serverUrl : serverUrl + "/"
        let urlStr = base + "api/v1/files/tus"
        guard let url = URL(string: urlStr) else {
            throw TusError.createFailed(0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        req.setValue(String(describing: totalBytes), forHTTPHeaderField: "Upload-Length")
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        if let tok = getToken() {
            req.setValue("Bearer " + tok, forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TusError.createFailed(0)
        }
        guard http.statusCode == 201 || http.statusCode == 200 else {
            throw TusError.createFailed(http.statusCode)
        }
        let location = http.value(forHTTPHeaderField: "Location") ?? ""
        guard !location.isEmpty else {
            throw TusError.missingLocation
        }
        return try extractFileId(from: location)
    }

    /// Shared PATCH loop used by both `upload()` (from offset 0) and
    /// `resume()` (from a HEAD-confirmed offset). Each chunk gets up to
    /// `maxChunkAttempts` tries with escalating backoff (tier 2 of the
    /// 3-tier retry) before the error propagates to the caller — which
    /// then falls through to tier 3 (fresh upload) per
    /// `ChatContainer.retryFailedMessage()`.
    private func runChunkLoop(
        fileId: String,
        data: Data,
        startOffset: Int64,
        total: Int64,
        onProgress: ((Int64, Int64) -> Void)?
    ) async throws {
        var offset = Int(startOffset)
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunkData = Data(data[offset..<end])
            let newOffset = try await patchWithRetry(fileId: fileId, offset: offset, bytes: chunkData)
            offset = newOffset
            onProgress?(Int64(offset), total)
        }
    }

    /// Tier 2: retries a single chunk PATCH up to `maxChunkAttempts`
    /// times with escalating backoff before propagating the last error.
    /// Only network/HTTP failures on THIS chunk are retried here — a
    /// success on attempt 2 or 3 is indistinguishable to the caller from
    /// a first-try success (same return value, no partial-failure state
    /// leaks upward).
    private func patchWithRetry(fileId: String, offset: Int, bytes: Data) async throws -> Int {
        var lastError: Error = TusError.patchFailed(0)
        for attempt in 0..<Self.maxChunkAttempts {
            do {
                return try await patch(fileId: fileId, offset: offset, bytes: bytes)
            } catch {
                lastError = error
                let isLastAttempt = attempt == Self.maxChunkAttempts - 1
                guard !isLastAttempt else { break }
                let backoffIdx = min(attempt, Self.chunkRetryBackoffNanos.count - 1)
                try? await Task.sleep(nanoseconds: Self.chunkRetryBackoffNanos[backoffIdx])
            }
        }
        throw lastError
    }

    private func patch(fileId: String, offset: Int, bytes: Data) async throws -> Int {
        let base = serverUrl.hasSuffix("/") ? serverUrl : serverUrl + "/"
        let urlStr = base + "api/v1/files/tus/" + fileId
        guard let url = URL(string: urlStr) else {
            throw TusError.patchFailed(0)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        req.setValue(String(describing: offset), forHTTPHeaderField: "Upload-Offset")
        req.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = bytes
        if let tok = getToken() {
            req.setValue("Bearer " + tok, forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TusError.patchFailed(0)
        }
        if http.statusCode == 404 {
            throw TusError.uploadNotFound(fileId: fileId)
        }
        guard http.statusCode == 204 || http.statusCode == 200 else {
            throw TusError.patchFailed(http.statusCode)
        }
        // Per tus core §11: server echoes the new offset in Upload-Offset.
        if let headerVal = http.value(forHTTPHeaderField: "Upload-Offset"),
           let newOff = Int(headerVal) {
            return newOff
        }
        return offset + bytes.count
    }

    // MARK: - Helpers

    /// Extract the bare fileId from a Location header value.
    /// Handles both relative (/api/v1/files/tus/<id>) and absolute URLs.
    private func extractFileId(from location: String) throws -> String {
        let marker = "files/tus/"
        guard let markerRange = location.range(of: marker) else {
            throw TusError.badFileId(location)
        }
        var fileId = String(location[markerRange.upperBound...])
        // Strip query string, fragment, trailing slashes.
        if let qIdx = fileId.firstIndex(of: "?") {
            fileId = String(fileId[..<qIdx])
        }
        if let hIdx = fileId.firstIndex(of: "#") {
            fileId = String(fileId[..<hIdx])
        }
        fileId = fileId.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !fileId.isEmpty else {
            throw TusError.badFileId(location)
        }
        return fileId
    }
}
