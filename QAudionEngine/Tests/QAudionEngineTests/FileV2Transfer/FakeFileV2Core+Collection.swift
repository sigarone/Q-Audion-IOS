import Foundation
@testable import QAudionEngine

// The collection routes (bulk.go), the cleanup worker (cleanup.go) and the controls the tests use to drive the server.

extension FakeFileV2Core {

    static let listDefaultLimit = 20
    static let listMaxLimit = 100
    /// storage.RetentionBatchSize: the most objects one bulk delete takes.
    static let bulkDeleteMax = 200

    struct Query {
        var items: [(key: [UInt8], value: [UInt8])] = []

        func values(_ key: String) -> [[UInt8]] {
            let wanted = Array(key.utf8)
            return items.filter { $0.key == wanted }.map { $0.value }
        }

        func has(_ key: String) -> Bool { !values(key).isEmpty }

        func first(_ key: String) -> [UInt8] { values(key).first ?? [] }
    }

    /// `url.ParseQuery`: `&`-separated pairs, no `;`, `%xx` and `+` unescaped; any malformed pair makes the whole query malformed.
    static func parseQuery(_ raw: [UInt8]) -> Query? {
        var query = Query()
        var malformed = false
        for segment in raw.split(separator: 0x26, omittingEmptySubsequences: false) {
            let pair = Array(segment)
            if pair.isEmpty { continue }
            if pair.contains(0x3B) {
                malformed = true
                continue
            }
            let key: [UInt8]
            let value: [UInt8]
            if let equals = pair.firstIndex(of: 0x3D) {
                key = Array(pair[..<equals])
                value = Array(pair[(equals + 1)...])
            } else {
                key = pair
                value = []
            }
            guard let decodedKey = percentDecode(key, plusIsSpace: true),
                  let decodedValue = percentDecode(value, plusIsSpace: true) else {
                malformed = true
                continue
            }
            query.items.append((key: decodedKey, value: decodedValue))
        }
        return malformed ? nil : query
    }

    /// `state=unfinished` is mandatory (no request can ever mean "everything"), every parameter must be one of `allowed`, and
    /// none may be repeated or malformed. The message of the refusal, or the query.
    func parseCollectionQuery(_ raw: [UInt8]?, allowed: [String]) -> (query: Query?, message: String?) {
        guard let query = FakeFileV2Core.parseQuery(raw ?? []) else { return (nil, "the query string is malformed") }
        let allowedBytes = allowed.map { Array($0.utf8) }
        for item in query.items {
            if !allowedBytes.contains(item.key) { return (nil, "unknown query parameter") }
            if query.items.filter({ $0.key == item.key }).count != 1 { return (nil, "query parameters must not be repeated") }
        }
        if query.first("state") != Array("unfinished".utf8) { return (nil, "state=unfinished is required") }
        return (query, nil)
    }

    // MARK: List

    func handleListUnfinished(user: XferName, query raw: [UInt8]?) -> FakeWireResponse {
        let parsed = parseCollectionQuery(raw, allowed: ["state", "limit", "after"])
        guard let query = parsed.query else {
            return failure(400, "bad_request", parsed.message ?? "bad query")
        }
        var limit = FakeFileV2Core.listDefaultLimit
        if query.has("limit") {
            // canonical decimal, 1 to 100: `strconv.Itoa(n) != v` refuses a sign and a leading zero
            let text = query.first("limit")
            guard let number = FakeFileV2Core.goAtoi(text), number >= 1, number <= Int64(FakeFileV2Core.listMaxLimit),
                  Array(String(number).utf8) == text else {
                return failure(400, "bad_request", "limit must be an integer from 1 to \(FakeFileV2Core.listMaxLimit)")
            }
            limit = Int(number)
        }
        let after = query.first("after")
        if query.has("after") && !FakeFileV2Core.isObjectID(after) {
            return failure(400, "bad_request", "after must be an object id from a previous page")
        }
        // the owner's rows in object id order, after the cursor (a cursor that names no object works the same)
        let rows = objects.values.filter { $0.owner == user && $0.completedMs == 0 }
            .sorted { Array($0.id.utf8).lexicographicallyPrecedes(Array($1.id.utf8)) }
            .filter { !query.has("after") || after.lexicographicallyPrecedes(Array($0.id.utf8)) }
        var items = [FakeJSON]()
        var next: String?
        for object in rows {
            if items.count == limit {
                next = rows[limit - 1].id
                break
            }
            items.append(.obj([
                ("obj", .string(object.id)), ("blob_len", .int(object.blobLength)), ("parts", .int(Int64(object.parts))),
                ("received", .int(Int64(object.done))), ("created_ms", .int(object.createdMs)),
                ("activity_ms", .int(object.activityMs))
            ]))
        }
        var fields: [(String, FakeJSON)] = [("objects", .array(items))]
        if let next = next { fields.append(("next", .string(next))) }
        return answer(200, fields)
    }

    // MARK: Delete

    func handleDeleteUnfinished(user: XferName, query raw: [UInt8]?) -> FakeWireResponse {
        let parsed = parseCollectionQuery(raw, allowed: ["state"])
        guard parsed.query != nil else { return failure(400, "bad_request", parsed.message ?? "bad query") }
        let victims = objects.values.filter { $0.owner == user && $0.completedMs == 0 }
            .sorted { Array($0.id.utf8).lexicographicallyPrecedes(Array($1.id.utf8)) }
            .prefix(FakeFileV2Core.bulkDeleteMax)
        var freed: Int64 = 0
        for object in victims {
            freed += object.blobLength
            remove(object)
        }
        return answer(200, [("deleted", .int(Int64(victims.count))), ("freed_bytes", .int(freed))])
    }

    // MARK: Cleanup (cleanup.go cleanupOnce)

    /// One pass of the hourly worker. A completed object goes `completedRetentionMs` after its completion; an unfinished one
    /// goes `incompleteAbandonMs` after its last part (after its creation if it never got one) and in any case
    /// `incompleteMaxLifetimeMs` after its creation. The comparisons are strict.
    func runCleanup() {
        let now = clock.nowMs()
        let completedCut = now - config.completedRetentionMs
        let abandonCut = now - config.incompleteAbandonMs
        let lifetimeCut = now - config.incompleteMaxLifetimeMs
        let victims = objects.values.filter { object in
            if object.completedMs != 0 { return object.completedMs < completedCut }
            return object.activityMs < abandonCut || object.createdMs < lifetimeCut
        }
        for object in victims { remove(object) }
        pumpDownloads()
    }

    // MARK: Controls

    /// `hold_create_gate`: the next create that would make a NEW object takes its turn at the disk and stays there.
    func holdNextCreate() { holdCreateGate = true }

    /// `release_create_gate`: lets the create that waits at the disk go on. Returns its id when there was one.
    @discardableResult
    func releaseCreateGate() -> Int? {
        holdCreateGate = false
        guard let id = gateHolder, let record = pending[id], case .createAtGate(let state) = record.kind else { return nil }
        record.response = makeObject(state)
        pumpDownloads()
        return id
    }

    /// `hold_download_slots`: occupies download slots of an account, as if the downloads were running.
    func holdDownloadSlots(user: XferName, count: Int) {
        heldDownloadSlots[user, default: 0] += count
        downloadsInFlight[user, default: 0] += count
    }

    /// `release_download_slots`: frees every slot held for that account.
    func releaseDownloadSlots(user: XferName) {
        let held = heldDownloadSlots[user] ?? 0
        heldDownloadSlots[user] = nil
        downloadsInFlight[user, default: held] -= held
    }

    func setGroupMember(group: XferName, user: XferName, member: Bool) {
        if member {
            groupMembers[group, default: []].insert(user)
        } else {
            groupMembers[group]?.remove(user)
        }
    }

    func setFeature(user: XferName, enabled: Bool) {
        if enabled {
            withoutFeature.remove(user)
        } else {
            withoutFeature.insert(user)
        }
    }

    /// `restart_server`: the server stops and starts again over the same storage. Objects, parts, tokens and counters survive;
    /// what lived in memory (the locks, the slots, the turn at the disk) does not. Nothing may be in flight: false when
    /// something is.
    @discardableResult
    func restart() -> Bool {
        let clean = pending.isEmpty
        lockHolder = [:]
        lockWaiters = [:]
        partsInFlight = [:]
        downloadsInFlight = [:]
        heldDownloadSlots = [:]
        gateHolder = nil
        holdCreateGate = false
        return clean
    }

    /// How long the server keeps the pending request `id` before it gives up on it: the wait of a download for its parts (the
    /// requested wait, capped), the wait of a retry for the lock of a busy part.
    func waitLimitMs(of id: Int) -> Int64? {
        switch pending[id]?.kind {
        case .waitingDownload(let state)?: return state.waitMs
        case .queuedUpload?: return config.partLockWaitMs
        default: return nil
        }
    }

    /// The answer of a request the server kept, if it is ready; nothing moves otherwise.
    func takeIfReady(_ id: Int) -> FakeWireResponse? {
        pumpDownloads()
        guard let record = pending[id], let response = record.response else { return nil }
        pending[id] = nil
        return response
    }

    /// The answer of a request the server kept. A download that is still waiting for its parts is answered as its wait ends (the
    /// timer clock moves by the wait); a retry that still waits for a busy part, as its wait for the lock ends.
    func awaitResult(_ id: Int) -> FakeWireResponse {
        guard let record = pending[id] else {
            var stuck = FakeWireResponse(status: 0)
            stuck.stuck = "nothing is pending under this name"
            return stuck
        }
        if let response = record.response {
            pending[id] = nil
            return response
        }
        switch record.kind {
        case .queuedUpload(let state):
            advanceTimer(ms: config.partLockWaitMs)
            lockWaiters[state.lockKey]?.removeAll { $0 == id }
            partsInFlight[state.user, default: 1] -= 1
            pending[id] = nil
            return failure(429, "part_busy", "this part is being uploaded by another request", headers: [("Retry-After", "2")])
        case .waitingDownload(let state):
            advanceTimer(ms: state.waitMs)
            downloadsInFlight[state.user, default: 1] -= 1
            pending[id] = nil
            return notYetReceived(first: state.first, last: state.last, carried: state.headers)
        case .holdingUpload:
            var stuck = FakeWireResponse(status: 0)
            stuck.stuck = "a stalled upload is released, not awaited"
            return stuck
        case .createAtGate:
            var stuck = FakeWireResponse(status: 0)
            stuck.stuck = "the create is held at the gate: release the gate first"
            return stuck
        }
    }
}
