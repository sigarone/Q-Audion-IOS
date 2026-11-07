import Foundation
import MachO
import QAudionEngine

/// W472 — lightweight in-app native-crash catcher.
///
/// Why this exists: the iOS test devices are NOT USB-connected to a
/// debugger, and the W417 live telemetry only captures `stdout`. A
/// native crash — a POSIX signal (EXC_BAD_ACCESS → SIGSEGV/SIGBUS), a
/// Swift trap (force-unwrap nil, out-of-bounds, `precondition` →
/// SIGTRAP/SIGILL), or an uncaught `NSException` (→ SIGABRT) — kills
/// the process WITHOUT writing a single stdout line, so the telemetry
/// shows only a session-UUID change with no cause. The iPhone-side
/// "crashes immediately on a call" bug is exactly this: invisible.
///
/// This installs an uncaught-exception handler plus POSIX signal
/// handlers that persist a backtrace to a file in Caches. On the NEXT
/// launch `flushPendingReport()` prints that file line-by-line — which
/// the W417 stdout tee then ships to the server. One reproduction of
/// the crash therefore makes the stack trace appear in the telemetry.
///
/// This is deliberately NOT a full crash-reporting SDK. The POSIX signal
/// handler is async-signal-safe: a file opened at launch, a buffer and a
/// frame array allocated at launch, `backtrace` and `write(2)` (see
/// `CrashRawCapture` below), writing raw addresses plus the main binary UUID
/// and load address; the next launch turns that into the report text. The
/// uncaught-NSException handler runs in normal context and still writes
/// the text report directly. After persisting, the signal handler restores
/// the default disposition and re-raises so the OS still produces its normal
/// crash report (for App Store Connect too).
enum CrashReporter {

    /// Absolute path of the persisted-crash file. Computed ONCE here so
    /// the signal handler never has to call `NSSearchPathForDirectories`
    /// (a syscall) from an async-signal context.
    private static let reportPath: String = {
        let base = NSSearchPathForDirectoriesInDomains(
            .cachesDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        return (base as NSString).appendingPathComponent("qaudion-last-crash.txt")
    }()

    /// W574j — set by the uncaught-NSException handler. An NSException aborts
    /// via SIGABRT, so the signal handler fires too; without this flag it
    /// overwrote the exception report (name + REASON — e.g. AVFAudio
    /// "required condition is false: …") with the bare signal stack, losing
    /// the one line that pinpoints the crash. The signal handler now skips
    /// persisting when an exception report is already in flight.
    fileprivate static var exceptionInFlight = false

    /// W-CRASHTELEMETRY (this task) — the CRASHED build's version, computed
    /// ONCE up front (same "force the lazy path computation up-front" style
    /// as `reportPath` above) so the signal handler never has to touch
    /// `Bundle.main.infoDictionary` from an async-signal context.
    private static let capturedAppVersion: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }()

    /// W-CRASHTELEMETRY (this task) — three small scalars captured at crash
    /// time for the `app.crash` telemetry event this task adds, kept in
    /// UserDefaults (like `crashCount` below) rather than in the persisted
    /// TEXT report: the text file's exact shape is locked in by
    /// `flushPendingReport()`'s stdout-tee consumers (symbolicate.py, the
    /// log shipper's fixtures) and this task adds no new required line to
    /// it. `pendingCrashTsKey`/`pendingAppVerKey` capture the CRASHED
    /// build's version and wall-clock time (may differ from the CURRENT
    /// build/time once the app relaunches, possibly after an update);
    /// `pendingThreadKey` records whether the crash happened on the main
    /// thread (`Thread.isMainThread` is a cheap, async-signal-safe read —
    /// no different in risk from the UserDefaults writes this function
    /// already does for `crashCount`).
    private static let pendingAppVerKey = "qaudion.crash.pending_app_ver"
    private static let pendingCrashTsKey = "qaudion.crash.pending_ts_ms"
    private static let pendingThreadKey = "qaudion.crash.pending_thread"

    /// W-CRASHTELEMETRY (this task) — the size-capped `app.crash` attrs
    /// built (by `buildTelemetryAttrs(fromReportText:)`) from the PREVIOUS
    /// launch's crash report, held here from `flushPendingReport()` (which
    /// parses the report text BEFORE deleting the file — its only copy)
    /// until `AppState.initialize()` consumes it via
    /// `consumePendingCrashTelemetry()`. That consumer call sits right after
    /// `TelemetryService.shared.start(...)` deliberately: `TelemetryService
    /// .emit()` silently drops an event until `started` flips true, and
    /// `.onAppear` calls `flushPendingReport()` BEFORE `appState.initialize()`
    /// runs — emitting straight from here would race that ordering and lose
    /// the event on every launch that actually has one.
    private static var pendingCrashTelemetryAttrs: [String: Any]?

    /// Install the handlers. Call as early as possible (App.init) —
    /// before any code that might crash. Does NOT flush; the flush has
    /// to wait until the stdout tee is attached (see `flushPendingReport`).
    static func installHandlers() {
        _ = reportPath  // force the lazy path computation up-front

        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.exceptionInFlight = true
            var report = "=== QAUDION CRASH — NSException ===\n"
            report += "name: " + exception.name.rawValue + "\n"
            report += "reason: " + (exception.reason ?? "(nil)") + "\n"
            report += "stack:\n"
            report += exception.callStackSymbols.joined(separator: "\n")
            CrashReporter.persist(report)
        }

        // Open the crash record and size its buffers NOW, in normal context: the handler below may only copy bytes
        // and call write(2).
        CrashRawCapture.install(reportDirectory: rawDirectory, appVersion: capturedAppVersion)

        let signalHandler: @convention(c) (Int32) -> Void = { sig in
            // Async-signal-safe: no Swift allocation, no UserDefaults, no Foundation. An uncaught NSException aborts
            // via SIGABRT, firing this handler too; `CrashRawCapture.record` skips then, so the exception report (with
            // name + reason) is the one that stays.
            CrashRawCapture.record(sig)
            // Restore the default disposition and re-raise so the OS
            // still records its own crash report and the process dies.
            signal(sig, SIG_DFL)
            raise(sig)
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, signalHandler)
        }
    }

    /// W-NATIVESRTPCRASHGUARD (this task) — peek only: does a crash report
    /// from the PREVIOUS launch exist? Unlike `flushPendingReport()`, this
    /// does NOT print or delete it — it must be callable from
    /// `QAudionApp.init()`, BEFORE the stdout tee is attached (whose
    /// absence is exactly why `flushPendingReport()` has to wait until
    /// `.onAppear`), so the crash-streak check that reads this can run
    /// ahead of any call path per spec section B's ordering requirement.
    static func hasPendingCrashReport() -> Bool {
        if CrashRawCapture.hasPendingRecord(pendingPath: pendingRawPath) { return true }
        guard let data = FileManager.default.contents(atPath: reportPath),
              let text = String(data: data, encoding: .utf8) else { return false }
        return !text.isEmpty
    }

    /// Directory of the signal handler's crash record (a Caches subfolder `FileProtection.prepareAppContainer` gives
    /// the after-first-unlock class), the record being written now, and the one the PREVIOUS launch left.
    fileprivate static let rawDirectory: String = {
        let base = NSSearchPathForDirectoriesInDomains(
            .cachesDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        return (base as NSString).appendingPathComponent("qaudion-crash")
    }()
    fileprivate static var pendingRawPath: String {
        return (rawDirectory as NSString).appendingPathComponent("pending.txt")
    }

    /// Turns the record the signal handler left in the previous launch into log lines and the `app.crash` stash.
    /// Called from `QAudionApp.init()` (so a background relaunch ships it too) and again from
    /// `startServicesBeforeInitialize()`; the second call finds nothing. The record carries addresses and the main
    /// binary's UUID and load address, no symbols: symbolicate offline with the dSYM of that build.
    private static func flushPendingRawReport() {
        let path = pendingRawPath
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        guard let report = RawCrashReport.parse(text) else {
            print("[CrashReporter] ==== CRASH RECORD FROM PREVIOUS LAUNCH (unparsed) ====")
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(80) {
                let out: String = "[CrashReporter] " + String(line)
                print(out)
            }
            print("[CrashReporter] ==== END CRASH REPORT ====")
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        // The call context survives in UserDefaults until `QAudionApp.init()` clears it, which is after this call.
        // The in-memory breadcrumb ring does not survive a crash: the signal handler cannot read it safely.
        let legacy = report.legacyReportText(context: CrashBreadcrumbs.lastCallContext(), breadcrumbs: [])
        let overrides = TelemetryOverrides(
            appVer: report.appVersion,
            crashTsMs: report.timestampSec * 1000,
            thread: report.mainThread ? "main" : "background")
        pendingCrashTelemetryAttrs = buildTelemetryAttrs(fromReportText: legacy, overrides: overrides)
        print("[CrashReporter] ==== CRASH REPORT FROM PREVIOUS LAUNCH ====")
        for line in report.summaryLines() {
            let out: String = "[CrashReporter] " + line
            print(out)
        }
        for line in legacy.split(separator: "\n", omittingEmptySubsequences: false) {
            let out: String = "[CrashReporter] " + String(line)
            print(out)
        }
        print("[CrashReporter] ==== END CRASH REPORT ====")
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "qaudion.crash_count") + 1,
                                  forKey: "qaudion.crash_count")
        try? FileManager.default.removeItem(atPath: path)
    }

    fileprivate struct TelemetryOverrides {
        let appVer: String
        let crashTsMs: Int64
        let thread: String
    }

    /// Print any crash report left by the previous launch so the W417
    /// stdout tee uploads it, then delete the file. MUST be called
    /// AFTER `RuntimeLogSink.attachStdoutTee()` — otherwise the prints
    /// happen before the tee and are never captured.
    static func flushPendingReport() {
        flushPendingRawReport()
        guard let data = FileManager.default.contents(atPath: reportPath),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return }
        // W-CRASHTELEMETRY (this task) — parse+format BEFORE printing/deleting:
        // the text file below is the only copy of this report, and this is
        // the last point that has it. Best-effort: a report this parser
        // doesn't recognize (a future format change) still gets fully
        // flushed to the stdout tee below unaffected; it just yields no
        // `app.crash` telemetry event (`pendingCrashTelemetryAttrs` stays nil).
        pendingCrashTelemetryAttrs = buildTelemetryAttrs(fromReportText: text)
        print("[CrashReporter] ==== CRASH REPORT FROM PREVIOUS LAUNCH ====")
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // CLAUDE.md §13 — build the String before the print call.
            let out: String = "[CrashReporter] " + String(line)
            print(out)
        }
        print("[CrashReporter] ==== END CRASH REPORT ====")
        try? FileManager.default.removeItem(atPath: reportPath)
    }

    /// W-CRASHTELEMETRY (this task) — one-shot consume of the `app.crash`
    /// attrs `flushPendingReport()` built (nil when there was no pending
    /// report, or it could not be parsed). Clears the stash so a second call
    /// in the same process — there is only ever one caller, `AppState
    /// .initialize()`, but SwiftUI's `.onAppear` can in principle re-fire —
    /// never double-emits the same crash.
    static func consumePendingCrashTelemetry() -> [String: Any]? {
        defer { pendingCrashTelemetryAttrs = nil }
        return pendingCrashTelemetryAttrs
    }

    // MARK: - Internals

    /// W-CRASHTELEMETRY (this task) — parses `text` (the just-read, not-yet-
    /// deleted report file) via `CrashReportTextParser`, combines it with the
    /// three scalars `persist()` captured in UserDefaults, and formats the
    /// result through `CrashTelemetryFormatter`. nil when `text` doesn't
    /// match the expected report shape (see that parser's own doc) — the
    /// stdout-tee flush around this call is unaffected either way.
    private static func buildTelemetryAttrs(fromReportText text: String,
                                            overrides: TelemetryOverrides? = nil) -> [String: Any]? {
        guard let parsed = CrashReportTextParser.parse(text) else { return nil }
        // A signal crash carries its own version, time and thread in the raw record (the handler cannot touch
        // UserDefaults); an NSException report still uses the scalars `persist()` stored.
        let appVer = overrides?.appVer
            ?? UserDefaults.standard.string(forKey: pendingAppVerKey) ?? capturedAppVersion
        let crashTsMs = overrides?.crashTsMs
            ?? Int64(UserDefaults.standard.integer(forKey: pendingCrashTsKey))
        let thread = overrides?.thread
            ?? UserDefaults.standard.string(forKey: pendingThreadKey) ?? "unknown"
        // Consumed — a stale value must not leak into a LATER, unrelated
        // report (mirrors `CrashBreadcrumbs.clearCallContext()`'s own
        // "consumed whether or not it triggered anything" rationale).
        UserDefaults.standard.removeObject(forKey: pendingAppVerKey)
        UserDefaults.standard.removeObject(forKey: pendingCrashTsKey)
        UserDefaults.standard.removeObject(forKey: pendingThreadKey)
        let report = CrashTelemetryFormatter.Report(
            crashKind: parsed.crashKind,
            name: parsed.name,
            reason: parsed.reason,
            thread: thread,
            stackLines: parsed.stackLines,
            callContext: parsed.callContext,
            breadcrumbLines: parsed.breadcrumbLines,
            appVer: appVer,
            crashTsMs: crashTsMs
        )
        return CrashTelemetryFormatter.attributes(for: report)
    }

    private static func persist(_ text: String) {
        // W-CRASHCRUMBS (this task) — append the call-context line and the
        // recent-log trail so a crash report answers "was this a
        // native-SRTP call, and what led up to it" without a second
        // reproduction. Same best-effort risk level this function already
        // accepted for `Thread.callStackSymbols` (not strictly
        // async-signal-safe, fine for a logic crash that is not itself
        // inside the allocator) — `lastCallContext()` is a plain
        // `UserDefaults` read (this function already does exactly that,
        // below, for `qaudion.crash_count`) and `snapshotForCrash()` uses
        // `NSLock.try()` so it can never block this handler.
        var full = text
        if let ctx = CrashBreadcrumbs.lastCallContext() {
            full += "\ncontext: " + ctx
        }
        let crumbs = CrashBreadcrumbs.snapshotForCrash()
        if !crumbs.isEmpty {
            full += "\nbreadcrumbs:\n" + crumbs.joined(separator: "\n")
        }
        guard let data = full.data(using: .utf8) else { return }
        // Created with the after-first-unlock class: the default (complete) class would lose the report of a crash
        // that happens while the phone is locked.
        FileManager.default.createFile(
            atPath: reportPath, contents: data,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let crashKey = "qaudion.crash_count"
        let count = UserDefaults.standard.integer(forKey: crashKey) + 1
        UserDefaults.standard.set(count, forKey: crashKey)
        // W-CRASHTELEMETRY (this task) — three scalars the `app.crash`
        // telemetry event needs that the text file above deliberately does
        // NOT carry (see `pendingAppVerKey`'s own doc). Same risk level as
        // the `UserDefaults.set` two lines above; `Thread.isMainThread` and
        // `Date()` are both cheap, allocation-free reads.
        UserDefaults.standard.set(capturedAppVersion, forKey: pendingAppVerKey)
        UserDefaults.standard.set(Int(Date().timeIntervalSince1970 * 1000), forKey: pendingCrashTsKey)
        UserDefaults.standard.set(Thread.isMainThread ? "main" : "background", forKey: pendingThreadKey)
    }

    static var crashCount: Int { UserDefaults.standard.integer(forKey: "qaudion.crash_count") }
    static func resetCrashCount() { UserDefaults.standard.set(0, forKey: "qaudion.crash_count") }
}

/// The signal handler's side of the crash record (format: `RawCrashReport`, QAudionEngine).
///
/// Everything that allocates, formats or touches Foundation happens in `install`, at launch: the file is created with
/// the after-first-unlock class and opened ONCE (a descriptor opened on a "complete"-class file loses its key when the
/// phone locks, which is exactly the lost-report case of 7/11), the fixed first lines are rendered into a buffer, the
/// frame array is allocated, `backtrace` is called once so its lazy set-up is done, and the `__crash_info` sections
/// (the Swift runtime's fatal-error message) are located. `record`, run from the signal handler, only copies bytes
/// into that buffer, calls `backtrace` and `write(2)`. It never calls Swift's allocator, `Thread`, `UserDefaults`,
/// `String` or any Foundation API.
fileprivate enum CrashRawCapture {

    struct State {
        var fd: Int32
        var inHandler: Bool
        var buffer: UnsafeMutablePointer<UInt8>
        var preambleLength: Int
        var frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>
        var crashInfoCount: Int
        var crashInfoSections: UnsafeMutablePointer<UnsafeRawPointer?>
    }

    static let bufferCapacity = 4096
    static let maxFrames = 64
    static let maxCrashInfoSections = 16
    static let maxFatalBytes = 400

    /// Set once at the end of `install`. Plain pointer read in the handler.
    static var state: UnsafeMutablePointer<State>?

    static func hasPendingRecord(pendingPath: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: pendingPath),
              let size = attrs[.size] as? NSNumber else { return false }
        return size.intValue > 0
    }

    // MARK: Launch time

    static func install(reportDirectory: String, appVersion: String) {
        if state != nil { return }
        let fm = FileManager.default
        FileProtection.prepareDirectory(URL(fileURLWithPath: reportDirectory, isDirectory: true))
        let current = (reportDirectory as NSString).appendingPathComponent("current.txt")
        let pending = (reportDirectory as NSString).appendingPathComponent("pending.txt")

        // A record left by the previous launch becomes the pending one (replacing an older pending record that was
        // never flushed); an empty `current.txt` means that launch ended without a crash.
        if let attrs = try? fm.attributesOfItem(atPath: current),
           let size = attrs[.size] as? NSNumber, size.intValue > 0 {
            _ = rename(current, pending)
        }
        // Created empty with the after-first-unlock class BEFORE it is opened, so the descriptor stays writable while
        // the phone is locked.
        fm.createFile(atPath: current, contents: Data(),
                      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let fd = open(current, O_WRONLY | O_TRUNC)
        if fd < 0 { return }

        let image = mainImage()
        let preamble = RawCrashReport.preamble(
            appVersion: appVersion, imageName: image.name, imageUUID: image.uuid,
            loadAddress: image.load, textSize: image.textSize)
        let preambleBytes = Array(preamble.utf8)

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferCapacity)
        buffer.initialize(repeating: 0, count: bufferCapacity)
        let preambleLength = min(preambleBytes.count, bufferCapacity / 2)
        for i in 0..<preambleLength { buffer[i] = preambleBytes[i] }

        let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: maxFrames)
        frames.initialize(repeating: nil, count: maxFrames)
        _ = backtrace(frames, Int32(maxFrames))

        let sections = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: maxCrashInfoSections)
        sections.initialize(repeating: nil, count: maxCrashInfoSections)
        let sectionCount = locateCrashInfoSections(into: sections)

        let st = UnsafeMutablePointer<State>.allocate(capacity: 1)
        st.initialize(to: State(fd: fd, inHandler: false, buffer: buffer, preambleLength: preambleLength,
                                frames: frames, crashInfoCount: sectionCount, crashInfoSections: sections))
        state = st
    }

    struct MainImage {
        var name: String
        var uuid: String
        var load: UInt64
        var textSize: UInt64
    }

    /// Image 0 is the main executable. Name, `LC_UUID`, header address and `__TEXT` size.
    static func mainImage() -> MainImage {
        var info = MainImage(name: "QAudionApp", uuid: "", load: 0, textSize: 0)
        if let exe = Bundle.main.executableURL?.lastPathComponent, !exe.isEmpty { info.name = exe }
        guard _dyld_image_count() > 0, let hdr = _dyld_get_image_header(0) else { return info }
        let mh = UnsafeRawPointer(hdr).assumingMemoryBound(to: mach_header_64.self)
        info.load = UInt64(UInt(bitPattern: hdr))
        var size: UInt = 0
        if getsegmentdata(mh, "__TEXT", &size) != nil { info.textSize = UInt64(size) }
        var cursor = UnsafeRawPointer(mh).advanced(by: MemoryLayout<mach_header_64>.size)
        var remaining = mh.pointee.ncmds
        while remaining > 0 {
            let lc = cursor.load(as: load_command.self)
            if lc.cmd == UInt32(LC_UUID) {
                let uc = cursor.load(as: uuid_command.self)
                info.uuid = UUID(uuid: uc.uuid).uuidString
                break
            }
            if lc.cmdsize == 0 { break }
            cursor = cursor.advanced(by: Int(lc.cmdsize))
            remaining -= 1
        }
        return info
    }

    /// `__DATA,__crash_info` of every loaded image that has one (`crashreporter_annotations_t`: version, then the
    /// `message` and `message2` `char*` fields): the Swift runtime writes its fatal-error text there before it traps.
    /// Images loaded later are not covered. Returns how many were stored.
    static func locateCrashInfoSections(into out: UnsafeMutablePointer<UnsafeRawPointer?>) -> Int {
        var found = 0
        let imageCount = _dyld_image_count()
        var i: UInt32 = 0
        while i < imageCount && found < maxCrashInfoSections {
            defer { i += 1 }
            guard let hdr = _dyld_get_image_header(i) else { continue }
            let mh = UnsafeRawPointer(hdr).assumingMemoryBound(to: mach_header_64.self)
            var size: UInt = 0
            var data = getsectiondata(mh, "__DATA", "__crash_info", &size)
            if data == nil {
                data = getsectiondata(mh, "__DATA_DIRTY", "__crash_info", &size)
            }
            guard let sect = data, size >= 40 else { continue }
            out[found] = UnsafeRawPointer(sect)
            found += 1
        }
        return found
    }

    // MARK: Signal handler (async-signal-safe)

    static func record(_ sig: Int32) {
        guard let st = state else { return }
        if st.pointee.inHandler { return }
        st.pointee.inHandler = true
        // An uncaught NSException aborts through SIGABRT: its own report already holds name and reason.
        if CrashReporter.exceptionInFlight { return }
        let fd = st.pointee.fd
        let buf = st.pointee.buffer
        let cap = bufferCapacity
        var pos = st.pointee.preambleLength

        put("sig=", buf, &pos, cap)
        putDecimal(UInt64(truncatingIfNeeded: Int64(sig)), buf, &pos, cap)
        put("\nts=", buf, &pos, cap)
        putDecimal(UInt64(truncatingIfNeeded: Int64(time(nil))), buf, &pos, cap)
        put("\nmain=", buf, &pos, cap)
        if pthread_main_np() != 0 { put("1", buf, &pos, cap) } else { put("0", buf, &pos, cap) }
        let frames = st.pointee.frames
        var n = Int(backtrace(frames, Int32(maxFrames)))
        if n < 0 { n = 0 }
        if n > maxFrames { n = maxFrames }
        put("\nbt=", buf, &pos, cap)
        putDecimal(UInt64(n), buf, &pos, cap)
        put("\n", buf, &pos, cap)
        var i = 0
        while i < n {
            put("0x", buf, &pos, cap)
            putHex16(UInt64(UInt(bitPattern: frames[i])), buf, &pos, cap)
            put("\n", buf, &pos, cap)
            i += 1
        }
        writeAll(fd, buf, pos)

        // The Swift runtime message is a separate write: reading those pointers is the one step that can fault.
        pos = 0
        put("fatal=", buf, &pos, cap)
        let headerLength = pos
        var section = 0
        while section < st.pointee.crashInfoCount {
            if let base = st.pointee.crashInfoSections[section] {
                let words = base.assumingMemoryBound(to: UInt64.self)
                var which = 0
                while which < 2 {
                    let idx = which == 0 ? 1 : 4
                    which += 1
                    let ptrVal = words[idx]
                    if ptrVal == 0 { continue }
                    guard let text = UnsafePointer<UInt8>(bitPattern: UInt(ptrVal)) else { continue }
                    if pos > headerLength { put(" | ", buf, &pos, cap) }
                    var k = 0
                    while k < maxFatalBytes && pos < cap - 2 {
                        let c = text[k]
                        if c == 0 { break }
                        buf[pos] = (c >= 32 && c < 127) ? c : 63
                        pos += 1
                        k += 1
                    }
                }
            }
            section += 1
        }
        if pos > headerLength {
            put("\n", buf, &pos, cap)
            writeAll(fd, buf, pos)
        }
    }

    @inline(__always)
    static func put(_ s: StaticString, _ buf: UnsafeMutablePointer<UInt8>, _ pos: inout Int, _ cap: Int) {
        let n = s.utf8CodeUnitCount
        if pos + n > cap { return }
        var i = 0
        while i < n {
            buf[pos + i] = s.utf8Start[i]
            i += 1
        }
        pos += n
    }

    static func putDecimal(_ value: UInt64, _ buf: UnsafeMutablePointer<UInt8>, _ pos: inout Int, _ cap: Int) {
        var digits = 1
        var t = value / 10
        while t > 0 {
            digits += 1
            t /= 10
        }
        if pos + digits > cap { return }
        var v = value
        var i = digits
        while i > 0 {
            i -= 1
            buf[pos + i] = UInt8(truncatingIfNeeded: 48 + v % 10)
            v /= 10
        }
        pos += digits
    }

    static func putHex16(_ value: UInt64, _ buf: UnsafeMutablePointer<UInt8>, _ pos: inout Int, _ cap: Int) {
        if pos + 16 > cap { return }
        var i = 0
        while i < 16 {
            let nibble = (value >> UInt64((15 - i) * 4)) & 0xF
            buf[pos + i] = UInt8(truncatingIfNeeded: nibble < 10 ? 48 + nibble : 87 + nibble)
            i += 1
        }
        pos += 16
    }

    static func writeAll(_ fd: Int32, _ buf: UnsafeMutablePointer<UInt8>, _ length: Int) {
        var written = 0
        while written < length {
            let r = write(fd, buf + written, length - written)
            if r <= 0 { return }
            written += r
        }
    }
}
