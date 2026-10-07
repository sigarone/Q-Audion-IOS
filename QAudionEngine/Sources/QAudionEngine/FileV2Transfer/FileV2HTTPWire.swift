import Foundation

/// The HTTP of the parts protocol (docs/FILES_V2_PARTS_PROTOCOL.md of the server repository) as pure functions: how a typed
/// request becomes a path, a header set and a JSON body, and how an answer becomes a typed value or a `FileV2ServerError`.
/// No network, no clock of its own: `FileV2HTTPServer` calls them around `URLSession`, and the tests call them on the JSON of
/// the protocol document.
///
/// The names of the JSON members and of the headers are the server's; the in-memory fake of the tests, which the server
/// conformance transcript holds to the real handlers, reads and writes the same ones.
enum FileV2HTTPWire {

    // MARK: Paths

    /// `/api/v1/files/v2/{obj}` plus `tail`. `nil` when `obj` is not a lowercase hyphenated UUID: an object id comes from a
    /// descriptor of a peer and must never reach a path as anything else (the server answers 404 to any other shape).
    static func objectPath(_ obj: String, _ tail: String = "") -> String? {
        guard isObjectID(obj) else { return nil }
        return FileV2Wire.pathPrefix + "/" + obj + tail
    }

    static func isObjectID(_ obj: String) -> Bool {
        let bytes = Array(obj.utf8)
        guard bytes.count == FileV2.objectIDLength else { return false }
        for (index, byte) in bytes.enumerated() {
            if index == 8 || index == 13 || index == 18 || index == 23 {
                if byte != 0x2D { return false }
            } else if !((byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)) {
                return false
            }
        }
        return true
    }

    // MARK: Headers

    /// `Content-Digest: sha-256=:<base64>:` (RFC 9530).
    static func contentDigest(_ sha256: Data) -> String { "sha-256=:" + sha256.base64EncodedString() + ":" }

    static func rangeHeader(from: Int64, toInclusive: Int64) -> String { "bytes=\(from)-\(toInclusive)" }

    /// The headers of a download: the three of the token and, when the caller waits for parts, `Prefer: wait=N`.
    static func downloadHeaders(from: Int64, toInclusive: Int64, token: FileV2DownloadAuth?, waitSeconds: Int) -> [String: String] {
        var headers = ["Range": rangeHeader(from: from, toInclusive: toInclusive)]
        if waitSeconds > 0 { headers["Prefer"] = "wait=\(waitSeconds)" }
        if let token {
            headers["X-Download-Token"] = token.v
            headers["X-Download-Expires-Ms"] = String(token.expMs)
            headers["X-Download-Max-Uses"] = String(token.max)
        }
        return headers
    }

    /// Total length of the blob from `Content-Range: bytes a-b/total`; `nil` for another shape (`*` included).
    static func totalLength(ofContentRange value: String) -> Int64? {
        let bytes = Array(value.utf8)
        guard let slash = bytes.lastIndex(of: 0x2F), slash + 1 < bytes.count else { return nil }
        let digits = bytes[(slash + 1)...]
        guard digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int64(String(decoding: digits, as: UTF8.self))
    }

    // MARK: Request bodies

    static func tokenObject(_ token: FileV2TokenRequest) -> [String: Any] {
        var object: [String: Any] = [:]
        if let user = token.recipientUserID { object["recipient_user_id"] = user }
        if let group = token.groupID { object["group_id"] = group }
        if let ttl = token.ttlSeconds { object["ttl_seconds"] = ttl }
        if let uses = token.maxUses { object["max_uses"] = uses }
        return object
    }

    static func createBody(_ request: FileV2CreateRequest) throws -> Data {
        var object: [String: Any] = [
            "blob_len": request.blobLength,
            "head": request.head.base64EncodedString(),
            "part_size": request.partSize
        ]
        if let token = request.token { object["token"] = tokenObject(token) }
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func tokenBody(_ scope: FileV2TokenRequest) throws -> Data {
        try JSONSerialization.data(withJSONObject: tokenObject(scope))
    }

    static func listQuery(limit: Int?, after: String?) -> String {
        var query = "state=unfinished"
        if let limit { query += "&limit=\(limit)" }
        if let after { query += "&after=" + percentEscaped(after) }
        return query
    }

    static func percentEscaped(_ text: String) -> String {
        var out = [UInt8]()
        let digits = Array("0123456789ABCDEF".utf8)
        for byte in text.utf8 {
            let plain = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x5F || byte == 0x2E || byte == 0x7E
            if plain {
                out.append(byte)
            } else {
                out.append(0x25)
                out.append(digits[Int(byte >> 4)])
                out.append(digits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Answers

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// An integer member: a JSON number with no fraction, never a boolean.
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        #if canImport(Darwin)
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        #endif
        let whole = number.int64Value
        guard number.doubleValue == Double(whole) else { return nil }
        return whole
    }

    private static func parseToken(_ value: Any?) -> FileV2IssuedToken? {
        guard let json = value as? [String: Any], let v = json["v"] as? String, let exp = integer(json["exp"]),
              let max = integer(json["max"]), let scope = json["scope"] as? String else { return nil }
        return FileV2IssuedToken(v: v, exp: exp, max: Int(clamping: max), scope: scope)
    }

    static func parseCreated(_ data: Data) throws -> FileV2Created {
        guard let json = object(data), let obj = json["obj"] as? String, let blobLength = integer(json["blob_len"]),
              let partSize = integer(json["part_size"]), let parts = integer(json["parts"]),
              let parallelism = integer(json["parallelism"]), let maxParallelism = integer(json["max_parallelism"]) else {
            throw FileV2WireFormatError.malformedAnswer
        }
        return FileV2Created(obj: obj, blobLength: blobLength, partSize: Int(clamping: partSize), parts: Int(clamping: parts),
                             parallelism: Int(clamping: parallelism), maxParallelism: Int(clamping: maxParallelism),
                             token: parseToken(json["token"]), existing: json["existing"] as? Bool ?? false,
                             received: Int(clamping: integer(json["received"]) ?? 0),
                             complete: json["complete"] as? Bool ?? false)
    }

    static func parsePut(_ data: Data) throws -> FileV2PutResult {
        guard let json = object(data), let part = integer(json["part"]), let duplicate = json["duplicate"] as? Bool,
              let received = integer(json["received"]), let parts = integer(json["parts"]) else {
            throw FileV2WireFormatError.malformedAnswer
        }
        return FileV2PutResult(part: Int(clamping: part), duplicate: duplicate, received: Int(clamping: received),
                               parts: Int(clamping: parts))
    }

    static func parsePartsMap(_ data: Data) throws -> FileV2PartsMap {
        guard let json = object(data), let blobLength = integer(json["blob_len"]), let partSize = integer(json["part_size"]),
              let parts = integer(json["parts"]), let received = integer(json["received"]),
              let complete = json["complete"] as? Bool, let map = json["map"] as? String,
              let bitmap = Data(base64Encoded: map) else { throw FileV2WireFormatError.malformedAnswer }
        return try FileV2PartsMap.fromWire(blobLength: blobLength, partSize: Int(clamping: partSize),
                                           parts: Int(clamping: parts), received: Int(clamping: received),
                                           complete: complete, bitmap: bitmap)
    }

    static func parseIssuedToken(_ data: Data) throws -> FileV2IssuedToken {
        guard let json = object(data), let token = parseToken(json) else { throw FileV2WireFormatError.malformedAnswer }
        return token
    }

    static func parseUnfinished(_ data: Data) throws -> FileV2UnfinishedPage {
        guard let json = object(data), let items = json["objects"] as? [Any] else { throw FileV2WireFormatError.malformedAnswer }
        var objects: [FileV2UnfinishedItem] = []
        for item in items {
            guard let entry = item as? [String: Any], let obj = entry["obj"] as? String,
                  let blobLength = integer(entry["blob_len"]), let parts = integer(entry["parts"]),
                  let received = integer(entry["received"]), let created = integer(entry["created_ms"]),
                  let activity = integer(entry["activity_ms"]) else { throw FileV2WireFormatError.malformedAnswer }
            objects.append(FileV2UnfinishedItem(obj: obj, blobLength: blobLength, parts: Int(clamping: parts),
                                                received: Int(clamping: received), createdMs: created, activityMs: activity))
        }
        return FileV2UnfinishedPage(objects: objects, next: json["next"] as? String)
    }

    static func parseBulkDelete(_ data: Data) throws -> FileV2BulkDeleteResult {
        guard let json = object(data), let deleted = integer(json["deleted"]), let freed = integer(json["freed_bytes"]) else {
            throw FileV2WireFormatError.malformedAnswer
        }
        return FileV2BulkDeleteResult(deleted: Int(clamping: deleted), freedBytes: freed)
    }

    /// The error of a non-2xx answer: `status`, the `error` code of the JSON body (a body that is not the protocol's gives the
    /// code `http_<status>`), the `Retry-After` header in seconds, the first `missing` indices and the detail fields.
    static func parseError(status: Int, body: Data, retryAfterHeader: String?, nowMs: Int64) -> FileV2ServerError {
        let json = object(body)
        var retryAfter: Int?
        if let header = retryAfterHeader { retryAfter = FileV2RetryAfter.seconds(from: header, nowMs: nowMs) }
        let missing = ((json?["missing"] as? [Any]) ?? []).compactMap { integer($0) }.prefix(32).map { Int(clamping: $0) }
        var details = FileV2ErrorDetails()
        details.used = integer(json?["used"])
        details.limit = integer(json?["limit"])
        details.maxBlobLength = integer(json?["max_blob_len"])
        details.partSize = integer(json?["part_size"])
        details.expected = integer(json?["expected"])
        details.parts = integer(json?["parts"])
        details.firstPart = integer(json?["first_part"])
        details.lastPart = integer(json?["last_part"])
        details.feature = json?["feature"] as? String
        details.packageName = json?["package"] as? String
        let code = (json?["error"] as? String) ?? "http_\(status)"
        return FileV2ServerError(status: status, code: code, retryAfter: retryAfter, missing: missing, details: details)
    }
}
