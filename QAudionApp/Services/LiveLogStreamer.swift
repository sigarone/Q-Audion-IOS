import Foundation
import QAudionEngine
import Network
import UIKit
import CryptoKit

/// W417 — Opt-in real-time telemetry pump (SECURITY C-10).
///
/// **Consent gate (SECURITY C-10):** this streamer uploads runtime
/// log chunks to the server. Doing that without explicit user consent
/// is a privacy violation. `start(...)` therefore checks the
/// UserDefaults bool `qaudion.diagnostics.liveStreamEnabled` and does
/// NOTHING (no tee, no upload, no timer) unless the user has
/// explicitly opted in. The key DEFAULTS TO FALSE when absent — the
/// pump is OFF until a Settings toggle flips it via
/// `LiveLogStreamer.setEnabled(true)`. Disabling it calls `stop()`
/// which fully tears down the timer + network path monitor.
///
/// **Why this exists:** the user reported on 2026-05-03 that opening
/// Settings → Diagnostica freezes the app, blocking the W415/W416
/// manual "Carica al server" flow. When the user has consented, an
/// auto-push mechanism lets the maintainer inspect runtime behaviour.
///
/// **What it does (only when consented):** every `flushIntervalSeconds`
/// (default 3s) the streamer reads new entries from `RuntimeLogSink`
/// since the last successful flush, formats them as a UTF-8 .log
/// chunk, and POSTs to `/api/v1/files/upload`. Each chunk's filename
/// is:
///   `qaudion-live-<sessionHmac8>-<bootSession>-<seqZeroPad6>.log`
/// The maintainer reconstructs the timeline by listing files
/// matching the prefix sorted by name. The user-id prefix is an
/// HMAC (SECURITY L-6) so the server cannot enumerate logs by raw
/// user id.
///
/// **API design — IMPORTANT:** `start()` takes PRIMITIVE values plus
/// `@MainActor` closures, NEVER an `AppState` parameter directly. The
/// bisect from v1.0.386→v1.0.397 proved that having `AppState` as a
/// parameter TYPE in a method signature on a new file BREAKS THE
/// BUILD silently (Swift 6 strict concurrency Sendable inference
/// explodes on AppState's many @Published properties). The closure
/// approach captures only the specific values needed (token, userId)
/// without dragging the whole AppState type into the signature.
/// See CLAUDE.md "Hard-won lesson 16" for the full story.
///
/// **Non-interference design:**
///   1. `Task { ... }` (inherits @MainActor) — `await uploadFile`
///      suspends so URLSession's network I/O runs off-main internally.
///   2. Single-flight: one upload concurrent max.
///   3. Throttle: ≥ 2s between upload starts.
///   4. Hard caps: 64 KB / 256 lines per chunk.
///   5. Self-suppression: "livelog"-tagged entries filtered by
///      `RuntimeLogSink.entriesSince(...)` to avoid feedback loop.
///   6. Auth-gated, fail-silent: skip when no token.
///
/// **Lifetime:** singleton, started once from `AppState.initialize()`.
@MainActor
public final class LiveLogStreamer {

    public static let shared = LiveLogStreamer()

    /// SECURITY C-10 — UserDefaults bool that gates ALL telemetry
    /// upload. Absent / false ⇒ the pump is fully inert. A future
    /// Settings toggle flips it through `setEnabled(_:)`.
    public static let consentKey: String = "qaudion.diagnostics.liveStreamEnabled"

    /// SECURITY C-10 — current consent state.
    ///
    /// MASVS-PRIVACY remediation (2026-08-20): an EXPLICIT user choice
    /// (Settings → Diagnostica → toggle → `setEnabled`) always wins. When
    /// the user has never chosen, the default is now unconditionally
    /// `false` on EVERY build channel — including TestFlight. Before this
    /// fix, the default was `!isAppStoreBuild`, which resolved `true` for
    /// TestFlight (the app's only real distribution channel today, per
    /// `CLAUDE.md`), with `setEnabled()` having zero reachable UI call
    /// sites anywhere in the app — i.e. the pump was silently on for every
    /// real user with no way to see or disable it, contradicting this very
    /// file's "opt-in" framing. See
    /// `docs/security/MASVS_ASSESSMENT_2026-08-20.md` §1.1 for the full
    /// writeup. A real Settings toggle now exists (`PrivacySettingsScreen`,
    /// "Log diagnostici in tempo reale" under DIAGNOSTICA) and is the only
    /// way this ever becomes `true`.
    public static var isEnabled: Bool {
        if let explicit = UserDefaults.standard.object(forKey: consentKey) as? Bool {
            return explicit
        }
        return false
    }

    /// SECURITY C-10 — flip the consent flag. When disabled we also
    /// tear the running pump down so consent withdrawal is immediate.
    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: consentKey)
        if !enabled {
            LiveLogStreamer.shared.stop()
        }
    }

    public let bootSessionId: String = UUID().uuidString.lowercased()
    public var flushIntervalSeconds: TimeInterval = 3.0
    public let maxChunkBytes: Int = 64 * 1024
    public let maxLinesPerChunk: Int = 256

    public private(set) var lastUploadedFileId: String?
    public private(set) var lastUploadedAt: Date?
    public private(set) var totalUploadedChunks: Int = 0
    public private(set) var totalUploadedBytes: Int = 0
    public private(set) var failedUploads: Int = 0
    public private(set) var skippedDueToInflight: Int = 0
    public private(set) var skippedDueToNoAuth: Int = 0

    public typealias TokenProvider = @MainActor () -> String?
    public typealias UserIdProvider = @MainActor () -> String?

    private var serverUrl: String?
    private var tokenProvider: TokenProvider?
    private var userIdProvider: UserIdProvider?
    private var timer: Timer?
    private var lastSeq: Int64 = 0
    private var chunkSeq: Int = 0
    private var inflight: Bool = false
    private var lastUploadStartedAt: Date = Date.distantPast
    private let minSecondsBetweenUploads: TimeInterval = 2.0
    private var isStarted: Bool = false
    
    private let pathMonitor = NWPathMonitor()
    private var currentPath: NWPath?

    private init() {}

    /// Start the flush pump. Idempotent. Pass primitive values + closures
    /// — NEVER AppState directly (see file header for why).
    public func start(serverUrl: String,
                      getToken: @escaping TokenProvider,
                      getUserId: @escaping UserIdProvider) {
        // SECURITY C-10 — consent gate. No consent ⇒ no tee, no
        // upload, no timer, no path monitor. Returns BEFORE any
        // side effect. Default is false (key absent ⇒ false).
        guard LiveLogStreamer.isEnabled else { return }
        if isStarted { return }
        isStarted = true
        self.serverUrl = serverUrl
        self.tokenProvider = getToken
        self.userIdProvider = getUserId
        
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.currentPath = path
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .background))
        
        scheduleTimer()
        let session: String = bootSessionId
        let line: String = "LiveLogStreamer started session=" + session
        RTLog.info("livelog", line)
    }

    /// Fully tear down the pump. Safe to call when not started.
    /// SECURITY C-10 — invoked on consent withdrawal so no timer or
    /// network monitor survives after the user opts out.
    public func stop() {
        timer?.invalidate()
        timer = nil
        if isStarted {
            pathMonitor.cancel()
        }
        inflight = false
        isStarted = false
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval: TimeInterval = flushIntervalSeconds
        let t: Timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                LiveLogStreamer.shared.flushOnce()
            }
        }
        RunLoop.main.add(t, forMode: RunLoop.Mode.common)
        timer = t
    }

    private func flushOnce() {
        // W-FLAGS -- RUNTIME kill-switch for the log SHIPPER. Checked on
        // EVERY flush (not just start()) so a VPS edit to flags.json can
        // STOP/allow uploads on an already-shipped TestFlight build within
        // the FeatureFlags refresh window, without a rebuild. The compiled
        // default is the existing consent gate (`isEnabled`), so absent /
        // unparseable flag => unchanged behaviour (fail-safe to consent).
        //
        // SECURITY -- this gates SHIP only. Egress REDACTION
        // (`RuntimeLogSink.entriesSince` -> `redactStructured`) is the
        // load-bearing privacy control and stays UNCONDITIONAL: returning
        // here skips an UPLOAD, never a scrub. Redaction is never flagged.
        guard FeatureFlags.bool("LOG_OTLP_EXPORT_ENABLED", LiveLogStreamer.isEnabled) else { return }
        if inflight {
            skippedDueToInflight += 1
            return
        }
        let now: Date = Date()
        let elapsed: TimeInterval = now.timeIntervalSince(lastUploadStartedAt)
        if elapsed < minSecondsBetweenUploads { return }

        guard let serverUrlLocal = serverUrl,
              let getToken = tokenProvider,
              let getUserId = userIdProvider else {
            skippedDueToNoAuth += 1
            return
        }
        guard let tokenLocal = getToken(), !tokenLocal.isEmpty else {
            skippedDueToNoAuth += 1
            return
        }

        let snap = RuntimeLogSink.shared.entriesSince(seq: lastSeq)
        if snap.lines.isEmpty { return }

        var lines: [String] = snap.lines
        if lines.count > maxLinesPerChunk {
            lines = Array(lines.prefix(maxLinesPerChunk))
        }

        let model = UIDevice.current.model
        let os = "ios-" + UIDevice.current.systemVersion
        let net = getNetworkType()
        let metered = currentPath?.isExpensive ?? false
        let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        let header = "{\"type\":\"header\",\"session\":\"\(bootSessionId)\",\"model\":\"\(model)\",\"brand\":\"Apple\",\"os\":\"\(os)\",\"net\":\"\(net)\",\"metered\":\(metered),\"app_ver\":\"\(appVer)\"}"
        
        var body: String = ""
        body.reserveCapacity(lines.count * 220 + 256)
        body.append(header)
        body.append("\n")
        for line in lines {
            body.append(line)
            body.append("\n")
        }
        var data: Data = Data()
        if let encoded = body.data(using: String.Encoding.utf8) {
            data = encoded
        }
        if data.count > maxChunkBytes {
            let cap: Int = maxChunkBytes - 64
            let upper: Int = min(cap, data.count)
            let head: Data = data.subdata(in: 0..<upper)
            let markerStr: String = "\n[livelog-truncated]\n"
            var combined: Data = head
            if let markerData = markerStr.data(using: String.Encoding.utf8) {
                combined.append(markerData)
            }
            data = combined
        }

        chunkSeq += 1
        let mySeq: Int = chunkSeq
        let chunkBytes: Int = data.count
        let highestSeqInChunk: Int64 = snap.highestSeq

        let userIdRaw: String = getUserId() ?? "anon"
        // SECURITY L-6 — do NOT leak the raw user-id prefix in the
        // filename (server-side enumeration). Use an HMAC-SHA256 of
        // the user id keyed by the per-boot session UUID, hex-
        // truncated to 8 chars. Stable within a session so the
        // maintainer's pattern-based log fetch still groups chunks;
        // unlinkable across sessions and not reversible to the id.
        let userPrefix: String = LiveLogStreamer.sessionScopedTag(userId: userIdRaw,
                                                                  sessionKey: bootSessionId)
        let seqStr: String = LiveLogStreamer.zeroPad(mySeq, width: 6)
        let session: String = bootSessionId
        let filename: String = "qaudion-live-" + userPrefix + "-" + session + "-" + seqStr + ".log"

        inflight = true
        lastUploadStartedAt = now
        // W-LIVELOGHANG (2026-08-03): a hung tus PATCH (no per-attempt bound
        // on the underlying `TusUploadClient` call — network-saturated by
        // live call RTP is exactly when this hits) used to leave `inflight`
        // stuck `true` forever, silently freezing this pump for the rest of
        // the process lifetime. `skippedDueToInflight` never logs, so the
        // ONE window this evidence matters most (a live call) went dark
        // with zero trace — confirmed live: a real receiving device
        // produced exactly ONE chunk across an entire ~8-minute call, then
        // resumed only after something unrelated eventually unstuck it.
        //
        // Fix: a watchdog keyed on `mySeq` force-clears `inflight` if the
        // matching upload hasn't finished within `uploadTimeoutSeconds`.
        // The original upload keeps running in the background (nothing
        // here cancels it — `TusUploadClient`/`URLSession` own that), but
        // the PUMP no longer waits on it forever; if it later succeeds,
        // its own completion still runs and advances `lastSeq`/counters
        // (harmless double-report if the watchdog already logged the
        // timeout). A `[weak self]` + sequence-number guard means a
        // watchdog for an OLD chunk can never clobber a NEWER upload that
        // is already legitimately in flight.
        let watchdogSeq: Int = mySeq
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: LiveLogStreamer.uploadTimeoutSeconds * 1_000_000_000)
            guard let self, self.inflight, self.chunkSeq == watchdogSeq else { return }
            self.inflight = false
            self.failedUploads += 1
            let seqStr: String = String(watchdogSeq)
            let line: String = "livelog upload timeout seq=" + seqStr
            RTLog.warn("net", line)
        }
        Task {
            await self.uploadChunk(
                serverUrl: serverUrlLocal,
                token: tokenLocal,
                filename: filename,
                data: data,
                chunkBytes: chunkBytes,
                seq: mySeq,
                highestSeqInChunk: highestSeqInChunk)
        }
    }

    /// Bound for the watchdog above — see its comment for why it exists.
    private static let uploadTimeoutSeconds: UInt64 = 12

    private func uploadChunk(serverUrl: String,
                             token: String,
                             filename: String,
                             data: Data,
                             chunkBytes: Int,
                             seq: Int,
                             highestSeqInChunk: Int64) async {
        let cfg: BackendConfig = BackendConfig.pinned(serverUrl: serverUrl, accessToken: token)
        let provider: BCryptoBackendProvider = BCryptoBackendProvider(config: cfg)
        do {
            let fileId: String = try await provider.storageApi.uploadFile(
                data: data, filename: filename)
            // A watchdog may already have timed THIS seq out and moved on
            // (see enqueueSend) — a late success arriving after that must
            // not resurrect `inflight`/`lastSeq` state for a chunk the pump
            // has already given up on and possibly superseded.
            guard chunkSeq == seq else { return }
            lastUploadedFileId = fileId
            lastUploadedAt = Date()
            totalUploadedChunks += 1
            totalUploadedBytes += chunkBytes
            // W-LIVELOGHANG — only advance the read cursor on a CONFIRMED
            // send. Advancing it unconditionally in flushOnce() (the old
            // behaviour) meant a failed/timed-out chunk's lines were gone
            // forever — the next flush started reading past them, so a
            // transient failure silently and permanently dropped evidence
            // instead of retrying it on the next tick.
            lastSeq = highestSeqInChunk
            inflight = false
            let shouldLog: Bool = totalUploadedChunks <= 3 || (totalUploadedChunks % 50) == 0
            if shouldLog {
                let seqStr: String = String(seq)
                let bytesStr: String = String(chunkBytes)
                let line: String = "chunk #" + seqStr + " fileId=" + fileId + " bytes=" + bytesStr
                RTLog.info("livelog", line)
            }
        } catch {
            // A watchdog may have already cleared `inflight` and logged a
            // timeout for this same `seq` (see enqueueSend) — only bump
            // the failure counter/log here if this completion is still the
            // one the pump is waiting on, so a late-arriving failure after
            // a watchdog timeout doesn't double-count.
            guard chunkSeq == seq else { return }
            failedUploads += 1
            inflight = false
            // W-LIVELOGHANG — the OLD catch block was silent (no RTLog at
            // all), so a run of failures was indistinguishable from the
            // pump never having started. "net" (not "livelog") so this
            // actually ships once the pump recovers, instead of being
            // filtered out by entriesSince's own livelog self-exclusion.
            //
            // W-LIVELOGSILENTFAIL (2026-08-21): the line used to stop at
            // seq/totalfail — a bare failure COUNT with no REASON, so a run
            // of failures was visible but undiagnosable from the server
            // side (confirmed live: a call session logged
            // "totalfail=4" and nothing else ever shipped from that
            // device for the rest of the call, no way to tell why).
            // `TusUploadClient.TusError` already conforms to
            // `LocalizedError` with a real per-case message ("TUS create
            // failed: HTTP 401", "TUS patch failed: HTTP 404", ...) — it
            // was just never read here. Appending it costs nothing (this
            // whole pump is already gated on explicit consent, C-10) and
            // turns the next occurrence into an actionable line instead of
            // a dead end.
            let seqStr: String = String(seq)
            let failStr: String = String(failedUploads)
            let reason: String = error.localizedDescription
            let line: String = "livelog upload error seq=" + seqStr + " totalfail=" + failStr + " reason=" + reason
            RTLog.warn("net", line)
        }
    }

    /// SECURITY L-6 — HMAC-SHA256(userId) keyed by the per-boot
    /// session UUID, hex, first 8 chars. Stable per session so the
    /// server-side `qaudion-live-<tag>-<session>-<seq>` grep still
    /// groups a session's chunks, but the tag reveals nothing about
    /// the user id and differs every boot.
    private static func sessionScopedTag(userId: String, sessionKey: String) -> String {
        let keyData: Data = Data(sessionKey.utf8)
        let msgData: Data = Data(userId.utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: msgData,
                                                  using: SymmetricKey(data: keyData))
        var hex: String = ""
        hex.reserveCapacity(16)
        for byte in mac {
            let b: UInt8 = byte
            hex.append(String(format: "%02x", b))
            if hex.count >= 8 { break }
        }
        return String(hex.prefix(8))
    }

    private static func zeroPad(_ value: Int, width: Int) -> String {
        let s: String = String(value)
        if s.count >= width { return s }
        let padding: Int = width - s.count
        var prefix: String = ""
        prefix.reserveCapacity(padding)
        var i: Int = 0
        while i < padding {
            prefix.append("0")
            i += 1
        }
        return prefix + s
    }

    private func getNetworkType() -> String {
        guard let path = currentPath else { return "NONE" }
        if path.usesInterfaceType(.wifi) { return "WIFI" }
        if path.usesInterfaceType(.cellular) { return "CELLULAR" }
        if path.usesInterfaceType(.wiredEthernet) { return "ETHERNET" }
        if path.usesInterfaceType(.loopback) { return "LOOPBACK" }
        return "OTHER"
    }
}
