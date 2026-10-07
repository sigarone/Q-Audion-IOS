import Foundation
import CryptoKit
@testable import QAudionEngine

// Part upload, parts map, complete and delete: handler.go handlePutPart, handleGetParts, handleComplete, handleDelete and
// store.go markPart, completeObject, deleteObject.

extension FakeFileV2Core {

    enum DigestFailure: Error {
        case required
        case invalid
    }

    // MARK: Content-Digest (RFC 9530), handler.go parseContentDigest

    private static func trimSpace(_ bytes: [UInt8]) -> [UInt8] {
        func space(_ byte: UInt8) -> Bool { byte == 0x20 || (byte >= 0x09 && byte <= 0x0D) }
        var start = 0
        var end = bytes.count
        while start < end, space(bytes[start]) { start += 1 }
        while end > start, space(bytes[end - 1]) { end -= 1 }
        return Array(bytes[start..<end])
    }

    /// The sha-256 member of the `Content-Digest` header values: another algorithm is ignored, the sha-256 member must be a
    /// byte sequence (`:base64:`) of 32 bytes and appear once.
    static func parseContentDigest(_ values: [String]) -> Result<Data, DigestFailure> {
        var found: Data?
        for value in values {
            for member in Array(value.utf8).split(separator: 0x2C, omittingEmptySubsequences: false) {
                let trimmed = trimSpace(Array(member))
                guard let equals = trimmed.firstIndex(of: 0x3D) else { continue }
                let key = asciiFold(String(decoding: trimSpace(Array(trimmed[..<equals])), as: UTF8.self))
                guard key == Array("sha-256".utf8) else { continue }
                let item = trimSpace(Array(trimmed[(equals + 1)...]))
                guard item.count >= 2, item[0] == 0x3A, item[item.count - 1] == 0x3A else { return .failure(.invalid) }
                let inner = String(decoding: item[1..<item.count - 1], as: UTF8.self)
                guard let sum = XferSupport.base64Decode(inner), sum.count == 32, found == nil else { return .failure(.invalid) }
                found = sum
            }
        }
        guard let digest = found else { return .failure(.required) }
        return .success(digest)
    }

    /// A canonical non-negative integer of at most 6 digits: no sign, no leading zero, no other character.
    static func canonicalPart(_ text: String) -> Int? {
        let bytes = Array(text.utf8)
        guard (1...6).contains(bytes.count), bytes.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        if bytes.count > 1 && bytes[0] == 0x30 { return nil }
        return bytes.reduce(0) { $0 * 10 + Int($1 - 0x30) }
    }

    // MARK: Part upload

    func handlePutPart(_ request: FakeWireRequest, user: XferName, obj: String, partText: String,
                       async: Bool) -> FakeOutcome {
        guard let part = FakeFileV2Core.canonicalPart(partText) else {
            return .response(failure(400, "bad_part", "part index is not a canonical non-negative integer"))
        }
        guard let object = objects[obj] else { return .response(notFound()) }
        guard object.owner == user else { return .response(failure(403, "not_owner")) }
        guard part < object.parts else {
            return .response(failure(400, "bad_part", "part index out of range", extra: [("parts", .int(Int64(object.parts)))]))
        }
        let want = FileV2Wire.partLength(blobLength: object.blobLength, part: part)
        guard let length = request.contentLength else {
            return .response(failure(411, "length_required", "Content-Length is required"))
        }
        guard length == want else {
            return .response(failure(400, "bad_length", "Content-Length must be the exact length of the part",
                                     extra: [("expected", .int(Int64(want)))]))
        }
        let digest: Data
        switch FakeFileV2Core.parseContentDigest(request.headers.values("Content-Digest")) {
        case .success(let sum):
            digest = sum
        case .failure(let why):
            let code = why == .required ? "digest_required" : "digest_invalid"
            let message = why == .required ? "Content-Digest with sha-256 is required"
                : "Content-Digest sha-256 is not a valid RFC 9530 byte sequence of 32 bytes"
            return .response(failure(400, code, message, headers: [("Want-Content-Digest", "sha-256=10")]))
        }

        // at most MaxPartsInFlightPerUser uploads of one account run at once, refused before the body is read
        if (partsInFlight[user] ?? 0) >= config.maxPartsInFlightPerUser {
            return .response(failure(429, "too_many_parts_in_flight", "too many part uploads in flight",
                                     headers: [("Retry-After", "1")]))
        }
        partsInFlight[user, default: 0] += 1

        let state = UploadState(user: user, obj: obj, part: part, partText: partText, digest: digest, want: want,
                                body: request.body, mode: request.upload)
        // one writer per (object, part): a retry that overlaps the original waits for it, up to partLockWaitMs
        if lockHolder[state.lockKey] != nil {
            if async {
                let id = newID()
                lockWaiters[state.lockKey, default: []].append(id)
                pending[id] = Pending(id: id, kind: .queuedUpload(state))
                return .pending(id)
            }
            advanceTimer(ms: config.partLockWaitMs)
            partsInFlight[user, default: 1] -= 1
            return .response(failure(429, "part_busy", "this part is being uploaded by another request",
                                     headers: [("Retry-After", "2")]))
        }
        let id = newID()
        lockHolder[state.lockKey] = id
        return runUpload(state, id: id)
    }

    /// The upload holds a slot and the lock of its part. A part already on the server never changes again: the same digest is
    /// a duplicate, another digest a conflict decided before a byte is read. Otherwise the body is read, checked and marked.
    func runUpload(_ state: UploadState, id: Int) -> FakeOutcome {
        if let current = objects[state.obj]?.digests[state.part] {
            if current != state.digest {
                return .response(endUpload(state, id: id, failure(409, "part_conflict",
                                                                   "this part was already received with a different digest")))
            }
            switch state.mode {
            case .stall(let after) where after < state.body.count:
                return hold(state, id: id, duplicate: true)
            case .abort(let after) where after < state.body.count:
                return .response(endUpload(state, id: id, abortedResponse()))
            default:
                return .response(endUpload(state, id: id, duplicateAnswer(state)))
            }
        }
        switch state.mode {
        case .stall(let after) where after < state.body.count:
            return hold(state, id: id, duplicate: false)
        case .abort(let after) where after < state.body.count:
            return .response(endUpload(state, id: id, abortedResponse()))
        case .halfClose(let after) where after < state.body.count:
            return .response(endUpload(state, id: id, failure(400, "short_body", "the request body ended before Content-Length")))
        default:
            return .response(endUpload(state, id: id, consume(state)))
        }
    }

    private func hold(_ state: UploadState, id: Int, duplicate: Bool) -> FakeOutcome {
        pending[id] = Pending(id: id, kind: .holdingUpload(state, duplicate: duplicate))
        return .pending(id)
    }

    func abortedResponse() -> FakeWireResponse {
        var response = FakeWireResponse(status: 0)
        response.aborted = true
        return response
    }

    /// The answer to a retry of a part that is already on the server: the object as it is now, not as it was.
    func duplicateAnswer(_ state: UploadState) -> FakeWireResponse {
        guard let fresh = objects[state.obj] else { return notFound() }
        return answer(200, [("part", .int(Int64(state.part))), ("duplicate", .bool(true)),
                            ("received", .int(Int64(fresh.done))), ("parts", .int(Int64(fresh.parts)))])
    }

    /// The whole body has been read: the digest, then the mark.
    func consume(_ state: UploadState) -> FakeWireResponse {
        guard XferSupport.sha256(state.body) == state.digest else {
            return failure(400, "digest_mismatch", "the body does not match Content-Digest; send the part again")
        }
        guard let object = objects[state.obj] else { return notFound() }
        if let current = object.digests[state.part] {
            if current != state.digest {
                return failure(409, "part_conflict", "this part was already received with a different digest")
            }
            return duplicateAnswer(state)
        }
        object.data[state.part] = state.body
        object.digests[state.part] = state.digest
        object.activityMs = clock.nowMs()
        var response = answer(200, [("part", .int(Int64(state.part))), ("duplicate", .bool(false)),
                                    ("received", .int(Int64(object.done))), ("parts", .int(Int64(object.parts)))])
        response.headers.set("Server-Timing", "write;dur=0, sync;dur=0, db;dur=0, total;dur=0")
        return response
    }

    /// The request is over: its slot and the lock of its part are free, and the retry that waited for the lock goes on.
    func endUpload(_ state: UploadState, id: Int, _ response: FakeWireResponse) -> FakeWireResponse {
        partsInFlight[state.user, default: 1] -= 1
        let key = state.lockKey
        lockHolder[key] = nil
        if var waiting = lockWaiters[key], !waiting.isEmpty {
            let next = waiting.removeFirst()
            lockWaiters[key] = waiting.isEmpty ? nil : waiting
            lockHolder[key] = next
            resumeQueued(next)
        }
        return response
    }

    private func resumeQueued(_ id: Int) {
        guard let queued = pending[id], case .queuedUpload(let state) = queued.kind else { return }
        switch runUpload(state, id: id) {
        case .response(let response):
            queued.response = response
        case .pending:
            break   // it holds the lock now (a stalled retry): `hold` replaced the record
        }
    }

    /// Lets a stalled upload finish: the rest of its body arrives (`sendRest`) or the connection is dropped.
    func releaseUpload(_ id: Int, sendRest: Bool) -> FakeWireResponse {
        guard let held = pending[id], case .holdingUpload(let state, let duplicate) = held.kind else {
            var stuck = FakeWireResponse(status: 0)
            stuck.stuck = "no stalled upload is waiting under this name"
            return stuck
        }
        pending[id] = nil
        let response: FakeWireResponse
        if !sendRest {
            response = abortedResponse()
        } else if duplicate {
            response = duplicateAnswer(state)
        } else {
            response = consume(state)
        }
        let outcome = endUpload(state, id: id, response)
        pumpDownloads()
        return outcome
    }

    // MARK: Parts map, complete, delete

    func handleGetParts(user: XferName, obj: String) -> FakeWireResponse {
        guard let object = objects[obj] else { return notFound() }
        guard object.owner == user else { return failure(403, "not_owner") }
        var bitmap = [UInt8](repeating: 0, count: (object.parts + 7) / 8)
        for part in object.digests.keys where part >= 0 && part < object.parts { bitmap[part / 8] |= UInt8(1) << UInt8(part % 8) }
        return answer(200, [
            ("blob_len", .int(object.blobLength)), ("part_size", .int(Int64(FileV2Wire.partSize))),
            ("parts", .int(Int64(object.parts))), ("received", .int(Int64(object.done))),
            ("complete", .bool(object.completedMs != 0)), ("map", .string(Data(bitmap).base64EncodedString()))
        ])
    }

    func handleComplete(user: XferName, obj: String) -> FakeWireResponse {
        guard let object = objects[obj] else { return notFound() }
        guard object.owner == user else { return failure(403, "not_owner") }
        if object.completedMs == 0 {
            if object.done != object.parts {
                var missing = [FakeJSON]()
                for part in 0..<object.parts where object.digests[part] == nil {
                    if missing.count == 32 { break }
                    missing.append(.int(Int64(part)))
                }
                return failure(409, "incomplete", "not every part has been received",
                               extra: [("parts", .int(Int64(object.parts))), ("missing", .array(missing))])
            }
            let now = clock.nowMs()
            object.completedMs = now
            object.activityMs = now
        }
        return answer(200, [("complete", .bool(true)), ("blob_len", .int(object.blobLength)),
                            ("parts", .int(Int64(object.parts)))])
    }

    func handleDelete(user: XferName, obj: String) -> FakeWireResponse {
        guard let object = objects[obj] else { return notFound() }
        guard object.owner == user else { return failure(403, "not_owner") }
        remove(object)
        var response = FakeWireResponse(status: 204)
        response.headers.set("Cache-Control", "no-store")
        return response
    }

    /// The rows go first (from then on every request finds nothing, and waiting downloads are woken with 404), then the blob,
    /// then the part and counter rows.
    func remove(_ object: Object) {
        objects[object.id] = nil
        let key = HeadKey(owner: object.owner, hash: object.headHash)
        if byHead[key] == object.id { byHead[key] = nil }
        for counterKey in counters.keys where counterKey.obj == object.id { counters[counterKey] = nil }
    }
}
