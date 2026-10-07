import Foundation
import CryptoKit
@testable import QAudionEngine

// Create and the download tokens: handler.go handleCreate and handleToken, store.go createObject and admit, token.go.

extension FakeFileV2Core {

    struct IssuedToken {
        let v: String
        let exp: Int64
        let max: Int64
        let scope: String

        var json: FakeJSON {
            .obj([("v", .string(v)), ("exp", .int(exp)), ("max", .int(max)), ("scope", .string(scope))])
        }
    }

    enum Admission {
        case ok
        case tooManyObjects
        case tooManyUploads
        case quota(used: Int64)
        case unfinishedCap
    }

    enum Lookup {
        case existing(Object)
        case refused(FakeWireResponse)
        case proceed
    }

    static let tokenLabel = Array("qaudion-files-v2-token\u{0}".utf8)
    static let defaultTokenTTLSeconds: Int64 = 7 * 86_400
    static let maxTokenTTLSeconds: Int64 = 30 * 86_400
    static let defaultTokenMaxUses: Int64 = 10
    static let maxTokenMaxUses: Int64 = 1000
    static let maxGroupsPerObject = 8

    // MARK: Create

    func handleCreate(_ request: FakeWireRequest, user: XferName) -> FakeOutcome {
        if let refusal = requireFeature(user) { return .response(refusal) }
        let blobLength: Int64
        let headText: String
        let partSize: Int64
        var token: TokenRequest?
        do {
            let fields = try decodeObject(request.body, fields: ["blob_len", "head", "part_size", "token"])
            blobLength = try decodeInteger(fields["blob_len"], bits: 64)
            headText = try decodeString(fields["head"])
            partSize = try decodeInteger(fields["part_size"], bits: 64)
            if let raw = fields["token"], !raw.isNull { token = try decodeTokenRequest(raw) }
        } catch {
            return .response(failure(400, "bad_request", "the body is not the JSON object the route takes"))
        }
        if blobLength <= Int64(FileV2.headerLength) {
            return .response(failure(400, "bad_blob_len", "blob_len must be larger than the 64-byte header"))
        }
        if blobLength > Int64(FileV2.maxBlob) {
            return .response(failure(413, "blob_too_large", "blob_len exceeds the maximum object size",
                                     extra: [("max_blob_len", .int(Int64(FileV2.maxBlob)))]))
        }
        if partSize != Int64(FileV2Wire.partSize) {
            return .response(failure(400, "bad_part_size", "part_size must be exactly the protocol part size",
                                     extra: [("part_size", .int(Int64(FileV2Wire.partSize)))]))
        }
        guard let head = XferSupport.base64Decode(headText), head.count == FileV2.headerLength else {
            return .response(failure(400, "bad_head", "head must be 64 bytes in standard base64"))
        }
        var ttl: Int64 = 0
        if let requested = token {
            switch precheckToken(owner: user, requested) {
            case .success(let seconds): ttl = seconds
            case .failure(let refusal): return .response(refusal.response)
            }
        }
        let state = CreateState(user: user, blobLength: blobLength, head: head, headHash: XferSupport.sha256(head),
                                token: token, ttlSeconds: ttl)
        return createObject(state)
    }

    /// store.go createObject: look, take the turn at the disk, look again, make the blob, insert.
    func createObject(_ state: CreateState) -> FakeOutcome {
        switch lookupOrAdmit(state) {
        case .existing(let object): return .response(finishCreate(state, object: object, existing: true))
        case .refused(let response): return .response(response)
        case .proceed: break
        }
        if gateHolder != nil {
            advanceTimer(ms: config.createGateWaitMs)
            return .response(failure(429, "create_busy", "too many uploads are being created, try again",
                                     headers: [("Retry-After", "2")]))
        }
        let gate = newID()
        gateHolder = gate
        switch lookupOrAdmit(state) {
        case .existing(let object):
            gateHolder = nil
            return .response(finishCreate(state, object: object, existing: true))
        case .refused(let response):
            gateHolder = nil
            return .response(response)
        case .proceed: break
        }
        if holdCreateGate {
            holdCreateGate = false
            pending[gate] = Pending(id: gate, kind: .createAtGate(state))
            return .pending(gate)
        }
        return .response(makeObject(state))
    }

    /// The rest of a create after the turn at the disk: the free-space floor, the rows, the token. Releases the turn.
    func makeObject(_ state: CreateState) -> FakeWireResponse {
        defer { gateHolder = nil }
        if let free = config.freeBytes, free - state.blobLength < config.minFreeBytes {
            return failure(507, "insufficient_storage", "the server has no room for this object")
        }
        // the transaction that inserts the rows checks once more, and is the authoritative check
        switch lookupOrAdmit(state) {
        case .existing(let object): return finishCreate(state, object: object, existing: true)
        case .refused(let response): return response
        case .proceed: break
        }
        let object = Object(id: UUID().uuidString.lowercased(), owner: state.user, blobLength: state.blobLength,
                            head: state.head, headHash: state.headHash, nowMs: clock.nowMs())
        objects[object.id] = object
        byHead[HeadKey(owner: state.user, hash: state.headHash)] = object.id
        return finishCreate(state, object: object, existing: false)
    }

    private func finishCreate(_ state: CreateState, object: Object, existing: Bool) -> FakeWireResponse {
        var issued: IssuedToken?
        if let requested = state.token {
            switch issueFor(object: object, owner: state.user, requested, ttlSeconds: state.ttlSeconds) {
            case .success(let token): issued = token
            case .failure(let refusal): return refusal.response
            }
        }
        var fields: [(String, FakeJSON)] = [
            ("obj", .string(object.id)), ("blob_len", .int(object.blobLength)),
            ("part_size", .int(Int64(FileV2Wire.partSize))), ("parts", .int(Int64(object.parts))),
            ("parallelism", .int(Int64(config.recommendedParallelism))),
            ("max_parallelism", .int(Int64(maxParallelism)))
        ]
        if existing { fields.append(("existing", .bool(true))) }
        if object.done > 0 { fields.append(("received", .int(Int64(object.done)))) }
        if object.completedMs != 0 { fields.append(("complete", .bool(true))) }
        if let issued = issued { fields.append(("token", issued.json)) }
        return answer(existing ? 200 : 201, fields, headers: [("Location", FileV2Wire.pathPrefix + "/" + object.id)])
    }

    /// What the server tells the client it may run per object: its in-flight cap per account when that is below 8.
    var maxParallelism: Int { config.maxPartsInFlightPerUser < 8 ? config.maxPartsInFlightPerUser : 8 }

    // MARK: Limits (store.go ownerUsage, admit, lookupOrAdmit)

    func admit(owner: XferName, blobLength: Int64) -> Admission {
        var rows = 0
        var bytes: Int64 = 0
        var unfinished = 0
        for object in objects.values where object.owner == owner {
            rows += 1
            bytes += object.blobLength
            if object.completedMs == 0 { unfinished += 1 }
        }
        if rows >= config.maxObjectsPerUser { return .tooManyObjects }
        if unfinished >= config.maxIncompletePerUser { return .tooManyUploads }
        if bytes + blobLength > config.quota { return .quota(used: bytes) }
        let open = objects.values.filter { $0.completedMs == 0 }.reduce(Int64(0)) { $0 + $1.blobLength }
        if open + blobLength > config.maxUnfinishedBytes { return .unfinishedCap }
        return .ok
    }

    func lookupOrAdmit(_ state: CreateState) -> Lookup {
        if let id = byHead[HeadKey(owner: state.user, hash: state.headHash)], let object = objects[id] {
            if object.blobLength != state.blobLength {
                return .refused(failure(409, "head_conflict", "an object with this header and another length exists"))
            }
            return .existing(object)
        }
        switch admit(owner: state.user, blobLength: state.blobLength) {
        case .ok:
            return .proceed
        case .tooManyObjects:
            return .refused(failure(429, "too_many_objects", "too many stored objects"))
        case .tooManyUploads:
            return .refused(failure(429, "too_many_uploads", "too many uploads in flight",
                                    extra: [("limit", .int(Int64(config.maxIncompletePerUser)))],
                                    headers: [("Retry-After", "30")]))
        case .quota(let used):
            return .refused(failure(413, "quota_exceeded", "storage quota exceeded",
                                    extra: [("used", .int(used)), ("limit", .int(config.quota))]))
        case .unfinishedCap:
            return .refused(failure(507, "insufficient_storage", "the server has no room for another upload right now",
                                    headers: [("Retry-After", "60")]))
        }
    }

    // MARK: Token requests (handler.go decode, checkTokenRequest, precheckToken, issueFor)

    struct TokenRefusal: Error {
        let response: FakeWireResponse
    }

    func decodeTokenRequest(_ value: FakeJSON) throws -> TokenRequest {
        let fields = try decodeMembers(value, fields: ["recipient_user_id", "group_id", "ttl_seconds", "max_uses"])
        var request = TokenRequest()
        request.recipient = try decodeString(fields["recipient_user_id"])
        request.group = try decodeString(fields["group_id"])
        request.ttlSeconds = try decodeInteger(fields["ttl_seconds"], bits: 64)
        request.maxUses = try decodeInteger(fields["max_uses"], bits: 32)
        return request
    }

    private func validUserID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard !bytes.isEmpty, bytes.count <= 64 else { return false }
        return bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    private func validGroupID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard bytes.count >= 8, bytes.count <= 64 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D || byte == 0x5F
        }
    }

    /// The TTL in seconds, or the message of the refusal.
    private func checkTokenRequest(_ request: TokenRequest) -> (ttl: Int64, message: String?) {
        if request.recipient.isEmpty == request.group.isEmpty {
            return (0, "exactly one of recipient_user_id and group_id is required")
        }
        if !request.recipient.isEmpty && !validUserID(request.recipient) { return (0, "recipient_user_id is not valid") }
        if !request.group.isEmpty && !validGroupID(request.group) { return (0, "group_id is not valid") }
        if request.ttlSeconds < 0 || request.ttlSeconds > FakeFileV2Core.maxTokenTTLSeconds {
            return (0, "ttl_seconds out of range")
        }
        if request.maxUses < 0 || request.maxUses > FakeFileV2Core.maxTokenMaxUses { return (0, "max_uses out of range") }
        return (request.ttlSeconds, nil)
    }

    /// Validates a token request BEFORE anything is created or changed: its shape, that the server can issue tokens at all and,
    /// for a group scope, that the group store is there and the owner is a member.
    func precheckToken(owner: XferName, _ request: TokenRequest) -> Result<Int64, TokenRefusal> {
        let checked = checkTokenRequest(request)
        if let message = checked.message {
            return .failure(TokenRefusal(response: failure(400, "bad_token_request", message)))
        }
        if !config.hasTokenSecret {
            return .failure(TokenRefusal(response: failure(503, "tokens_disabled",
                                                           "download tokens are not enabled on this server")))
        }
        if !request.group.isEmpty {
            if !config.hasGroupStore {
                return .failure(TokenRefusal(response: failure(503, "groups_unavailable", "group tokens are not available")))
            }
            if groupLookupFails { return .failure(TokenRefusal(response: storageError())) }
            if !isGroupMember(group: XferName(request.group), user: owner) {
                return .failure(TokenRefusal(response: failure(403, "not_group_member",
                                                               "the owner is not a member of this group")))
            }
        }
        return .success(checked.ttl)
    }

    func isGroupMember(group: XferName, user: XferName) -> Bool {
        groupMembers[group]?.contains(user) ?? false
    }

    private func issueFor(object: Object, owner: XferName, _ request: TokenRequest,
                          ttlSeconds: Int64) -> Result<IssuedToken, TokenRefusal> {
        switch issueToken(objectID: object.id, owner: owner, recipient: request.recipient, group: request.group,
                          ttlSeconds: ttlSeconds, maxUses: request.maxUses) {
        case .success(let token): return .success(token)
        case .failure(let refusal): return .failure(refusal)
        }
    }

    /// token.go issueToken: allowed before the object is complete (streaming delivery).
    func issueToken(objectID: String, owner: XferName, recipient: String, group: String, ttlSeconds: Int64,
                    maxUses: Int64) -> Result<IssuedToken, TokenRefusal> {
        guard config.hasTokenSecret else {
            return .failure(TokenRefusal(response: failure(503, "tokens_disabled",
                                                           "download tokens are not enabled on this server")))
        }
        let ttl = ttlSeconds <= 0 ? FakeFileV2Core.defaultTokenTTLSeconds : ttlSeconds
        let uses = maxUses <= 0 ? FakeFileV2Core.defaultTokenMaxUses : maxUses
        let expMs = clock.nowMs() + ttl * 1000
        guard let object = objects[objectID] else { return .failure(TokenRefusal(response: notFound())) }
        guard object.owner == owner else { return .failure(TokenRefusal(response: failure(403, "not_owner"))) }
        if !group.isEmpty {
            let name = XferName(group)
            if !object.groups.contains(name) {
                if object.groups.count >= FakeFileV2Core.maxGroupsPerObject {
                    return .failure(TokenRefusal(response: failure(409, "too_many_group_scopes",
                        "this object is already shared with the maximum number of groups")))
                }
                object.groups.append(name)
            }
            let mac = tokenMAC(obj: objectID, owner: owner, scope: 2, scopeID: name, expMs: expMs, maxUses: uses)
            return .success(IssuedToken(v: XferSupport.hex(mac), exp: expMs, max: uses, scope: "group"))
        }
        let mac = tokenMAC(obj: objectID, owner: owner, scope: 1, scopeID: XferName(recipient), expMs: expMs, maxUses: uses)
        return .success(IssuedToken(v: XferSupport.hex(mac), exp: expMs, max: uses, scope: "user"))
    }

    func handleToken(_ request: FakeWireRequest, user: XferName, obj: String) -> FakeWireResponse {
        if let refusal = requireFeature(user) { return refusal }
        let parsed: TokenRequest
        do {
            let value = try decodeBodyValue(request.body)
            parsed = try decodeTokenRequest(value)
        } catch {
            return failure(400, "bad_request", "the body is not the JSON object the route takes")
        }
        let ttl: Int64
        switch precheckToken(owner: user, parsed) {
        case .success(let seconds): ttl = seconds
        case .failure(let refusal): return refusal.response
        }
        switch issueToken(objectID: obj, owner: user, recipient: parsed.recipient, group: parsed.group, ttlSeconds: ttl,
                          maxUses: parsed.maxUses) {
        case .success(let token): return answer(200, token.fields)
        case .failure(let refusal): return refusal.response
        }
    }

    /// The first JSON value of a body under the same rules as `decodeObject`, for a route whose body is read straight into a
    /// struct (the struct decoder runs on the returned value).
    func decodeBodyValue(_ body: Data) throws -> FakeJSON {
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
        return first
    }

    // MARK: Token MAC, authorisation and budget (token.go)

    private func lengthPrefixed(_ bytes: [UInt8]) -> [UInt8] {
        let count = UInt32(bytes.count)
        return [UInt8(count >> 24 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)] + bytes
    }

    func tokenMAC(obj: String, owner: XferName, scope: UInt8, scopeID: XferName, expMs: Int64, maxUses: Int64) -> Data {
        var message = FakeFileV2Core.tokenLabel
        message += lengthPrefixed(Array(obj.utf8))
        message += lengthPrefixed(owner.bytes)
        message.append(scope)
        message += lengthPrefixed(scopeID.bytes)
        let exp = UInt64(bitPattern: expMs)
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8(exp >> UInt64(shift) & 0xFF)) }
        let uses = UInt32(truncatingIfNeeded: maxUses)
        for shift in stride(from: 24, through: 0, by: -8) { message.append(UInt8(uses >> UInt32(shift) & 0xFF)) }
        return Data(HMAC<SHA256>.authenticationCode(for: Data(message), using: tokenKey))
    }

    enum TokenFailure: Error {
        case invalid
        case storage
    }

    /// Checks the MAC, the expiry and, for a group token, the membership of the presenting user, without touching a counter.
    func authorizeToken(object: Object, presenter: XferName, tokenHex: String, expMs: Int64,
                        maxUses: Int64) -> Result<TokenGrant, TokenFailure> {
        guard expMs > 0, maxUses > 0 else { return .failure(.invalid) }
        if clock.nowMs() > expMs { return .failure(.invalid) }
        guard let got = FakeFileV2Core.hexDecode(tokenHex), got.count == 32 else { return .failure(.invalid) }
        let own = tokenMAC(obj: object.id, owner: object.owner, scope: 1, scopeID: presenter, expMs: expMs, maxUses: maxUses)
        if own == got {
            return .success(TokenGrant(key: CounterKey(obj: object.id, mac: own, presenter: presenter), maxUses: Int(maxUses)))
        }
        for group in object.groups {
            let mac = tokenMAC(obj: object.id, owner: object.owner, scope: 2, scopeID: group, expMs: expMs, maxUses: maxUses)
            guard mac == got else { continue }
            guard config.hasGroupStore else { return .failure(.invalid) }
            if groupLookupFails { return .failure(.storage) }
            guard isGroupMember(group: group, user: presenter) else { return .failure(.invalid) }
            return .success(TokenGrant(key: CounterKey(obj: object.id, mac: mac, presenter: presenter), maxUses: Int(maxUses)))
        }
        return .failure(.invalid)
    }

    static func hexDecode(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x61...0x66: return byte - 0x61 + 10
            case 0x41...0x46: return byte - 0x41 + 10
            default: return nil
            }
        }
        var out = [UInt8]()
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return Data(out)
    }

    /// Spends the budget of one request: `served` bytes toward the cap of 8 times the blob length and, when the request starts
    /// at offset 0, one use. False when either gate is spent.
    func chargeToken(_ grant: TokenGrant, blobLength: Int64, served: Int64, isStart: Bool) -> Bool {
        let byteCap = blobLength * 8
        var counter = counters[grant.key] ?? Counter(uses: grant.maxUses, bytes: 0)
        if counter.bytes >= byteCap || counter.bytes + max(0, served) > byteCap { return false }
        if isStart && counter.uses <= 0 { return false }
        counter.bytes += max(0, served)
        if isStart { counter.uses -= 1 }
        counters[grant.key] = counter
        return true
    }
}

extension FakeFileV2Core.IssuedToken {
    var fields: [(String, FakeJSON)] {
        [("v", .string(v)), ("exp", .int(exp)), ("max", .int(max)), ("scope", .string(scope))]
    }
}
