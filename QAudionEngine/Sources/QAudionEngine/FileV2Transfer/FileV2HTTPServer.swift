import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on Linux (the scratch harness); on Apple platforms it is Foundation
#endif

/// `FileV2Server` over `URLSession`: the real client of the parts protocol.
///
/// It is built the way the tus client is, from what the app's authenticated REST client already holds: its `URLSession` (so
/// the same TLS pinning), the certificate-pinned primary server (the node that stores files; `files.db` and the blobs are not
/// replicated, so a file request never rides the node selector), a closure that reads the CURRENT access token, and the
/// closure that runs the session recovery. A request that is answered 401 is made again ONCE after the recovery, with the
/// fresh token (the request is rebuilt, never resent with the old header); a 401 that is left is the caller's.
///
/// The typed rules (what an error means, how long to wait) are not here: this type only turns the HTTP into typed values and
/// typed errors (`FileV2HTTPWire`), and an I/O failure of the transport (a reset, a timeout) is thrown as the `URLError` it
/// is, for the retry loop (`FileV2Retry`) to classify. Timeouts are the idle kind of `URLSession` (the interval is the time
/// without a byte, not a total), which is the progress-based deadline the slowest legitimate part needs.
///
/// Nothing here prints a token, an object id or a key.
public final class FileV2HTTPServer: FileV2Server, @unchecked Sendable {

    private let session: URLSession
    private let baseURL: String
    private let getToken: () -> String?
    private let refreshToken: (() async throws -> Bool)?
    private let clock: FileV2Clock

    /// Idle timeout of a control request (create, complete, delete, lists): the server may hold a create for up to 10 s, and syncs the
    /// whole file before `complete` answers. Not 60: that is the default value of a `URLRequest`, and a request that carries the default
    /// can end up on the shorter timeout (15 s) the app's session is configured with.
    static let controlTimeout: TimeInterval = 90
    /// Idle timeout of a part: it slides while bytes move.
    static let partTimeout: TimeInterval = 120

    public init(session: URLSession, serverURL: String, getToken: @escaping () -> String?,
                refreshToken: (() async throws -> Bool)? = nil, clock: FileV2Clock = FileV2SystemClock()) {
        self.session = session
        self.baseURL = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        self.getToken = getToken
        self.refreshToken = refreshToken
        self.clock = clock
    }

    // MARK: The interface

    public func create(_ request: FileV2CreateRequest) async throws -> FileV2Created {
        let body = try FileV2HTTPWire.createBody(request)
        let (data, _) = try await perform("POST", path: FileV2Wire.pathPrefix, json: body)
        return try FileV2HTTPWire.parseCreated(data)
    }

    public func putPart(obj: String, part: Int, body: Data, sha256: Data) async throws -> FileV2PutResult {
        let path = try objectPath(obj, "/parts/\(part)")
        let headers = ["Content-Type": "application/octet-stream", "Content-Digest": FileV2HTTPWire.contentDigest(sha256)]
        let (data, _) = try await perform("PUT", path: path, headers: headers, upload: body, timeout: Self.partTimeout)
        return try FileV2HTTPWire.parsePut(data)
    }

    public func partsMap(obj: String) async throws -> FileV2PartsMap {
        let (data, _) = try await perform("GET", path: try objectPath(obj, "/parts"))
        return try FileV2HTTPWire.parsePartsMap(data)
    }

    public func complete(obj: String) async throws {
        _ = try await perform("POST", path: try objectPath(obj, "/complete"))
    }

    public func delete(obj: String) async throws {
        _ = try await perform("DELETE", path: try objectPath(obj))
    }

    public func issueToken(obj: String, scope: FileV2TokenRequest) async throws -> FileV2IssuedToken {
        let (data, _) = try await perform("POST", path: try objectPath(obj, "/token"), json: try FileV2HTTPWire.tokenBody(scope))
        return try FileV2HTTPWire.parseIssuedToken(data)
    }

    public func listUnfinished(limit: Int?, after: String?) async throws -> FileV2UnfinishedPage {
        let (data, _) = try await perform("GET", path: FileV2Wire.pathPrefix,
                                          query: FileV2HTTPWire.listQuery(limit: limit, after: after))
        return try FileV2HTTPWire.parseUnfinished(data)
    }

    public func deleteUnfinished() async throws -> FileV2BulkDeleteResult {
        let (data, _) = try await perform("DELETE", path: FileV2Wire.pathPrefix, query: "state=unfinished")
        return try FileV2HTTPWire.parseBulkDelete(data)
    }

    public func fetchRange(obj: String, from: Int64, toInclusive: Int64, token: FileV2DownloadAuth?,
                           waitSeconds: Int) async throws -> FileV2RangeResult {
        let headers = FileV2HTTPWire.downloadHeaders(from: from, toInclusive: toInclusive, token: token,
                                                     waitSeconds: waitSeconds)
        let wait = TimeInterval(max(0, min(waitSeconds, 25)))
        let (data, response) = try await perform("GET", path: try objectPath(obj), headers: headers,
                                                 timeout: Self.partTimeout + wait)
        // A ranged answer says the blob length in `Content-Range`. The whole object (200, no range) is its own length.
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let total = FileV2HTTPWire.totalLength(ofContentRange: range) {
            return FileV2RangeResult(body: data, totalLength: total)
        }
        guard response.statusCode == 200, from == 0 else { throw FileV2WireFormatError.malformedAnswer }
        return FileV2RangeResult(body: data, totalLength: Int64(data.count))
    }

    // MARK: Plumbing

    private func objectPath(_ obj: String, _ tail: String = "") throws -> String {
        guard let path = FileV2HTTPWire.objectPath(obj, tail) else {
            // not an id the server could have issued: a request error, not worth a request
            throw FileV2ServerError(status: 400, code: "bad_request")
        }
        return path
    }

    private func makeRequest(method: String, path: String, query: String?, headers: [String: String],
                             json: Data?, timeout: TimeInterval) throws -> URLRequest {
        let text = baseURL + path + (query.map { "?" + $0 } ?? "")
        guard let url = URL(string: text) else { throw FileV2ServerError(status: 400, code: "bad_request") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        if let token = getToken(), !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if headers["Range"] == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        } else {
            // A download is bytes, and the bytes of a part are the ones the Range asks for: nothing may re-encode them on the way.
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = json
        }
        return request
    }

    /// One request, with the single refresh-and-repeat of a 401. A non-2xx answer is thrown as a `FileV2ServerError`.
    private func perform(_ method: String, path: String, query: String? = nil, headers: [String: String] = [:],
                         json: Data? = nil, upload: Data? = nil,
                         timeout: TimeInterval = FileV2HTTPServer.controlTimeout) async throws -> (Data, HTTPURLResponse) {
        func once() async throws -> (Data, HTTPURLResponse) {
            let request = try makeRequest(method: method, path: path, query: query, headers: headers, json: json,
                                          timeout: timeout)
            let answer: (Data, URLResponse)
            if let upload {
                answer = try await session.upload(for: request, from: upload)
            } else {
                answer = try await session.data(for: request)
            }
            guard let http = answer.1 as? HTTPURLResponse else { throw FileV2WireFormatError.malformedAnswer }
            return (answer.0, http)
        }
        var result = try await once()
        if result.1.statusCode == 401, let refreshToken, try await refreshToken() {
            result = try await once()
        }
        let (data, http) = result
        guard (200...299).contains(http.statusCode) else {
            throw FileV2HTTPWire.parseError(status: http.statusCode, body: data,
                                            retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                                            nowMs: clock.nowMs())
        }
        return (data, http)
    }
}
