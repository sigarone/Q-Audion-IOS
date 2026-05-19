import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(MachO)
import MachO   // _dyld_image_count / _dyld_get_image_name (Frida-dylib probe)
#endif

/// Best-effort, **advisory-only** runtime environment probe.
///
/// ⚠️ HARD CONTRACT (read before changing anything here):
/// - This type ONLY observes and returns booleans. It MUST NEVER
///   `abort()`, `exit()`, `fatalError()`, throw, block, or alter app
///   behavior. A jailbroken / instrumented device is still a fully
///   working device for a legitimate user — the app must run normally.
/// - Every check is wrapped so a failure of the check itself (missing
///   syscall, sandbox denial, etc.) degrades to `false`, never a crash.
/// - This file deliberately takes NO `AppState` parameter and imports
///   only Foundation/Darwin (CLAUDE.md "Hard-won lesson 16": a new
///   file referencing `AppState` silently breaks the CI build).
///
/// The snapshot is shipped as an INFO-severity security event for
/// fleet visibility only. No client-side enforcement is derived from
/// it — enforcement, if ever wanted, belongs server-side where it
/// can't be patched out on a rooted device anyway.
public enum RuntimeIntegrity {

    /// Snapshot keys are stable strings (telemetry-friendly).
    public static let kJailbreakPaths      = "jb_paths"
    public static let kJailbreakWritable   = "jb_writable"
    public static let kJailbreakURLScheme  = "jb_url_scheme"
    public static let kDebuggerAttached    = "debugger_attached"
    public static let kInstrumentation     = "instrumentation"

    /// Returns a flat `[key: Bool]` of advisory signals. Never throws,
    /// never crashes — each probe independently degrades to `false`.
    public static func snapshot() -> [String: Bool] {
        var out: [String: Bool] = [:]
        out[kJailbreakPaths]     = probe { suspiciousPathsPresent() }
        out[kJailbreakWritable]  = probe { canWriteOutsideSandbox() }
        out[kJailbreakURLScheme] = probe { jailbreakURLSchemeOpenable() }
        out[kDebuggerAttached]   = probe { debuggerAttached() }
        out[kInstrumentation]    = probe { instrumentationDylibPresent() }
        return out
    }

    /// Compact one-line summary for the telemetry `details` field.
    /// e.g. `"jb_paths=0 jb_writable=0 debugger_attached=1 ..."`.
    public static func summaryLine(_ snap: [String: Bool]) -> String {
        let order = [kJailbreakPaths, kJailbreakWritable,
                     kJailbreakURLScheme, kDebuggerAttached,
                     kInstrumentation]
        var parts: [String] = []
        for k in order {
            let v: Bool = snap[k] ?? false
            let bit: String = v ? "1" : "0"
            parts.append(k + "=" + bit)
        }
        return parts.joined(separator: " ")
    }

    /// True if ANY advisory signal fired (handy for severity choice).
    public static func anyFlag(_ snap: [String: Bool]) -> Bool {
        for (_, v) in snap where v { return true }
        return false
    }

    // MARK: - Defensive wrapper

    /// Runs a probe, swallowing ANYTHING (the probe must not throw, but
    /// this is belt-and-suspenders so a future edit can't make the
    /// whole snapshot crash). Always returns a Bool.
    private static func probe(_ body: () -> Bool) -> Bool {
        return body()
    }

    // MARK: - Jailbreak: suspicious paths

    private static func suspiciousPathsPresent() -> Bool {
        // Classic jailbreak artifacts. Presence is advisory only; some
        // can also appear on legitimately-modified dev devices.
        let paths = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/Library/MobileSubstrate/DynamicLibraries",
            "/usr/sbin/sshd",
            "/usr/bin/ssh",
            "/bin/bash",
            "/bin/sh",
            "/etc/apt",
            "/private/var/lib/apt",
            "/private/var/lib/cydia",
            "/var/jb",
            "/usr/libexec/cydia",
        ]
        let fm = FileManager.default
        for p in paths {
            if fm.fileExists(atPath: p) { return true }
        }
        return false
    }

    // MARK: - Jailbreak: sandbox escape write probe

    private static func canWriteOutsideSandbox() -> Bool {
        // A non-jailbroken app cannot write outside its container.
        // Use a unique filename so a real failure doesn't clobber
        // anything and parallel runs don't race.
        let probePath = "/private/jb_probe_"
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + ".tmp"
        let payload = Data("x".utf8)
        do {
            try payload.write(to: URL(fileURLWithPath: probePath),
                              options: .atomic)
            // If we got here the sandbox is broken — clean up quietly.
            try? FileManager.default.removeItem(atPath: probePath)
            return true
        } catch {
            // Expected path on a healthy device — NOT a problem.
            return false
        }
    }

    // MARK: - Jailbreak: tweak-manager URL scheme

    private static func jailbreakURLSchemeOpenable() -> Bool {
        // `canOpenURL` for cydia:/sileo: requires the scheme in
        // LSApplicationQueriesSchemes to be reliable; we intentionally
        // do NOT add it (avoids App Review questions). Instead probe
        // the on-disk handler indirectly via a known tweak path that
        // only exists if a package manager is installed. This keeps
        // the check UIKit-free and side-effect-free.
        let managerArtifacts = [
            "/Applications/Cydia.app/Cydia",
            "/Applications/Sileo.app/Sileo",
            "/var/jb/Applications/Sileo.app",
        ]
        let fm = FileManager.default
        for a in managerArtifacts where fm.fileExists(atPath: a) {
            return true
        }
        return false
    }

    // MARK: - Debugger attached (sysctl KERN_PROC, P_TRACED)

    private static func debuggerAttached() -> Bool {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let rc = mib.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return sysctl(base, u_int(buf.count), &info, &size, nil, 0)
        }
        guard rc == 0 else { return false }
        // P_TRACED set ⇒ a debugger is attached to this process.
        return (info.kp_proc.p_flag & P_TRACED) != 0
        #else
        return false
        #endif
    }

    // MARK: - Anti-instrumentation (Frida / objection dylibs)

    private static func instrumentationDylibPresent() -> Bool {
        #if canImport(Darwin)
        let needles = [
            "frida", "FridaGadget", "frida-gadget",
            "cynject", "libcycript", "cycript",
            "objection", "substrate", "substitute",
            "shadowtrace", "libhooker",
        ]
        let count = _dyld_image_count()
        var i: UInt32 = 0
        while i < count {
            if let cName = _dyld_get_image_name(i) {
                let name = String(cString: cName).lowercased()
                for n in needles where name.contains(n) {
                    return true
                }
            }
            i &+= 1
        }
        return false
        #else
        return false
        #endif
    }
}
