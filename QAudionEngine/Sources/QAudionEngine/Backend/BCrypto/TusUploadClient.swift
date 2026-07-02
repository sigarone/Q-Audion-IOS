import Foundation

/// W443 — tus.io v1.0.0 resumable upload client for bcrypto-server.
///
/// Protocol overview (subset implemented here):
///   POST  {serverUrl}/api/v1/files/tus
///     Headers: Tus-Resumable: 1.0.0, Upload-Length: <totalBytes>
///     Response: 201 Created, Location: /api/v1/files/tus/{fileId}
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
///   - Resumability: if a chunk PATCH returns 409 (offset mismatch) the
///     caller should recreate the upload — full resume requires a HEAD
///     request which is out of scope for the current use-case (upload size
///     is bounded by the 10 MB file cap; partial failures are rare enough
///     that a fresh create is the right trade-off).
///   - The threshold decision (multipart vs TUS) is made by the caller
///     (`BCryptoStorageApiImpl.uploadFile`).
final class TusUploadClient {

    // MARK: - Error

    enum TusError: Error, LocalizedError {
        case createFailed(Int)
        case missingLocation
        case badFileId(String)
        case patchFailed(Int)

        var errorDescription: String? {
            switch self {
            case .createFailed(let code):
                return "TUS create failed: HTTP " + String(describing: code)
            case .missingLocation:
                return "TUS create: missing Location header"
            case .badFileId(let loc):
                return "TUS create: cannot parse fileId from: " + loc
            case .patchFailed(let code):
                return "TUS patch failed: HTTP " + String(describing: code)
            }
        }
    }

    // MARK: - State

    private let session: URLSession
    private let serverUrl: String
    private let getToken: () -> String?
    let chunkSize: Int

    static let defaultChunkSize = 512 * 1024   // 512 KB

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
    func upload(data: Data, onProgress: ((Int64, Int64) -> Void)? = nil) async throws -> String {
        let fileId = try await create(totalBytes: data.count)
        let total = Int64(data.count)
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunkData = Data(data[offset..<end])
            let newOffset = try await patch(fileId: fileId, offset: offset, bytes: chunkData)
            offset = newOffset
            onProgress?(Int64(offset), total)
        }
        return fileId
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
