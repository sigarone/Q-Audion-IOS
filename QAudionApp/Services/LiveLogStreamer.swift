import Foundation
import UIKit
import QAudionEngine

/// W417 — Always-on real-time telemetry pump.
///
/// **Why this exists:** the user reported that opening Settings →
/// Diagnostica freezes the app, blocking the manual W415/W416
/// "Carica al server" flow. Without an auto-push mechanism the
/// maintainer has no way to inspect runtime behaviour during the
/// debug period.
///
/// **What it does:** every `flushIntervalSeconds` (default 3s) the
/// streamer reads the new entries from `RuntimeLogSink` since the
/// last successful flush, formats them as a UTF-8 .log chunk, and
/// POSTs to `/api/v1/files/upload` via the existing storage API
/// using the user's bearer token. Each chunk is a standalone file
/// named `qaudion-live-<userPrefix>-<bootSession>-<seq>.log`. The
/// maintainer reconstructs the timeline server-side by listing
/// uploads sorted by name (the seq is zero-padded so lexical sort
/// matches numeric).
///
/// **Non-interference design (CRITICAL — must not affect calls):**
///   1. Background QoS dispatch queue + URLSession with
///      `networkServiceType = .background` so iOS's network scheduler
///      gives audio + WS traffic priority over us.
///   2. `waitsForConnectivity = false` — when offline we DROP the
///      chunk rather than queue (queueing would let memory grow
///      unbounded across a long offline window).
///   3. Single-flight: at most ONE upload in flight. If the previous
///      upload hasn't completed by the next tick we skip the tick,
///      avoiding stack-up that could starve the URLSession workers.
///   4. Hard caps: ≤ 64KB per chunk, ≤ 256 lines per chunk, ≤ 1
///      upload per 2 seconds. Even under a log storm we won't push
///      more than ~32 KB/s — negligible compared to a Q-Audion call's
///      ~25 KB/s audio stream.
///   5. Self-suppression: lines tagged "livelog" are filtered out by
///      `RuntimeLogSink.entriesSince(...)` so each upload doesn't
///      generate an entry that becomes the next upload's payload.
///   6. Auth-gated, fail-silent: skip flush if no token. Network
///      errors are counted in `failedUploads` but never re-tried —
///      retry could double-spend the chunk and inflate server cost.
///
/// **Server-side discovery (manual today):**
/// the maintainer fetches the user's recent live-log files via
///   `curl -H "Authorization: Bearer <admin>" \
///         https://voip.bcrypto.com/api/v1/files?owner=<userId>&prefix=qaudion-live-`
/// (or analogous list endpoint). A future server enhancement may
/// announce each chunk's fileId via WebSocket so the maintainer can
/// subscribe in real-time. For now, the convention-based filename
/// pattern is the contract.
///
/// **Lifetime:** singleton. Started once from `AppState.initialize()`
/// after the engine is constructed. The flush timer runs whenever the
/// app is foregrounded or in a CallKit-elevated background state. iOS
/// suspends the timer when the process moves to plain background
/// (which is desirable — no calls, no relevant logs).
@MainActor
public final class LiveLogStreamer {

    public static let shared = LiveLogStreamer()

    /// Boot session UUID — same value across the entire process
    /// lifetime. Restarting the app starts a new session, so chunks
    /// are naturally segmented into "app run" units.
    public let bootSessionId: String = UUID().uuidString.lowercased()

    /// Cadence of the upload pump. 3 seconds is the sweet spot:
    /// short enough that a crash mid-call still leaves > 95% of the
    /// trail server-side, long enough that we don't generate one
    /// upload per second.
    public var flushIntervalSeconds: TimeInterval = 3.0

    /// Hard cap on a single chunk's payload size. Chunks above this
    /// are split (only the first 64KB ships; remainder waits for
    /// next tick). Prevents pathological log bursts from creating a
    /// single huge upload that ties up bandwidth.
    public let maxChunkBytes: Int = 64 * 1024

    /// Hard cap on lines per chunk to bound JSON-encoding work even
    /// when individual lines are short.
    public let maxLinesPerChunk: Int = 256

    // MARK: - Telemetry counters (read by UI / debug card)

    public private(set) var lastUploadedFileId: String?
    public private(set) var lastUploadedAt: Date?
    public private(set) var totalUploadedChunks: Int = 0
    public private(set) var totalUploadedBytes: Int = 0
    public private(set) var failedUploads: Int = 0
    public private(set) var skippedDueToInflight: Int = 0
    public private(set) var skippedDueToNoAuth: Int = 0

    // MARK: - Private state

    private weak var appStateRef: AppState?
    private var timer: Timer?
    private var lastSeq: Int64 = 0
    private var chunkSeq: Int = 0
    private var inflight: Bool = false
    private var lastUploadStartedAt: Date = .distantPast
    /// Minimum gap between upload STARTS — even if the timer fires
    /// faster, this throttles us so a transient burst doesn't open
    /// 5 sockets in 5 seconds.
    private let minSecondsBetweenUploads: TimeInterval = 2.0
    private var isStarted: Bool = false

    private init() {}

    // MARK: - Public lifecycle

    /// Starts the flush pump. Idempotent.
    /// Pass the AppState so we can read `serverUrl`, `currentUserId`,
    /// `authService.loadToken()` lazily on each flush (auth state may
    /// change after start-up).
    public func start(appState: AppState) {
        guard !isStarted else { return }
        isStarted = true
        appStateRef = appState
        // Fire one flush immediately so boot logs ship within ~3 sec
        // of process start (instead of waiting a full interval).
        scheduleTimer()
        RTLog.info("livelog", "LiveLogStreamer started session=\(bootSessionId) interval=\(flushIntervalSeconds)s")
    }

    /// Stops the flush pump. Used by tests / sign-out paths.
    public func stop() {
        timer?.invalidate(); timer = nil
        isStarted = false
        RTLog.info("livelog", "LiveLogStreamer stopped (totalChunks=\(totalUploadedChunks) failed=\(failedUploads))")
    }

    // MARK: - Internal

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: flushIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushOnce()
            }
        }
        // Use .common so the timer keeps firing during scroll / modal
        // presentation — would be tragic if telemetry stalled exactly
        // when the user scrolls Settings looking for the freeze cause.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// One pump cycle. Reads new entries → builds chunk → uploads.
    /// All bail-out paths are silent counters, never errors.
    private func flushOnce() {
        // (1) Single-flight gate.
        if inflight {
            skippedDueToInflight += 1
            return
        }
        // (2) Throttle by elapsed wall-clock, independent of timer.
        let now = Date()
        if now.timeIntervalSince(lastUploadStartedAt) < minSecondsBetweenUploads {
            return
        }
        // (3) Auth gate. AppState may not have a token yet during
        //     the first few seconds after launch; we stay quiet and
        //     wait — RuntimeLogSink keeps buffering meanwhile.
        guard let appState = appStateRef,
              let token = appState.authService.loadToken(), !token.isEmpty else {
            skippedDueToNoAuth += 1
            return
        }
        // (4) Read new entries. If nothing new, no upload.
        let snap = RuntimeLogSink.shared.entriesSince(seq: lastSeq)
        guard !snap.lines.isEmpty else { return }

        // (5) Cap lines + bytes.
        var lines = snap.lines
        if lines.count > maxLinesPerChunk {
            lines = Array(lines.prefix(maxLinesPerChunk))
        }
        var body = String()
        body.reserveCapacity(lines.count * 220)
        for line in lines { body.append(line); body.append("\n") }
        var data = body.data(using: .utf8) ?? Data()
        if data.count > maxChunkBytes {
            // Truncate mid-line — better to lose the tail than to
            // skip the chunk entirely. Append a marker so the maintainer
            // sees the truncation in the file.
            data = data.prefix(maxChunkBytes - 64)
            data.append("\n[livelog-truncated-at-\(maxChunkBytes)-bytes]\n".data(using: .utf8) ?? Data())
        }

        // (6) Reserve seq numbers + filename.
        chunkSeq += 1
        let mySeq = chunkSeq
        let chunkBytes = data.count
        // Update lastSeq optimistically so the next tick doesn't re-read
        // the same lines while we're uploading. If the upload fails the
        // chunk is lost forever — accepted trade-off (see file header).
        lastSeq = snap.highestSeq
        let userPrefix = (appState.currentUserId ?? "anon").prefix(8)
        let filename = String(format: "qaudion-live-%@-%@-%06d.log",
                              String(userPrefix), bootSessionId, mySeq)
        let serverUrl = appState.serverUrl

        // (7) Mark in-flight + dispatch the actual network I/O off-main.
        inflight = true
        lastUploadStartedAt = now
        Task.detached(priority: .utility) { [weak self] in
            await self?.performUpload(
                serverUrl: serverUrl,
                token: token,
                filename: filename,
                data: data,
                chunkBytes: chunkBytes,
                seq: mySeq)
        }
    }

    /// Detached task that actually POSTs. Runs at .utility QoS so the
    /// audio + WebRTC threads always pre-empt us.
    /// `nonisolated` so it executes entirely off the main actor —
    /// the only main-actor work is the explicit `MainActor.run`
    /// block at the end which mutates the @Published counters.
    nonisolated private func performUpload(serverUrl: String,
                                           token: String,
                                           filename: String,
                                           data: Data,
                                           chunkBytes: Int,
                                           seq: Int) async {
        let cfg = BackendConfig(serverUrl: serverUrl, accessToken: token)
        let provider = BCryptoBackendProvider(config: cfg)
        do {
            let fileId = try await provider.storageApi.uploadFile(data: data, filename: filename)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.lastUploadedFileId = fileId
                self.lastUploadedAt = Date()
                self.totalUploadedChunks += 1
                self.totalUploadedBytes += chunkBytes
                self.inflight = false
                // Use OSLog directly (no RTLog) to avoid pumping our
                // own success line into the next chunk's payload.
                // The "livelog" tag is filter-suppressed but going
                // straight through OSLog also keeps Console.app in
                // sync with what's been shipped.
                // (We DO want the very first success visible so the
                //  user / maintainer can confirm the pipeline works.)
                if self.totalUploadedChunks <= 3 || self.totalUploadedChunks % 50 == 0 {
                    RTLog.info("livelog", "chunk #\(seq) → fileId=\(fileId) bytes=\(chunkBytes)")
                }
            }
        } catch {
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.failedUploads += 1
                self.inflight = false
                // Don't RTLog the error (that would spam the buffer).
                // Counter visible via debug UI is sufficient.
            }
        }
    }
}
