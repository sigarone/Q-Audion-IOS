import Foundation
@testable import QAudionEngine

// The replay of the server conformance transcript against the in-memory fake (docs/FILES_V2_SERVER_TRANSCRIPT.md, "How a
// client replays it"): for each scenario, start the fake with the scenario's config and a clock at `clock_start_ms`, run the
// steps as the account in `as`, compare exactly what an expectation lists (status, code, headers, JSON fields, body bytes)
// and capture the variables later steps use. Nothing is compared that the transcript does not list.

/// What one scenario came to: the failures are texts that name the scenario, the step, the operation and the difference.
struct XferScenarioReport {
    let name: String
    /// Why the scenario was not replayed; `nil` when it was.
    let skipped: String?
    var failures: [String] = []
    var stepsRun = 0
    /// How many listed items were compared: a status, a code, a header, a JSON path, a body, `waited_ms`, `aborted`.
    var checksRun = 0
}

/// The tags of `requires` a harness can honour. The fake models every one of them, so no scenario is skipped; a tag that is
/// not in this list (a later revision of the transcript) skips its scenarios, and a test pins that none is.
enum XferReplayCapabilities {
    /// - concurrency: requests in flight at the same time (`async`, `stall_after`, `release`, `await`): the fake keeps them as
    ///   pending operations and answers them when the test lets them go.
    /// - real_time_wait: the server waits on a timer: the fake advances the clock of its own timers by the wait.
    /// - large_declared: objects of up to MAX_BLOB are declared and never sent: the fake stores a header and a length.
    /// - server_seam: the create gate, the download slots and the disk floor are switches of the fake.
    /// - linux_statfs: the free space of the volume is a number of the fake.
    /// - raw_request: the fake is driven at the level of the HTTP request, so a malformed body or an unknown route is just
    ///   another request.
    /// - raw_tcp_half_close: a body that stops early after a half-close is an upload mode of the fake.
    static let honoured: Set<String> = [
        "concurrency", "real_time_wait", "large_declared", "server_seam", "linux_statfs", "raw_request", "raw_tcp_half_close"
    ]
}

final class XferScenarioRun {

    enum Variable {
        case json(FakeJSON)
        case text(String)
    }

    private struct Held {
        let id: Int?
        let response: FakeWireResponse?
    }

    let transcript: XferTranscript
    let scenario: XferScenario
    let clock: XferManualClock
    let core: FakeFileV2Core

    private var variables: [String: Variable] = [:]
    private var held: [String: Held] = [:]
    private var partCache: [String: Data] = [:]
    private(set) var failures: [String] = []
    private(set) var checks = 0
    private var current: XferStep?

    /// Test hook: changes the fake after the scenario's own configuration is applied (the replay-is-not-vacuous test).
    var mutateConfigAfterSetup: ((FakeFileV2Core) -> Void)?

    init(transcript: XferTranscript, scenario: XferScenario) {
        self.transcript = transcript
        self.scenario = scenario
        clock = XferManualClock(startMs: scenario.clockStartMs)
        core = FakeFileV2Core(config: FakeCoreConfig(), clock: clock)
    }

    // MARK: Reporting

    private func fail(_ message: String) {
        let step = current.map { "step \($0.index) (\($0.op))" } ?? "setup"
        failures.append("\(scenario.name), \(step): \(message)")
    }

    // MARK: Run

    func run() -> XferScenarioReport {
        var report = XferScenarioReport(name: scenario.name, skipped: nil)
        for tag in scenario.requires where !XferReplayCapabilities.honoured.contains(tag) {
            return XferScenarioReport(name: scenario.name, skipped: "needs the capability \(tag)")
        }
        applyConfig()
        mutateConfigAfterSetup?(core)
        for step in scenario.steps {
            current = step
            execute(step)
            report.stepsRun += 1
        }
        current = nil
        for (name, entry) in held where entry.id != nil || entry.response != nil {
            failures.append("\(scenario.name): the asynchronous request \(name) was never awaited or released")
        }
        report.failures = failures
        report.checksRun = checks
        return report
    }

    // MARK: Config

    private func applyConfig() {
        var config = FakeCoreConfig()
        guard let members = scenario.config.objectMembers else { return }
        for member in members {
            switch member.key {
            case "quota": config.quota = member.value.intValue ?? config.quota
            case "max_incomplete_per_user": config.maxIncompletePerUser = Int(member.value.intValue ?? 0)
            case "max_objects_per_user": config.maxObjectsPerUser = Int(member.value.intValue ?? 0)
            case "max_unfinished_bytes": config.maxUnfinishedBytes = member.value.intValue ?? config.maxUnfinishedBytes
            case "completed_retention_ms": config.completedRetentionMs = member.value.intValue ?? 0
            case "incomplete_retention_ms": config.incompleteAbandonMs = member.value.intValue ?? 0
            case "incomplete_max_lifetime_ms": config.incompleteMaxLifetimeMs = member.value.intValue ?? 0
            case "max_parts_in_flight_per_user": config.maxPartsInFlightPerUser = Int(member.value.intValue ?? 0)
            case "max_downloads_per_user": config.maxDownloadsPerUser = Int(member.value.intValue ?? 0)
            case "stream_wait_max_ms": config.streamWaitMaxMs = member.value.intValue ?? 0
            case "create_gate_wait_ms": config.createGateWaitMs = member.value.intValue ?? 0
            case "no_token_secret": config.hasTokenSecret = !(member.value.boolValue ?? false)
            case "no_group_store": config.hasGroupStore = !(member.value.boolValue ?? false)
            case "disk_full": if member.value.boolValue ?? false { config.freeBytes = 0 }
            case "without_feature":
                for user in member.value.arrayValue ?? [] {
                    if let name = user.stringValue { core.withoutFeature.insert(XferName(name)) }
                }
            default: fail("unknown config key \(member.key)")
            }
        }
        core.config = config
    }

    // MARK: Blobs and placeholders

    private func findBlob(_ name: String?) -> XferBlob? {
        guard let name = name, let found = scenario.blob(named: name) else {
            fail("unknown blob \(name ?? "(none)")")
            return nil
        }
        return found
    }

    private func part(_ blob: XferBlob, _ index: Int) -> Data {
        let key = "\(blob.name)#\(index)"
        if let cached = partCache[key] { return cached }
        if blob.declaredOnly { fail("a declared-only blob is never sent: \(blob.name)") }
        let data = blob.part(index)
        partCache[key] = data
        return data
    }

    /// Replaces `{name}` and `{name.field}` (a name of letters, digits and `_`) by the variable; any other brace is text.
    private func substitute(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard bytes.contains(0x7B) else { return text }
        var out = [UInt8]()
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x7B, let close = bytes[(index + 1)...].firstIndex(of: 0x7D) else {
                out.append(bytes[index])
                index += 1
                continue
            }
            let inner = Array(bytes[(index + 1)..<close])
            guard let replacement = placeholder(inner) else {
                out.append(bytes[index])
                index += 1
                continue
            }
            out.append(contentsOf: Array(replacement.utf8))
            index = close + 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The value of a placeholder, or `nil` when `inner` is not one (it is then plain text).
    private func placeholder(_ inner: [UInt8]) -> String? {
        func word(_ bytes: ArraySlice<UInt8>) -> Bool {
            !bytes.isEmpty && bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }
        }
        let name: ArraySlice<UInt8>
        var field: ArraySlice<UInt8>?
        if let dot = inner.firstIndex(of: 0x2E) {
            name = inner[..<dot]
            field = inner[(dot + 1)...]
            guard word(name), let tail = field, word(tail) else { return nil }
        } else {
            name = inner[...]
            guard word(name) else { return nil }
        }
        let key = String(decoding: Array(name), as: UTF8.self)
        guard let variable = variables[key] else {
            fail("the placeholder {\(key)} is not defined")
            return ""
        }
        switch (variable, field) {
        case (.text(let value), nil): return value
        case (.json(let value), nil): return value.scalarText ?? ""
        case (.json(let value), let name?):
            let fieldName = String(decoding: Array(name), as: UTF8.self)
            guard let inside = value.member(fieldName)?.scalarText else {
                fail("the variable \(key) has no field \(fieldName)")
                return ""
            }
            return inside
        case (.text, _?):
            fail("the variable \(key) is text and has no fields")
            return ""
        }
    }

    private func substitute(_ json: FakeJSON) -> FakeJSON {
        switch json {
        case .string(let text): return .string(substitute(text))
        case .array(let items): return .array(items.map { substitute($0) })
        case .object(let members): return .object(members.map { FakeJSON.Member(key: $0.key, value: substitute($0.value)) })
        default: return json
        }
    }

    // MARK: Steps

    private func execute(_ step: XferStep) {
        let args = substitute(step.args)
        let timerBefore = core.timerMs
        switch step.op {
        case "create": send(step, create(step, args))
        case "put_part": send(step, putPart(step, args))
        case "get_parts": send(step, simple(step, "GET", "/parts", args))
        case "complete": send(step, simple(step, "POST", "/complete", args))
        case "delete": send(step, simple(step, "DELETE", "", args))
        case "get_range": send(step, getRange(step, args))
        case "issue_token": send(step, issueToken(step, args))
        case "list_unfinished": send(step, collection(step, "GET", args))
        case "delete_unfinished": send(step, collection(step, "DELETE", args))
        case "raw": send(step, raw(step, args))
        case "advance_clock": clock.advance(ms: args.member("ms")?.intValue ?? 0)
        case "cleanup": core.runCleanup()
        case "restart_server": if !core.restart() { fail("restart_server with a request in flight") }
        case "set_group_member": setGroupMember(args)
        case "set_group_lookup_error": core.groupLookupFails = args.member("on")?.boolValue ?? false
        case "set_feature": setFeature(args)
        case "hold_create_gate": core.holdNextCreate()
        case "release_create_gate": core.releaseCreateGate()
        case "hold_download_slots": holdSlots(args, hold: true)
        case "release_download_slots": holdSlots(args, hold: false)
        case "await": finish(step, args, release: false, timerBefore: timerBefore)
        case "release": finish(step, args, release: true, timerBefore: timerBefore)
        default: fail("unknown operation")
        }
    }

    /// Sends a request and compares its answer (a synchronous step) or keeps it under its name (an `async` one).
    private func send(_ step: XferStep, _ request: FakeWireRequest?) {
        guard let request = request else { return }
        let timerBefore = core.timerMs
        if let name = step.asyncName {
            if step.expect != nil { fail("an asynchronous step carries no expectation") }
            switch core.serve(request, async: true) {
            case .pending(let id): held[name] = Held(id: id, response: nil)
            case .response(let response): held[name] = Held(id: nil, response: response)
            }
            return
        }
        switch core.serve(request, async: false) {
        case .response(let response):
            compare(step, response, timerAdvance: core.timerMs - timerBefore)
        case .pending:
            fail("the request is held by the server, and the step is not asynchronous")
        }
    }

    private func finish(_ step: XferStep, _ args: FakeJSON, release: Bool, timerBefore: Int64) {
        guard let name = args.member("name")?.stringValue else {
            fail("no name")
            return
        }
        guard let entry = held[name] else {
            fail("nothing is held under the name \(name)")
            return
        }
        held[name] = nil
        let response: FakeWireResponse
        if let ready = entry.response {
            response = ready
        } else if let id = entry.id {
            if release {
                response = core.releaseUpload(id, sendRest: args.member("mode")?.stringValue == "send_rest")
                core.pumpDownloads()
            } else {
                response = core.awaitResult(id)
            }
        } else {
            fail("nothing is held under the name \(name)")
            return
        }
        compare(step, response, timerAdvance: core.timerMs - timerBefore)
    }

    // MARK: Requests

    private func objectPath(_ args: FakeJSON, _ tail: String) -> String {
        FileV2Wire.pathPrefix + "/" + (args.member("obj")?.stringValue ?? "") + tail
    }

    private func simple(_ step: XferStep, _ method: String, _ tail: String, _ args: FakeJSON) -> FakeWireRequest {
        FakeWireRequest(method: method, path: objectPath(args, tail), user: step.user)
    }

    private func create(_ step: XferStep, _ args: FakeJSON) -> FakeWireRequest? {
        var request = FakeWireRequest(method: "POST", path: FileV2Wire.pathPrefix, user: step.user)
        if let rawText = args.member("raw")?.stringValue {
            request.body = Data(rawText.utf8)
            return request
        }
        guard let blob = findBlob(args.member("blob")?.stringValue) else { return nil }
        var members: [FakeJSON.Member] = [
            FakeJSON.Member(key: "blob_len", value: .int(blob.length)),
            FakeJSON.Member(key: "head", value: .string(blob.headBase64)),
            FakeJSON.Member(key: "part_size", value: .int(transcript.constant("part_size") ?? 0))
        ]
        // `body` is merged over it; a null value removes the key
        for override in args.member("body")?.objectMembers ?? [] {
            members.removeAll { $0.key == override.key }
            if !override.value.isNull { members.append(override) }
        }
        if let token = args.member("token") { members.append(FakeJSON.Member(key: "token", value: token)) }
        request.body = FakeJSON.object(members).serialized()
        return request
    }

    private func issueToken(_ step: XferStep, _ args: FakeJSON) -> FakeWireRequest {
        var request = simple(step, "POST", "/token", args)
        if let rawText = args.member("raw")?.stringValue {
            request.body = Data(rawText.utf8)
        } else if let body = args.member("body") {
            request.body = body.serialized()
        }
        return request
    }

    private func collection(_ step: XferStep, _ method: String, _ args: FakeJSON) -> FakeWireRequest {
        let query = args.member("query")?.stringValue ?? ""
        return FakeWireRequest(method: method, path: FileV2Wire.pathPrefix + (query.isEmpty ? "" : "?" + query), user: step.user)
    }

    private func raw(_ step: XferStep, _ args: FakeJSON) -> FakeWireRequest {
        var request = FakeWireRequest(method: args.member("method")?.stringValue ?? "GET",
                                      path: args.member("path")?.stringValue ?? "", user: step.user)
        for header in args.member("headers")?.objectMembers ?? [] {
            if let value = header.value.stringValue { request.headers.add(header.key, value) }
        }
        if let text = args.member("body")?.stringValue { request.body = Data(text.utf8) }
        return request
    }

    private func putPart(_ step: XferStep, _ args: FakeJSON) -> FakeWireRequest? {
        guard let source = args.member("body"), let blob = findBlob(source.member("blob")?.stringValue),
              let index = source.member("part")?.intValue else {
            fail("a put_part without a body")
            return nil
        }
        let partText: String
        if let number = args.member("part")?.intValue {
            partText = String(number)
        } else {
            partText = args.member("part")?.stringValue ?? ""
        }
        let original = part(blob, Int(index))
        var body = original
        if let flip = source.member("flip_bit_at")?.intValue, flip >= 0, Int(flip) < body.count {
            body[body.startIndex + Int(flip)] ^= 1
        }
        if let cut = source.member("truncate_to")?.intValue { body = body.prefix(Int(cut)) }
        if let delta = source.member("len_delta")?.intValue {
            if delta < 0 {
                body = body.prefix(max(0, body.count + Int(delta)))
            } else {
                body.append(Data(count: Int(delta)))
            }
        }
        var request = FakeWireRequest(method: "PUT", path: objectPath(args, "/parts/" + partText), user: step.user)
        request.headers.set("Content-Type", "application/octet-stream")
        request.body = body
        request.contentLength = body.count
        if args.member("chunked")?.boolValue ?? false { request.contentLength = nil }
        if let after = args.member("stall_after")?.intValue {
            request.upload = .stall(after: Int(after))
        } else if let after = args.member("abort_after")?.intValue {
            request.upload = .abort(after: Int(after))
        } else if let after = args.member("half_close_after")?.intValue {
            request.upload = .halfClose(after: Int(after))
        }
        let source256: Data
        if let other = args.member("digest_of"), let otherBlob = findBlob(other.member("blob")?.stringValue),
           let otherIndex = other.member("part")?.intValue {
            source256 = XferSupport.sha256(part(otherBlob, Int(otherIndex)))
        } else {
            source256 = XferSupport.sha256(original)
        }
        setDigest(&request, kind: args.member("digest")?.stringValue ?? "good", sha256: source256)
        return request
    }

    private func setDigest(_ request: inout FakeWireRequest, kind: String, sha256: Data) {
        let good = XferSupport.base64(sha256)
        switch kind {
        case "good": request.headers.set("Content-Digest", "sha-256=:" + good + ":")
        case "absent": break
        case "no_colons": request.headers.set("Content-Digest", "sha-256=" + good)
        case "short": request.headers.set("Content-Digest", "sha-256=:" + XferSupport.base64(sha256.prefix(16)) + ":")
        case "not_base64": request.headers.set("Content-Digest", "sha-256=:!!!:")
        // a sha-512 member: only its name matters to the server, which ignores every algorithm but sha-256
        case "sha512_only": request.headers.set("Content-Digest", "sha-512=:" + XferSupport.base64(sha256 + sha256) + ":")
        case "multi_member":
            request.headers.set("Content-Digest", "sha-512=:AAAA:, sha-256=:" + good + ":")
        case "duplicate_member":
            request.headers.set("Content-Digest", "sha-256=:" + good + ":, sha-256=:" + good + ":")
        default: fail("unknown digest kind \(kind)")
        }
    }

    private func getRange(_ step: XferStep, _ args: FakeJSON) -> FakeWireRequest {
        var request = simple(step, "GET", "", args)
        if let range = args.member("range")?.stringValue { request.headers.set("Range", range) }
        if let prefer = args.member("prefer")?.stringValue { request.headers.set("Prefer", prefer) }
        if let name = args.member("token")?.stringValue { applyToken(&request, name: name, tamper: args.member("tamper")?.stringValue) }
        for header in args.member("headers")?.objectMembers ?? [] {
            if header.value.isNull {
                request.headers.remove(header.key)
            } else if let value = header.value.stringValue {
                request.headers.set(header.key, value)
            }
        }
        return request
    }

    private func applyToken(_ request: inout FakeWireRequest, name: String, tamper: String?) {
        guard case .json(let token)? = variables[name], let value = token.member("v")?.stringValue,
              let exp = token.member("exp")?.intValue, let max = token.member("max")?.intValue else {
            fail("the variable \(name) is not an issued token")
            return
        }
        var v = value
        var expiry = exp
        var uses = max
        switch tamper {
        case nil: break
        case "longer_expiry"?: expiry += 86_400_000
        case "more_uses"?: uses = 500
        case "flipped_bit"?: v = (v.hasPrefix("0") ? "1" : "0") + String(v.dropFirst())
        case "short_token"?: v = String(v.prefix(60))
        case "non_hex"?: v = String(repeating: "z", count: 64)
        default: fail("unknown tamper \(tamper ?? "")")
        }
        request.headers.set("X-Download-Token", v)
        request.headers.set("X-Download-Expires-Ms", String(expiry))
        request.headers.set("X-Download-Max-Uses", String(uses))
    }

    // MARK: Controls

    private func setGroupMember(_ args: FakeJSON) {
        guard let group = args.member("group")?.stringValue, let user = args.member("user")?.stringValue,
              let member = args.member("member")?.boolValue else {
            fail("set_group_member needs group, user and member")
            return
        }
        core.setGroupMember(group: XferName(group), user: XferName(user), member: member)
    }

    private func setFeature(_ args: FakeJSON) {
        guard let user = args.member("user")?.stringValue, let enabled = args.member("enabled")?.boolValue else {
            fail("set_feature needs user and enabled")
            return
        }
        core.setFeature(user: XferName(user), enabled: enabled)
    }

    private func holdSlots(_ args: FakeJSON, hold: Bool) {
        guard let user = args.member("user")?.stringValue else {
            fail("a download slot step needs a user")
            return
        }
        if hold {
            core.holdDownloadSlots(user: XferName(user), count: Int(args.member("count")?.intValue ?? 0))
        } else {
            core.releaseDownloadSlots(user: XferName(user))
        }
    }

    // MARK: Expectations

    private func compare(_ step: XferStep, _ response: FakeWireResponse, timerAdvance: Int64) {
        if let stuck = response.stuck {
            fail(stuck)
            return
        }
        guard let expectation = step.expect else {
            fail("the step makes a request and has no expectation")
            return
        }
        // the variables of the answer first: the expectations of the same step may use them
        capture(expectation.member("var"), response)
        let expect = substitute(expectation)

        if expect.member("aborted")?.boolValue ?? false {
            checks += 1
            if !response.aborted { fail("expected the request to be dropped, got \(response.status)") }
            return
        }
        if response.aborted {
            fail("the request was dropped, expected \(expect.member("status")?.intValue ?? 0)")
            return
        }
        if let status = expect.member("status")?.intValue {
            checks += 1
            if Int64(response.status) != status {
                fail("status \(response.status), expected \(status)\(response.errorCode.map { " (\($0))" } ?? "")")
            }
        }
        if let code = expect.member("code")?.stringValue {
            checks += 1
            if Array((response.errorCode ?? "").utf8) != Array(code.utf8) {
                fail("code \(response.errorCode ?? "(none)"), expected \(code)")
            }
        }
        for header in expect.member("headers")?.objectMembers ?? [] {
            checks += 1
            compareHeader(header, response)
        }
        for member in expect.member("json")?.objectMembers ?? [] {
            checks += 1
            compareJSON(path: member.key, expected: member.value, response)
        }
        if let wanted = expect.member("body") {
            checks += 1
            compareBody(wanted, response)
        }
        if let waited = expect.member("waited_ms")?.intValue {
            checks += 1
            if waited != timerAdvance { fail("the server waited \(timerAdvance) ms, expected \(waited)") }
        }
    }

    private func capture(_ variables: FakeJSON?, _ response: FakeWireResponse) {
        for member in variables?.objectMembers ?? [] {
            guard let rule = member.value.stringValue else { continue }
            if rule.hasPrefix("json:") {
                let path = String(rule.dropFirst(5))
                if path.isEmpty {
                    if let whole = response.json { self.variables[member.key] = .json(whole) }
                } else if let json = response.json, let value = XferScenarioRun.resolve(path, in: json) {
                    if let text = value.stringValue { self.variables[member.key] = .text(text) } else { self.variables[member.key] = .json(value) }
                } else {
                    fail("cannot capture \(member.key): no \(path) in the answer")
                }
            } else if rule.hasPrefix("header:") {
                if let value = response.headers.first(String(rule.dropFirst(7))) {
                    self.variables[member.key] = .text(value)
                } else {
                    fail("cannot capture \(member.key): no header \(rule.dropFirst(7))")
                }
            } else {
                fail("unknown capture rule \(rule)")
            }
        }
    }

    private func compareHeader(_ expected: FakeJSON.Member, _ response: FakeWireResponse) {
        guard let want = expected.value.stringValue else { return }
        let actual = response.headers.first(expected.key)
        switch want {
        case "<present>": if actual == nil { fail("header \(expected.key) is missing") }
        case "<absent>": if let value = actual { fail("header \(expected.key) is present (\(value)), expected none") }
        default:
            guard let value = actual else {
                fail("header \(expected.key) is missing, expected \(want)")
                return
            }
            if Array(value.utf8) != Array(want.utf8) { fail("header \(expected.key) is \(value), expected \(want)") }
        }
    }

    private func compareBody(_ wanted: FakeJSON, _ response: FakeWireResponse) {
        guard let blob = findBlob(wanted.member("blob")?.stringValue), let from = wanted.member("from")?.intValue,
              let to = wanted.member("to")?.intValue else {
            fail("a body expectation needs blob, from and to")
            return
        }
        guard let body = response.body else {
            fail("the answer has no body, expected bytes \(from) to \(to) of \(blob.name)")
            return
        }
        let expected = blob.bytes(from: from, toInclusive: to)
        if body != expected {
            fail("the body (\(body.count) bytes) differs from bytes \(from) to \(to) of \(blob.name) (\(expected.count) bytes)")
        }
    }

    // MARK: JSON paths and matchers

    /// A dotted path of object keys and array indexes; `name[]` collects the rest of the path from every element of an array.
    static func resolve(_ path: String, in json: FakeJSON) -> FakeJSON? {
        resolve(tokens: path.split(separator: ".", omittingEmptySubsequences: false).map { String($0) }, in: json)
    }

    private static func resolve(tokens: [String], in json: FakeJSON) -> FakeJSON? {
        guard let token = tokens.first else { return json }
        let rest = Array(tokens.dropFirst())
        if token.hasSuffix("[]") {
            guard let items = json.member(String(token.dropLast(2)))?.arrayValue else { return nil }
            var collected = [FakeJSON]()
            for item in items {
                guard let value = resolve(tokens: rest, in: item) else { return nil }
                collected.append(value)
            }
            return .array(collected)
        }
        let next: FakeJSON?
        if let items = json.arrayValue {
            let digits = Array(token.utf8)
            guard !digits.isEmpty, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let index = Int(token), index < items.count else {
                return nil
            }
            next = items[index]
        } else {
            next = json.member(token)
        }
        guard let value = next else { return nil }
        return resolve(tokens: rest, in: value)
    }

    /// Equality of two values with strings compared as UTF-8 bytes.
    static func same(_ lhs: FakeJSON, _ rhs: FakeJSON) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return Array(a.utf8) == Array(b.utf8)
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { same($0, $1) }
        case (.object(let a), .object(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { Array($0.key.utf8) == Array($1.key.utf8) && same($0.value, $1.value) }
        default: return lhs == rhs
        }
    }

    private func compareJSON(path: String, expected: FakeJSON, _ response: FakeWireResponse) {
        guard let json = response.json else {
            fail("the answer has no JSON body, expected \(path)")
            return
        }
        let actual = XferScenarioRun.resolve(path, in: json)
        if case .string(let marker) = expected {
            if marker == "<present>" {
                if actual == nil { fail("json \(path) is missing") }
                return
            }
            if marker == "<absent>" {
                if actual != nil { fail("json \(path) is present, expected none") }
                return
            }
        }
        guard let value = actual else {
            fail("json \(path) is missing")
            return
        }
        if case .object(let matchers) = expected {
            for matcher in matchers { check(matcher, path: path, value: value, json: json) }
            return
        }
        if !XferScenarioRun.same(value, expected) { fail("json \(path) is \(describe(value)), expected \(describe(expected))") }
    }

    private func check(_ matcher: FakeJSON.Member, path: String, value: FakeJSON, json: FakeJSON) {
        switch matcher.key {
        case "len":
            let count = value.arrayValue?.count ?? value.stringValue.map { $0.utf8.count }
            if count == nil || Int64(count ?? -1) != matcher.value.intValue { fail("json \(path) has length \(count ?? -1), expected \(describe(matcher.value))") }
        case "multiset":
            guard let wanted = matcher.value.arrayValue, let got = value.arrayValue else {
                fail("json \(path): multiset needs two arrays")
                return
            }
            let a = got.map { String(decoding: $0.serialized(), as: UTF8.self) }.sorted()
            let b = wanted.map { String(decoding: $0.serialized(), as: UTF8.self) }.sorted()
            if a != b { fail("json \(path) is not the multiset \(describe(matcher.value))") }
        case "sorted":
            guard let items = value.arrayValue else {
                fail("json \(path) is not an array")
                return
            }
            let texts = items.compactMap { $0.stringValue }.map { Array($0.utf8) }
            let ascending = texts.count == items.count && zip(texts, texts.dropFirst()).allSatisfy { $0.lexicographicallyPrecedes($1) }
            if matcher.value.boolValue == true && !ascending { fail("json \(path) is not strictly ascending") }
        case "same_as":
            guard let other = matcher.value.stringValue, let theirs = XferScenarioRun.resolve(other, in: json) else {
                fail("json \(path): same_as names a path that does not exist")
                return
            }
            if !XferScenarioRun.same(value, theirs) { fail("json \(path) differs from \(other)") }
        case "not":
            if XferScenarioRun.same(value, matcher.value) { fail("json \(path) is \(describe(value)), expected anything else") }
        case "gt":
            guard let bound = matcher.value.stringValue, let text = value.stringValue,
                  Array(bound.utf8).lexicographicallyPrecedes(Array(text.utf8)) else {
                fail("json \(path) is not greater than \(describe(matcher.value))")
                return
            }
        default:
            fail("json \(path): unknown matcher \(matcher.key)")
        }
    }

    private func describe(_ value: FakeJSON) -> String {
        let text = String(decoding: value.serialized(), as: UTF8.self)
        return text.count > 120 ? String(text.prefix(120)) + "..." : text
    }
}
