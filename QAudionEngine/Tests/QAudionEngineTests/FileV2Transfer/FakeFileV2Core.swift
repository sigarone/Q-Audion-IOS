import Foundation
import CryptoKit
@testable import QAudionEngine

// An in-memory model of the server's parts protocol (Bcrypto-server internal/filesv2, commit f541653b), written by reading
// handler.go, store.go, service.go, bulk.go, token.go, download.go and cleanup.go, and held to the real handlers by the
// conformance transcript (FileV2TranscriptReplay.swift replays every scenario against it).
//
// It is a state machine over HTTP-shaped requests (FakeWireRequest) and answers (FakeWireResponse), with no thread and no
// timer of its own: a request that the real server would hold (a stalled upload, a retry that waits for a busy part, a
// download that waits for parts, a create that waits for its turn at the disk) is kept as a pending operation and answered
// when the test lets it go. `timerMs` is the clock the server's OWN timers run on: a wait does not sleep, it advances this
// clock by the wait, and never moves the clock of the scenario (`clock`), which only the test moves.
//
// Known divergences from the real server (none is reachable through the typed `FileV2Server` interface and none is pinned
// by the transcript): the 64 kbit/s read deadline and the paced download body, the fsync and fallocate of a part and a
// blob (a part is held in memory; the free-space floor is a number the test sets), the rows of files.db (objects, parts and
// counters are dictionaries), the HMAC key of the tokens (a fixed one) and the matching of JSON member names, which is
// ASCII case-insensitive here and Unicode simple folding in Go.

struct FakeCoreConfig {
    var quota: Int64 = Int64(FileV2.maxBlob)
    var maxIncompletePerUser = 10
    var maxObjectsPerUser = 20_000
    var maxUnfinishedBytes: Int64 = 16 << 30
    var completedRetentionMs: Int64 = 30 * 86_400_000
    var incompleteAbandonMs: Int64 = 6 * 3_600_000
    var incompleteMaxLifetimeMs: Int64 = 24 * 3_600_000
    var createGateWaitMs: Int64 = 10_000
    var minFreeBytes: Int64 = 1 << 30
    /// The free space of the volume; `nil` when it cannot be read (the check is then skipped, as on the real server).
    var freeBytes: Int64?
    var recommendedParallelism = 6
    var maxPartsInFlightPerUser = 16
    var maxDownloadsPerUser = 12
    var streamWaitMaxMs: Int64 = 25_000
    /// How long a request waits for a part that another request is uploading (5 s on the real server).
    var partLockWaitMs: Int64 = 5_000
    var hasTokenSecret = true
    var hasGroupStore = true
}

final class FakeFileV2Core {

    // MARK: State

    final class Object {
        let id: String
        let owner: XferName
        let blobLength: Int64
        let parts: Int
        let head: Data
        let headHash: Data
        let createdMs: Int64
        var activityMs: Int64
        var completedMs: Int64 = 0
        var groups: [XferName] = []
        var data: [Int: Data] = [:]
        var digests: [Int: Data] = [:]

        init(id: String, owner: XferName, blobLength: Int64, head: Data, headHash: Data, nowMs: Int64) {
            self.id = id
            self.owner = owner
            self.blobLength = blobLength
            self.parts = FileV2Wire.partCount(blobLength: blobLength)
            self.head = head
            self.headHash = headHash
            self.createdMs = nowMs
            self.activityMs = nowMs
        }

        var done: Int { digests.count }
    }

    struct HeadKey: Hashable {
        let owner: XferName
        let hash: Data
    }

    struct CounterKey: Hashable {
        let obj: String
        let mac: Data
        let presenter: XferName
    }

    struct Counter {
        var uses: Int
        var bytes: Int64
    }

    struct TokenGrant {
        let key: CounterKey
        let maxUses: Int
    }

    /// What a pending upload holds on to.
    struct UploadState {
        let user: XferName
        let obj: String
        let part: Int
        let partText: String
        let digest: Data
        let want: Int
        let body: Data
        let mode: FakeUploadMode
        var lockKey: String { obj + "/" + partText }
    }

    struct DownloadState {
        let user: XferName
        let obj: String
        let start: Int64
        let length: Int64
        let partial: Bool
        let grant: TokenGrant?
        let first: Int
        let last: Int
        let waitMs: Int64
        let headers: FakeHeaders
    }

    struct CreateState {
        let user: XferName
        let blobLength: Int64
        let head: Data
        let headHash: Data
        let token: TokenRequest?
        let ttlSeconds: Int64
    }

    struct TokenRequest {
        var recipient = ""
        var group = ""
        var ttlSeconds: Int64 = 0
        var maxUses: Int64 = 0
    }

    enum PendingKind {
        /// A stalled upload: holds a slot and the lock of its part, and waits for the rest of its body. `duplicate` says that
        /// the part was already on the server with the same digest when the upload took the lock.
        case holdingUpload(UploadState, duplicate: Bool)
        /// A retry of a part another request is uploading: holds a slot and waits for the lock.
        case queuedUpload(UploadState)
        case waitingDownload(DownloadState)
        case createAtGate(CreateState)
    }

    final class Pending {
        let id: Int
        var kind: PendingKind
        var response: FakeWireResponse?

        init(id: Int, kind: PendingKind) {
            self.id = id
            self.kind = kind
        }
    }

    var config: FakeCoreConfig
    let clock: FileV2Clock

    /// The clock the server's own timers run on: it moves only by the waits the server would have made.
    private(set) var timerMs: Int64 = 0

    var objects: [String: Object] = [:]
    var byHead: [HeadKey: String] = [:]
    var counters: [CounterKey: Counter] = [:]
    var withoutFeature: Set<XferName> = []
    var groupMembers: [XferName: Set<XferName>] = [:]
    var groupLookupFails = false

    var partsInFlight: [XferName: Int] = [:]
    var downloadsInFlight: [XferName: Int] = [:]
    /// Download slots occupied by the test (the seam that stands for downloads that are running).
    var heldDownloadSlots: [XferName: Int] = [:]
    var lockHolder: [String: Int] = [:]
    var lockWaiters: [String: [Int]] = [:]
    var pending: [Int: Pending] = [:]
    var nextID = 1

    /// The create seam: the next create that would make a NEW object takes its turn at the disk and stays there.
    var holdCreateGate = false
    var gateHolder: Int?

    /// The fixed HMAC key of the tokens of this fake (the real one is the server's secret).
    let tokenKey = SymmetricKey(data: Data(repeating: 0x42, count: 32))

    init(config: FakeCoreConfig = FakeCoreConfig(), clock: FileV2Clock) {
        self.config = config
        self.clock = clock
    }

    func advanceTimer(ms: Int64) { timerMs += ms }

    func newID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    // MARK: Answers

    func answer(_ status: Int, _ fields: [(String, FakeJSON)], headers: [(String, String)] = []) -> FakeWireResponse {
        var response = FakeWireResponse(status: status)
        response.headers.set("Cache-Control", "no-store")
        response.headers.set("Content-Type", "application/json")
        for (name, value) in headers { response.headers.set(name, value) }
        response.json = .obj(fields)
        return response
    }

    func failure(_ status: Int, _ code: String, _ message: String = "", extra: [(String, FakeJSON)] = [],
                 headers: [(String, String)] = []) -> FakeWireResponse {
        var fields: [(String, FakeJSON)] = [("error", .string(code))]
        if !message.isEmpty { fields.append(("message", .string(message))) }
        fields.append(contentsOf: extra)
        return answer(status, fields, headers: headers)
    }

    func failure(_ status: Int, _ code: String, headers: FakeHeaders) -> FakeWireResponse {
        var response = failure(status, code)
        for pair in headers.pairs { response.headers.set(pair.name, pair.value) }
        return response
    }

    func notFound() -> FakeWireResponse { failure(404, "not_found") }

    func storageError() -> FakeWireResponse { failure(500, "storage_error", "storage error") }

    func methodNotAllowed(_ allow: String) -> FakeWireResponse {
        failure(405, "method_not_allowed", headers: [("Allow", allow)])
    }

    // MARK: Routing (handler.go ServeHTTP)

    private static let objectIDLength = 36

    static func isObjectID(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == objectIDLength else { return false }
        for (index, byte) in bytes.enumerated() {
            if index == 8 || index == 13 || index == 18 || index == 23 {
                if byte != 0x2D { return false }
            } else {
                let digit = byte >= 0x30 && byte <= 0x39
                let lower = byte >= 0x61 && byte <= 0x66
                if !(digit || lower) { return false }
            }
        }
        return true
    }

    static func percentDecode(_ bytes: [UInt8], plusIsSpace: Bool) -> [UInt8]? {
        var out = [UInt8]()
        var index = 0
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x61...0x66: return byte - 0x61 + 10
            case 0x41...0x46: return byte - 0x41 + 10
            default: return nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x25 {
                guard index + 2 < bytes.count, let high = nibble(bytes[index + 1]),
                      let low = nibble(bytes[index + 2]) else { return nil }
                out.append(high << 4 | low)
                index += 3
            } else if byte == 0x2B && plusIsSpace {
                out.append(0x20)
                index += 1
            } else {
                out.append(byte)
                index += 1
            }
        }
        return out
    }

    /// Serves one request. `async` says that the test does not wait for the answer of a request the server keeps: it gets
    /// `.pending`; a synchronous request that the server would hold for a timer is answered as the timer ends (the timer
    /// clock moves by the wait).
    func serve(_ request: FakeWireRequest, async: Bool = false) -> FakeOutcome {
        let outcome = route(request, async: async)
        pumpDownloads()
        return outcome
    }

    private func route(_ request: FakeWireRequest, async: Bool) -> FakeOutcome {
        let raw = Array(request.path.utf8)
        var pathBytes = raw
        var query: [UInt8]?
        if let mark = raw.firstIndex(of: 0x3F) {
            pathBytes = Array(raw[..<mark])
            query = Array(raw[(mark + 1)...])
        }
        guard let decoded = FakeFileV2Core.percentDecode(pathBytes, plusIsSpace: false) else {
            return .response(failure(400, "bad_request"))
        }
        let prefix = Array(FileV2Wire.pathPrefix.utf8)
        guard decoded.starts(with: prefix) else { return .response(notFound()) }
        var rest = Array(decoded[prefix.count...])
        if let first = rest.first, first != 0x2F { return .response(notFound()) }
        guard let userText = request.user, !userText.isEmpty else { return .response(failure(401, "unauthorized")) }
        let user = XferName(userText)
        if rest.first == 0x2F { rest.removeFirst() }

        if rest.isEmpty { return serveCollection(request, user: user, query: query) }
        let segments = rest.split(separator: 0x2F, omittingEmptySubsequences: false).map { Array($0) }
        guard FakeFileV2Core.isObjectID(segments[0]) else { return .response(notFound()) }
        let obj = String(decoding: segments[0], as: UTF8.self)
        return serveObject(request, user: user, obj: obj, segments: segments, async: async)
    }

    private func serveCollection(_ request: FakeWireRequest, user: XferName, query: [UInt8]?) -> FakeOutcome {
        switch request.method {
        case "POST": return handleCreate(request, user: user)
        case "GET": return .response(handleListUnfinished(user: user, query: query))
        case "DELETE": return .response(handleDeleteUnfinished(user: user, query: query))
        default: return .response(methodNotAllowed("POST, GET, DELETE"))
        }
    }

    private func serveObject(_ request: FakeWireRequest, user: XferName, obj: String, segments: [[UInt8]],
                             async: Bool) -> FakeOutcome {
        func name(_ index: Int, is text: String) -> Bool { segments.count > index && segments[index] == Array(text.utf8) }
        if segments.count == 1 {
            switch request.method {
            case "GET": return handleDownload(request, user: user, obj: obj, async: async)
            case "DELETE": return .response(handleDelete(user: user, obj: obj))
            default: return .response(methodNotAllowed("GET, DELETE"))
            }
        }
        if segments.count == 2 && name(1, is: "parts") {
            guard request.method == "GET" else { return .response(methodNotAllowed("GET")) }
            return .response(handleGetParts(user: user, obj: obj))
        }
        if segments.count == 3 && name(1, is: "parts") {
            guard request.method == "PUT" else { return .response(methodNotAllowed("PUT")) }
            return handlePutPart(request, user: user, obj: obj, partText: String(decoding: segments[2], as: UTF8.self),
                                 async: async)
        }
        if segments.count == 2 && name(1, is: "complete") {
            guard request.method == "POST" else { return .response(methodNotAllowed("POST")) }
            return .response(handleComplete(user: user, obj: obj))
        }
        if segments.count == 2 && name(1, is: "token") {
            guard request.method == "POST" else { return .response(methodNotAllowed("POST")) }
            return .response(handleToken(request, user: user, obj: obj))
        }
        return .response(notFound())
    }

    // MARK: Entitlement and the Go-style JSON decoder

    func requireFeature(_ user: XferName) -> FakeWireResponse? {
        guard withoutFeature.contains(user) else { return nil }
        return failure(402, "entitlement_required", extra: [("feature", .string("feat.files")), ("package", .string("pro"))])
    }

    struct DecodeFailure: Error {}

    /// `json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))` with `DisallowUnknownFields`, then `dec.More()`: the first JSON
    /// value of the body, which must be an object (or `null`, which leaves every field at its zero value); a member that
    /// is not one of `fields` is an error; the last of a repeated member wins; more data after the value is an error unless it
    /// starts with `]` or `}` (which is what `More` reports).
    func decodeObject(_ body: Data, fields: [String]) throws -> [String: FakeJSON] {
        let bytes = Array(body)
        guard bytes.count <= 4096 else { throw DecodeFailure() }
        let first: FakeJSON
        let end: Int
        do {
            (first, end) = try FakeJSON.parseFirstValue(bytes)
        } catch {
            throw DecodeFailure()
        }
        var index = end
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
        if index < bytes.count, bytes[index] != 0x5D, bytes[index] != 0x7D { throw DecodeFailure() }
        return try decodeMembers(first, fields: fields)
    }

    func decodeMembers(_ value: FakeJSON, fields: [String]) throws -> [String: FakeJSON] {
        if value.isNull { return [:] }
        guard case .object(let members) = value else { throw DecodeFailure() }
        var out: [String: FakeJSON] = [:]
        for member in members {
            let folded = FakeFileV2Core.asciiFold(member.key)
            guard let known = fields.first(where: { FakeFileV2Core.asciiFold($0) == folded }) else { throw DecodeFailure() }
            out[known] = member.value
        }
        return out
    }

    static func asciiFold(_ text: String) -> [UInt8] {
        text.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }
    }

    /// A string field: absent and `null` are the empty string, anything but a string is an error.
    func decodeString(_ value: FakeJSON?) throws -> String {
        guard let value = value, !value.isNull else { return "" }
        guard let text = value.stringValue else { throw DecodeFailure() }
        return text
    }

    /// An integer field of `bits` bits: absent and `null` are 0; a number that is not an integer of that size is an error.
    func decodeInteger(_ value: FakeJSON?, bits: Int) throws -> Int64 {
        guard let value = value, !value.isNull else { return 0 }
        guard let number = value.intValue else { throw DecodeFailure() }
        if bits == 32 && (number < Int64(Int32.min) || number > Int64(Int32.max)) { throw DecodeFailure() }
        return number
    }
}
