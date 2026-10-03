import Foundation
import CryptoKit
import UIKit
import QAudionEngine

/// W541-3 — Encrypted telemetry batch pump.
///
/// Buffers `TelemetryEvent` values, periodically seals a batch with
/// X25519+AES-256-GCM against the server's public key, and POSTs the
/// wire to `POST /api/v1/telemetry/batch`.
///
/// Wire format documented in `docs/TELEMETRY_v1.md` §"Wire format
/// (encrypted batch)". Summary:
///
///   wire = [0x01] || ephemeral_pub(32) || nonce(12)
///        || AES-256-GCM(HKDF-SHA256(X25519(eph_priv, server_pub),
///                                  info="qaudion-telemetry-v1"),
///                       nonce, jsonl_payload)
///
/// **Design choices:**
/// - Per-batch ephemeral X25519 keypair → forward secrecy.
/// - JSONL payload (one event per line) so the server can append
///   straight to the daily file without per-batch framing overhead.
/// - 5-second flush cadence + 256-event max buffer to bound latency
///   and memory.
/// - Single-flight upload: a new flush waits for the in-flight POST
///   before starting; no parallel pumps.
/// - Failure never breaks the call and a failed batch is never thrown
///   away for being unlucky. W-RETRYAFTER (2026-10-03): on 429, 503, any
///   other 5xx, 401/402/403/404 and on a network error the events STAY
///   queued and the pump goes quiet until the server's `Retry-After`
///   (1...300 s, else 30 s doubling for 429/503, 10 s doubling otherwise,
///   plus jitter) has passed; only a 400/413/415/422 (the batch itself can
///   never be accepted) is dropped, once, counted and logged. Before this a
///   429 from the server's per-IP limiter (one bucket for every device
///   behind the same home address) was read as "the batch is rejected":
///   the batch of call 6 of 2026-10-03 was lost and the next flush hit the
///   same exhausted bucket five seconds later. The queue is bounded
///   (`maxBufferedEvents`); when it overflows the OLDEST routine event goes
///   first, every drop is counted, and the count rides in the next batch the
///   server confirms as a `telemetry.queue_dropped` event. The policy and the
///   queue are `UploadRetryPolicy` / `RetryBatchBuffer` (QAudionEngine,
///   unit-tested).
/// - Coexists with `LiveLogStreamer` (W417) — that one ships opaque
///   text chunks; this one ships structured JSON events.
/// - **C7 consent gate (2026-08-19):** opt-in, default OFF via
///   `TelemetryService.isEnabled` / `setEnabled(_:)` — parity with
///   Android `SealedTelemetryService.consentEnabled` and Desktop
///   `SealedTelemetryService.enabled`. Before this the pump ran
///   unconditionally from app launch on iOS only.
@MainActor
public final class TelemetryService {

    public static let shared = TelemetryService()

    // ─── Config ────────────────────────────────────────────────────

    /// Flush cadence. Trade-off: 5s keeps server load low while still
    /// giving the maintainer near-real-time visibility.
    public var flushIntervalSec: TimeInterval = 5.0

    /// Max events queued (sent or not yet confirmed). Prevents memory growth on a
    /// long video call with high event rate, or while the server is throttling.
    public var maxBufferedEvents: Int { return queue.capacity }

    /// `kind` of the synthetic event that reports how many queued events were dropped for
    /// want of room (W-RETRYAFTER).
    public static let droppedKind: String = "telemetry.queue_dropped"

    /// Per-batch hard cap (16 KiB of JSONL → comfortably under the
    /// server's 1 MiB max-body limit even after the 32 B X25519 +
    /// 12 B nonce + 16 B tag overhead).
    public var maxBatchBytes: Int = 16 * 1024

    /// Wire version (matches server's `telemetryWireVer`).
    private let wireVersion: UInt8 = 0x01

    /// HKDF info string (matches server's `telemetryHKDFInfo`).
    private let hkdfInfo: Data = "qaudion-telemetry-v1".data(using: .utf8)!

    // ─── State ─────────────────────────────────────────────────────

    /// Random device-id, generated once on first launch and persisted
    /// to UserDefaults. Stable across launches; rotates only on app
    /// reinstall.
    public let deviceId: String

    /// Random session-id, regenerated every launch.
    public let sessionId: String

    /// Queued events, already encoded as one JSONL line each (no trailing newline), kept
    /// until the server confirms them. Mutations on MainActor only. W-RETRYAFTER: also owns
    /// the pump's pause (`Retry-After`) and the drop counter.
    private var queue = RetryBatchBuffer<Data>(capacity: 256)

    /// Periodic flush timer. Started on first event AND on enable().
    private var flushTimer: Timer?

    /// Single-flight gate.
    private var flushInFlight: Bool = false

    /// Cached server X25519 pubkey. Fetched lazily from
    /// `/api/v1/telemetry/pubkey` and reused for every batch. Nil
    /// while bootstrapping or after a 401 (re-fetch on next attempt).
    private var serverPubKey: Curve25519.KeyAgreement.PublicKey?

    /// Closures supplied by AppState at start() time — see the
    /// LiveLogStreamer comment about NEVER taking AppState as a
    /// parameter type (Swift 6 strict concurrency Sendable inference
    /// breaks the build silently). Primitives + @MainActor closures
    /// only.
    public typealias TokenProvider = @MainActor () -> String?
    public typealias UserIdProvider = @MainActor () -> String?

    private var serverUrl: String = ""
    private var getToken: TokenProvider?
    private var getUserId: UserIdProvider?
    private var started: Bool = false

    // ─── Init ──────────────────────────────────────────────────────

    private init() {
        let key = "qaudion.telemetry.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            self.deviceId = existing
        } else {
            let new = UUID().uuidString
            UserDefaults.standard.set(new, forKey: key)
            self.deviceId = new
        }
        self.sessionId = UUID().uuidString
    }

    // ─── C7 — consent gate ─────────────────────────────────────────
    //
    // Android (`SealedTelemetryService.consentEnabled`) and Desktop
    // (`SealedTelemetryService.enabled`) both gate this exact wire
    // stream behind an `operationalDiagnosticsEnabled` opt-in that
    // defaults to false. iOS never got the equivalent gate — this
    // pump ran unconditionally from app launch (audit 2026-08-19).
    // Mirrors Desktop's shape: the UserDefaults flag decides whether
    // start() actually arms the timer/pubkey-fetch; setEnabled(_:)
    // is the runtime kill-switch a Settings toggle calls.

    /// UserDefaults bool that gates this pump. Absent/false ⇒ inert —
    /// unlike `LiveLogStreamer.isEnabled`, there is NO build-channel
    /// default-on for TestFlight/dev: this stream ships structured
    /// call-pipeline metrics (not just text logs), so it stays off
    /// until the user explicitly opts in, same as Android/Desktop.
    public static let consentKey: String = "qaudion.diagnostics.operationalDiagnosticsEnabled"

    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: consentKey)
    }

    /// Flip the consent flag at runtime. ON re-arms an already-wired
    /// pump immediately (no relaunch needed); OFF tears the timer down
    /// and drops whatever is buffered so nothing queued before the
    /// withdrawal is shipped afterward — same as Android's
    /// `buffer.clear()` / Desktop's `this.buffer = []` on revoke.
    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: consentKey)
        if enabled {
            TelemetryService.shared.activate()
        } else {
            TelemetryService.shared.disableAndClearBuffer()
        }
    }

    // ─── Lifecycle ─────────────────────────────────────────────────

    /// Wire the pump. Idempotent — calling twice is a no-op past the
    /// first call. AppState invokes this once at app start (BEFORE the
    /// call code emits any events; events emitted before activation are
    /// silently dropped).
    ///
    /// C7: the closures are captured unconditionally so a later
    /// Settings opt-in can activate the pump without AppState
    /// re-supplying them, but the timer/pubkey-fetch only start when
    /// `TelemetryService.isEnabled` is true — no consent, no network.
    public func start(
        serverUrl: String,
        getToken: @escaping TokenProvider,
        getUserId: @escaping UserIdProvider
    ) {
        self.serverUrl = serverUrl
        self.getToken = getToken
        self.getUserId = getUserId
        guard TelemetryService.isEnabled else { return }
        activate()
    }

    /// C7: actually arms the timer + pubkey prefetch. Split out of
    /// `start()` so `setEnabled(true)` can call it directly once the
    /// closures above are already wired from a prior `start()`.
    private func activate() {
        guard TelemetryService.isEnabled else { return }
        if started { return }
        started = true

        flushTimer?.invalidate()
        let timer = Timer(timeInterval: flushIntervalSec,
                          target: self,
                          selector: #selector(periodicFlushObjC),
                          userInfo: nil,
                          repeats: true)
        // Keep firing even when ScrollView is active.
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer

        // Fetch the server pubkey opportunistically so the first
        // batch doesn't pay the round-trip latency.
        Task { @MainActor [weak self] in
            await self?.fetchServerPubKeyIfNeeded()
        }
    }

    /// C7 — consent-withdrawal path. Unlike `stop()`, this does NOT
    /// flush: buffered events must not leak to the server after the
    /// user has revoked consent.
    private func disableAndClearBuffer() {
        flushTimer?.invalidate()
        flushTimer = nil
        queue.removeAll()
        started = false
    }

    public func stop() {
        flushTimer?.invalidate()
        flushTimer = nil
        // Drain anything buffered so the maintainer sees the
        // shutdown trail.
        Task { @MainActor [weak self] in
            await self?.flushOnce(reason: "stop")
        }
        started = false
    }

    // ─── Public event API ──────────────────────────────────────────

    /// Emit a structured event. Safe to call from any thread —
    /// internally hops to MainActor for queue mutation. When the queue
    /// is full the oldest routine event is dropped (counted, reported in
    /// the next confirmed batch) to make room.
    public nonisolated func emit(
        kind: String,
        callId: String? = nil,
        attrs: [String: Any] = [:]
    ) {
        let tsMs = Int64(Date().timeIntervalSince1970 * 1000)
        let attrsJSONSafe = sanitize(attrs)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.started else { return }
            // P2 SECOND EGRESS -- run every attribute STRING value through
            // the SAME fail-closed scrub the text path uses
            // (`RuntimeLogSink.redactStructured`) BEFORE the batch is
            // sealed. `sanitize(_:)` only coerces JSON types; without this
            // the structured path would ship JWT/bearer/psk/base64 in attr
            // values un-redacted. UNCONDITIONAL (never flag-gated). Done
            // here (MainActor) because `redactStructured` is MainActor-
            // isolated; `sanitize` is `nonisolated`.
            let attrsRedacted = Self.redactAttrs(attrsJSONSafe)
            let ev = TelemetryEvent(
                tsMs: tsMs,
                sessionId: self.sessionId,
                deviceId: self.deviceId,
                platform: "ios",
                appVer: Self.appVersion,
                userId: self.getUserId?(),
                callId: callId,
                kind: kind,
                attrs: attrsRedacted
            )
            // Encoded once, here, not at every (re)try.
            guard let line = ev.toJSONLLine() else { return }
            // W-RETRYAFTER: when full the OLDEST routine event goes (errors are
            // prioritised because they're rarer + more diagnostic), and every drop is
            // counted and reported in the next confirmed batch. Before this the NEWEST
            // routine event was discarded and nothing counted it.
            let dropped = self.queue.append(line, isPriority: ev.kind.contains("error"))
            if dropped > 0 && self.queue.unreportedDrops == dropped {
                // First drop since the last report: say so once, not once per event.
                RTLog.warn("telemetry", "queue full: dropping oldest queued events cap=" + String(self.maxBufferedEvents))
            }
            if self.queue.count >= self.maxBufferedEvents / 2 && !self.flushInFlight
                && !self.queue.isPaused(now: Self.monotonicNow()) {
                Task { @MainActor [weak self] in
                    await self?.flushOnce(reason: "buffer-half-full")
                }
            }
        }
    }

    // ─── Flush ─────────────────────────────────────────────────────

    @objc private func periodicFlushObjC() {
        Task { @MainActor [weak self] in
            await self?.flushOnce(reason: "periodic")
        }
    }

    private func flushOnce(reason: String) async {
        guard started else { return }
        if flushInFlight { return }
        if queue.isEmpty { return }
        // W-RETRYAFTER: an uploader the server told to wait, waits. Nothing is built, sealed or
        // sent (not even the pubkey fetch) before the pause has passed; the 5 s timer just
        // finds the gate shut.
        if queue.isPaused(now: Self.monotonicNow()) { return }

        // Single flight covers the pubkey fetch too, so two ticks cannot both go out.
        flushInFlight = true
        defer { flushInFlight = false }

        // Try to fetch pubkey if we don't have it. If still no
        // pubkey after the fetch, retain the queue for next attempt.
        if serverPubKey == nil {
            await fetchServerPubKeyIfNeeded()
            guard serverPubKey != nil else { return }
        }
        guard let token = getToken?(), !token.isEmpty else { return }

        // A drop report goes first in the batch, so its size is reserved out of the budget.
        // It is only acknowledged once the server confirms this batch.
        let reportedDrops = queue.unreportedDrops
        var jsonlBytes: Data = Data()
        if reportedDrops > 0, let line = droppedReportLine(dropped: reportedDrops) {
            jsonlBytes.append(line)
            jsonlBytes.append(0x0A)  // newline
        }
        // Snapshot batch under capped bytes. Always at least one event, so one oversized
        // event cannot wedge the queue.
        let budget = max(maxBatchBytes - jsonlBytes.count, 1)
        guard let batch = queue.peekBatch(maxCount: Int.max, maxCost: budget, cost: { $0.count + 1 }) else {
            return
        }
        for line in batch.elements {
            jsonlBytes.append(line)
            jsonlBytes.append(0x0A)  // newline
        }

        // Seal.
        // W541-3-fix1: don't shadow `self.serverPubKey` with a local
        // `let` named the same — the 401 branch below needs to clear
        // the property, but Swift binds the inner name to a
        // non-mutable constant. Use a distinctly-named local.
        guard let pubKeyForSeal = self.serverPubKey,
              let wire = sealBatch(jsonlBytes, serverPubKey: pubKeyForSeal) else {
            return
        }

        // POST.
        guard let url = URL(string: serverUrl + "/api/v1/telemetry/batch") else {
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = wire

        do {
            // W-AUXPIN (2026-09-01): cert-pinned session (same delegate/pins
            // as the REST client) instead of URLSession.shared — this
            // bearer-token POST had no pin at all (audit memory
            // reference_ios_stability_audit_2026_09_01, P1 item 6).
            let (_, resp) = try await PinnedURLSession.auxiliary(for: serverUrl).data(for: req)
            let http = resp as? HTTPURLResponse
            applyBatchOutcome(status: http?.statusCode,
                              retryAfterHeader: http?.value(forHTTPHeaderField: "Retry-After"),
                              batch: batch,
                              reportedDrops: reportedDrops)
        } catch {
            // Network error / timeout: no status. The batch stays queued and the pump
            // pauses on the short schedule instead of retrying every tick.
            applyBatchOutcome(status: nil, retryAfterHeader: nil, batch: batch, reportedDrops: reportedDrops)
            _ = reason
        }
    }

    /// W-RETRYAFTER — apply the server's answer to one batch. 2xx confirms it; a status that
    /// condemns the batch itself drops it (counted, logged); everything else keeps it and
    /// pauses the pump. See `UploadRetryPolicy`.
    private func applyBatchOutcome(status: Int?,
                                   retryAfterHeader: String?,
                                   batch: RetryBatchBuffer<Data>.Batch,
                                   reportedDrops: Int) {
        switch UploadRetryPolicy.verdict(status: status) {
        case .success:
            queue.confirm(throughSeq: batch.lastSeq)
            queue.acknowledgeDropReport(reportedDrops)
            queue.recordSuccess()
        case .reject:
            // The batch itself can never be accepted: retrying it would burn requests
            // forever. Dropped once, explicitly, counted for the next report.
            let removed = queue.discard(throughSeq: batch.lastSeq)
            let statusText = status.map { String($0) } ?? "none"
            RTLog.warn("telemetry", "batch rejected status=" + statusText + " dropped=" + String(removed)
                       + " queued=" + String(queue.count))
        case .keep:
            // JWT expired or unauthorised — drop the pubkey so we re-fetch on next try.
            if status == 401 { serverPubKey = nil }
            noteUploadFailure(status: status, retryAfterHeader: retryAfterHeader)
        }
    }

    /// W-RETRYAFTER — a kept failure (batch POST or pubkey fetch): pause the pump and log
    /// ONE line: status, the server's `Retry-After` (parsed), the pause, how many events are
    /// queued. No payload content.
    private func noteUploadFailure(status: Int?, retryAfterHeader: String?) {
        let now = Self.monotonicNow()
        let delay = queue.recordFailure(status: status,
                                        retryAfterHeader: retryAfterHeader,
                                        now: now,
                                        wallClock: Date(),
                                        jitterUnit: Double.random(in: 0...1))
        let statusText = status.map { String($0) } ?? "net"
        let hint = UploadRetryPolicy.parseRetryAfter(retryAfterHeader, now: Date())
        let hintText = hint.map { String(Int($0.rounded())) } ?? "none"
        RTLog.warn("telemetry", "upload paused status=" + statusText + " retry_after=" + hintText
                   + " pause=" + String(Int(delay.rounded())) + " queued=" + String(queue.count))
    }

    /// The synthetic event that tells the maintainer how many queued events were dropped.
    private func droppedReportLine(dropped: Int) -> Data? {
        let ev = TelemetryEvent(
            tsMs: Int64(Date().timeIntervalSince1970 * 1000),
            sessionId: sessionId,
            deviceId: deviceId,
            platform: "ios",
            appVer: Self.appVersion,
            userId: getUserId?(),
            callId: nil,
            kind: Self.droppedKind,
            attrs: ["dropped": dropped, "dropped_total": queue.droppedTotal]
        )
        return ev.toJSONLLine()
    }

    private static func monotonicNow() -> TimeInterval {
        return ProcessInfo.processInfo.systemUptime
    }

    // ─── Server pubkey fetch ───────────────────────────────────────

    private func fetchServerPubKeyIfNeeded() async {
        guard serverPubKey == nil else { return }
        // W-RETRYAFTER: the pubkey GET goes through the same per-IP limiter as the batch, so
        // it honours the same pause.
        if queue.isPaused(now: Self.monotonicNow()) { return }
        guard let token = getToken?(), !token.isEmpty else { return }
        guard let url = URL(string: serverUrl + "/api/v1/telemetry/pubkey") else {
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        do {
            // W-AUXPIN (2026-09-01): pinned session, see flushOnce.
            let (data, resp) = try await PinnedURLSession.auxiliary(for: serverUrl).data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                noteUploadFailure(status: nil, retryAfterHeader: nil)
                return
            }
            guard http.statusCode == 200 else {
                noteUploadFailure(status: http.statusCode,
                                  retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"))
                return
            }
            struct PubResp: Decodable { let pubkey: String; let alg: String? }
            let pr = try JSONDecoder().decode(PubResp.self, from: data)
            guard let raw = Data(base64Encoded: pr.pubkey), raw.count == 32 else { return }
            serverPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        } catch {
            // Network error or an unreadable answer: try again after the short pause.
            noteUploadFailure(status: nil, retryAfterHeader: nil)
        }
    }

    // ─── Seal ──────────────────────────────────────────────────────

    /// Build the wire = [v1][eph_pub(32)][nonce(12)][AES-GCM(hkdf(X25519),
    /// nonce, plaintext)] bundle. Returns nil on cryptography failure
    /// (extremely unlikely — would mean CryptoKit is broken).
    private func sealBatch(_ plaintext: Data,
                           serverPubKey: Curve25519.KeyAgreement.PublicKey) -> Data? {
        let ephPriv = Curve25519.KeyAgreement.PrivateKey()
        guard let shared = try? ephPriv.sharedSecretFromKeyAgreement(with: serverPubKey)
        else { return nil }
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                  salt: Data(),
                                                  sharedInfo: hkdfInfo,
                                                  outputByteCount: 32)
        guard let sealed = try? AES.GCM.seal(plaintext, using: key) else {
            return nil
        }
        // Reconstruct nonce(12) + ciphertext + tag(16) explicitly so
        // we control the wire layout (CryptoKit's combined form
        // happens to match but we don't want to rely on it).
        var wire = Data(capacity: 1 + 32 + 12 + sealed.ciphertext.count + 16)
        wire.append(wireVersion)
        wire.append(ephPriv.publicKey.rawRepresentation)
        wire.append(sealed.nonce.withUnsafeBytes { Data($0) })
        wire.append(sealed.ciphertext)
        wire.append(sealed.tag)
        return wire
    }

    // ─── Helpers ───────────────────────────────────────────────────

    private static let appVersion: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return v ?? "0.0.0"
    }()

    /// P2 -- recursively scrub every STRING value in a sanitized attrs
    /// dict through `RuntimeLogSink.redactStructured`, the SAME fail-closed
    /// egress redactor the text path (`LiveLogWorker`, via `LogRedactor`) uses. Keys are
    /// app-controlled identifiers and are NOT redacted; only values.
    /// Non-string scalars (Int/Int64/Double/Bool) pass through untouched.
    /// MainActor-isolated because `redactStructured` is. Preserves
    /// call_id UUIDs (-> short8) and crash frames per the redactor's
    /// stash rules.
    @MainActor
    private static func redactAttrs(_ attrs: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in attrs {
            switch v {
            case let s as String:
                out[k] = RuntimeLogSink.redactStructured(s)
            case let dict as [String: Any]:
                out[k] = redactAttrs(dict)
            case let arr as [Any]:
                out[k] = arr.map { element -> Any in
                    if let es = element as? String {
                        return RuntimeLogSink.redactStructured(es)
                    }
                    return element
                }
            default:
                out[k] = v
            }
        }
        return out
    }

    /// JSON-sanitize attrs: convert non-Encodable values to strings,
    /// strip nested closures / classes / NS-types CryptoKit might
    /// trip over. Pragmatic — keeps the emit() call sites simple.
    private nonisolated func sanitize(_ raw: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in raw {
            switch v {
            case let n as Int:        out[k] = n
            case let n as Int64:      out[k] = n
            case let n as Double:     out[k] = n
            case let s as String:     out[k] = s
            case let b as Bool:       out[k] = b
            case let arr as [Any]:
                out[k] = arr.map { "\($0)" }
            case let dict as [String: Any]:
                out[k] = sanitize(dict)
            default:
                out[k] = String(describing: v)
            }
        }
        return out
    }
}

// ─── Event struct + JSONL encoding ─────────────────────────────────

public struct TelemetryEvent {
    public let tsMs: Int64
    public let sessionId: String
    public let deviceId: String
    public let platform: String
    public let appVer: String
    public let userId: String?
    public let callId: String?
    public let kind: String
    public let attrs: [String: Any]

    /// Encode as ONE compact JSON line (no trailing newline; caller
    /// appends '\n'). Returns nil only when attrs contain values that
    /// can't be JSON-serialized after sanitization — defensive.
    public func toJSONLLine() -> Data? {
        var obj: [String: Any] = [
            "ts_ms":     tsMs,
            "session_id": sessionId,
            "device_id": deviceId,
            "platform":  platform,
            "app_ver":   appVer,
            "kind":      kind,
            "attrs":     attrs,
        ]
        if let u = userId, !u.isEmpty { obj["user_id"] = u }
        if let c = callId, !c.isEmpty { obj["call_id"] = c }
        return try? JSONSerialization.data(withJSONObject: obj,
                                            options: [.sortedKeys, .fragmentsAllowed])
    }
}
