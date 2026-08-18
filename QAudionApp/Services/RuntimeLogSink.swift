import Foundation
import os
import Darwin

/// W415 — in-memory ring buffer + helper API for app-side runtime
/// logging. Two goals:
///   1. Capture diagnostic context that the user can export from
///      Settings → Diagnostica when no Mac is connected to the iPhone
///      (the standard Console.app workflow assumes USB pairing).
///   2. Provide a single bottleneck (`RTLog.info/warn/error`) that
///      writes to BOTH the standard `os_log` system (for Console.app
///      when available) AND a process-local ring buffer that
///      DiagnosticsExportScreen can dump + upload to the server for
///      out-of-band analysis.
///
/// **Sizing:** 5000 lines × ~256 bytes ≈ 1.25 MB resident. Old
/// entries are evicted FIFO. The user's "Carica al server" action
/// snapshots the buffer into a UTF-8 .log file and POSTs via the
/// existing `/api/v1/files/upload`, returning a fileId the user can
/// share verbally so the maintainer pulls it via REST admin token.
@MainActor
public final class RuntimeLogSink: ObservableObject {

    public static let shared = RuntimeLogSink()

    public struct Entry: Identifiable {
        public let id = UUID()
        /// W417 — monotonic sequence number assigned at insert time.
        public let seq: Int64
        public let timestamp: Date
        public let level: Level
        public let tag: String
        public let message: String
    }

    public enum Level: String, Codable {
        case debug, info, warn, error

        var symbol: String {
            switch self {
            case .debug: return "🔵"
            case .info:  return "ℹ️"
            case .warn:  return "⚠️"
            case .error: return "❌"
            }
        }
    }

    private let maxEntries = 5000
    private let lock = NSLock()
    private var entries: [Entry] = []

    /// W417 — global monotonic counter incremented for every recorded
    /// entry. Independent from `entries.count` (FIFO eviction).
    private var nextSeq: Int64 = 1

    /// Bumped every time `record` adds a new line so SwiftUI views
    /// observing this sink re-render. Cheap monotonic counter.
    @Published public private(set) var entryCount: Int = 0

    /// Mirror to OSLog so Console.app on a connected Mac (when
    /// available) sees the same lines. Subsystem matches the bundle
    /// id so a developer can filter on `process == QAudionApp`.
    private let osLogger = Logger(subsystem: "com.qaudion.app", category: "runtime")

    private init() {}

    public func record(level: Level, tag: String, _ message: String) {
        lock.lock()
        let seq = nextSeq
        nextSeq &+= 1
        let entry = Entry(seq: seq, timestamp: Date(), level: level, tag: tag, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            // Drop the oldest 10% in one shot so we don't pay the
            // O(n) array shift on every single append past the cap.
            entries.removeFirst(maxEntries / 10)
        }
        lock.unlock()
        // Mirror to OSLog for Console.app + retain the formatted
        // form so a future os_log_store snapshot picks it up too.
        // SECURITY M-20 — `.private` so Apple sysdiagnose / device
        // log captures redact tag+message as <private>, while a
        // developer attached via Console.app (or the in-app dump)
        // still sees the full text. Prevents inadvertent leak of
        // app-authored diagnostics through OS-level log collection.
        switch level {
        case .debug: osLogger.debug("[\(tag, privacy: .private)] \(message, privacy: .private)")
        case .info:  osLogger.info("[\(tag, privacy: .private)] \(message, privacy: .private)")
        case .warn:  osLogger.warning("[\(tag, privacy: .private)] \(message, privacy: .private)")
        case .error: osLogger.error("[\(tag, privacy: .private)] \(message, privacy: .private)")
        }
        // Bump observable count on main (we're already @MainActor).
        entryCount &+= 1
        // W559 — feed errors into the auto-detection window.
        if level == .error {
            BugReporter.shared.onError(tag: tag, message: message)
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Snapshot of the current buffer formatted for log export.
    /// One line per entry, ISO8601-ish timestamp, level, tag, body.
    public func snapshot() -> String {
        lock.lock()
        let copy = entries
        lock.unlock()
        var out = String()
        out.reserveCapacity(copy.count * 200)
        for e in copy {
            out.append(Self.isoFormatter.string(from: e.timestamp))
            out.append(" ")
            out.append(e.level.rawValue.uppercased())
            out.append(" [")
            out.append(e.tag)
            out.append("] ")
            out.append(e.message)
            out.append("\n")
        }
        return out
    }

    /// W559 — Returns the last `minutes` minutes of log entries as a
    /// plain-text string formatted as `[timestamp] [LEVEL] [tag] message`.
    /// Thread-safe; allocates a temporary copy of the ring buffer.
    public func recentLogsAsString(minutes: Double = 2.0) -> String {
        lock.lock()
        let copy = entries
        lock.unlock()
        let cutoff = Date().addingTimeInterval(-minutes * 60.0)
        let recent = copy.filter { $0.timestamp >= cutoff }
        var out = String()
        out.reserveCapacity(recent.count * 200)
        for e in recent {
            out.append(Self.isoFormatter.string(from: e.timestamp))
            out.append(" [")
            out.append(e.level.rawValue.uppercased())
            out.append("] [")
            out.append(e.tag)
            out.append("] ")
            out.append(e.message)
            out.append("\n")
        }
        return out
    }

    /// W417 — incremental reader for LiveLogStreamer. Returns all
    /// entries with seq > since, plus the highest seq seen, so the
    /// caller can pass that back next time and skip what was already
    /// uploaded. Filters out lines tagged "livelog" to avoid feedback.
    public struct IncrementalSnapshot {
        public let lines: [String]
        public let highestSeq: Int64
    }

    public func entriesSince(seq since: Int64) -> IncrementalSnapshot {
        lock.lock()
        let copy = entries
        lock.unlock()
        var lines: [String] = []
        lines.reserveCapacity(min(copy.count, 256))
        var highest: Int64 = since
        for e in copy where e.seq > since {
            if e.tag == "livelog" { continue }
            
            let ts = Self.isoFormatter.string(from: e.timestamp)
            let lvl = e.level.rawValue.uppercased().prefix(1)
            let tag = escapeJson(e.tag)
            let msg = escapeJson(RuntimeLogSink.redactStructured(e.message))
            
            let json = "{\"ts\":\"\(ts)\",\"lvl\":\"\(lvl)\",\"tag\":\"\(tag)\",\"msg\":\"\(msg)\"}"
            lines.append(json)
            
            if e.seq > highest { highest = e.seq }
        }
        return IncrementalSnapshot(lines: lines, highestSeq: highest)
    }

    private func escapeJson(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Drop everything. Used by Settings → "Pulisci log".
    public func clear() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
        entryCount = 0
    }

    /// View-side accessor. SwiftUI list reads this; `entryCount`
    /// drives invalidation so we don't leak the lock.
    public var snapshotEntries: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    // MARK: - W416 stdout/stderr tee

    /// Holds the duplicated original stdout fd so we can keep
    /// forwarding to Console.app after we redirect to the pipe.
    private var origStdoutFd: Int32 = -1
    private var origStderrFd: Int32 = -1
    private var stdoutPipeSource: DispatchSourceRead?
    private var teeAttached: Bool = false

    /// W416 — capture every `print(...)` (stdlib, third-party, OS-level
    /// stderr noise) into the ring buffer too, so the user doesn't have
    /// to hand-convert ~100 existing print sites to RTLog. Idempotent.
    ///
    /// **How:** create an unnamed pipe, dup2 STDOUT_FILENO + STDERR_FILENO
    /// onto its write end, then in a background DispatchSourceRead
    /// loop read from the read end and:
    ///   1. write the bytes back to the SAVED original stdout/stderr fd
    ///      → Console.app + Xcode console still see everything as before;
    ///   2. parse the chunk as UTF-8 lines and `record(...)` each one
    ///      with tag "stdout" so the buffer + diagnostic dump capture
    ///      every line that any code path emits.
    ///
    /// **Cost:** ≈ 4KB transient buffer per read, one background
    /// dispatch source per process. No measurable overhead at typical
    /// log rates (< 100 lines/s).
    ///
    /// **Always-on:** `QAudionApp.onAppear` calls this once at launch.
    /// Combined with the FIFO ring buffer eviction (oldest 10% dropped
    /// when capacity exceeded), the system stays bounded — after 50
    /// telephone calls the buffer simply wraps over, never grows.
    /// SECURITY H-2 — best-effort secret scrubber for the
    /// stdout/stderr tee. Masks bearer tokens, `token=`/`token:`
    /// values, Authorization headers, and any long hex/base64 run
    /// (>= 24 chars, which catches raw keys / JWTs / hashes). Not a
    /// substitute for not logging secrets, but stops the common
    /// leak paths from reaching the uploadable ring buffer.
    ///
    /// Compiled once; the regexes are static-let so the per-line
    /// hot path only does `stringByReplacingMatches`.
    private static let redactPlaceholder: String = "***REDACTED***"

    // Single source of truth for the keyword alternation, shared by the
    // stdout-tee redact() and the egress redactStructured(). P2 extends
    // the set with crypto-secret keywords (psk|seed|mnemonic|privkey|
    // private-key|mlkem|sframe|kyber). `keyfp` is deliberately NOT in
    // the alternation, so keyfp=<8-16hex> short fingerprints survive.
    //
    // Value-introducer is ['":=] (quote/colon/equals) optionally followed
    // by whitespace -- a BARE SPACE after the keyword does NOT arm the
    // rule, so prose like "PSK selected keyfp=..." keeps the keyfp the
    // unseal-debug diagnostics need (the old [\"'\s:=]+ armed on a space
    // and ate the following token). The value run is [^\s\x{0001}]+ which
    // EXCLUDES the U+0001 sentinel byte used by redactStructured() to
    // stash call_id UUIDs / fingerprints, so a keyworded value can never
    // swallow a stashed-and-restored diagnostic. (Harmless to the
    // stdout-tee redact() path, which never produces sentinels.)
    private static let secretPrefixedEgress: NSRegularExpression = try! NSRegularExpression(
        pattern: #"(?i)(bearer|authorization|token|secret|api[-_]?key|password|psk|seed|mnemonic|privkey|private[-_]?key|mlkem|sframe|kyber)([\"':=]\s*)[^\s\x{0001}]+"#)

    private static let redactRegexes: [NSRegularExpression] = {
        // Patterns are compile-time constants; force-try is safe.
        let secretPrefixed = secretPrefixedEgress
        let longBlob = try! NSRegularExpression(
            pattern: #"[A-Za-z0-9+/=_-]{24,}"#)
        return [secretPrefixed, longBlob]
    }()

    private static func redact(_ line: String) -> String {
        var working: String = line
        for rx in redactRegexes {
            let full = NSRange(working.startIndex..<working.endIndex, in: working)
            let template: String = redactPlaceholder
            working = rx.stringByReplacingMatches(in: working,
                                                  options: [],
                                                  range: full,
                                                  withTemplate: template)
        }
        return working
    }

    // P2 - EGRESS redactor for the upload boundary (entriesSince()).
    // Distinct from redact(_:) (stdout-tee): this MUST preserve
    // diagnostics that fetch-ios-live.py / correlate-call.py /
    // symbolicate.py / ship-ios-logs.py parse, while still removing
    // secrets at rest. Unconditional security control - never flag-gated.
    //
    // Strategy (ASCII-only U+0001 sentinels):
    //   1a. STASH call_id UUIDs (8-4-4-4-12) so neither the blob rule nor
    //       the residual sweep can eat them (correlate-call / shipper
    //       derive short8/h8 from full UUIDs).
    //   1b. STASH labelled short-hex fingerprints (keyfp/short8/h8/fp/
    //       selectedPskFingerprint = <8-16 hex>) -- these are the exact
    //       identifiers the W574n PSK-convergence / unseal diagnostics
    //       reference. Stashing them BEFORE any scrub is what makes the
    //       keyfp= form survive (the residual sweep would otherwise eat a
    //       run that includes the '=' separator).
    //   2.  Redact dot-delimited JWTs (3 base64url segments) explicitly --
    //       the '.' fragments each segment below the blob/residual bars,
    //       so a JWT is invisible to length-only rules.
    //   3.  Run secretPrefixed (keyworded VALUES) + blob scrub (continuous
    //       base64url/hex run >= 24). The blob/residual charset now
    //       INCLUDES '-' because UUIDs AND fingerprints are already stashed
    //       out of the way, so '-' can no longer span a call_id -- this
    //       closes the base64url/JWT-with-hyphen fail-OPEN hole.
    //   4.  FAIL-CLOSED residual sweep: any mixed-alnum run >= 20 left over
    //       (charset incl '-') gets redacted. Runs BEFORE restore so the
    //       sentinels (which the U+0001 bytes break into short tokens)
    //       survive.
    //   5.  RESTORE stashed UUIDs + fingerprints.
    private static let uuidRegex = try! NSRegularExpression(
        pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#)
    // Labelled short-hex fingerprint (8-16 hex) preceded by a known label.
    // Stash the WHOLE match so neither the secret-keyword rule nor the
    // residual sweep can touch the fingerprint regardless of separator.
    private static let fingerprintRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(keyfp|selectedpskfingerprint|short8|h8|fp)([\s:=]+)([0-9a-fA-F]{8,16})\b"#)
    // Dot-delimited JWT: three base64url segments. Caught explicitly because
    // '.' fragments each segment below the length bars of the blob/residual
    // rules (the classic base64url fail-open).
    private static let jwtRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}"#)
    // High-entropy run: base64/base64url/hex >= 24. INCLUDES '-' (safe now
    // that UUIDs + fingerprints are sentinel-stashed) so it catches
    // base64url tokens, raw keys, ML-KEM ciphertext, hyphen-chunked blobs.
    private static let blobWithHyphen = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9+/=_-]{24,}"#)
    // Fail-closed residual: mixed run >= 20 (lower bar than the blob rule),
    // charset incl '-'. Crash frames ("QAudionApp ... + 12345") are pure
    // digits after '+' and survive; hex offsets "0x..." are guarded by the
    // leading-[0-9a-fA-Fx] negative lookbehind.
    private static let residualRegex = try! NSRegularExpression(
        pattern: #"(?<![0-9a-fA-Fx])[A-Za-z0-9+/=_-]{20,}"#)

    /// P2 EGRESS redactor, also reused by `TelemetryService.emit()` so the
    /// structured-event path gets the SAME fail-closed scrub as the text
    /// path before `sealBatch`. Exposed (public) for that second egress;
    /// the implementation and its UNCONDITIONAL nature are unchanged.
    public static func redactStructured(_ line: String) -> String {
        var work: String = line
        var stash: [String] = []

        // --- 1a. stash call_id UUIDs ---
        work = RuntimeLogSink.stashMatches(of: uuidRegex, in: work, stash: &stash)
        // --- 1b. stash labelled short-hex fingerprints ---
        work = RuntimeLogSink.stashMatches(of: fingerprintRegex, in: work, stash: &stash)

        // --- 2. dot-delimited JWT scrub ---
        let fullJwt = NSRange(work.startIndex..<work.endIndex, in: work)
        work = jwtRegex.stringByReplacingMatches(
            in: work, options: [], range: fullJwt, withTemplate: redactPlaceholder)

        // --- 3. secret keyword + hyphen-inclusive blob scrub ---
        let full1 = NSRange(work.startIndex..<work.endIndex, in: work)
        work = secretPrefixedEgress.stringByReplacingMatches(
            in: work, options: [], range: full1, withTemplate: redactPlaceholder)
        let full2 = NSRange(work.startIndex..<work.endIndex, in: work)
        work = blobWithHyphen.stringByReplacingMatches(
            in: work, options: [], range: full2, withTemplate: redactPlaceholder)

        // --- 4. fail-closed residual (run BEFORE restore so the U+0001
        //         sentinel bytes break stashed runs into short tokens) ---
        let full3 = NSRange(work.startIndex..<work.endIndex, in: work)
        work = residualRegex.stringByReplacingMatches(
            in: work, options: [], range: full3, withTemplate: redactPlaceholder)

        // --- 5. restore stashed UUIDs + fingerprints ---
        if !stash.isEmpty {
            for (i, u) in stash.enumerated() {
                work = work.replacingOccurrences(
                    of: "\u{0001}K\(i)\u{0001}", with: u)
            }
        }
        return work
    }

    /// Replace every match of `rx` in `text` with a U+0001-delimited
    /// sentinel (`\u{0001}K<idx>\u{0001}`) and append the original matched
    /// substring to `stash` at that index. The sentinel bytes are control
    /// chars outside every scrub charset, so the stashed value is immune to
    /// the secret/blob/residual rules until restored by index. Left-to-
    /// right, non-overlapping; indices are assigned in match order.
    private static func stashMatches(of rx: NSRegularExpression,
                                     in text: String,
                                     stash: inout [String]) -> String {
        let ns = text as NSString
        let matches = rx.matches(
            in: text, options: [],
            range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        var out: String = ""
        out.reserveCapacity(text.count)
        var lastEnd = text.startIndex
        for m in matches {
            guard let r = Range(m.range, in: text) else { continue }
            out.append(contentsOf: text[lastEnd..<r.lowerBound])
            let idx: Int = stash.count
            stash.append(String(text[r]))
            out.append("\u{0001}K")
            out.append(String(idx))
            out.append("\u{0001}")
            lastEnd = r.upperBound
        }
        out.append(contentsOf: text[lastEnd..<text.endIndex])
        return out
    }

    public func attachStdoutTee() {
        guard !teeAttached else { return }
        var pipeFds = [Int32](repeating: 0, count: 2)
        guard pipe(&pipeFds) == 0 else {
            print("[RuntimeLogSink] pipe() failed errno=\(errno)")
            return
        }
        let readFd = pipeFds[0]
        let writeFd = pipeFds[1]

        // Save originals so the tee can forward to Console.app/Xcode.
        origStdoutFd = dup(STDOUT_FILENO)
        origStderrFd = dup(STDERR_FILENO)

        // Redirect both streams to the pipe write end.
        dup2(writeFd, STDOUT_FILENO)
        dup2(writeFd, STDERR_FILENO)
        close(writeFd)

        // Disable stdout buffering so prints surface promptly.
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)

        let queue = DispatchQueue(label: "qaudion.runtime.stdout-tee", qos: .utility)
        let source = DispatchSource.makeReadSource(fileDescriptor: readFd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(readFd, &buf, buf.count)
            if n > 0 {
                // 1) Forward to the saved original stdout/stderr so
                //    Console.app + Xcode still see the line.
                _ = write(self.origStdoutFd, buf, n)
                // 2) Parse + record into the ring buffer.
                if let chunk = String(bytes: buf[0..<n], encoding: .utf8) {
                    let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true)
                    for line in lines {
                        // SECURITY H-2 — scrub obvious secrets out of
                        // captured stdout/stderr BEFORE they enter the
                        // ring buffer (which can be uploaded by the
                        // diagnostics dump). Redaction runs off-main.
                        let safe: String = RuntimeLogSink.redact(String(line))
                        Task { @MainActor [weak self] in
                            self?.record(level: .info, tag: "stdout", safe)
                        }
                    }
                }
            }
        }
        source.setCancelHandler {
            close(readFd)
        }
        source.resume()
        stdoutPipeSource = source
        teeAttached = true
        // Confirm via OSLog so even if stdout gets weird the wiring
        // is visible in Console.app.
        osLogger.info("[RuntimeLogSink] stdout/stderr tee attached")
    }

    /// Detach the stdout tee. Mostly for tests — production app
    /// keeps it attached for the process lifetime.
    public func detachStdoutTee() {
        guard teeAttached else { return }
        if origStdoutFd >= 0 { dup2(origStdoutFd, STDOUT_FILENO); close(origStdoutFd); origStdoutFd = -1 }
        if origStderrFd >= 0 { dup2(origStderrFd, STDERR_FILENO); close(origStderrFd); origStderrFd = -1 }
        stdoutPipeSource?.cancel()
        stdoutPipeSource = nil
        teeAttached = false
    }
}

/// Convenience global facade. Call `RTLog.info(...)` from any
/// production code path; it routes to `RuntimeLogSink.shared` on
/// MainActor (Task hop when off-main).
public enum RTLog {
    public static func debug(_ tag: String, _ message: String) { dispatch(.debug, tag, message) }
    public static func info (_ tag: String, _ message: String) { dispatch(.info,  tag, message) }
    public static func warn (_ tag: String, _ message: String) { dispatch(.warn,  tag, message) }
    public static func error(_ tag: String, _ message: String) { dispatch(.error, tag, message) }

    private static func dispatch(_ level: RuntimeLogSink.Level, _ tag: String, _ message: String) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                RuntimeLogSink.shared.record(level: level, tag: tag, message)
            }
        } else {
            Task { @MainActor in
                RuntimeLogSink.shared.record(level: level, tag: tag, message)
            }
        }
    }
}
