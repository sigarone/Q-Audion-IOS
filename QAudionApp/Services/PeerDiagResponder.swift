import Foundation
import UIKit

/// Answers a `diag_request` frame from the server: a short, redacted, windowed set of log
/// lines, encrypted to the admin key and uploaded to an opaque endpoint.
///
/// No UI, no notification, no wake. The only consent consulted is the operational
/// diagnostics toggle (`TelemetryService.isEnabled`), plus a local kill switch
/// (`PeerDiagFeature`). With the toggle off the frame is only acknowledged: the ring is not
/// read and nothing is uploaded. Defence in depth, whatever the server sends: only a call this
/// device took part in (a 48 h local record) is answered, the window is clamped to that call,
/// and at most 10 requests are answered per day.

struct PeerDiagRequest: Equatable {
    let requestId: String
    let callId: String
    let windowStartMs: Int64
    let windowEndMs: Int64
    let maxBytes: Int
    let expiresMs: Int64
    let nonce: String

    /// Hard caps applied whatever the server says.
    static let maxWindowMs: Int64 = 30 * 60 * 1000
    static let absoluteMaxBytes: Int = 512 * 1024
    /// Request lifetime counted from receipt, and the clock skew tolerated on `expires_ms`.
    static let maxLifetimeMs: Int64 = 2 * 60 * 60 * 1000
    static let clockSkewMs: Int64 = 5 * 60 * 1000
    /// Slack around the call's own start and end.
    static let callSlackMs: Int64 = 60 * 1000

    /// ASCII `[A-Za-z0-9_-]` only. The server nonce is base64url without padding (22 characters).
    static func isSafeToken(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122) || $0.value == 45 || $0.value == 95
        }
    }

    /// Absurd expiries are clamped to receipt + 2 h; up to 5 min of clock skew is tolerated.
    static func effectiveExpiry(receivedMs: Int64, expiresMs: Int64) -> Int64 {
        let withSkew = expiresMs > Int64.max - clockSkewMs ? Int64.max : expiresMs + clockSkewMs
        return min(withSkew, receivedMs + maxLifetimeMs)
    }

    /// The window narrowed to the call (start - 60 s .. end + 60 s, an ongoing call ends
    /// "now" only when the controller reports this very call as active, else its last seen time) and to 30 minutes (the end wins). `nil` when nothing is left.
    func clamped(to call: PeerDiagCallRecord, nowMs: Int64, expiresMs: Int64,
                 activeCallId: String? = nil) -> PeerDiagRequest? {
        let lo = call.startMs - Self.callSlackMs
        let isActive = activeCallId?.lowercased() == call.id
        let hi = call.effectiveEndMs(nowMs: nowMs, isActive: isActive) + Self.callSlackMs
        let end = min(windowEndMs, hi)
        let start = max(max(windowStartMs, lo), end - Self.maxWindowMs)
        guard end > start else { return nil }
        return PeerDiagRequest(requestId: requestId, callId: callId, windowStartMs: start,
                               windowEndMs: end, maxBytes: maxBytes, expiresMs: expiresMs, nonce: nonce)
    }

    static func parse(_ data: [String: Any]) -> PeerDiagRequest? {
        func int64(_ key: String) -> Int64? {
            if let n = data[key] as? NSNumber { return n.int64Value }
            return nil
        }
        guard let requestId = data["request_id"] as? String, !requestId.isEmpty,
              requestId.count <= 64, isSafeToken(requestId),
              let callId = data["call_id"] as? String, !callId.isEmpty, callId.count <= 64,
              isSafeToken(callId),
              let start = int64("window_start_ms"), let end = int64("window_end_ms"), end > start,
              let expires = int64("expires_ms"),
              let nonce = data["nonce"] as? String, !nonce.isEmpty, nonce.count <= 64,
              isSafeToken(nonce)
        else { return nil }
        let maxBytes = (data["max_bytes"] as? NSNumber)?.intValue ?? absoluteMaxBytes
        guard maxBytes > 64 else { return nil }
        return PeerDiagRequest(requestId: requestId, callId: callId,
                               windowStartMs: start, windowEndMs: end,
                               maxBytes: min(maxBytes, absoluteMaxBytes),
                               expiresMs: expires, nonce: nonce)
    }
}

/// Local kill switch: compiled ON, the public flags file can only switch it OFF
/// (`FeatureFlags.killSwitch`), so a build already in the field can be silenced without a
/// release.
enum PeerDiagFeature {
    static let flagKey = "peer_diag.enabled"
    static let compiledDefault = true
    @MainActor static var isEnabled: Bool {
        FeatureFlags.killSwitch(flagKey, compiledDefault: compiledDefault)
    }
}

enum PeerDiagGate {
    /// The one consent: the operational diagnostics toggle.
    static func mayCollect(diagnosticsEnabled: Bool) -> Bool { diagnosticsEnabled }

    enum Decision: Equatable {
        case ignore
        /// A duplicate of a request already handled and not expired: only acknowledged again.
        case reAck
        case ackOnly
        case collect
    }

    static func decide(nowMs: Int64, expiresMs: Int64, alreadyHandled: Bool, diagnosticsEnabled: Bool,
                       featureEnabled: Bool = true, callKnown: Bool = true,
                       withinQuota: Bool = true) -> Decision {
        if !featureEnabled || nowMs >= expiresMs { return .ignore }
        if alreadyHandled { return .reAck }
        if !callKnown { return .ignore }
        guard mayCollect(diagnosticsEnabled: diagnosticsEnabled) else { return .ackOnly }
        return withinQuota ? .collect : .ignore
    }
}

/// A call this device took part in (answered, placed, joined) or that rang here. `endMs == nil`
/// while it is still going on.
struct PeerDiagCallRecord: Equatable {
    var id: String
    var startMs: Int64
    var endMs: Int64?
    /// Last time the call was seen live (heartbeat). Used to close an entry nobody closed.
    var lastSeenMs: Int64? = nil

    /// Longest a call is ever considered to have lasted.
    static let maxDurationMs: Int64 = 4 * 60 * 60 * 1000

    /// End of the call for windowing: its own end; for an open entry "now" only if the call
    /// controller reports this call as active, else the last seen time. Always capped.
    func effectiveEndMs(nowMs: Int64, isActive: Bool) -> Int64 {
        let raw = endMs ?? (isActive ? nowMs : (lastSeenMs ?? startMs))
        return min(raw, startMs + Self.maxDurationMs)
    }
}

/// The calls of the last 48 h, kept locally so a request is answered only for a call this
/// device really was part of. Ids are compared lower-case.
struct PeerDiagCallLedger {
    static let ttlMs: Int64 = 48 * 60 * 60 * 1000
    static let maxEntries = 200
    /// How long a call that only rang is considered to have lasted.
    static let ringMs: Int64 = 60 * 1000
    private(set) var records: [PeerDiagCallRecord]

    init(records: [PeerDiagCallRecord] = []) { self.records = records }

    /// A record still open (no end) after this long was never closed (app killed mid-call):
    /// it is marked ended at its last seen time instead of staying open for ever.
    static let staleOpenMs: Int64 = 4 * 60 * 60 * 1000
    /// Minimum spacing of the persisted "last seen" updates (coalesced writes).
    static let heartbeatMs: Int64 = 20 * 1000

    /// Process start: nothing can still be live, so every open entry is closed at its last
    /// seen time (or its start).
    mutating func closeAllOpen() {
        for i in records.indices where records[i].endMs == nil {
            records[i].endMs = records[i].lastSeenMs ?? records[i].startMs
        }
    }

    mutating func prune(nowMs: Int64, keepOpen: Set<String> = []) {
        for i in records.indices where records[i].endMs == nil && !keepOpen.contains(records[i].id) && nowMs - records[i].startMs > Self.staleOpenMs {
            records[i].endMs = records[i].lastSeenMs ?? records[i].startMs
        }
        records.removeAll { ($0.endMs ?? nowMs) < nowMs - Self.ttlMs }
        if records.count > Self.maxEntries { records.removeFirst(records.count - Self.maxEntries) }
    }

    func record(for id: String) -> PeerDiagCallRecord? {
        let key = id.lowercased()
        return records.first { $0.id == key }
    }

    /// The calls going on right now: new ones open, the ones no longer active close.
    mutating func sync(activeIds: Set<String>, nowMs: Int64) {
        let active = Set(activeIds.map { $0.lowercased() }.filter { !$0.isEmpty })
        for id in active {
            if let i = records.firstIndex(where: { $0.id == id }) {
                records[i].endMs = nil
                if records[i].lastSeenMs.map({ nowMs - $0 >= Self.heartbeatMs }) ?? true {
                    records[i].lastSeenMs = nowMs
                }
            } else {
                records.append(PeerDiagCallRecord(id: id, startMs: nowMs, endMs: nil, lastSeenMs: nowMs))
            }
        }
        for i in records.indices where records[i].endMs == nil && !active.contains(records[i].id) {
            records[i].endMs = nowMs
        }
        prune(nowMs: nowMs, keepOpen: active)
    }

    /// A call that rang on this device (it may end up missed).
    mutating func noteRang(id: String, nowMs: Int64) {
        let key = id.lowercased()
        guard !key.isEmpty, record(for: key) == nil else { return }
        records.append(PeerDiagCallRecord(id: key, startMs: nowMs, endMs: nowMs + Self.ringMs))
        prune(nowMs: nowMs)
    }
}

/// UserDefaults persistence of the ledger, and the two hooks `AppState` calls.
@MainActor
enum PeerDiagCallLedgerStore {
    nonisolated static let key = "qaudion.peerdiag.calls"

    static func load() -> [PeerDiagCallRecord] {
        let raw = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        return raw.compactMap { d in
            guard let id = d["id"] as? String, let st = (d["s"] as? NSNumber)?.int64Value else { return nil }
            return PeerDiagCallRecord(id: id, startMs: st, endMs: (d["e"] as? NSNumber)?.int64Value,
                                      lastSeenMs: (d["l"] as? NSNumber)?.int64Value)
        }
    }

    /// Set once the entries left open by a previous process have been closed.
    private static var recoveredOpenEntries = false

    /// The ledger as stored. The first read of a process closes every entry still open: a
    /// previous process cannot have a live call.
    static func loadClosingStale() -> [PeerDiagCallRecord] {
        var records = load()
        if !recoveredOpenEntries {
            recoveredOpenEntries = true
            var ledger = PeerDiagCallLedger(records: records)
            ledger.closeAllOpen()
            if ledger.records != records { save(ledger.records) }
            records = ledger.records
        }
        return records
    }

    static func save(_ records: [PeerDiagCallRecord]) {
        let raw: [[String: Any]] = records.map {
            var d: [String: Any] = ["id": $0.id, "s": NSNumber(value: $0.startMs)]
            if let e = $0.endMs { d["e"] = NSNumber(value: e) }
            if let l = $0.lastSeenMs { d["l"] = NSNumber(value: l) }
            return d
        }
        UserDefaults.standard.set(raw, forKey: key)
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000.0) }

    static func sync(activeIds: Set<String>) {
        var ledger = PeerDiagCallLedger(records: loadClosingStale())
        let before = ledger.records
        ledger.sync(activeIds: activeIds, nowMs: nowMs())
        if ledger.records != before { save(ledger.records) }
    }

    static func noteRang(callId: String) {
        var ledger = PeerDiagCallLedger(records: loadClosingStale())
        let before = ledger.records
        ledger.noteRang(id: callId, nowMs: nowMs())
        if ledger.records != before { save(ledger.records) }
    }
}

/// Requests answered in the last 24 h: at most 10.
enum PeerDiagQuota {
    static let maxPerDay = 10
    static let windowMs: Int64 = 24 * 60 * 60 * 1000

    static func recent(_ times: [Int64], nowMs: Int64) -> [Int64] {
        times.filter { nowMs - $0 < windowMs }
    }

    static func allows(_ times: [Int64], nowMs: Int64) -> Bool {
        recent(times, nowMs: nowMs).count < maxPerDay
    }
}

/// The last handled request ids (20, kept 4 h), so a re-sent frame is not answered twice.
struct PeerDiagHandledSet {
    static let maxEntries = 20
    static let ttlMs: Int64 = 4 * 60 * 60 * 1000
    private(set) var entries: [(id: String, atMs: Int64)]

    init(entries: [(id: String, atMs: Int64)] = []) { self.entries = entries }

    mutating func prune(nowMs: Int64) {
        entries.removeAll { nowMs - $0.atMs > Self.ttlMs }
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    func contains(_ id: String, nowMs: Int64) -> Bool {
        entries.contains { $0.id == id && nowMs - $0.atMs <= Self.ttlMs }
    }

    mutating func insert(_ id: String, nowMs: Int64) {
        prune(nowMs: nowMs)
        guard !entries.contains(where: { $0.id == id }) else { return }
        entries.append((id: id, atMs: nowMs))
        prune(nowMs: nowMs)
    }
}

enum PeerDiagLogBuilder {
    static let maxLines = 5000
    static let maxPlaintextBytes = 400 * 1024
    static let maxSnapshotBytes = 32 * 1024

    /// Entries inside the server window narrowed to at most 30 minutes (the end wins),
    /// oldest first, newest `maxLines` kept.
    static func select(_ entries: [LiveLogRawEntry], request: PeerDiagRequest) -> [LiveLogRawEntry] {
        let end = request.windowEndMs
        let start = max(request.windowStartMs, end - PeerDiagRequest.maxWindowMs)
        var out = entries.filter {
            let ms = Int64($0.timestamp.timeIntervalSince1970 * 1000.0)
            return ms >= start && ms <= end
        }
        out.sort { $0.seq < $1.seq }
        if out.count > maxLines { out.removeFirst(out.count - maxLines) }
        return out
    }

    private static func levelLetter(_ level: String) -> String {
        switch level.lowercased() {
        case "debug": return "D"
        case "info": return "I"
        case "warn", "warning": return "W"
        case "error": return "E"
        default: return "I"
        }
    }

    /// Other users' ids never leave in full: every UUID is cut to its first 8 characters
    /// (the requested call's own id stays whole) and the participant roster keeps 8-character
    /// prefixes at most, whatever their format.
    static func sanitizeSnapshot(_ snap: String, keepCallId: String) -> String {
        var text = snap
        if let data = snap.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func walk(_ v: Any) -> Any {
                if let d = v as? [String: Any] {
                    var out: [String: Any] = [:]
                    for (k, x) in d {
                        if k == "group_participants", let arr = x as? [Any] {
                            out[k] = arr.map { item -> String in
                                if let str = item as? String { return String(str.prefix(8)) }
                                return "?"
                            }
                        } else {
                            out[k] = walk(x)
                        }
                    }
                    return out
                }
                if let a = v as? [Any] { return a.map(walk) }
                return v
            }
            if let obj = walk(parsed) as? [String: Any], JSONSerialization.isValidJSONObject(obj),
               let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
               let str = String(data: out, encoding: .utf8) { text = str }
        }
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let keep = keepCallId.lowercased()
        let ns = text as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let id = ns.substring(with: m.range)
            result += id.lowercased() == keep ? id : String(id.prefix(8))
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// `<ISO-8601 UTC Z> <L> [<tag>] <message>` per line, every message through the report
    /// redactor again, oldest lines dropped until the text fits `maxBytes`. `nil` when there
    /// is nothing to send (no entry in the window): no empty marker is ever sent.
    static func build(entries: [LiveLogRawEntry],
                      request: PeerDiagRequest,
                      appVersion: String, osVersion: String, deviceModel: String,
                      callSnapshot: String?,
                      maxBytes: Int = maxPlaintextBytes) -> String? {
        let selected = select(entries, request: request)
        guard !selected.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = TimeZone(identifier: "UTC")
        var lines: [String] = selected.map {
            iso.string(from: $0.timestamp) + " " + levelLetter($0.level) + " [" + oneLine($0.tag) + "] "
                + oneLine(LogRedactor.redactStructured($0.message))
        }
        var snapshotLine = ""
        if let snap = callSnapshot, !snap.isEmpty {
            var s = oneLine(LogRedactor.redactStructured(sanitizeSnapshot(snap, keepCallId: request.callId)))
            if s.utf8.count > maxSnapshotBytes {
                s = String(decoding: Array(s.utf8.prefix(maxSnapshotBytes)), as: UTF8.self)
            }
            snapshotLine = "# call-snapshot " + s + "\n"
        }
        func header(_ count: Int) -> String {
            "# peer-diag v1 platform=ios app=\(oneLine(appVersion)) os=\(oneLine(osVersion)) model=\(oneLine(deviceModel)) window=\(request.windowStartMs)-\(request.windowEndMs) lines=\(count)\n"
        }
        // Drop from the oldest side until the whole text fits.
        var total = header(lines.count).utf8.count + snapshotLine.utf8.count
            + lines.reduce(0) { $0 + $1.utf8.count + 1 }
        var drop = 0
        while total > maxBytes && drop < lines.count {
            total -= lines[drop].utf8.count + 1
            drop += 1
        }
        if drop > 0 { lines.removeFirst(drop) }
        guard !lines.isEmpty else { return nil }
        return header(lines.count) + snapshotLine + lines.joined(separator: "\n") + "\n"
    }
}

@MainActor
final class PeerDiagResponder {

    static let shared = PeerDiagResponder()

    /// Everything the responder needs from the outside, as plain values and closures.
    struct Dependencies {
        /// Local kill switch (`PeerDiagFeature`).
        var featureEnabled: @MainActor () -> Bool = { PeerDiagFeature.isEnabled }
        var diagnosticsEnabled: @MainActor () -> Bool = { TelemetryService.isEnabled }
        var nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000.0) }
        /// Sends `diag_ack` on the socket.
        var sendAck: (String) -> Void = { _ in }
        /// Copy of the log ring covering the last `minutes` minutes.
        var readRing: @MainActor (Double) -> [LiveLogRawEntry] = { RuntimeLogSink.shared.recentRawEntries(minutes: $0) }
        var token: @MainActor () -> String? = { nil }
        /// Refreshes the session after a 401 for the given stale token; returns the new token.
        var refreshToken: @MainActor (String) async -> String? = { _ in nil }
        var serverUrl: @MainActor () -> String = { "" }
        var activeCallId: @MainActor () -> String? = { nil }
        var callSnapshot: @MainActor () -> String = { "{}" }
        var adminPubKey: @MainActor (String, String) async -> String? = { _, _ in nil }
        var isThermalSerious: () -> Bool = {
            let s = ProcessInfo.processInfo.thermalState
            return s == .serious || s == .critical
        }
        var upload: (URLRequest, String) async -> Int? = { request, serverUrl in
            do {
                let (_, response) = try await PinnedURLSession.auxiliary(for: serverUrl).data(for: request)
                return (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch { return nil }
        }
        var sleep: (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        var loadHandled: () -> [(id: String, atMs: Int64)] = {
            let raw = UserDefaults.standard.array(forKey: PeerDiagResponder.handledKey) as? [[String: Any]] ?? []
            return raw.compactMap { d in
                guard let id = d["id"] as? String, let at = (d["at"] as? NSNumber)?.int64Value else { return nil }
                return (id: id, atMs: at)
            }
        }
        var saveHandled: ([(id: String, atMs: Int64)]) -> Void = { items in
            let raw: [[String: Any]] = items.map { ["id": $0.id, "at": NSNumber(value: $0.atMs)] }
            UserDefaults.standard.set(raw, forKey: PeerDiagResponder.handledKey)
        }
        /// The calls this device took part in (48 h).
        var loadCalls: @MainActor () -> [PeerDiagCallRecord] = { PeerDiagCallLedgerStore.loadClosingStale() }
        /// Times (ms) at which a request was answered, for the daily cap.
        var loadAnswered: () -> [Int64] = {
            (UserDefaults.standard.array(forKey: PeerDiagResponder.answeredKey) as? [NSNumber] ?? []).map { $0.int64Value }
        }
        var saveAnswered: ([Int64]) -> Void = { times in
            UserDefaults.standard.set(times.map { NSNumber(value: $0) }, forKey: PeerDiagResponder.answeredKey)
        }
    }

    nonisolated static let handledKey = "qaudion.peerdiag.handled"
    nonisolated static let answeredKey = "qaudion.peerdiag.answered"
    static let retryDelays: [TimeInterval] = [30, 120, 480]
    static let deferPollSeconds: TimeInterval = 30

    var deps: Dependencies
    private var inFlight: Set<String> = []

    init(deps: Dependencies = Dependencies()) { self.deps = deps }

    /// Entry point for an inbound `diag_request` frame. Returns the work task (tests await it).
    @discardableResult
    func handle(_ data: [String: Any]) -> Task<Void, Never>? {
        guard deps.featureEnabled(), let parsed = PeerDiagRequest.parse(data) else { return nil }
        let now = deps.nowMs()
        let expiry = PeerDiagRequest.effectiveExpiry(receivedMs: now, expiresMs: parsed.expiresMs)
        var handled = PeerDiagHandledSet(entries: deps.loadHandled())
        var ledger = PeerDiagCallLedger(records: deps.loadCalls())
        ledger.prune(nowMs: now, keepOpen: Set([deps.activeCallId()?.lowercased()].compactMap { $0 }))
        let call = ledger.record(for: parsed.callId)
        let activeNow = deps.activeCallId()
        let answered = PeerDiagQuota.recent(deps.loadAnswered(), nowMs: now)
        let decision = PeerDiagGate.decide(
            nowMs: now, expiresMs: expiry,
            alreadyHandled: handled.contains(parsed.requestId, nowMs: now)
                || inFlight.contains(parsed.requestId),
            diagnosticsEnabled: deps.diagnosticsEnabled(),
            featureEnabled: true,
            callKnown: call != nil,
            withinQuota: PeerDiagQuota.allows(answered, nowMs: now))
        switch decision {
        case .ignore:
            return nil
        case .reAck:
            deps.sendAck(parsed.requestId)
            return nil
        case .ackOnly:
            handled.insert(parsed.requestId, nowMs: now)
            deps.saveHandled(handled.entries)
            deps.sendAck(parsed.requestId)
            return nil
        case .collect:
            guard let call, let request = parsed.clamped(to: call, nowMs: now, expiresMs: expiry, activeCallId: activeNow) else {
                return nil
            }
            handled.insert(request.requestId, nowMs: now)
            deps.saveHandled(handled.entries)
            deps.saveAnswered(answered + [now])
            deps.sendAck(request.requestId)
            inFlight.insert(request.requestId)
            // The call snapshot is taken now, while the call is the active one: after a
            // deferral it is gone. The ring is read only after the deferral.
            var snapshot: String?
            if let active = deps.activeCallId(), active.lowercased() == request.callId.lowercased() {
                snapshot = deps.callSnapshot()
            }
            return Task { [weak self] in
                await self?.run(request: request, snapshot: snapshot)
            }
        }
    }

    private func mayContinue() -> Bool {
        deps.featureEnabled() && PeerDiagGate.mayCollect(diagnosticsEnabled: deps.diagnosticsEnabled())
    }

    func run(request: PeerDiagRequest, snapshot: String?) async {
        defer { inFlight.remove(request.requestId) }
        // Wait out an active call and a hot device, until the request expires.
        while deps.activeCallId() != nil || deps.isThermalSerious() {
            if deps.nowMs() >= request.expiresMs { return }
            await deps.sleep(Self.deferPollSeconds)
        }
        // Consent and kill switch again after the wait, before the ring is touched.
        guard deps.nowMs() < request.expiresMs, mayContinue() else { return }
        let minutes = max(1.0, Double(deps.nowMs() - request.windowStartMs) / 60_000.0)
        let ring = deps.readRing(min(minutes, 24 * 60))
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let os = UIDevice.current.systemVersion
        let model = UIDevice.current.model
        let req = request
        let plaintext = await Task.detached(priority: .background) {
            PeerDiagLogBuilder.build(entries: ring, request: req, appVersion: version,
                                     osVersion: os, deviceModel: model, callSnapshot: snapshot,
                                     maxBytes: min(PeerDiagLogBuilder.maxPlaintextBytes, req.maxBytes - 28))
        }.value
        guard let plaintext else { return }
        var attempt = 0
        while true {
            if deps.nowMs() >= request.expiresMs { return }
            // Consent again, right before the bytes leave the device.
            guard mayContinue() else { return }
            let status = await attemptUpload(request: request, plaintext: plaintext, version: version)
            if let code = status {
                if (200..<300).contains(code) { return }
                if code != 429 && code < 500 { return }
            }
            guard attempt < Self.retryDelays.count else { return }
            await deps.sleep(Self.retryDelays[attempt])
            attempt += 1
        }
    }

    /// One attempt. `nil` = no HTTP answer (network error, no token, no key yet): retry.
    func attemptUpload(request: PeerDiagRequest, plaintext: String, version: String) async -> Int? {
        let serverUrl = deps.serverUrl()
        guard !serverUrl.isEmpty, let token = deps.token(), !token.isEmpty,
              let url = URL(string: serverUrl + "/api/v1/diag-requests/" + request.requestId + "/logs"),
              let key = await deps.adminPubKey(serverUrl, token),
              let enc = try? ReportCrypto.encrypt(adminPubKeyHex: key, plaintext: Data(plaintext.utf8)),
              enc.ciphertext.count <= request.maxBytes
        else { return nil }
        func send(_ bearer: String) async -> Int? {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.setValue(request.nonce, forHTTPHeaderField: "X-Diag-Nonce")
            req.setValue(enc.ephemeralPubHex, forHTTPHeaderField: "X-Diag-Eph")
            req.setValue("ios", forHTTPHeaderField: "X-Platform")
            req.setValue(String(version.prefix(32)), forHTTPHeaderField: "X-App-Version")
            req.httpBody = enc.ciphertext
            req.timeoutInterval = 60
            return await deps.upload(req, serverUrl)
        }
        let status = await send(token)
        // One refresh-and-retry when the access token was rejected.
        if status == 401, let fresh = await deps.refreshToken(token), !fresh.isEmpty {
            return await send(fresh)
        }
        return status
    }
}
