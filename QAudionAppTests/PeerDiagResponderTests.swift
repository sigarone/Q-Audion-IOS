import XCTest
import CryptoKit
import QAudionEngine
@testable import QAudionApp

/// Diagnostics request responder: consent gate, local record of calls, window clamps, upload
/// behaviour (through `run` / `attemptUpload` with injected dependencies) and window selection.
@MainActor
final class PeerDiagResponderTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000
    private let callId = "11111111-2222-3333-4444-555555555555"

    /// Plain mutable state the injected closures read and write.
    final class Harness {
        var now: Int64 = 1_800_000_000_000
        var featureOn = true
        var diagOn = true
        var acks: [String] = []
        var reads = 0
        var uploads: [URLRequest] = []
        var statuses: [Int?] = [200]
        var sleeps: [TimeInterval] = []
        var busy = false
        var busyUntilSleeps = 2
        var onSleep: (() -> Void)?
        var calls: [PeerDiagCallRecord] = []
        var handled: [(id: String, atMs: Int64)] = []
        var answered: [Int64] = []
        var token: String? = "tok-abc"
        var serverUrl = "https://srv.example"
        var key: String? = {
            let k = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            return k.map { String(format: "%02x", $0) }.joined()
        }()
        var ring: [LiveLogRawEntry] = []
        var snapshotCalls = 0
    }

    private func entry(_ seq: Int64, atMs: Int64, msg: String = "m") -> LiveLogRawEntry {
        LiveLogRawEntry(seq: seq, timestamp: Date(timeIntervalSince1970: Double(atMs) / 1000.0),
                        level: "warn", tag: "call", message: msg)
    }

    private func harness(callKnown: Bool = true) -> Harness {
        let h = Harness()
        h.now = now
        if callKnown {
            h.calls = [PeerDiagCallRecord(id: callId, startMs: now - 20 * 60_000, endMs: now - 60_000)]
        }
        h.ring = [entry(1, atMs: now - 120_000, msg: "hello")]
        return h
    }

    private func make(_ h: Harness) -> PeerDiagResponder {
        var deps = PeerDiagResponder.Dependencies()
        deps.featureEnabled = { h.featureOn }
        deps.diagnosticsEnabled = { h.diagOn }
        deps.nowMs = { h.now }
        deps.sendAck = { h.acks.append($0) }
        deps.readRing = { _ in h.reads += 1; return h.ring }
        deps.token = { h.token }
        deps.serverUrl = { h.serverUrl }
        deps.activeCallId = { h.busy ? "other-call" : nil }
        deps.callSnapshot = { h.snapshotCalls += 1; return "{}" }
        deps.adminPubKey = { _, _ in h.key }
        deps.isThermalSerious = { false }
        deps.upload = { req, _ in
            h.uploads.append(req)
            let i = min(h.uploads.count - 1, h.statuses.count - 1)
            return h.statuses[i]
        }
        deps.sleep = { s in
            h.sleeps.append(s)
            if h.busy && h.sleeps.count >= h.busyUntilSleeps { h.busy = false }
            h.onSleep?()
        }
        deps.loadHandled = { h.handled }
        deps.saveHandled = { h.handled = $0 }
        deps.loadCalls = { h.calls }
        deps.loadAnswered = { h.answered }
        deps.saveAnswered = { h.answered = $0 }
        return PeerDiagResponder(deps: deps)
    }

    private func frame(id: String = "req-1", call: String? = nil, start: Int64? = nil, end: Int64? = nil,
                       expires: Int64? = nil, maxBytes: Int = 524288,
                       nonce: String = "AAAAAAAAAAAAAAAAAAAAAA") -> [String: Any] {
        return [
            "v": 1,
            "request_id": id,
            "call_id": call ?? callId,
            "window_start_ms": NSNumber(value: start ?? (now - 600_000)),
            "window_end_ms": NSNumber(value: end ?? now),
            "max_bytes": maxBytes,
            "expires_ms": NSNumber(value: expires ?? (now + 7_200_000)),
            "nonce": nonce,
        ]
    }

    private func request(_ h: Harness? = nil, maxBytes: Int = 524288) throws -> PeerDiagRequest {
        try XCTUnwrap(PeerDiagRequest.parse(frame(maxBytes: maxBytes)))
    }

    // MARK: - Gate

    func testGateDecisions() {
        func d(_ expires: Int64 = 1, handled: Bool = false, diag: Bool = true, feature: Bool = true,
               known: Bool = true, quota: Bool = true) -> PeerDiagGate.Decision {
            PeerDiagGate.decide(nowMs: now, expiresMs: now + expires, alreadyHandled: handled,
                                diagnosticsEnabled: diag, featureEnabled: feature, callKnown: known,
                                withinQuota: quota)
        }
        XCTAssertEqual(d(), .collect)
        XCTAssertEqual(d(diag: false), .ackOnly)
        XCTAssertEqual(d(0), .ignore)
        XCTAssertEqual(d(handled: true), .reAck)
        XCTAssertEqual(d(0, handled: true), .ignore)
        XCTAssertEqual(d(feature: false), .ignore)
        XCTAssertEqual(d(known: false), .ignore)
        XCTAssertEqual(d(diag: false, known: false), .ignore)
        XCTAssertEqual(d(quota: false), .ignore)
    }

    func testToggleOffOnlyAcksAndNeverReadsTheRing() {
        let h = harness()
        h.diagOn = false
        let r = make(h)
        XCTAssertNil(r.handle(frame()))
        XCTAssertEqual(h.acks, ["req-1"])
        XCTAssertEqual(h.reads, 0)
        XCTAssertTrue(h.uploads.isEmpty)
    }

    func testToggleOnAcksReadsTheRingOnceAndUploads() async throws {
        let h = harness()
        let r = make(h)
        let task = r.handle(frame())
        XCTAssertNotNil(task)
        await task?.value
        XCTAssertEqual(h.acks, ["req-1"])
        XCTAssertEqual(h.reads, 1)
        XCTAssertEqual(h.uploads.count, 1)
        XCTAssertEqual(h.answered, [now])
    }

    func testKillSwitchOffIgnoresEverything() {
        let h = harness()
        h.featureOn = false
        let r = make(h)
        XCTAssertNil(r.handle(frame()))
        XCTAssertTrue(h.acks.isEmpty)
        XCTAssertEqual(h.reads, 0)
        XCTAssertTrue(h.handled.isEmpty)
    }

    func testKillSwitchResolutionIsOffOnly() {
        XCTAssertTrue(FeatureFlags.resolveKillSwitch(compiledDefault: PeerDiagFeature.compiledDefault, remote: nil))
        XCTAssertFalse(FeatureFlags.resolveKillSwitch(compiledDefault: PeerDiagFeature.compiledDefault, remote: false))
        XCTAssertEqual(PeerDiagFeature.flagKey, "peer_diag.enabled")
    }

    func testExpiredAndMalformedFramesAreIgnored() {
        let h = harness()
        let r = make(h)
        XCTAssertNil(r.handle(frame(expires: now - 6 * 60_000)))
        XCTAssertNil(r.handle(["type": "nonsense"]))
        XCTAssertTrue(h.acks.isEmpty)
        XCTAssertEqual(h.reads, 0)
    }

    // MARK: - Defence in depth

    func testUnknownCallIsIgnoredEvenWithToggleOn() {
        let h = harness(callKnown: false)
        let r = make(h)
        XCTAssertNil(r.handle(frame()))
        XCTAssertNil(r.handle(frame(call: "99999999-2222-3333-4444-555555555555")))
        XCTAssertTrue(h.acks.isEmpty)
        XCTAssertEqual(h.reads, 0)
        XCTAssertTrue(h.answered.isEmpty)
    }

    func testCallIdMatchIsCaseInsensitive() async {
        let h = harness()
        let r = make(h)
        let task = r.handle(frame(call: callId.uppercased()))
        XCTAssertNotNil(task)
        await task?.value
        XCTAssertEqual(h.uploads.count, 1)
    }

    func testWindowIsClampedToTheCallPlusSixtySeconds() throws {
        let call = PeerDiagCallRecord(id: callId, startMs: now - 600_000, endMs: now - 300_000)
        let req = try request()
        let c = try XCTUnwrap(req.clamped(to: call, nowMs: now, expiresMs: now + 1))
        XCTAssertEqual(c.windowStartMs, now - 600_000)
        XCTAssertEqual(c.windowEndMs, now - 240_000)
        // Ongoing call: ends "now" + 60 s.
        let ongoing = PeerDiagCallRecord(id: callId, startMs: now - 100_000, endMs: nil)
        let o = try XCTUnwrap(req.clamped(to: ongoing, nowMs: now, expiresMs: now + 1, activeCallId: callId.uppercased()))
        XCTAssertEqual(o.windowStartMs, now - 160_000)
        XCTAssertEqual(o.windowEndMs, now)
        // A window entirely outside the call leaves nothing.
        let old = PeerDiagCallRecord(id: callId, startMs: now - 9_000_000, endMs: now - 8_000_000)
        XCTAssertNil(req.clamped(to: old, nowMs: now, expiresMs: now + 1))
    }

    func testWindowIsClampedToThirtyMinutes() throws {
        let call = PeerDiagCallRecord(id: callId, startMs: now - 4 * 3_600_000, endMs: nil)
        let req = try XCTUnwrap(PeerDiagRequest.parse(frame(start: now - 3 * 3_600_000, end: now)))
        let c = try XCTUnwrap(req.clamped(to: call, nowMs: now, expiresMs: now + 1, activeCallId: callId))
        XCTAssertEqual(c.windowEndMs - c.windowStartMs, PeerDiagRequest.maxWindowMs)
        XCTAssertEqual(c.windowEndMs, now)
    }

    func testLogsOutsideTheCallAreNeverSent() async throws {
        let h = harness()
        h.ring = [entry(1, atMs: now - 15 * 60_000, msg: "before the call window")]
        // Call started 5 min ago: the clamp starts at now-6min, so the older line is out.
        h.calls = [PeerDiagCallRecord(id: callId, startMs: now - 5 * 60_000, endMs: nil)]
        let r = make(h)
        await r.handle(frame(start: now - 30 * 60_000, end: now))?.value
        XCTAssertEqual(h.reads, 1)
        XCTAssertTrue(h.uploads.isEmpty)
    }

    func testAtMostTenRequestsPerDay() async {
        let h = harness()
        h.answered = (0..<10).map { now - Int64($0) * 1000 }
        let r = make(h)
        XCTAssertNil(r.handle(frame()))
        XCTAssertTrue(h.acks.isEmpty)
        // A request older than 24 h no longer counts.
        h.answered = (0..<10).map { now - 25 * 3_600_000 - Int64($0) }
        let task = r.handle(frame(id: "req-2"))
        XCTAssertNotNil(task)
        await task?.value
        XCTAssertEqual(h.answered, [now])
        XCTAssertTrue(PeerDiagQuota.allows((0..<9).map { now - Int64($0) }, nowMs: now))
        XCTAssertFalse(PeerDiagQuota.allows((0..<10).map { now - Int64($0) }, nowMs: now))
    }

    func testDuplicateFrameIsReAckedOnceHandledAndNotExpired() async {
        let h = harness()
        let r = make(h)
        await r.handle(frame())?.value
        XCTAssertEqual(h.acks, ["req-1"])
        XCTAssertNil(r.handle(frame()))
        XCTAssertEqual(h.acks, ["req-1", "req-1"])
        XCTAssertEqual(h.reads, 1)
        XCTAssertEqual(h.uploads.count, 1)
        // Expired: silent.
        h.now = now + 3 * 3_600_000
        XCTAssertNil(r.handle(frame()))
        XCTAssertEqual(h.acks.count, 2)
    }

    func testClockSkewAndAbsurdExpiry() {
        // 4 min past expiry is still inside the 5 min skew; 6 min is not.
        XCTAssertEqual(PeerDiagRequest.effectiveExpiry(receivedMs: now, expiresMs: now - 4 * 60_000), now + 60_000)
        XCTAssertLessThan(PeerDiagRequest.effectiveExpiry(receivedMs: now, expiresMs: now - 6 * 60_000), now)
        // Absurd expiry: now + 2 h.
        XCTAssertEqual(PeerDiagRequest.effectiveExpiry(receivedMs: now, expiresMs: Int64.max - 1), now + 7_200_000)
        XCTAssertEqual(PeerDiagRequest.effectiveExpiry(receivedMs: now, expiresMs: now + 10 * 3_600_000), now + 7_200_000)
        let h = harness()
        let r = make(h)
        XCTAssertNotNil(r.handle(frame(expires: now - 4 * 60_000)))
    }

    func testIdsAndNoncesAreAsciiTokensOnly() {
        XCTAssertNotNil(PeerDiagRequest.parse(frame()))
        XCTAssertNil(PeerDiagRequest.parse(frame(id: "req/1")))
        XCTAssertNil(PeerDiagRequest.parse(frame(id: "req\u{00E9}")))
        XCTAssertNil(PeerDiagRequest.parse(frame(id: "req 1")))
        XCTAssertNil(PeerDiagRequest.parse(frame(call: "../etc")))
        XCTAssertNil(PeerDiagRequest.parse(frame(nonce: "AAAA==")))
        XCTAssertNil(PeerDiagRequest.parse(frame(nonce: "a+b")))
        XCTAssertNotNil(PeerDiagRequest.parse(frame(nonce: "a-b_C9")))
        // Server nonce: base64url without padding, 22 characters.
        let n22 = "Zm9vYmFyLV9iYXpRdXV4MQ"
        XCTAssertEqual(n22.count, 22)
        XCTAssertEqual(PeerDiagRequest.parse(frame(nonce: n22))?.nonce, n22)
    }

    func testSnapshotKeepsOnlyEightCharacterPrefixesOfOtherIds() throws {
        let other = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let snap = "{\"call\":{\"group_call_id\":\"\(callId)\",\"group_participants\":[\"\(other)\",\"user-with-a-long-name\"],\"x\":\"peer \(other)\"}}"
        let out = PeerDiagLogBuilder.sanitizeSnapshot(snap, keepCallId: callId)
        XCTAssertTrue(out.contains(callId))
        XCTAssertFalse(out.contains(other))
        XCTAssertFalse(out.contains("user-with-a-long-name"))
        XCTAssertTrue(out.contains("aaaaaaaa"))
        XCTAssertTrue(out.contains("user-wit"))
        // Not JSON: the UUID cut still applies.
        XCTAssertFalse(PeerDiagLogBuilder.sanitizeSnapshot("peer \(other)", keepCallId: callId).contains(other))
    }

    // MARK: - Call record

    func testLedgerTracksCallsAndExpiresAfterFortyEightHours() {
        var l = PeerDiagCallLedger()
        l.sync(activeIds: ["ABC"], nowMs: now)
        XCTAssertEqual(l.record(for: "abc"), PeerDiagCallRecord(id: "abc", startMs: now, endMs: nil, lastSeenMs: now))
        l.sync(activeIds: [], nowMs: now + 5000)
        XCTAssertEqual(l.record(for: "ABC")?.endMs, now + 5000)
        l.noteRang(id: "ring-1", nowMs: now + 6000)
        XCTAssertEqual(l.record(for: "ring-1")?.endMs, now + 6000 + PeerDiagCallLedger.ringMs)
        // Answered after ringing: same record, reopened.
        l.sync(activeIds: ["ring-1"], nowMs: now + 8000)
        XCTAssertEqual(l.record(for: "ring-1"), PeerDiagCallRecord(id: "ring-1", startMs: now + 6000, endMs: nil, lastSeenMs: now + 8000))
        l.sync(activeIds: [], nowMs: now + 9000)
        l.prune(nowMs: now + PeerDiagCallLedger.ttlMs + 10_000)
        XCTAssertNil(l.record(for: "abc"))
        XCTAssertNil(l.record(for: "ring-1"))
    }

    func testStaleOpenRecordIsClosedAfterFourHours() {
        var l = PeerDiagCallLedger(records: [PeerDiagCallRecord(id: "open", startMs: now, endMs: nil)])
        l.prune(nowMs: now + 3 * 3_600_000)
        XCTAssertNil(l.record(for: "open")?.endMs)
        l.prune(nowMs: now + 5 * 3_600_000)
        XCTAssertEqual(l.record(for: "open")?.endMs, now)
        l.prune(nowMs: now + PeerDiagCallLedger.ttlMs + 10_000)
        XCTAssertNil(l.record(for: "open"))
    }

    func testHeartbeatRefreshesLastSeenOnlyEveryTwentySeconds() {
        var l = PeerDiagCallLedger()
        l.sync(activeIds: ["c1"], nowMs: now)
        l.sync(activeIds: ["c1"], nowMs: now + 5000)
        XCTAssertEqual(l.record(for: "c1")?.lastSeenMs, now)
        l.sync(activeIds: ["c1"], nowMs: now + PeerDiagCallLedger.heartbeatMs)
        XCTAssertEqual(l.record(for: "c1")?.lastSeenMs, now + PeerDiagCallLedger.heartbeatMs)
        XCTAssertNil(l.record(for: "c1")?.endMs)
    }

    func testReloadClosesEveryOpenEntryAtLastSeen() {
        var l = PeerDiagCallLedger(records: [
            PeerDiagCallRecord(id: "a", startMs: now, endMs: nil, lastSeenMs: now + 90_000),
            PeerDiagCallRecord(id: "b", startMs: now, endMs: nil),
            PeerDiagCallRecord(id: "c", startMs: now, endMs: now + 5000, lastSeenMs: now + 4000),
        ])
        l.closeAllOpen()
        XCTAssertEqual(l.record(for: "a")?.endMs, now + 90_000)
        XCTAssertEqual(l.record(for: "b")?.endMs, now)
        XCTAssertEqual(l.record(for: "c")?.endMs, now + 5000)
    }

    func testOpenEntryNotReportedActiveUsesLastSeen() throws {
        let call = PeerDiagCallRecord(id: callId, startMs: now - 3_600_000, endMs: nil, lastSeenMs: now - 3_000_000)
        XCTAssertEqual(call.effectiveEndMs(nowMs: now, isActive: false), now - 3_000_000)
        XCTAssertEqual(call.effectiveEndMs(nowMs: now, isActive: true), now)
        let req = try XCTUnwrap(PeerDiagRequest.parse(frame(start: now - 30 * 60_000, end: now)))
        // Another call is active (or none): the window stops at last seen + 60 s, which is
        // before the requested window, so nothing is left.
        XCTAssertNil(req.clamped(to: call, nowMs: now, expiresMs: now + 1, activeCallId: "other-call"))
        XCTAssertNil(req.clamped(to: call, nowMs: now, expiresMs: now + 1))
        XCTAssertNotNil(req.clamped(to: call, nowMs: now, expiresMs: now + 1, activeCallId: callId))
    }

    func testCallDurationIsCappedAtFourHours() {
        let start = now - 10 * 3_600_000
        let cap = start + PeerDiagCallRecord.maxDurationMs
        let active = PeerDiagCallRecord(id: callId, startMs: start, endMs: nil, lastSeenMs: now)
        XCTAssertEqual(active.effectiveEndMs(nowMs: now, isActive: true), cap)
        XCTAssertEqual(active.effectiveEndMs(nowMs: now, isActive: false), cap)
        let closed = PeerDiagCallRecord(id: callId, startMs: start, endMs: now)
        XCTAssertEqual(closed.effectiveEndMs(nowMs: now, isActive: false), cap)
    }

    func testOne401RefreshesTokenAndRetriesOnce() async throws {
        let h = harness()
        let r = make(h)
        r.deps.refreshToken = { _ in "tok-new" }
        r.deps.upload = { req, _ in
            h.uploads.append(req)
            return h.uploads.count == 1 ? 401 : 200
        }
        let req = try XCTUnwrap(PeerDiagRequest.parse(frame()))
        let status = await r.attemptUpload(request: req, plaintext: "hello", version: "1")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(h.uploads.count, 2)
        XCTAssertEqual(h.uploads[1].value(forHTTPHeaderField: "Authorization"), "Bearer tok-new")
    }

    // MARK: - Upload through run / attemptUpload

    func testConsentWithdrawnDuringDeferralUploadsNothingAndNeverReadsTheRing() async {
        let h = harness()
        h.busy = true
        h.onSleep = { h.diagOn = false }
        let r = make(h)
        let task = r.handle(frame())
        XCTAssertNotNil(task)
        await task?.value
        XCTAssertFalse(h.sleeps.isEmpty)
        XCTAssertTrue(h.uploads.isEmpty)
        XCTAssertEqual(h.reads, 0)
    }

    func testDeferralDuringActiveCallReadsRingOnlyAfterwards() async {
        let h = harness()
        h.busy = true
        h.busyUntilSleeps = 2
        let r = make(h)
        await r.handle(frame())?.value
        XCTAssertEqual(h.sleeps, [PeerDiagResponder.deferPollSeconds, PeerDiagResponder.deferPollSeconds])
        XCTAssertEqual(h.reads, 1)
        XCTAssertEqual(h.uploads.count, 1)
    }

    func testRequestExpiringDuringDeferralIsDropped() async {
        let h = harness()
        h.busy = true
        h.busyUntilSleeps = 1000
        h.onSleep = { h.now += 3 * 3_600_000 }
        let r = make(h)
        await r.handle(frame())?.value
        XCTAssertEqual(h.reads, 0)
        XCTAssertTrue(h.uploads.isEmpty)
    }

    func testUploadUrlAndHeaders() async throws {
        let h = harness()
        let r = make(h)
        await r.handle(frame(nonce: "Nonce_9-x"))?.value
        let req = try XCTUnwrap(h.uploads.first)
        XCTAssertEqual(req.url?.absoluteString, "https://srv.example/api/v1/diag-requests/req-1/logs")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-abc")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Diag-Nonce"), "Nonce_9-x")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Platform"), "ios")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Diag-Eph")?.count, 64)
        XCTAssertNotNil(req.value(forHTTPHeaderField: "X-App-Version"))
        XCTAssertGreaterThan(req.httpBody?.count ?? 0, 28)
        XCTAssertLessThanOrEqual(req.httpBody?.count ?? Int.max, 524288)
    }

    func testRetriesOn429And5xxThenStopsOnSuccess() async {
        let h = harness()
        h.statuses = [429, 503, 200]
        let r = make(h)
        await r.handle(frame())?.value
        XCTAssertEqual(h.uploads.count, 3)
        XCTAssertEqual(h.sleeps, [30, 120])
    }

    func testOtherClientErrorsStopImmediately() async {
        for code in [400, 401, 403, 404, 413] {
            let h = harness()
            h.statuses = [code]
            let r = make(h)
            await r.handle(frame(id: "req-\(code)"))?.value
            XCTAssertEqual(h.uploads.count, 1, "status \(code)")
            XCTAssertTrue(h.sleeps.isEmpty, "status \(code)")
        }
    }

    func testBackoffIsThirtyOneTwentyFourEighty() async {
        let h = harness()
        h.statuses = [500]
        let r = make(h)
        await r.handle(frame())?.value
        XCTAssertEqual(h.sleeps, [30, 120, 480])
        XCTAssertEqual(h.uploads.count, 4)
    }

    func testNetworkErrorRetriesLikeA5xx() async {
        let h = harness()
        h.statuses = [nil, 200]
        let r = make(h)
        await r.handle(frame())?.value
        XCTAssertEqual(h.uploads.count, 2)
        XCTAssertEqual(h.sleeps, [30])
    }

    func testCiphertextOverMaxBytesIsNeverSent() async throws {
        let h = harness()
        let r = make(h)
        let req = try XCTUnwrap(PeerDiagRequest.parse(frame()))
        let big = String(repeating: "x", count: 2000)
        let tiny = PeerDiagRequest(requestId: req.requestId, callId: req.callId, windowStartMs: req.windowStartMs,
                                   windowEndMs: req.windowEndMs, maxBytes: 100, expiresMs: now + 1000, nonce: req.nonce)
        let status = await r.attemptUpload(request: tiny, plaintext: big, version: "1")
        XCTAssertNil(status)
        XCTAssertTrue(h.uploads.isEmpty)
    }

    func testNoTokenOrNoKeyMeansNoUpload() async throws {
        let req = try request()
        let h1 = harness()
        h1.token = nil
        let s1 = await make(h1).attemptUpload(request: req, plaintext: "hello", version: "1")
        XCTAssertNil(s1)
        XCTAssertTrue(h1.uploads.isEmpty)
        let h2 = harness()
        h2.token = ""
        let s2 = await make(h2).attemptUpload(request: req, plaintext: "hello", version: "1")
        XCTAssertNil(s2)
        XCTAssertTrue(h2.uploads.isEmpty)
        let h3 = harness()
        h3.key = nil
        let s3 = await make(h3).attemptUpload(request: req, plaintext: "hello", version: "1")
        XCTAssertNil(s3)
        XCTAssertTrue(h3.uploads.isEmpty)
    }

    func testNoKeyRetriesThenGivesUpWithoutPlaintextFallback() async {
        let h = harness()
        h.key = nil
        let r = make(h)
        await r.handle(frame())?.value
        XCTAssertTrue(h.uploads.isEmpty)
        XCTAssertEqual(h.sleeps, [30, 120, 480])
    }

    func testHandledSetKeepsTwentyForFourHours() {
        var set = PeerDiagHandledSet()
        for i in 0..<25 { set.insert("id\(i)", nowMs: now + Int64(i)) }
        XCTAssertEqual(set.entries.count, 20)
        XCTAssertFalse(set.contains("id0", nowMs: now + 30))
        XCTAssertTrue(set.contains("id24", nowMs: now + 30))
        XCTAssertFalse(set.contains("id24", nowMs: now + PeerDiagHandledSet.ttlMs + 100))
    }

    // MARK: - Window

    func testWindowKeepsOnlyEntriesInsideAndOrdersOldestFirst() throws {
        let request = try XCTUnwrap(PeerDiagRequest.parse(frame(start: now - 60_000, end: now)))
        let entries = [
            entry(3, atMs: now - 1_000),
            entry(1, atMs: now - 120_000),
            entry(2, atMs: now - 30_000),
            entry(4, atMs: now + 5_000),
        ]
        XCTAssertEqual(PeerDiagLogBuilder.select(entries, request: request).map { $0.seq }, [2, 3])
    }

    func testWindowIsNarrowedToThirtyMinutes() throws {
        let request = try XCTUnwrap(PeerDiagRequest.parse(frame(start: now - 3_600_000, end: now)))
        let entries = [entry(1, atMs: now - 40 * 60_000), entry(2, atMs: now - 20 * 60_000)]
        XCTAssertEqual(PeerDiagLogBuilder.select(entries, request: request).map { $0.seq }, [2])
    }

    func testBuildSendsNothingWhenWindowIsEmpty() throws {
        let request = try XCTUnwrap(PeerDiagRequest.parse(frame(start: now - 60_000, end: now)))
        let text = PeerDiagLogBuilder.build(entries: [entry(1, atMs: now - 500_000)], request: request,
                                            appVersion: "1", osVersion: "27", deviceModel: "iPhone",
                                            callSnapshot: nil)
        XCTAssertNil(text)
    }

    func testBuildFormatsLinesAndDropsOldestToFitTheCap() throws {
        let request = try XCTUnwrap(PeerDiagRequest.parse(frame(start: now - 600_000, end: now)))
        let pad = String(repeating: "x", count: 100)
        let entries = (0..<200).map { i in
            entry(Int64(i), atMs: now - 500_000 + Int64(i) * 100, msg: "line \(i) " + pad)
        }
        let full = try XCTUnwrap(PeerDiagLogBuilder.build(entries: entries, request: request, appVersion: "1",
                                                          osVersion: "27", deviceModel: "iPhone", callSnapshot: nil))
        XCTAssertTrue(full.hasPrefix("# peer-diag v1 platform=ios"))
        let first = try XCTUnwrap(full.split(separator: "\n").dropFirst().first)
        XCTAssertTrue(first.contains("Z W [call] line 0 "), String(first))
        let capped = try XCTUnwrap(PeerDiagLogBuilder.build(entries: entries, request: request, appVersion: "1",
                                                            osVersion: "27", deviceModel: "iPhone",
                                                            callSnapshot: nil, maxBytes: 4000))
        XCTAssertLessThanOrEqual(capped.utf8.count, 4000)
        XCTAssertTrue(capped.contains("line 199 "))
        XCTAssertFalse(capped.contains("line 0 "))
    }
}
