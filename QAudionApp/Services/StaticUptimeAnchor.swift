import Foundation

/// W134 — captures the systemUptime value at module-load so any later
/// caller can compute a stable session-uptime delta.
///
/// `ProcessInfo.systemUptime` is "seconds since the device booted",
/// not since the process launched, so subtracting a snapshot taken at
/// our process start gives us the correct "how long has this app been
/// alive on this run" duration. The anchor is captured the first time
/// any code path references the type — for SettingsScreen that's
/// during view construction, which is plenty early enough.
enum StaticUptimeAnchor {
    /// Snapshot of `ProcessInfo.processInfo.systemUptime` at static
    /// init. Subtract from a current snapshot to get session uptime.
    static let processStartedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
}
