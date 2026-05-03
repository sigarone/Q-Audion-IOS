import Foundation
import QAudionEngine

/// W417 — Always-on real-time telemetry pump.
///
/// Singleton that ships log chunks to /api/v1/files/upload every
/// ~3 seconds without user interaction. Designed for the debug
/// period where Settings → Diagnostica freezes the app.
///
/// **Non-interference budget (do NOT weaken without re-evaluating):**
///   - ≤ 1 upload per `minSecondsBetweenUploads` (2.0s)
///   - ≤ `maxChunkBytes` (64 KB) per chunk
///   - ≤ `maxLinesPerChunk` (256) per chunk
///   - Single-flight (max 1 upload concurrent)
///   - Self-suppression: "livelog" tag entries excluded from chunks
///   - Auth-gated: skip flush if no token (silent counter bump)
///   - Fail-silent: network errors counted, never re-tried
///
/// **Filename pattern:**
///   `qaudion-live-<userPrefix8>-<bootSession>-<seqZeroPad6>.log`
@MainActor
public final class LiveLogStreamer {

    public static let shared: LiveLogStreamer = LiveLogStreamer()

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

    private weak var appStateRef: AppState?
    private var timer: Timer?
    private var lastSeq: Int64 = 0
    private var chunkSeq: Int = 0
    private var inflight: Bool = false
    private var lastUploadStartedAt: Date = Date.distantPast
    private let minSecondsBetweenUploads: TimeInterval = 2.0
    private var isStarted: Bool = false

    private init() {}

    public func start(appState: AppState) {
        if isStarted { return }
        isStarted = true
        appStateRef = appState
        scheduleTimer()
        let session: String = bootSessionId
        let interval: TimeInterval = flushIntervalSeconds
        let intervalStr: String = String(interval)
        let line: String = "LiveLogStreamer started session=" + session + " interval=" + intervalStr + "s"
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

        guard let appState = appStateRef else {
            skippedDueToNoAuth += 1
            return
        }
        guard let tokenLocal = appState.authService.loadToken() else {
            skippedDueToNoAuth += 1
            return
        }
        if tokenLocal.isEmpty {
            skippedDueToNoAuth += 1
            return
        }

        let snap = RuntimeLogSink.shared.entriesSince(seq: lastSeq)
        if snap.lines.isEmpty { return }

        // Build the chunk body. Pre-typed vars throughout.
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
            // Truncate via Data slice — explicit Range to dodge prefix overload ambiguity.
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

        // Build filename without String(format:) variadic to avoid
        // type-checker overload-resolution overhead.
        let userIdRaw: String = appState.currentUserId ?? "anon"
        let userPrefix: String = String(userIdRaw.prefix(8))
        let seqStr: String = LiveLogStreamer.zeroPad(mySeq, width: 6)
        let session: String = bootSessionId
        let filename: String = "qaudion-live-" + userPrefix + "-" + session + "-" + seqStr + ".log"
        let serverUrlLocal: String = appState.serverUrl

        inflight = true
        lastUploadStartedAt = now
        // Strong self capture (singleton) — no [weak self] dance.
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
            // Surface first 3 + every 50th success so the maintainer
            // knows the pipeline is alive without spamming the buffer.
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

    /// Zero-pad an integer to a fixed width without going through
    /// String(format:) — avoids the type-checker variadic CVarArg
    /// overhead inside this concurrency-heavy file.
    private static func zeroPad(_ value: Int, width: Int) -> String {
        var s: String = String(value)
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
