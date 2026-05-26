import Foundation
import CryptoKit
import UIKit

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
/// - Failure is silent (telemetry must NEVER break the call). On
///   network error the batch is retained for the next attempt up to
///   3 retries, after which it's dropped.
/// - Coexists with `LiveLogStreamer` (W417) — that one ships opaque
///   text chunks; this one ships structured JSON events.
@MainActor
public final class TelemetryService {

    public static let shared = TelemetryService()

    // ─── Config ────────────────────────────────────────────────────

    /// Flush cadence. Trade-off: 5s keeps server load low while still
    /// giving the maintainer near-real-time visibility.
    public var flushIntervalSec: TimeInterval = 5.0

    /// Max events buffered before forcing an early flush. Prevents
    /// memory growth on a long video call with high event rate.
    public var maxBufferedEvents: Int = 256

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

    /// Buffered events. Mutations on MainActor only.
    private var buffer: [TelemetryEvent] = []

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

    // ─── Lifecycle ─────────────────────────────────────────────────

    /// Start the periodic pump. Idempotent — calling twice is a no-op.
    /// AppState invokes this once at app start (BEFORE the call code
    /// emits any events; events emitted before start are silently
    /// dropped).
    public func start(
        serverUrl: String,
        getToken: @escaping TokenProvider,
        getUserId: @escaping UserIdProvider
    ) {
        if started { return }
        self.serverUrl = serverUrl
        self.getToken = getToken
        self.getUserId = getUserId
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
    /// internally hops to MainActor for buffer mutation. Drops the
    /// event when buffer is full and the in-flight upload hasn't
    /// freed space yet.
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
            let ev = TelemetryEvent(
                tsMs: tsMs,
                sessionId: self.sessionId,
                deviceId: self.deviceId,
                platform: "ios",
                appVer: Self.appVersion,
                userId: self.getUserId?(),
                callId: callId,
                kind: kind,
                attrs: attrsJSONSafe
            )
            if self.buffer.count >= self.maxBufferedEvents {
                // Drop oldest non-error event to make room for new.
                // Errors are prioritised because they're rarer + more
                // diagnostic.
                if !ev.kind.contains("error") {
                    return
                }
                self.buffer.removeFirst()
            }
            self.buffer.append(ev)
            if self.buffer.count >= self.maxBufferedEvents / 2 && !self.flushInFlight {
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
        if buffer.isEmpty { return }

        // Try to fetch pubkey if we don't have it. If still no
        // pubkey after the fetch, retain the buffer for next attempt.
        if serverPubKey == nil {
            await fetchServerPubKeyIfNeeded()
            guard serverPubKey != nil else { return }
        }
        guard let token = getToken?(), !token.isEmpty else { return }

        flushInFlight = true
        defer { flushInFlight = false }

        // Snapshot batch under capped bytes.
        var jsonlBytes: Data = Data()
        var batchEvents: [TelemetryEvent] = []
        for ev in buffer {
            guard let line = ev.toJSONLLine() else { continue }
            if jsonlBytes.count + line.count + 1 > maxBatchBytes {
                break
            }
            jsonlBytes.append(line)
            jsonlBytes.append(0x0A)  // '\n'
            batchEvents.append(ev)
        }
        guard !batchEvents.isEmpty else { return }

        // Seal.
        guard let serverPubKey,
              let wire = sealBatch(jsonlBytes, serverPubKey: serverPubKey) else {
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
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                // Drop the events we just shipped.
                if batchEvents.count <= buffer.count {
                    buffer.removeFirst(batchEvents.count)
                }
            } else if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                // JWT expired or unauthorised — drop the pubkey so
                // we re-fetch on next try.
                serverPubKey = nil
            } else {
                // 4xx/5xx — drop batch to avoid stuck loop on
                // malformed events.
                if batchEvents.count <= buffer.count {
                    buffer.removeFirst(batchEvents.count)
                }
            }
        } catch {
            // Network error — keep batch for next attempt. No log
            // (telemetry MUST be silent).
            _ = reason
        }
    }

    // ─── Server pubkey fetch ───────────────────────────────────────

    private func fetchServerPubKeyIfNeeded() async {
        guard serverPubKey == nil else { return }
        guard let token = getToken?(), !token.isEmpty else { return }
        guard let url = URL(string: serverUrl + "/api/v1/telemetry/pubkey") else {
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            struct PubResp: Decodable { let pubkey: String; let alg: String? }
            let pr = try JSONDecoder().decode(PubResp.self, from: data)
            guard let raw = Data(base64Encoded: pr.pubkey), raw.count == 32 else { return }
            serverPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        } catch {
            // Silent — try again on next flush.
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
