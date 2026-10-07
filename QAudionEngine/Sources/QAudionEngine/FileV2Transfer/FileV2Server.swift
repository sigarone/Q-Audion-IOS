import Foundation

// File transfer v2, step 2a: the client side of the server's parts protocol (docs/FILES_V2_PARTS_PROTOCOL.md of the
// server repository), as the send and receive pipelines will see it. This file holds the typed values, the error the
// server raises and the interface; there is no network here, no HTTP client, no state store and no pipeline.
//
// Everything that crosses this interface is typed. Nothing here parses an HTTP message: the later URLSession client
// builds the requests and reads the answers, the in-memory fake of the tests implements the same interface, and the
// server conformance transcript (test/kat/file_v2_server/transcript.json) ties that fake to the real handlers.

/// Time for the transfer layer, injectable so token expiry, idle times, goodput windows and `Retry-After` dates are testable.
///
/// There are two clocks because they answer two different questions, and a wall clock can be set back (by the user, by the
/// network time service, by a device with a wrong date that has just corrected it):
///
/// - `nowMs()` is the wall clock in epoch milliseconds. It is for what the protocol states in wall time: the expiry of a
///   download token (`FileV2IssuedToken.exp`) and the date form of `Retry-After`.
/// - `monotonicMs()` never goes back while the process runs. It is the only clock for DURATIONS: the goodput windows of
///   `FileV2AdaptiveParallelism`, `FileV2ProgressDeadline`, idle and wait timers. Its zero is arbitrary, so only differences
///   mean anything and it is never compared with `nowMs()`.
public protocol FileV2Clock: Sendable {
    func nowMs() -> Int64
    func monotonicMs() -> Int64
}

/// The system clocks: the wall clock, and the time the system has been up (monotonic).
public struct FileV2SystemClock: FileV2Clock {
    public init() {}

    public func nowMs() -> Int64 {
        let seconds = Date().timeIntervalSince1970
        guard seconds.isFinite else { return 0 }
        return Int64(seconds * 1000.0)
    }

    public func monotonicMs() -> Int64 {
        let seconds = ProcessInfo.processInfo.systemUptime
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(min(seconds, 1.0e12) * 1000.0)
    }
}

/// The constants of the parts protocol and the geometry of an object (WIRE_SPEC 12.10, server `FILES_V2_PARTS_PROTOCOL.md`).
///
/// An object is a 64-byte header followed by parts of a fixed size. Part `p` occupies the bytes from
/// `64 + p * partSize`; the last one is shorter.
public enum FileV2Wire {
    /// 8 chunks of `FileV2.stride`: the same for every part but the last. A client sends it with the create and the
    /// server refuses any other value (400 `bad_part_size`).
    public static let partSize: Int = 8 * FileV2.stride
    public static let chunksPerPart: Int = 8
    /// 640 full parts: `FileV2.maxBlob` is exactly `headerLength + 640 * partSize`.
    public static let maxParts: Int = 640
    /// The prefix of every route of the protocol.
    public static let pathPrefix: String = "/api/v1/files/v2"
    /// Longest `Retry-After` a client waits for, in seconds. A longer one is NOT waited for at all (no automatic wait: the
    /// transfer pauses, or fails with a reason the user sees); it is not cut down to this value. See `FileV2RetryPolicy`.
    public static let maxRetryAfterSeconds: Int = 300

    /// `ceil((blobLength - 64) / partSize)`; 0 for a length that holds no payload.
    public static func partCount(blobLength: Int64) -> Int {
        let (payload, overflow) = blobLength.subtractingReportingOverflow(Int64(FileV2.headerLength))
        guard !overflow, payload > 0 else { return 0 }
        let size = Int64(partSize)
        let count = payload / size + (payload % size == 0 ? 0 : 1)
        return count > Int64(Int32.max) ? Int(Int32.max) : Int(count)
    }

    /// Offset of part `part` in the blob; `nil` for a negative index.
    public static func partOffset(_ part: Int) -> Int64? {
        guard part >= 0 else { return nil }
        let (product, overflow) = Int64(part).multipliedReportingOverflow(by: Int64(partSize))
        guard !overflow else { return nil }
        let (sum, overflow2) = product.addingReportingOverflow(Int64(FileV2.headerLength))
        return overflow2 ? nil : sum
    }

    /// Length of part `part`: `partSize`, or the remainder for the last one; 0 for a part that does not exist.
    public static func partLength(blobLength: Int64, part: Int) -> Int {
        guard part >= 0, part < partCount(blobLength: blobLength), let offset = partOffset(part) else { return 0 }
        return Int(min(Int64(partSize), blobLength - offset))
    }
}

/// A download token request: exactly one of `recipientUserID` and `groupID`. The server validates it; this type does
/// not, so that a malformed request can reach the server (and the fake) and be refused with `bad_token_request`.
/// A `ttlSeconds` or `maxUses` of `nil` or 0 selects the server default (7 days, 10 uses; 0 is NOT unlimited).
public struct FileV2TokenRequest: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let recipientUserID: String?
    public let groupID: String?
    public let ttlSeconds: Int64?
    public let maxUses: Int?

    public init(recipientUserID: String?, groupID: String?, ttlSeconds: Int64? = nil, maxUses: Int? = nil) {
        self.recipientUserID = recipientUserID
        self.groupID = groupID
        self.ttlSeconds = ttlSeconds
        self.maxUses = maxUses
    }

    public static func forRecipient(_ userID: String, ttlSeconds: Int64? = nil, maxUses: Int? = nil) -> FileV2TokenRequest {
        FileV2TokenRequest(recipientUserID: userID, groupID: nil, ttlSeconds: ttlSeconds, maxUses: maxUses)
    }

    public static func forGroup(_ groupID: String, ttlSeconds: Int64? = nil, maxUses: Int? = nil) -> FileV2TokenRequest {
        FileV2TokenRequest(recipientUserID: nil, groupID: groupID, ttlSeconds: ttlSeconds, maxUses: maxUses)
    }

    /// Only the kind of scope: never a user or group identifier (not in `description`, not in a `dump` either).
    public var description: String { "FileV2TokenRequest(\(groupID != nil ? "group" : "user"))" }
    public var customMirror: Mirror {
        Mirror(self, children: ["scope": groupID != nil ? "group" : "user", "ttlSeconds": ttlSeconds as Any,
                                "maxUses": maxUses as Any], displayStyle: .struct)
    }
}

/// `POST /`. `head` is the 64-byte file header; it identifies the file and is never printed (not in `description`, not in a
/// `dump`: the mirror holds the lengths and the redacted token request only).
public struct FileV2CreateRequest: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let blobLength: Int64
    public let head: Data
    public let partSize: Int
    public let token: FileV2TokenRequest?

    public init(blobLength: Int64, head: Data, partSize: Int = FileV2Wire.partSize, token: FileV2TokenRequest? = nil) {
        self.blobLength = blobLength
        self.head = head
        self.partSize = partSize
        self.token = token
    }

    public var description: String { "FileV2CreateRequest(blobLength=\(blobLength), partSize=\(partSize))" }
    public var customMirror: Mirror {
        Mirror(self, children: ["blobLength": blobLength, "headBytes": head.count, "partSize": partSize,
                                "token": token as Any], displayStyle: .struct)
    }
}

/// The download token as the server issues it. `v` is a secret (it is what the descriptor's `src.tok.v` carries); `exp`
/// is in epoch milliseconds.
public struct FileV2IssuedToken: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let v: String
    public let exp: Int64
    public let max: Int
    public let scope: String

    public init(v: String, exp: Int64, max: Int, scope: String) {
        self.v = v
        self.exp = exp
        self.max = max
        self.scope = scope
    }

    public var description: String { "FileV2IssuedToken(scope=\(scope), max=\(max))" }
    public var customMirror: Mirror {
        Mirror(self, children: ["scope": scope, "max": max], displayStyle: .struct)
    }
}

/// What a reader presents (`X-Download-Token`, `X-Download-Expires-Ms`, `X-Download-Max-Uses`): the descriptor's
/// `src.tok`. Never printed.
public struct FileV2DownloadAuth: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let v: String
    public let expMs: Int64
    public let max: Int

    public init(v: String, expMs: Int64, max: Int) {
        self.v = v
        self.expMs = expMs
        self.max = max
    }

    public var description: String { "FileV2DownloadAuth(max=\(max))" }
    public var customMirror: Mirror {
        Mirror(self, children: ["max": max], displayStyle: .struct)
    }
}

/// Cuts an object id to the 8 characters that may be printed.
func fileV2ShortID(_ id: String) -> String { String(id.prefix(8)) }

/// Answer of create: 201 for a new object, 200 with `existing` true (and `received`, `complete`) for a resume. The object id
/// and the token are secrets of the transfer: a description or a `dump` shows the first 8 characters of the id and the
/// redacted token only.
public struct FileV2Created: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let obj: String
    public let blobLength: Int64
    public let partSize: Int
    public let parts: Int
    public let parallelism: Int
    public let maxParallelism: Int
    public let token: FileV2IssuedToken?
    public let existing: Bool
    public let received: Int
    public let complete: Bool

    public init(obj: String, blobLength: Int64, partSize: Int, parts: Int, parallelism: Int, maxParallelism: Int,
                token: FileV2IssuedToken?, existing: Bool, received: Int, complete: Bool) {
        self.obj = obj
        self.blobLength = blobLength
        self.partSize = partSize
        self.parts = parts
        self.parallelism = parallelism
        self.maxParallelism = maxParallelism
        self.token = token
        self.existing = existing
        self.received = received
        self.complete = complete
    }

    public var description: String {
        let id = fileV2ShortID(obj)
        return "FileV2Created(obj=\(id), parts=\(parts), existing=\(existing), received=\(received), complete=\(complete))"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["obj": fileV2ShortID(obj), "blobLength": blobLength, "partSize": partSize, "parts": parts,
                                "parallelism": parallelism, "maxParallelism": maxParallelism, "token": token as Any,
                                "existing": existing, "received": received, "complete": complete], displayStyle: .struct)
    }
}

/// Answer of a part upload. `duplicate` is true when the part was already on the server with the same digest.
public struct FileV2PutResult: Sendable, Equatable {
    public let part: Int
    public let duplicate: Bool
    public let received: Int
    public let parts: Int

    public init(part: Int, duplicate: Bool, received: Int, parts: Int) {
        self.part = part
        self.duplicate = duplicate
        self.received = received
        self.parts = parts
    }
}

/// An answer of the server that does not say what the protocol says: a protocol violation of the server (or of whatever sits
/// between), not a request error and not an HTTP status of the error table.
public enum FileV2WireFormatError: Error, Equatable, Sendable {
    /// A parts map that does not describe the object it claims to: a bad length, a bit set past the last part, a count that
    /// differs from the bits.
    case invalidPartsMap
    /// A success answer with a missing or mistyped field.
    case malformedAnswer
}

/// `GET /{obj}/parts`: bit `i` is set when part `i` is on the server.
public struct FileV2PartsMap: Sendable, Equatable {
    public let blobLength: Int64
    public let partSize: Int
    public let parts: Int
    public let received: Int
    public let complete: Bool
    /// One entry per part.
    public let bits: [Bool]

    public init(blobLength: Int64, partSize: Int, parts: Int, received: Int, complete: Bool, bits: [Bool]) {
        self.blobLength = blobLength
        self.partSize = partSize
        self.parts = parts
        self.received = received
        self.complete = complete
        self.bits = bits
    }

    /// Decodes the `map` field (already base64-decoded): bit `i % 8` of byte `i / 8`, least significant bit first.
    /// `parts` must be 1...`FileV2Wire.maxParts` (every integer here is the server's JSON and is checked before it is used for
    /// a length or an allocation: an object of this protocol has at least one part and at most 640), the bitmap must be exactly
    /// `ceil(parts / 8)` bytes, must not set a bit past the last part, and its population count must equal `received`:
    /// anything else is `invalidPartsMap`.
    public static func fromWire(blobLength: Int64, partSize: Int, parts: Int, received: Int, complete: Bool,
                                bitmap: Data) throws -> FileV2PartsMap {
        guard parts >= 1, parts <= FileV2Wire.maxParts, bitmap.count == bitmapLength(parts: parts) else {
            throw FileV2WireFormatError.invalidPartsMap
        }
        var bits = [Bool](repeating: false, count: parts)
        var count = 0
        let bytes = Array(bitmap)
        for index in 0..<bytes.count * 8 {
            let set = (bytes[index / 8] >> UInt8(index % 8)) & 1 == 1
            if index >= parts {
                if set { throw FileV2WireFormatError.invalidPartsMap }
            } else if set {
                bits[index] = true
                count += 1
            }
        }
        guard count == received else { throw FileV2WireFormatError.invalidPartsMap }
        return FileV2PartsMap(blobLength: blobLength, partSize: partSize, parts: parts, received: received,
                              complete: complete, bits: bits)
    }

    /// `ceil(parts / 8)`, without the `parts + 7` that overflows for a count near `Int.max`; 0 for a count below 1.
    static func bitmapLength(parts: Int) -> Int {
        parts < 1 ? 0 : parts / 8 + (parts % 8 == 0 ? 0 : 1)
    }

    /// The wire form: bit `i % 8` of byte `i / 8`, least significant bit first.
    public func toWireBitmap() -> Data {
        // one entry of `bits` per part: a map whose `parts` says more than `bits` holds (only a hand-made one) is cut to `bits`
        let count = max(0, min(parts, bits.count))
        var out = [UInt8](repeating: 0, count: FileV2PartsMap.bitmapLength(parts: count))
        for index in 0..<count where bits[index] {
            out[index / 8] |= UInt8(1) << UInt8(index % 8)
        }
        return Data(out)
    }

    public func isReceived(_ part: Int) -> Bool { part >= 0 && part < bits.count && bits[part] }

    /// The parts that are not on the server yet, in order.
    public var missing: [Int] { (0..<bits.count).filter { !bits[$0] } }
}

/// The operations of `FileV2Server`. The meaning of an error depends on which one failed (see `disposition(for:)`).
public enum FileV2Op: String, Sendable, CaseIterable {
    case create, putPart, partsMap, complete, delete, issueToken, fetchRange, listUnfinished, deleteUnfinished
}

/// One unfinished object of the caller, as the collection route lists it. Only the first 8 characters of the id are ever
/// printed (description or `dump`).
public struct FileV2UnfinishedItem: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let obj: String
    public let blobLength: Int64
    public let parts: Int
    public let received: Int
    public let createdMs: Int64
    public let activityMs: Int64

    public init(obj: String, blobLength: Int64, parts: Int, received: Int, createdMs: Int64, activityMs: Int64) {
        self.obj = obj
        self.blobLength = blobLength
        self.parts = parts
        self.received = received
        self.createdMs = createdMs
        self.activityMs = activityMs
    }

    public var description: String {
        "FileV2UnfinishedItem(obj=\(fileV2ShortID(obj)), parts=\(parts), received=\(received))"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["obj": fileV2ShortID(obj), "blobLength": blobLength, "parts": parts, "received": received,
                                "createdMs": createdMs, "activityMs": activityMs], displayStyle: .struct)
    }
}

/// A page of `FileV2Server.listUnfinished`; `next` is the cursor of the following page (an object id), `nil` on the last
/// one. A description or a `dump` shows the number of objects and whether there is a next page, never the cursor.
public struct FileV2UnfinishedPage: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let objects: [FileV2UnfinishedItem]
    public let next: String?

    public init(objects: [FileV2UnfinishedItem], next: String?) {
        self.objects = objects
        self.next = next
    }

    public var description: String { "FileV2UnfinishedPage(objects=\(objects.count), hasNext=\(next != nil))" }
    public var customMirror: Mirror {
        Mirror(self, children: ["objects": objects, "hasNext": next != nil], displayStyle: .struct)
    }
}

/// Answer of `FileV2Server.deleteUnfinished`: how many objects went and the declared size they held.
public struct FileV2BulkDeleteResult: Sendable, Equatable {
    public let deleted: Int
    public let freedBytes: Int64

    public init(deleted: Int, freedBytes: Int64) {
        self.deleted = deleted
        self.freedBytes = freedBytes
    }
}

/// A ranged read: `body` holds the bytes of the range, `totalLength` is the blob length from `Content-Range`. The bytes are
/// the file itself (the first range holds the 64-byte header): a description or a `dump` shows their number only.
public struct FileV2RangeResult: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let body: Data
    public let totalLength: Int64

    public init(body: Data, totalLength: Int64) {
        self.body = body
        self.totalLength = totalLength
    }

    public var description: String { "FileV2RangeResult(bytes=\(body.count), totalLength=\(totalLength))" }
    public var customMirror: Mirror {
        Mirror(self, children: ["bodyBytes": body.count, "totalLength": totalLength], displayStyle: .struct)
    }
}

/// The other fields of the JSON error body of the server, by what they mean. Every field is absent unless the server
/// sent it: `used` and `limit` (413 `quota_exceeded`), `limit` (429 `too_many_uploads`), `maxBlobLength` (413
/// `blob_too_large`), `partSize` (400 `bad_part_size`), `expected` (400 `bad_length`), `parts` (400 `bad_part`, 409
/// `incomplete`), `firstPart` and `lastPart` (425), `feature` and `packageName` (402 `entitlement_required`).
public struct FileV2ErrorDetails: Sendable, Equatable {
    public var used: Int64?
    public var limit: Int64?
    public var maxBlobLength: Int64?
    public var partSize: Int64?
    public var expected: Int64?
    public var parts: Int64?
    public var firstPart: Int64?
    public var lastPart: Int64?
    public var feature: String?
    public var packageName: String?

    public init(used: Int64? = nil, limit: Int64? = nil, maxBlobLength: Int64? = nil, partSize: Int64? = nil,
                expected: Int64? = nil, parts: Int64? = nil, firstPart: Int64? = nil, lastPart: Int64? = nil,
                feature: String? = nil, packageName: String? = nil) {
        self.used = used
        self.limit = limit
        self.maxBlobLength = maxBlobLength
        self.partSize = partSize
        self.expected = expected
        self.parts = parts
        self.firstPart = firstPart
        self.lastPart = lastPart
        self.feature = feature
        self.packageName = packageName
    }

    /// No detail at all.
    public static let none = FileV2ErrorDetails()
}

/// An HTTP error of the parts protocol. `status` and `code` are those of the server's error table;
/// `retryAfter` is the `Retry-After` header in seconds as the server sent it (`FileV2RetryAfter`; NOT cut down: above
/// `FileV2Wire.maxRetryAfterSeconds` the retry policy does not wait for it); `missing` is the `missing` list of 409
/// `incomplete` (at most the first 32 indices); `details` are the other fields of the JSON error body, and the numbers a UI
/// shows stay there: `used` and `limit` of 413 `quota_exceeded`, `maxBlobLength` of 413 `blob_too_large`, `limit` of 429
/// `too_many_uploads`. `FileV2ServerError.disposition(for:)` says what to do (`fail(.quota)`); the error is what the user
/// is told about, so a pipeline keeps both.
///
/// The text of the error is the status and the code only: never a token, a key, a name or a URL. The `code` of a
/// server answer is kept only when it is 1 to 64 characters of lowercase ASCII letters, digits and `_` (every code of
/// the protocol is); anything else becomes `invalid_code`, so the text of a hostile or broken answer can never reach a
/// log, and every comparison of a code is a byte comparison.
public struct FileV2ServerError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public let status: Int
    public let code: String
    public let retryAfter: Int?
    public let missing: [Int]
    public let details: FileV2ErrorDetails

    public init(status: Int, code: String, retryAfter: Int? = nil, missing: [Int] = [],
                details: FileV2ErrorDetails = .none) {
        self.status = status
        self.code = FileV2ServerError.sanitized(code)
        self.retryAfter = retryAfter
        self.missing = missing
        self.details = details
    }

    public var description: String { "\(status) \(code)" }
    public var errorDescription: String? { description }

    static func sanitized(_ code: String) -> String {
        let bytes = Array(code.utf8)
        guard (1...64).contains(bytes.count) else { return "invalid_code" }
        for byte in bytes {
            let letter = byte >= 0x61 && byte <= 0x7A
            let digit = byte >= 0x30 && byte <= 0x39
            if !(letter || digit || byte == 0x5F) { return "invalid_code" }
        }
        return code
    }
}

/// The server side of the parts protocol, as the send and receive pipelines see it. A failure is a
/// `FileV2ServerError` (an HTTP answer of the server) or an I/O error of the transport (a reset, a timeout), which the
/// pipelines retry; `Task` cancellation is never a failure of the transport (see `fileV2TransportDisposition`).
///
/// Facts of the server to respect (docs/FILES_V2_PARTS_PROTOCOL.md; the conformance transcript pins every one):
///
/// - Token requests (in `create` and `issueToken`): `ttl_seconds` absent or 0 is 7 days, above 30 days or negative is
///   400 `bad_token_request`; `max_uses` absent or 0 is 10 (0 is NOT unlimited), above 1000 or negative is 400. A group
///   scope has the same limits; membership is checked at download time.
/// - `create` on an existing object (the same account and the same header hash) answers 200 with `existing`,
///   `received` and `complete`, and a NEW token on every call that asks for one; the same header with another length
///   is 409 `head_conflict`. Creations take turns at the disk: 429 `create_busy` (Retry-After 2).
/// - `delete` of a missing object is 404, which a caller that cancels a transfer treats as done. The owner's delete
///   frees the quota at once.
/// - An unfinished object is removed by the hourly cleanup 6 hours after its last part (after its creation if it never
///   got one) and in any case 24 hours after its creation, whatever it did since; a completed one after 30 days by
///   default (14 in production). Every object counts against the account's quota (the sum of ALL its objects,
///   finished or not, idle or not), against the cap of 10 unfinished objects and against the server-wide cap of 16 GiB
///   of unfinished bytes until it is deleted: only completion (for the last two), delete or the cleanup free anything.
/// - `create`: after the lookup of an existing object come the account limits (`too_many_objects`, `too_many_uploads`,
///   `quota_exceeded`) and the server-wide cap (507 with Retry-After 60), then the turn at the disk (429
///   `create_busy`, which the server answers only after waiting up to 10 s), then the disk (507 without Retry-After
///   when less than the floor would remain). `too_many_uploads` and `too_many_objects` do NOT clear by waiting.
/// - Timeouts: the slowest legitimate part (8 MiB at the server's floor of 8000 B/s) lasts about 17.5 minutes, so the
///   timeout of a part must allow that on slow networks, and it must be a progress-based deadline (it slides while
///   bytes move), not a fixed total: see `FileV2PartTimeout`.
public protocol FileV2Server: Sendable {
    func create(_ request: FileV2CreateRequest) async throws -> FileV2Created

    /// `PUT /{obj}/parts/{part}` with `Content-Length` = `body.count` and `Content-Digest: sha-256=:...:` = `sha256`.
    func putPart(obj: String, part: Int, body: Data, sha256: Data) async throws -> FileV2PutResult

    func partsMap(obj: String) async throws -> FileV2PartsMap

    /// 200; 409 `incomplete` carries the first 32 missing parts in `FileV2ServerError.missing`.
    func complete(obj: String) async throws

    /// 204; 404 when the object is already gone (a caller that cancels a transfer treats that as done).
    func delete(obj: String) async throws

    func issueToken(obj: String, scope: FileV2TokenRequest) async throws -> FileV2IssuedToken

    /// `GET /?state=unfinished&limit=&after=`: the caller's own unfinished objects in object id order, never a
    /// completed one. No entitlement is needed (an account that lost `feat.files` must still be able to free what it
    /// holds). `limit` nil is 20; outside 1...100 it is 400 `bad_request`, as is an `after` that is not an object id.
    /// For a client that lost its transfer state: every unfinished object counts against the quota and the slots.
    func listUnfinished(limit: Int?, after: String?) async throws -> FileV2UnfinishedPage

    /// `DELETE /?state=unfinished`: deletes every unfinished object of the caller (never a completed one); no
    /// entitlement; idempotent (`deleted` is 0 when there is none). Frees quota and slots at once.
    func deleteUnfinished() async throws -> FileV2BulkDeleteResult

    /// Bytes `from`...`toInclusive` of the blob. `waitSeconds` above 0 sends `Prefer: wait=N` (the server caps it at 25).
    func fetchRange(obj: String, from: Int64, toInclusive: Int64, token: FileV2DownloadAuth?,
                    waitSeconds: Int) async throws -> FileV2RangeResult
}
