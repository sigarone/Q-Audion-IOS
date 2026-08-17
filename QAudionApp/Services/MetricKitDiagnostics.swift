import Foundation
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

/// W-MK -- MetricKit diagnostic bridge into the existing W417 telemetry.
///
/// MetricKit (MXMetricManager) hands the app a batch of diagnostic
/// payloads -- crashes, hangs, CPU exceptions, disk-write exceptions --
/// at most once per 24h, delivered at the NEXT launch after the event.
///
/// ## Why this emits a SUMMARY, not the raw JSON blob
///
/// `MXDiagnosticPayload.jsonRepresentation()` returns a multi-hundred-KB
/// pretty-printed blob. Pushing that through the W417 telemetry pipe is
/// structurally broken, as the three real downstream components prove:
///
///  1. `RuntimeLogSink.redact()` (SECURITY H-2) runs the regex
///     `[A-Za-z0-9+/=_-]{24,}` on EVERY tee'd line. MetricKit JSON is
///     full of base64 microstackshots, mach addresses and binary UUIDs
///     >= 24 chars, so the raw blob would be shredded into
///     `***REDACTED***` and become unparseable -- the diagnostic value
///     would be ~zero.
///  2. `LiveLogStreamer.maxChunkBytes` (64 KB) and `maxLinesPerChunk`
///     (256) cap each upload; a big payload split into many lines plus
///     `RuntimeLogSink.maxEntries` (5000, FIFO-evicted) means early
///     chunks get evicted before the 256-line/3s pump drains them ->
///     the server receives a non-reassemblable fragment.
///  3. The pump truncates an over-cap chunk with `[livelog-truncated]`,
///     silently dropping the tail.
///
/// So this bridge emits ONE bounded, human-readable, redaction-safe
/// summary per payload (the fields a maintainer triages on), plus a few
/// short per-diagnostic lines. The FULL symbolicated stack is already
/// delivered by two other channels and does NOT belong on this pipe:
///   - `CrashReporter` (W472) ships the in-process backtrace, and
///   - Apple's own MetricKit -> App Store Connect path surfaces the
///     complete payload in Xcode Organizer (Regressions / Diagnostics).
///
/// Each emitted line is a plain `print(...)`, captured 1:1 by the W416
/// stdout tee and shipped by the W417 pump -- exactly like
/// `CrashReporter.flushPendingReport()`. This file touches neither
/// `RuntimeLogSink` nor `LiveLogStreamer` directly.
///
/// ## CLAUDE.md compliance
///  - Section 16: `start()` takes NO parameters (no AppState anywhere).
///  - Section 13: every `print` argument is a single pre-bound
///    `let line: String`. No multi-segment interpolation, no
///    `String(num)` (only `String(describing:)`), no inline `+` at any
///    call site. All formatting lives in top-level static helpers.
///  - Raw `import MetricKit` -- NO new SPM dependency.
///  - Pure ASCII only.
///
/// ## Threading
/// MetricKit delivers `didReceive` on an INTERNAL (non-main) queue.
/// Every helper here is a pure value transform and emits via `print`
/// (thread-safe); the W416 tee hops each captured line to @MainActor
/// before `record(...)`. Do NOT touch UI or @MainActor state from any
/// method reached by `didReceive`.
enum MetricKitDiagnostics {

    #if canImport(MetricKit) && os(iOS)
    /// Strong-held singleton subscriber. MXMetricManager keeps only a
    /// weak reference, so the bridge must retain it for the app's life.
    /// The `@available` is the only legal way to store an iOS-14-typed
    /// value as a static stored property (deployment target is 16.0, so
    /// the availability is always satisfied at runtime).
    @available(iOS 14.0, *)
    private static let subscriber = MetricKitSubscriber()

    /// One-shot guard so a double `.onAppear` (possible on some SwiftUI
    /// navigation) cannot register the subscriber twice. MXMetricManager
    /// dedupes by instance, so this is belt-and-suspenders.
    private static var didRegister = false
    #endif

    /// Register the MetricKit subscriber. Call from `.onAppear` AFTER
    /// `RuntimeLogSink.shared.attachStdoutTee()` so the prints emitted
    /// on payload delivery are captured by the W416 tee and shipped by
    /// the W417 pump -- same ordering rationale as
    /// `CrashReporter.flushPendingReport()`.
    ///
    /// Called on the main thread from `.onAppear`; the `didRegister`
    /// guard is therefore not contended.
    static func start() {
        #if canImport(MetricKit) && os(iOS)
        if didRegister { return }
        didRegister = true
        MXMetricManager.shared.add(subscriber)
        print("[MetricKit] subscriber registered")
        #endif
    }
}

#if canImport(MetricKit) && os(iOS)

@available(iOS 14.0, *)
private final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber {

    /// iOS 13+ metric payloads (performance metrics). Not used by the
    /// telemetry bridge; emit one short marker so the W417 trail records
    /// that MetricKit delivered something.
    func didReceive(_ payloads: [MXMetricPayload]) {
        let count: String = String(describing: payloads.count)
        let line: String = "[MetricKit] metric payloads delivered: " + count
        print(line)
    }

    /// iOS 14+ diagnostic payloads (crashes, hangs, CPU exceptions,
    /// disk-write exceptions). Each is summarized to bounded,
    /// redaction-safe lines and emitted.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            MetricKitDiagnostics.emit(payload)
        }
    }
}

extension MetricKitDiagnostics {

    /// Top-level helper -- lifts ALL formatting out of the delegate so
    /// the Swift 6 type-checker has a clean, shallow scope (CLAUDE.md
    /// section 13). Summarizes one diagnostic payload as a handful of
    /// short, redaction-immune lines.
    @available(iOS 14.0, *)
    static func emit(_ payload: MXDiagnosticPayload) {
        let header: String = "[MetricKit] diagnostic payload begin"
        print(header)

        emitWindow(payload)
        emitCrashes(payload)
        emitHangs(payload)
        emitCPUExceptions(payload)
        emitDiskWriteExceptions(payload)

        let footer: String = "[MetricKit] diagnostic payload end"
        print(footer)
    }

    // MARK: - Per-category summaries (each line is short + redaction-safe)

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    @available(iOS 14.0, *)
    private static func emitWindow(_ payload: MXDiagnosticPayload) {
        let begin: String = isoFormatter.string(from: payload.timeStampBegin)
        let end: String = isoFormatter.string(from: payload.timeStampEnd)
        let line: String = "[MetricKit] window " + begin + " .. " + end
        print(line)
    }

    @available(iOS 14.0, *)
    private static func emitCrashes(_ payload: MXDiagnosticPayload) {
        guard let crashes = payload.crashDiagnostics, !crashes.isEmpty else { return }
        let header: String = countLine("crash", crashes.count)
        print(header)
        for c in crashes {
            let meta: String = appOSLine(c.metaData)
            let crashLine: String = "[MetricKit] crash " + meta
            print(crashLine)
            // Termination / exception detail -- short tokens only, never
            // a base64/hex run, so RuntimeLogSink.redact() leaves them be.
            let sig: String = optString(c.signal)
            let excType: String = optString(c.exceptionType)
            let excCode: String = optString(c.exceptionCode)
            // term uses a wider clip than the other fields: RBSTerminateContext
            // explanations (why RunningBoard/watchdog killed the app -- the
            // single most useful diagnostic token here) run well past 23 chars
            // and were being silently guillotined mid-word. redact() still
            // protects any embedded long base64/hex run, so widening this is
            // safe -- worst case a substring becomes ***REDACTED***, same as
            // every other diagnostic line in the pipe.
            let term: String = optStringWide(c.terminationReason)
            let detail: String = "[MetricKit] crash detail signal=" + sig
                + " excType=" + excType + " excCode=" + excCode
                + " term=" + term
            print(detail)
            // Emit the crashing thread's app frames as `QAudionApp + <offset>`
            // lines so scripts/symbolicate.py resolves them to file:line — the
            // ONLY channel for a SIGKILL/watchdog (0x8BADF00D) stack, which the
            // in-process CrashReporter cannot catch (no signal handler runs on a
            // RunningBoard kill). The offset is a plain decimal < redaction
            // threshold; binaryName is short. Bounded to keep the W417 pipe sane.
            emitCrashStack(c)
        }
    }

    /// Parse `MXCrashDiagnostic.callStackTree` (the crashing thread's frames,
    /// present in the payload) and print each frame in the exact format the
    /// offline symbolicator expects. Best-effort: any parse miss is silent —
    /// the term= line above still carries the kill reason.
    @available(iOS 14.0, *)
    private static func emitCrashStack(_ c: MXCrashDiagnostic) {
        let data: Data = c.callStackTree.jsonRepresentation()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        guard let stacks = root["callStacks"] as? [[String: Any]] else { return }
        // Prefer the crash-attributed thread; fall back to the first stack.
        let chosen = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks.first
        guard let stack = chosen,
              let roots = stack["callStackRootFrames"] as? [[String: Any]] else { return }
        print("[MetricKit] crash stack:")
        var emitted = 0
        emitFrames(roots, depth: 0, count: &emitted)
    }

    /// Depth-first walk of the frame tree (`subFrames` chains root→leaf).
    /// Emits at most `maxCrashFrames` lines total.
    @available(iOS 14.0, *)
    private static func emitFrames(_ frames: [[String: Any]], depth: Int, count: inout Int) {
        for f in frames {
            if count >= maxCrashFrames { return }
            let bin: String = (f["binaryName"] as? String) ?? "?"
            let off: Int = (f["offsetIntoBinaryTextSegment"] as? Int) ?? -1
            let offStr: String = String(describing: off)
            let idxStr: String = String(describing: count)
            // Match the CrashReporter/symbolicate.py line shape: any line
            // containing "<binaryName> + <decimalOffset>" is resolvable.
            let line: String = "[MetricKit] " + idxStr + "  " + bin + " + " + offStr
            print(line)
            count += 1
            if let sub = f["subFrames"] as? [[String: Any]], !sub.isEmpty {
                emitFrames(sub, depth: depth + 1, count: &count)
            }
        }
    }

    private static let maxCrashFrames = 48

    @available(iOS 14.0, *)
    private static func emitHangs(_ payload: MXDiagnosticPayload) {
        guard let hangs = payload.hangDiagnostics, !hangs.isEmpty else { return }
        let header: String = countLine("hang", hangs.count)
        print(header)
        for h in hangs {
            let meta: String = appOSLine(h.metaData)
            let dur: String = measurementString(h.hangDuration)
            let line: String = "[MetricKit] hang duration=" + dur + " " + meta
            print(line)
        }
    }

    @available(iOS 14.0, *)
    private static func emitCPUExceptions(_ payload: MXDiagnosticPayload) {
        guard let cpu = payload.cpuExceptionDiagnostics, !cpu.isEmpty else { return }
        let header: String = countLine("cpu_exception", cpu.count)
        print(header)
        for e in cpu {
            let meta: String = appOSLine(e.metaData)
            let secs: String = measurementString(e.totalCPUTime)
            let line: String = "[MetricKit] cpu_exception cpuTime=" + secs + " " + meta
            print(line)
        }
    }

    @available(iOS 14.0, *)
    private static func emitDiskWriteExceptions(_ payload: MXDiagnosticPayload) {
        guard let disk = payload.diskWriteExceptionDiagnostics, !disk.isEmpty else { return }
        let header: String = countLine("disk_write_exception", disk.count)
        print(header)
        for e in disk {
            let meta: String = appOSLine(e.metaData)
            let written: String = measurementString(e.totalWritesCaused)
            let line: String = "[MetricKit] disk_write_exception writes=" + written + " " + meta
            print(line)
        }
    }

    // MARK: - Formatting helpers (single-overload, type-checker-safe)

    /// App + OS versions from a diagnostic payload's metadata. These are
    /// short version strings, well under the 24-char redaction threshold.
    @available(iOS 14.0, *)
    private static func appOSLine(_ meta: MXMetaData?) -> String {
        guard let m = meta else { return "app=? os=?" }
        let app: String = clip(m.applicationBuildVersion)
        let os: String = clip(m.osVersion)
        return "app=" + app + " os=" + os
    }

    private static func countLine(_ kind: String, _ count: Int) -> String {
        let n: String = String(describing: count)
        return "[MetricKit] " + kind + " count=" + n
    }

    /// Convert any `Measurement` to a plain Double description. Avoids
    /// `String(_:)`'s numeric-overload set (CLAUDE.md section 13).
    private static func measurementString<U>(_ m: Measurement<U>) -> String {
        let v: Double = m.value
        return String(describing: v)
    }

    private static func optString(_ s: String?) -> String {
        guard let v = s, !v.isEmpty else { return "?" }
        return clip(v)
    }

    /// Same as `optString` but keeps up to `wideClipMaxLen` chars instead of
    /// the default 23 -- for the one field (`terminationReason`) where the
    /// diagnostic payload lives past the redaction-safety cutoff.
    private static func optStringWide(_ s: String?) -> String {
        guard let v = s, !v.isEmpty else { return "?" }
        return clip(v, maxLen: wideClipMaxLen)
    }

    private static let wideClipMaxLen = 240

    private static func optString(_ n: NSNumber?) -> String {
        guard let v = n else { return "?" }
        return String(describing: v.intValue)
    }

    /// Keep every emitted token short, single-line, and below the
    /// `[A-Za-z0-9+/=_-]{24,}` redaction threshold so the secret
    /// scrubber never mangles a summary line. Collapses whitespace and
    /// hard-caps length at 23 chars.
    private static func clip(_ s: String, maxLen: Int = 23) -> String {
        let flat0: String = s.replacingOccurrences(of: "\n", with: " ")
        let flat: String = flat0.replacingOccurrences(of: "\r", with: " ")
        if flat.count <= maxLen {
            return flat
        }
        let cut: String = String(flat.prefix(maxLen))
        return cut
    }
}

#endif
