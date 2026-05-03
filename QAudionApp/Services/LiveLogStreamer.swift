import Foundation
import QAudionEngine

/// W417 — Always-on real-time telemetry pump.
///
/// **Why this exists:** the user reported on 2026-05-03 that opening
/// Settings → Diagnostica freezes the app, blocking the W415/W416
/// manual "Carica al server" flow. Without an auto-push mechanism the
/// maintainer has no way to inspect runtime behaviour.
///
/// **What it does:** every `flushIntervalSeconds` (default 3s) the
/// streamer reads new entries from `RuntimeLogSink` since the last
/// successful flush, formats them as a UTF-8 .log chunk, and POSTs to
/// `/api/v1/files/upload`. Each chunk's filename is:
///   `qaudion-live-<userPrefix8>-<bootSession>-<seqZeroPad6>.log`
/// The maintainer reconstructs the timeline by listing files
/// matching the prefix sorted by name.
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

    private init() {}

    /// Start the flush pump. Idempotent. Pass primitive values + closures
    /// — NEVER AppState directly (see file header for why).
    public func start(serverUrl: String,
                      getToken: @escaping TokenProvider,
                      getUserId: @escaping UserIdProvider) {
        if isStarted { return }
        isStarted = true
        self.serverUrl = serverUrl
        self.tokenProvider = getToken
        self.userIdProvider = getUserId
        scheduleTimer()
        let session: String = bootSessionId
        let line: String = "LiveLogStreamer started session=" + session
        RTLog.info("livelog", line)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
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
        var body: String = ""
        body.reserveCapacity(lines.count * 220)
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
        lastSeq = snap.highestSeq

        let userIdRaw: String = getUserId() ?? "anon"
        let userPrefix: String = String(userIdRaw.prefix(8))
        let seqStr: String = LiveLogStreamer.zeroPad(mySeq, width: 6)
        let session: String = bootSessionId
        let filename: String = "qaudion-live-" + userPrefix + "-" + session + "-" + seqStr + ".log"

        inflight = true
        lastUploadStartedAt = now
        Task {
            await self.uploadChunk(
                serverUrl: serverUrlLocal,
                token: tokenLocal,
                filename: filename,
                data: data,
                chunkBytes: chunkBytes,
                seq: mySeq)
        }
    }

    private func uploadChunk(serverUrl: String,
                             token: String,
                             filename: String,
                             data: Data,
                             chunkBytes: Int,
                             seq: Int) async {
        let cfg: BackendConfig = BackendConfig(serverUrl: serverUrl, accessToken: token)
        let provider: BCryptoBackendProvider = BCryptoBackendProvider(config: cfg)
        do {
            let fileId: String = try await provider.storageApi.uploadFile(
                data: data, filename: filename)
            lastUploadedFileId = fileId
            lastUploadedAt = Date()
            totalUploadedChunks += 1
            totalUploadedBytes += chunkBytes
            inflight = false
            let shouldLog: Bool = totalUploadedChunks <= 3 || (totalUploadedChunks % 50) == 0
            if shouldLog {
                let seqStr: String = String(seq)
                let bytesStr: String = String(chunkBytes)
                let line: String = "chunk #" + seqStr + " fileId=" + fileId + " bytes=" + bytesStr
                RTLog.info("livelog", line)
            }
        } catch {
            failedUploads += 1
            inflight = false
        }
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
}
