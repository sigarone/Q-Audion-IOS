import Foundation
import Network
import CryptoKit
import QAudionEngine

// W-LIVELOGOFFMAIN (2026-09-21) -- the off-main engine of the W417 opt-in log shipper.
//
// WHY: call 4da935fd (iPhone, 2026-09-20, perfect network) had five main-thread stalls of
// 0.7-4.5 s. The shipper (`LiveLogStreamer`, `@MainActor`) answered every upload with HTTP
// 429, never advanced its read cursor, and on every attempt re-read, re-redacted (several
// regexes per line) and re-serialised the WHOLE unshipped ring (up to 5000 entries) on the
// main thread, then built the upload provider there too. Each stall began right before an
// upload attempt and grew as the backlog did.
//
// WHAT NOW RUNS HERE, off the main thread, on this actor:
//   * redaction (`LogRedactor`) and JSON line building (`LiveLogBlob`), once per line;
//   * the bounded backlog (`LiveLogBacklog`), chunk assembly, file naming, the HMAC tag;
//   * the upload itself (provider construction, TUS requests) and its 401 refresh retry;
//   * the back-off decision (`LiveLogBackoff`: Retry-After, else 5 s doubling to 120 s);
//   * the timer (a sleeping task, not a main run-loop `Timer`) and the network-path monitor.
//
// WHAT STILL TOUCHES THE MAIN THREAD (and why):
//   * one short hop per tick to copy the NEW ring entries out of `RuntimeLogSink`, whose ring
//     is main-actor state (`rawEntriesSince`: cost proportional to the new entries, no
//     regex, no formatting);
//   * one hop every 30 s (5 s while signed out) to read the access token, the user id and the
//     remote kill-switch through the app's `@MainActor` providers (a Keychain read);
//   * one hop for the token refresh when an upload answers 401;
//   * each `RTLog` line this worker emits (a handful per failure, none per retry loop);
//   * `start`/`stop` and reading `UIDevice` once, in `LiveLogStreamer`.
//
// While the server is throttling, nothing is retried in a loop: the worker keeps collecting
// into the bounded backlog (drop-oldest, counted) and does no upload work at all until the
// back-off window has passed.

/// SECURITY C-10 consent flag, readable from any thread (UserDefaults is thread-safe).
/// `LiveLogStreamer.consentKey` / `isEnabled` forward here, unchanged.
enum LiveLogConsent {
    static let key: String = "qaudion.diagnostics.liveStreamEnabled"

    static var isEnabled: Bool {
        if let explicit = UserDefaults.standard.object(forKey: key) as? Bool {
            return explicit
        }
        return false
    }
}

/// One entry of the runtime log ring, copied out for the worker (unredacted).
struct LiveLogRawEntry: Sendable {
    let seq: Int64
    let timestamp: Date
    let level: String
    let tag: String
    let message: String
}

/// The new ring entries since a cursor, oldest first, plus how many were left out.
struct LiveLogRawBatch: Sendable {
    let entries: [LiveLogRawEntry]
    let skippedOlder: Int
}

actor LiveLogWorker {

    // MARK: - Types handed in by the main-actor façade

    struct AuthSnapshot: Sendable {
        let token: String
        let userId: String
        /// Runtime kill-switch (`LOG_OTLP_EXPORT_ENABLED`); consent is checked separately.
        let shipEnabled: Bool
    }

    struct Config {
        let serverUrl: String
        let bootSessionId: String
        let model: String
        let os: String
        let appVer: String
        let flushIntervalSeconds: TimeInterval
        let maxChunkBytes: Int
        let maxLinesPerChunk: Int
        /// Reads token, user id and kill-switch. Runs on the main actor.
        let authProvider: @MainActor () -> AuthSnapshot
        /// Runs the app's own single-flight token refresh. Runs on the main actor.
        let refreshProvider: @MainActor () async -> Void
    }

    // MARK: - Tunables

    private static let minSecondsBetweenUploads: TimeInterval = 2.0
    /// W-LIVELOGHANG -- a hung upload must not freeze the pump for good.
    private static let uploadTimeoutSeconds: UInt64 = 12
    private static let authTtlSeconds: TimeInterval = 30
    private static let noAuthRecheckSeconds: TimeInterval = 5
    /// Prepared lines kept while the server is not accepting them. At the ~12-50 lines/s a call
    /// produces this is 40-160 s of log; beyond it the OLDEST lines go and are counted.
    private static let backlogMaxEntries: Int = 2000
    private static let backlogMaxBytes: Int = 512 * 1024

    // MARK: - State (all touched only on this actor)

    private var config: Config?
    private var running: Bool = false
    private var appliedEpoch: Int = 0
    /// Bumped on every start and stop, so work started before a stop cannot act after it.
    private var runEpoch: Int = 0
    private var loopTask: Task<Void, Never>?

    private var pathMonitor: NWPathMonitor?
    private var netType: String = "NONE"
    private var netMetered: Bool = false

    private var backlog = LiveLogBacklog(maxEntries: LiveLogWorker.backlogMaxEntries,
                                         maxBytes: LiveLogWorker.backlogMaxBytes)
    private var backoff = LiveLogBackoff()
    /// Highest ring seq already moved into the backlog (or skipped as a "livelog" line).
    private var collectedSeq: Int64 = 0
    /// Highest ring seq the server confirmed. A restart after consent withdrawal resumes here.
    private var ackSeq: Int64 = 0

    private var chunkSeq: Int = 0
    private var inflight: Bool = false
    private var lastUploadStartedAt: TimeInterval = -Double.infinity
    /// The `performUpload` task currently attempting `chunkSeq`. Cancelled (not just
    /// forgotten) by `uploadTimedOut` so a hung TUS request is actually torn down instead of
    /// running on in the background while a replacement upload starts over the same backlog.
    private var uploadTask: Task<Void, Never>?
    /// Set by `uploadTimedOut` to the seq it just gave up on. `uploadFailed` checks this (in
    /// addition to the `chunkSeq == seq` generation check already used everywhere else in this
    /// file) so the cancellation unwinding through the SAME attempt's own catch block cannot
    /// double-count a failure or re-run the 401 refresh cascade for it. `uploadSucceeded`
    /// deliberately does NOT check it: a confirmation that still arrives is a fact about the
    /// server and is applied regardless (see that function's own comment).
    private var timedOutSeq: Int?

    private var cachedAuth: AuthSnapshot?
    private var cachedAuthAt: TimeInterval = -Double.infinity
    private var userTag: String = ""
    private var userTagFor: String = ""

    private var failedUploads: Int = 0
    private var uploadedChunks: Int = 0
    private var skippedDueToInflight: Int = 0
    private var skippedDueToNoAuth: Int = 0

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Lifecycle (driven by LiveLogStreamer, ordered by `epoch`)

    func start(epoch: Int, config: Config) {
        guard epoch > appliedEpoch else { return }
        appliedEpoch = epoch
        self.config = config
        loopTask?.cancel()
        pathMonitor?.cancel()
        running = true
        runEpoch += 1
        startPathMonitor()
        let thisEpoch: Int = runEpoch
        // `start` is reached from a task the main actor created, so a plain `Task { }` here would
        // inherit its high priority and run the regex work at the same QoS as the UI. A log
        // shipper has no deadline: `.utility` keeps it out of the way of the audio and UI work.
        loopTask = Task(priority: .utility) { [weak self] in
            await self?.runLoop(runEpoch: thisEpoch)
        }
    }

    /// SECURITY C-10 -- consent withdrawal is immediate: the loop, the path monitor and the
    /// buffered (already redacted) lines are dropped. The read cursor falls back to what the
    /// server confirmed, so re-enabling later resumes exactly where shipping stopped.
    func stop(epoch: Int) {
        guard epoch > appliedEpoch else { return }
        appliedEpoch = epoch
        running = false
        runEpoch += 1
        loopTask?.cancel()
        loopTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        inflight = false
        uploadTask?.cancel()
        uploadTask = nil
        timedOutSeq = nil
        backlog.removeAll()
        collectedSeq = ackSeq
        cachedAuth = nil
    }

    // MARK: - Network path

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let net: String = LiveLogWorker.networkType(of: path)
            let metered: Bool = path.isExpensive
            Task { [weak self] in
                await self?.updatePath(net: net, metered: metered)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .background))
        pathMonitor = monitor
    }

    func updatePath(net: String, metered: Bool) {
        netType = net
        netMetered = metered
    }

    private static func networkType(of path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) { return "WIFI" }
        if path.usesInterfaceType(.cellular) { return "CELLULAR" }
        if path.usesInterfaceType(.wiredEthernet) { return "ETHERNET" }
        if path.usesInterfaceType(.loopback) { return "LOOPBACK" }
        return "OTHER"
    }

    // MARK: - The loop

    /// Sleep first, then tick: like the `Timer` this replaces, the first flush comes one
    /// interval after start, not at the instant the app is still initialising.
    private func runLoop(runEpoch expected: Int) async {
        while !Task.isCancelled && running && runEpoch == expected {
            let seconds: TimeInterval = max(config?.flushIntervalSeconds ?? 3.0, 0.5)
            let nanos: UInt64 = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled || !running || runEpoch != expected { return }
            await tick(runEpoch: expected)
        }
    }

    private static func monotonicNow() -> TimeInterval {
        return ProcessInfo.processInfo.systemUptime
    }

    private func tick(runEpoch expected: Int) async {
        guard let cfg = config else { return }
        // Consent is re-read on every tick (SECURITY C-10): withdrawing it stops shipping at the
        // next tick even if `stop` has not reached this actor yet.
        guard LiveLogConsent.isEnabled else { return }

        let auth: AuthSnapshot = await currentAuth(cfg: cfg, force: false)
        guard runEpoch == expected else { return }
        // W-FLAGS runtime kill-switch. Gates SHIP only; redaction is unconditional (FIX-19:
        // consent is ANDed with the flag above, never replaced by it).
        guard auth.shipEnabled else { return }
        if auth.token.isEmpty {
            skippedDueToNoAuth += 1
            return
        }

        // Keep collecting even while an upload is in flight or the server is throttling: the
        // work is off-main, bounded, and each line is prepared exactly once.
        await collect(expected: expected)
        guard runEpoch == expected else { return }
        // SECURITY C-10 -- the auth read and the collection above each hopped through the main
        // thread, which can be busy for seconds, and `stop` reaches this actor through a main-actor
        // task of its own. The consent written by `setEnabled(false)` is already visible here, so
        // it is read again immediately before an upload can start: withdrawing consent must not
        // let one more chunk go out from a tick that was already suspended.
        guard LiveLogConsent.isEnabled else { return }

        if inflight {
            skippedDueToInflight += 1
            return
        }
        let now: TimeInterval = LiveLogWorker.monotonicNow()
        if now - lastUploadStartedAt < LiveLogWorker.minSecondsBetweenUploads { return }
        if backoff.isBackingOff(now: now) { return }
        launchUpload(cfg: cfg, auth: auth, now: now, expected: expected)
    }

    // MARK: - Auth snapshot (one main-actor hop, cached)

    private func currentAuth(cfg: Config, force: Bool) async -> AuthSnapshot {
        let now: TimeInterval = LiveLogWorker.monotonicNow()
        if !force, let cached = cachedAuth {
            let ttl: TimeInterval = cached.token.isEmpty ? LiveLogWorker.noAuthRecheckSeconds : LiveLogWorker.authTtlSeconds
            if now - cachedAuthAt < ttl { return cached }
        }
        let provider = cfg.authProvider
        let epochAtStart: Int = runEpoch
        let fresh: AuthSnapshot = await provider()
        // A `stop` that landed during the main-actor hop already dropped the cache (SECURITY C-10):
        // do not put the token back behind it.
        if runEpoch == epochAtStart {
            cachedAuth = fresh
            cachedAuthAt = LiveLogWorker.monotonicNow()
        }
        return fresh
    }

    // MARK: - Collecting

    private func collect(expected: Int) async {
        let since: Int64 = collectedSeq
        let maxTake: Int = backlog.maxEntries
        let batch: LiveLogRawBatch = await MainActor.run {
            RuntimeLogSink.shared.rawEntriesSince(seq: since, maxCount: maxTake)
        }
        guard runEpoch == expected else { return }
        backlog.noteDropped(batch.skippedOlder)
        var highest: Int64 = since
        for entry in batch.entries {
            if entry.seq > highest { highest = entry.seq }
            // Self-suppression: the shipper's own lines are never shipped (feedback loop).
            if entry.tag == "livelog" { continue }
            let timestamp: String = isoFormatter.string(from: entry.timestamp)
            let levelInitial: String = String(entry.level.uppercased().prefix(1))
            let redacted: String = LogRedactor.redactStructured(entry.message)
            let line: String = LiveLogBlob.jsonLine(timestamp: timestamp,
                                                    levelInitial: levelInitial,
                                                    tag: entry.tag,
                                                    message: redacted)
            backlog.append(seq: entry.seq, line: line)
        }
        if highest > collectedSeq { collectedSeq = highest }
    }

    // MARK: - Uploading

    private func launchUpload(cfg: Config, auth: AuthSnapshot, now: TimeInterval, expected: Int) {
        let header: String = LiveLogBlob.header(session: cfg.bootSessionId,
                                                model: cfg.model,
                                                os: cfg.os,
                                                net: netType,
                                                metered: netMetered,
                                                appVer: cfg.appVer)
        let budget: Int = LiveLogBlob.linesByteBudget(header: header, maxBytes: cfg.maxChunkBytes)
        guard let batch = backlog.peekBatch(maxLines: cfg.maxLinesPerChunk, byteBudget: budget) else { return }
        let data: Data = LiveLogBlob.chunkData(header: header, lines: batch.lines, maxBytes: cfg.maxChunkBytes)

        // SECURITY L-6 -- never the raw user id in the file name: an HMAC keyed by the per-boot
        // session id, stable within a session.
        if userTagFor != auth.userId {
            userTag = LiveLogWorker.sessionScopedTag(userId: auth.userId, sessionKey: cfg.bootSessionId)
            userTagFor = auth.userId
        }
        chunkSeq += 1
        let mySeq: Int = chunkSeq
        let filename: String = LiveLogBlob.filename(userTag: userTag, session: cfg.bootSessionId, seq: mySeq)
        inflight = true
        lastUploadStartedAt = now

        let serverUrl: String = cfg.serverUrl
        let token: String = auth.token
        let chunkBytes: Int = data.count
        let lastSeq: Int64 = batch.lastSeq

        // W-LIVELOGHANG watchdog: a hung upload releases `inflight` after `uploadTimeoutSeconds`.
        // W-LIVELOGSINGLEFLIGHT (below) additionally cancels the actual `uploadTask`, so a stuck
        // TUS request no longer keeps running (and potentially confirming) after the watchdog
        // gives up -- see `uploadTimedOut`. Cancellation of `URLSession.data(for:)` (used by
        // `TusUploadClient`) is cooperative but real: the async overload cancels its underlying
        // `URLSessionTask` when the wrapping `Task` is cancelled, so the in-flight HTTP request is
        // actually aborted, not just abandoned -- it does not wait for a server response first.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: LiveLogWorker.uploadTimeoutSeconds * 1_000_000_000)
            await self?.uploadTimedOut(seq: mySeq, runEpoch: expected)
        }
        // W-LIVELOGSINGLEFLIGHT -- keep the handle so a watchdog timeout can actually cancel
        // this attempt (see `uploadTimedOut`) instead of only clearing the `inflight` flag
        // while the TUS request keeps running in the background.
        uploadTask = Task { [weak self] in
            await self?.performUpload(serverUrl: serverUrl,
                                      token: token,
                                      filename: filename,
                                      data: data,
                                      chunkBytes: chunkBytes,
                                      seq: mySeq,
                                      lastSeq: lastSeq,
                                      runEpoch: expected,
                                      isRetryAfterRefresh: false)
        }
    }

    private func uploadTimedOut(seq: Int, runEpoch expected: Int) async {
        guard inflight, chunkSeq == seq, runEpoch == expected else { return }
        inflight = false
        // Mark this seq as timed out BEFORE cancelling: the cancellation unwinds into
        // `performUpload`'s catch block on this same actor, and by the time it runs
        // `timedOutSeq` must already say "this one is accounted for, ignore it".
        timedOutSeq = seq
        uploadTask?.cancel()
        uploadTask = nil
        failedUploads += 1
        let seqStr: String = String(describing: seq)
        let line: String = "livelog upload timeout seq=" + seqStr
        RTLog.warn("net", line)
    }

    private func performUpload(serverUrl: String,
                               token: String,
                               filename: String,
                               data: Data,
                               chunkBytes: Int,
                               seq: Int,
                               lastSeq: Int64,
                               runEpoch expected: Int,
                               isRetryAfterRefresh: Bool) async {
        // SECURITY C-10 -- last gate before anything is built or sent, for the first attempt (it
        // starts in a task of its own, after the tick that launched it) and for the retry after a
        // 401 refresh (which awaited the main thread twice). A stopped run does nothing; the
        // consent flag alone (stop not yet delivered) also ends this chunk without a failure.
        guard runEpoch == expected else { return }
        guard LiveLogConsent.isEnabled else {
            if chunkSeq == seq { inflight = false }
            return
        }
        let backendConfig: BackendConfig = BackendConfig.pinned(serverUrl: serverUrl, accessToken: token)
        let provider: BCryptoBackendProvider = BCryptoBackendProvider(config: backendConfig)
        var tusClient: TusUploadClient?
        do {
            let fileId: String
            if let storage = provider.storageApi as? BCryptoStorageApiImpl {
                let client: TusUploadClient = storage.makeTusClient()
                tusClient = client
                fileId = try await client.upload(data: data, filename: filename)
            } else {
                fileId = try await provider.storageApi.uploadFile(data: data, filename: filename)
            }
            await uploadSucceeded(fileId: fileId, chunkBytes: chunkBytes, seq: seq, lastSeq: lastSeq)
        } catch {
            let retryAfterHeader: String? = tusClient?.lastRetryAfterHeader
            await uploadFailed(error: error,
                               retryAfterHeader: retryAfterHeader,
                               serverUrl: serverUrl,
                               token: token,
                               filename: filename,
                               data: data,
                               chunkBytes: chunkBytes,
                               seq: seq,
                               lastSeq: lastSeq,
                               runEpoch: expected,
                               isRetryAfterRefresh: isRetryAfterRefresh)
        }
    }

    private func uploadSucceeded(fileId: String, chunkBytes: Int, seq: Int, lastSeq: Int64) async {
        // A confirmation is a fact about the server, so it is applied even if this chunk's
        // watchdog already fired or a newer chunk started (`removeThrough` is keyed by seq and
        // idempotent). Only the in-flight flag belongs to the chunk that is still awaited.
        if chunkSeq == seq { inflight = false }
        uploadedChunks += 1
        if lastSeq > ackSeq { ackSeq = lastSeq }
        // A confirmation that arrives after a `stop` (which rewound `collectedSeq` to the OLD
        // `ackSeq`) must not leave the read cursor behind what the server now holds: the lines in
        // between would be collected again after a restart and shipped twice.
        if lastSeq > collectedSeq { collectedSeq = lastSeq }
        backlog.removeThrough(seq: lastSeq)
        backoff.recordSuccess()
        if uploadedChunks <= 3 || (uploadedChunks % 50) == 0 {
            let seqStr: String = String(describing: seq)
            let bytesStr: String = String(describing: chunkBytes)
            let line: String = "chunk #" + seqStr + " fileId=" + fileId + " bytes=" + bytesStr
            RTLog.info("livelog", line)
        }
        let dropped: Int = backlog.takeUnreportedDropCount()
        if dropped > 0 {
            let droppedStr: String = String(describing: dropped)
            let line: String = "livelog backlog drop=" + droppedStr
            RTLog.warn("net", line)
        }
    }

    private func uploadFailed(error: Error,
                              retryAfterHeader: String?,
                              serverUrl: String,
                              token: String,
                              filename: String,
                              data: Data,
                              chunkBytes: Int,
                              seq: Int,
                              lastSeq: Int64,
                              runEpoch expected: Int,
                              isRetryAfterRefresh: Bool) async {
        // Only the failure of the upload the pump is still waiting on counts: a late failure
        // after the watchdog already gave up on it must not be double-counted.
        guard chunkSeq == seq, runEpoch == expected else { return }
        // W-LIVELOGSINGLEFLIGHT -- `uploadTimedOut` already cancelled this exact attempt's task,
        // cleared `inflight` and counted the failure. The `CancellationError`/`URLError.cancelled`
        // that cancellation produces unwinds right back into this catch block on the same actor;
        // without this check it would count a SECOND failure and, if the cancellation raced a 401,
        // could even kick off the refresh-and-retry cascade below for an attempt that is already dead.
        guard timedOutSeq != seq else { return }
        guard let cfg = config else { return }
        let status: Int? = LiveLogWorker.httpStatus(of: error)

        // W-LIVELOGAUTHREFRESH -- a 401 almost always means this process's access token expired
        // with no unrelated API call around to refresh it. Ask the app's OWN single-flight
        // refresh (never a second, independent cascade), re-read the token, retry this one chunk
        // once. A dead refresh token falls straight through to the normal failure path.
        if !isRetryAfterRefresh, status == 401 {
            let refresh = cfg.refreshProvider
            await refresh()
            let fresh: AuthSnapshot = await currentAuth(cfg: cfg, force: true)
            // Both awaits above went through the main thread: the run may have been stopped (or
            // stopped and started again) meanwhile, and the state below then belongs to the newer
            // run. Consent itself is re-read by `performUpload` before the retry is sent.
            guard chunkSeq == seq, runEpoch == expected else { return }
            if !fresh.token.isEmpty, fresh.token != token {
                await performUpload(serverUrl: serverUrl,
                                    token: fresh.token,
                                    filename: filename,
                                    data: data,
                                    chunkBytes: chunkBytes,
                                    seq: seq,
                                    lastSeq: lastSeq,
                                    runEpoch: expected,
                                    isRetryAfterRefresh: true)
                return
            }
        }

        failedUploads += 1
        inflight = false

        // 429 / 503: honour Retry-After, else exponential with jitter; other 5xx keep their
        // earlier schedule; everything else just ends the streak. Nothing here loops.
        let retryAfter: TimeInterval? = LiveLogBackoff.parseRetryAfter(retryAfterHeader, now: Date())
        let jitterDraw: Double = Double.random(in: 0...1)
        let delay: TimeInterval? = backoff.recordFailure(status: status,
                                                         retryAfterSeconds: retryAfter,
                                                         now: LiveLogWorker.monotonicNow(),
                                                         jitterUnit: jitterDraw)

        // W-LIVELOGSILENTFAIL -- keep the reason in the line ("net", not "livelog", so it ships
        // once the pump recovers). Unchanged.
        let seqStr: String = String(describing: seq)
        let failStr: String = String(describing: failedUploads)
        let reason: String = error.localizedDescription
        let line: String = "livelog upload error seq=" + seqStr + " totalfail=" + failStr + " reason=" + reason
        RTLog.warn("net", line)

        if let seconds = delay {
            let secondsStr: String = String(describing: Int(seconds.rounded()))
            let streakStr: String = String(describing: backoff.consecutiveFailures)
            let hintStr: String = retryAfter == nil ? "0" : "1"
            let backoffLine: String = "livelog backoff n=" + streakStr + " s=" + secondsStr + " ra=" + hintStr
            RTLog.warn("net", backoffLine)
        }
    }

    // MARK: - Helpers

    /// HTTP status carried by a TUS error, if any.
    private static func httpStatus(of error: Error) -> Int? {
        switch error {
        case TusUploadClient.TusError.createFailed(let c): return c
        case TusUploadClient.TusError.patchFailed(let c): return c
        case TusUploadClient.TusError.headFailed(let c): return c
        default: return nil
        }
    }

    /// SECURITY L-6 -- HMAC-SHA256(userId) keyed by the per-boot session UUID, hex, first 8
    /// chars. Stable per session so the `qaudion-live-<tag>-<session>-<seq>` grep still groups
    /// a session's chunks, but the tag reveals nothing about the user id and differs every boot.
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
}
