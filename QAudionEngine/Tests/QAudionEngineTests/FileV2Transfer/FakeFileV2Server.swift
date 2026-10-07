import Foundation
@testable import QAudionEngine

/// The in-memory `FileV2Server` for the tests of the send and receive pipelines: the typed interface over the HTTP-shaped
/// fake core (FakeFileV2Core), which the conformance transcript holds to the real server. Every typed call is turned into
/// the request a client would send (the JSON of a create, a `Content-Digest` header, a `Range` header, the three
/// `X-Download-*` headers), served by the core, and the answer is turned back into a typed value or a `FileV2ServerError`.
/// So a status, a code, a `Retry-After`, a `missing` list or a detail of an error is the real server's, not a guess.
///
/// One instance is one authenticated account; `asAccount(_:)` gives another account's view of the same server.
///
/// Test controls: the limits of the server (`maxIncomplete`, `quota`, ...), `injectFailure` (a call that fails before or
/// after its effect), `injectDelay` (a call that takes time on the injected sleeper, counted as in flight meanwhile: an upload
/// holds its slot and the lock of its part), the calls log and the cleanup worker. Time is injected twice: the `clock` of the
/// server (token expiry, idle times) and the `sleep` of the delays and of the downloads that wait for parts, so a test never
/// has to wait for real.
final class FakeFileV2Server: FileV2Server, @unchecked Sendable {

    enum When { case beforeEffect, afterEffect }

    struct Call: Equatable {
        let op: FileV2Op
        let part: Int?
    }

    private final class Fault {
        let op: FileV2Op
        let error: Error
        var times: Int
        let part: Int?
        let when: When

        init(op: FileV2Op, error: Error, times: Int, part: Int?, when: When) {
            self.op = op
            self.error = error
            self.times = times
            self.part = part
            self.when = when
        }
    }

    private struct DelayRule {
        let op: FileV2Op
        let ms: Int64
        let part: Int?
    }

    /// The state every account's view shares.
    private final class Shared {
        let lock = NSLock()
        let core: FakeFileV2Core
        var faults: [Fault] = []
        var delays: [DelayRule] = []
        var calls: [Call] = []

        init(core: FakeFileV2Core) { self.core = core }

        func locked<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
    }

    /// How often a download that waits for parts, or a retry that waits for a busy part, looks again, in sleeper milliseconds.
    private static let pollMs: Int64 = 50

    static let defaultSleep: @Sendable (Int64) async -> Void = { ms in
        try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
    }

    private let shared: Shared
    private let account: String
    private let sleep: @Sendable (Int64) async -> Void
    let clock: FileV2Clock

    init(clock: FileV2Clock = XferManualClock(), account: String = "alice",
         sleep: @escaping @Sendable (Int64) async -> Void = FakeFileV2Server.defaultSleep) {
        self.shared = Shared(core: FakeFileV2Core(config: FakeCoreConfig(), clock: clock))
        self.account = account
        self.sleep = sleep
        self.clock = clock
    }

    private init(shared: Shared, account: String, sleep: @escaping @Sendable (Int64) async -> Void, clock: FileV2Clock) {
        self.shared = shared
        self.account = account
        self.sleep = sleep
        self.clock = clock
    }

    /// Another account's view of the same server.
    func asAccount(_ name: String) -> FakeFileV2Server {
        FakeFileV2Server(shared: shared, account: name, sleep: sleep, clock: clock)
    }

    // MARK: Test controls

    private func config<T>(_ keyPath: WritableKeyPath<FakeCoreConfig, T>) -> T {
        shared.locked { shared.core.config[keyPath: keyPath] }
    }

    private func setConfig<T>(_ keyPath: WritableKeyPath<FakeCoreConfig, T>, _ value: T) {
        shared.locked { shared.core.config[keyPath: keyPath] = value }
    }

    /// The server has a token secret; without one only the owner reads and no token can be issued.
    var tokensEnabled: Bool {
        get { config(\.hasTokenSecret) }
        set { setConfig(\.hasTokenSecret, newValue) }
    }

    /// Free bytes of the server volume: create is 507 (no `Retry-After`) when less than 1 GiB would remain. `nil` is unknown.
    var freeBytes: Int64? {
        get { config(\.freeBytes) }
        set { setConfig(\.freeBytes, newValue) }
    }

    /// Server-wide cap on the declared size of unfinished objects (16 GiB): beyond it create is 507 with `Retry-After` 60.
    var maxUnfinishedBytes: Int64 {
        get { config(\.maxUnfinishedBytes) }
        set { setConfig(\.maxUnfinishedBytes, newValue) }
    }

    /// Unfinished objects one account may have (10 on the real server).
    var maxIncomplete: Int {
        get { config(\.maxIncompletePerUser) }
        set { setConfig(\.maxIncompletePerUser, newValue) }
    }

    var maxObjects: Int {
        get { config(\.maxObjectsPerUser) }
        set { setConfig(\.maxObjectsPerUser, newValue) }
    }

    var quota: Int64 {
        get { config(\.quota) }
        set { setConfig(\.quota, newValue) }
    }

    /// Part uploads one account may have in flight (16 on the real server). The `max_parallelism` of a create follows it
    /// when it is below 8.
    var maxPartsInFlight: Int {
        get { config(\.maxPartsInFlightPerUser) }
        set { setConfig(\.maxPartsInFlightPerUser, newValue) }
    }

    /// How long a create waits for its turn at the disk before 429 `create_busy` (10 s on the real server).
    var createGateWaitMs: Int64 {
        get { config(\.createGateWaitMs) }
        set { setConfig(\.createGateWaitMs, newValue) }
    }

    /// Completed objects are kept this long after completion: 30 days by default, 14 in production.
    var completedRetentionMs: Int64 {
        get { config(\.completedRetentionMs) }
        set { setConfig(\.completedRetentionMs, newValue) }
    }

    /// The `parallelism` a create tells the client (6).
    var parallelism: Int {
        get { config(\.recommendedParallelism) }
        set { setConfig(\.recommendedParallelism, newValue) }
    }

    var calls: [Call] { shared.locked { shared.calls } }

    var objectCount: Int { shared.locked { shared.core.objects.count } }

    /// The bytes of a stored part, or nil.
    func storedPart(obj: String, part: Int) -> Data? {
        shared.locked { shared.core.objects[obj]?.data[part] }
    }

    func revokeEntitlement(_ user: String) { shared.locked { shared.core.setFeature(user: XferName(user), enabled: false) } }

    func grantEntitlement(_ user: String) { shared.locked { shared.core.setFeature(user: XferName(user), enabled: true) } }

    func addGroupMember(group: String, user: String) {
        shared.locked { shared.core.setGroupMember(group: XferName(group), user: XferName(user), member: true) }
    }

    func removeGroupMember(group: String, user: String) {
        shared.locked { shared.core.setGroupMember(group: XferName(group), user: XferName(user), member: false) }
    }

    /// The group store fails: group lookups answer 500 `storage_error` instead of passing.
    func setGroupLookupFails(_ fails: Bool) { shared.locked { shared.core.groupLookupFails = fails } }

    /// The server's hourly worker (see `FakeFileV2Core.runCleanup`).
    func cleanup() { shared.locked { shared.core.runCleanup() } }

    /// Fails the next `times` calls of `op` (those of `part` when given) with `error`: before the call does anything, or
    /// after it has taken effect (the client sees a failure of a request the server has served).
    func injectFailure(_ op: FileV2Op, error: Error, times: Int = 1, part: Int? = nil, when: When = .beforeEffect) {
        shared.locked { shared.faults.append(Fault(op: op, error: error, times: times, part: part, when: when)) }
    }

    /// Every call of `op` (of `part` when given) takes `ms` of sleeper time, counted as in flight meanwhile.
    func injectDelay(_ op: FileV2Op, ms: Int64, part: Int? = nil) {
        shared.locked { shared.delays.append(DelayRule(op: op, ms: ms, part: part)) }
    }

    func clearDelays() { shared.locked { shared.delays.removeAll() } }

    func clearFaults() { shared.locked { shared.faults.removeAll() } }

    // MARK: The interface

    func create(_ request: FileV2CreateRequest) async throws -> FileV2Created {
        try begin(.create, nil)
        var members: [FakeJSON.Member] = [
            FakeJSON.Member(key: "blob_len", value: .int(request.blobLength)),
            FakeJSON.Member(key: "head", value: .string(XferSupport.base64(request.head))),
            FakeJSON.Member(key: "part_size", value: .int(Int64(request.partSize)))
        ]
        if let token = request.token { members.append(FakeJSON.Member(key: "token", value: tokenBody(token))) }
        var wire = FakeWireRequest(method: "POST", path: FileV2Wire.pathPrefix, user: account)
        wire.body = FakeJSON.object(members).serialized()
        let response = try await perform(wire, op: .create, part: nil)
        let created = try parseCreated(response)
        try finish(.create, nil)
        return created
    }

    func putPart(obj: String, part: Int, body: Data, sha256: Data) async throws -> FileV2PutResult {
        try begin(.putPart, part)
        var wire = FakeWireRequest(method: "PUT", path: objectPath(obj, "/parts/\(part)"), user: account)
        wire.headers.set("Content-Type", "application/octet-stream")
        wire.headers.set("Content-Digest", "sha-256=:" + XferSupport.base64(sha256) + ":")
        wire.body = body
        wire.contentLength = body.count
        let response = try await perform(wire, op: .putPart, part: part)
        guard let json = response.json, let number = json.member("part")?.intValue,
              let duplicate = json.member("duplicate")?.boolValue, let received = json.member("received")?.intValue,
              let parts = json.member("parts")?.intValue else { throw FileV2WireFormatError.malformedAnswer }
        try finish(.putPart, part)
        return FileV2PutResult(part: Int(number), duplicate: duplicate, received: Int(received), parts: Int(parts))
    }

    func partsMap(obj: String) async throws -> FileV2PartsMap {
        try begin(.partsMap, nil)
        let response = try await perform(FakeWireRequest(method: "GET", path: objectPath(obj, "/parts"), user: account),
                                         op: .partsMap, part: nil)
        guard let json = response.json, let blobLength = json.member("blob_len")?.intValue,
              let partSize = json.member("part_size")?.intValue, let parts = json.member("parts")?.intValue,
              let received = json.member("received")?.intValue, let complete = json.member("complete")?.boolValue,
              let map = json.member("map")?.stringValue, let bitmap = XferSupport.base64Decode(map) else {
            throw FileV2WireFormatError.malformedAnswer
        }
        let result = try FileV2PartsMap.fromWire(blobLength: blobLength, partSize: Int(partSize), parts: Int(parts),
                                                 received: Int(received), complete: complete, bitmap: bitmap)
        try finish(.partsMap, nil)
        return result
    }

    func complete(obj: String) async throws {
        try begin(.complete, nil)
        _ = try await perform(FakeWireRequest(method: "POST", path: objectPath(obj, "/complete"), user: account),
                              op: .complete, part: nil)
        try finish(.complete, nil)
    }

    func delete(obj: String) async throws {
        try begin(.delete, nil)
        _ = try await perform(FakeWireRequest(method: "DELETE", path: objectPath(obj, ""), user: account), op: .delete, part: nil)
        try finish(.delete, nil)
    }

    func issueToken(obj: String, scope: FileV2TokenRequest) async throws -> FileV2IssuedToken {
        try begin(.issueToken, nil)
        var wire = FakeWireRequest(method: "POST", path: objectPath(obj, "/token"), user: account)
        wire.body = tokenBody(scope).serialized()
        let response = try await perform(wire, op: .issueToken, part: nil)
        guard let token = parseToken(response.json) else { throw FileV2WireFormatError.malformedAnswer }
        try finish(.issueToken, nil)
        return token
    }

    func listUnfinished(limit: Int?, after: String?) async throws -> FileV2UnfinishedPage {
        try begin(.listUnfinished, nil)
        var query = "state=unfinished"
        if let limit = limit { query += "&limit=\(limit)" }
        if let after = after { query += "&after=" + FakeFileV2Server.queryEscape(after) }
        let response = try await perform(FakeWireRequest(method: "GET", path: FileV2Wire.pathPrefix + "?" + query, user: account),
                                         op: .listUnfinished, part: nil)
        guard let json = response.json, let items = json.member("objects")?.arrayValue else {
            throw FileV2WireFormatError.malformedAnswer
        }
        var objects = [FileV2UnfinishedItem]()
        for item in items {
            guard let obj = item.member("obj")?.stringValue, let blobLength = item.member("blob_len")?.intValue,
                  let parts = item.member("parts")?.intValue, let received = item.member("received")?.intValue,
                  let created = item.member("created_ms")?.intValue, let activity = item.member("activity_ms")?.intValue else {
                throw FileV2WireFormatError.malformedAnswer
            }
            objects.append(FileV2UnfinishedItem(obj: obj, blobLength: blobLength, parts: Int(parts), received: Int(received),
                                                createdMs: created, activityMs: activity))
        }
        try finish(.listUnfinished, nil)
        return FileV2UnfinishedPage(objects: objects, next: json.member("next")?.stringValue)
    }

    func deleteUnfinished() async throws -> FileV2BulkDeleteResult {
        try begin(.deleteUnfinished, nil)
        let response = try await perform(FakeWireRequest(method: "DELETE", path: FileV2Wire.pathPrefix + "?state=unfinished",
                                                         user: account), op: .deleteUnfinished, part: nil)
        guard let json = response.json, let deleted = json.member("deleted")?.intValue,
              let freed = json.member("freed_bytes")?.intValue else { throw FileV2WireFormatError.malformedAnswer }
        try finish(.deleteUnfinished, nil)
        return FileV2BulkDeleteResult(deleted: Int(deleted), freedBytes: freed)
    }

    func fetchRange(obj: String, from: Int64, toInclusive: Int64, token: FileV2DownloadAuth?,
                    waitSeconds: Int) async throws -> FileV2RangeResult {
        try begin(.fetchRange, nil)
        var wire = FakeWireRequest(method: "GET", path: objectPath(obj, ""), user: account)
        wire.headers.set("Range", "bytes=\(from)-\(toInclusive)")
        if waitSeconds > 0 { wire.headers.set("Prefer", "wait=\(waitSeconds)") }
        if let token = token {
            wire.headers.set("X-Download-Token", token.v)
            wire.headers.set("X-Download-Expires-Ms", String(token.expMs))
            wire.headers.set("X-Download-Max-Uses", String(token.max))
        }
        let response = try await perform(wire, op: .fetchRange, part: nil)
        guard let body = response.body, let range = response.headers.first("Content-Range"),
              let total = FakeFileV2Server.totalLength(ofContentRange: range) else { throw FileV2WireFormatError.malformedAnswer }
        try finish(.fetchRange, nil)
        return FileV2RangeResult(body: body, totalLength: total)
    }

    // MARK: Plumbing

    private func objectPath(_ obj: String, _ tail: String) -> String { FileV2Wire.pathPrefix + "/" + obj + tail }

    private func begin(_ op: FileV2Op, _ part: Int?) throws {
        try shared.locked {
            shared.calls.append(Call(op: op, part: part))
            try fire(op, part, .beforeEffect)
        }
    }

    private func finish(_ op: FileV2Op, _ part: Int?) throws {
        try shared.locked { try fire(op, part, .afterEffect) }
    }

    /// Called with the lock held.
    private func fire(_ op: FileV2Op, _ part: Int?, _ when: When) throws {
        guard let fault = shared.faults.first(where: {
            $0.op == op && $0.when == when && $0.times > 0 && ($0.part == nil || $0.part == part)
        }) else { return }
        fault.times -= 1
        throw fault.error
    }

    private func delayMs(_ op: FileV2Op, _ part: Int?) -> Int64 {
        shared.locked { shared.delays.filter { $0.op == op && ($0.part == nil || $0.part == part) }.reduce(0) { $0 + $1.ms } }
    }

    /// Serves one request. A call with an injected delay takes its time on the sleeper: an upload holds its slot and the lock of
    /// its part meanwhile, any other call waits first. A request the server keeps (a retry that waits for a busy part, a
    /// download that waits for parts) is looked at again every `pollMs` of sleeper time until it is answered or its wait ends.
    private func perform(_ request: FakeWireRequest, op: FileV2Op, part: Int?) async throws -> FakeWireResponse {
        let delay = delayMs(op, part)
        var wire = request
        if op == .putPart && delay > 0 { wire.upload = .stall(after: 0) }
        let outcome = shared.locked { shared.core.serve(wire, async: true) }
        let response: FakeWireResponse
        switch outcome {
        case .response(let answered):
            if delay > 0 && op != .putPart { await sleep(delay) }
            response = answered
        case .pending(let id):
            if op == .putPart && delay > 0 {
                await sleep(delay)
                response = shared.locked { shared.core.releaseUpload(id, sendRest: true) }
            } else {
                response = await waitFor(id)
            }
        }
        if let stuck = response.stuck { throw FakeServerTestBug(text: stuck) }
        if response.aborted { throw URLError(.networkConnectionLost) }
        if response.status >= 400 { throw serverError(response) }
        return response
    }

    private func waitFor(_ id: Int) async -> FakeWireResponse {
        let limit = shared.locked { shared.core.waitLimitMs(of: id) } ?? 0
        var waited: Int64 = 0
        while waited < limit {
            if let ready = shared.locked({ shared.core.takeIfReady(id) }) { return ready }
            await sleep(FakeFileV2Server.pollMs)
            waited += FakeFileV2Server.pollMs
        }
        return shared.locked { shared.core.awaitResult(id) }
    }

    // MARK: Typed values from answers

    private func tokenBody(_ token: FileV2TokenRequest) -> FakeJSON {
        var members = [FakeJSON.Member]()
        if let user = token.recipientUserID { members.append(FakeJSON.Member(key: "recipient_user_id", value: .string(user))) }
        if let group = token.groupID { members.append(FakeJSON.Member(key: "group_id", value: .string(group))) }
        if let ttl = token.ttlSeconds { members.append(FakeJSON.Member(key: "ttl_seconds", value: .int(ttl))) }
        if let uses = token.maxUses { members.append(FakeJSON.Member(key: "max_uses", value: .int(Int64(uses)))) }
        return .object(members)
    }

    private func parseToken(_ json: FakeJSON?) -> FileV2IssuedToken? {
        guard let json = json, let v = json.member("v")?.stringValue, let exp = json.member("exp")?.intValue,
              let max = json.member("max")?.intValue, let scope = json.member("scope")?.stringValue else { return nil }
        return FileV2IssuedToken(v: v, exp: exp, max: Int(max), scope: scope)
    }

    private func parseCreated(_ response: FakeWireResponse) throws -> FileV2Created {
        guard let json = response.json, let obj = json.member("obj")?.stringValue,
              let blobLength = json.member("blob_len")?.intValue, let partSize = json.member("part_size")?.intValue,
              let parts = json.member("parts")?.intValue, let parallelism = json.member("parallelism")?.intValue,
              let maxParallelism = json.member("max_parallelism")?.intValue else { throw FileV2WireFormatError.malformedAnswer }
        return FileV2Created(obj: obj, blobLength: blobLength, partSize: Int(partSize), parts: Int(parts),
                             parallelism: Int(parallelism), maxParallelism: Int(maxParallelism),
                             token: parseToken(json.member("token")), existing: json.member("existing")?.boolValue ?? false,
                             received: Int(json.member("received")?.intValue ?? 0),
                             complete: json.member("complete")?.boolValue ?? false)
    }

    private func serverError(_ response: FakeWireResponse) -> FileV2ServerError {
        let json = response.json
        var retryAfter: Int?
        if let header = response.headers.first("Retry-After") {
            retryAfter = FileV2RetryAfter.seconds(from: header, nowMs: clock.nowMs())
        }
        let missing = (json?.member("missing")?.arrayValue ?? []).compactMap { $0.intValue }.map { Int($0) }
        var details = FileV2ErrorDetails()
        details.used = json?.member("used")?.intValue
        details.limit = json?.member("limit")?.intValue
        details.maxBlobLength = json?.member("max_blob_len")?.intValue
        details.partSize = json?.member("part_size")?.intValue
        details.expected = json?.member("expected")?.intValue
        details.parts = json?.member("parts")?.intValue
        details.firstPart = json?.member("first_part")?.intValue
        details.lastPart = json?.member("last_part")?.intValue
        details.feature = json?.member("feature")?.stringValue
        details.packageName = json?.member("package")?.stringValue
        return FileV2ServerError(status: response.status, code: response.errorCode ?? "", retryAfter: retryAfter,
                                 missing: missing, details: details)
    }

    private static func totalLength(ofContentRange value: String) -> Int64? {
        // `bytes a-b/total`
        guard let slash = value.utf8.lastIndex(of: 0x2F) else { return nil }
        return Int64(String(decoding: Array(value.utf8[value.utf8.index(after: slash)...]), as: UTF8.self))
    }

    private static func queryEscape(_ text: String) -> String {
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
}

/// A request that cannot finish, which only a bug of the test can cause.
struct FakeServerTestBug: Error, CustomStringConvertible {
    let text: String

    var description: String { "FakeFileV2Server test bug: " + text }
}
