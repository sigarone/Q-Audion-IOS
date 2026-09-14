import Foundation

/// W-SCREENRECDETECT (2026-09-02) — pure decision logic for whether an
/// active-screen-capture transition (`UIScreen.capturedDidChangeNotification`
/// / `.isCaptured`) is worth a privacy log line.
///
/// Q-Audion already logged a one-shot still screenshot
/// (`UIApplication.userDidTakeScreenshotNotification`, see
/// `QAudionApp.registerScreenshotObserver`) but had no equivalent for an
/// ACTIVE recording session — Control Center screen recording, AirPlay/
/// QuickTime device mirroring, or any other consumer Apple's own `isCaptured`
/// documentation groups under "capture" (audit memory
/// reference_ios_stability_audit_2026_09_01, P2 privacy-overlay item).
/// `isCaptured` is a live, persistent flag, not a one-shot event like the
/// screenshot notification, so the app-layer NotificationCenter handler
/// needs an explicit rule for WHEN a transition is worth a log line — that
/// rule lives here, with no UIKit dependency, so it is pinned by
/// `ScreenCaptureAlertPolicyTests` without a simulator (same discipline as
/// `DatabaseOpenRecoveryPolicy` / `AudioInterruptionRecoveryPolicy`).
///
/// Gated behind the SAME `PrivacyGate.screenshotProtectionEnabled` flag the
/// screenshot handler already uses — no new toggle, no new kill switch: the
/// existing Settings toggle (`PrivacySettingsScreen`) is the off-switch for
/// both, by design.
public enum ScreenCaptureAlertPolicy {
    /// True only on the transition INTO an active capture while protection
    /// is on. A capture ending is not itself a privacy event (there is
    /// nothing left to warn about), and protection being off must stay
    /// silent — the identical contract the screenshot handler's own `guard`
    /// already enforces.
    public static func shouldLog(protectionEnabled: Bool, isCaptured: Bool) -> Bool {
        return protectionEnabled && isCaptured
    }
}
