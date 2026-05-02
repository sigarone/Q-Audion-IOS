import Foundation

/// W405 — single source of truth for notification-side gates.
///
/// Before W405, NotificationsSettingsScreen persisted booleans in
/// SettingsStore that no production path read. Banner sounds always
/// played; CallKit ring handled vibration via OS settings; quiet
/// hours had no effect. W405 wires the toggles to UserDefaults keys
/// that NotificationCenterService.scheduleLocal + the in-app banner
/// presentation honor before posting.
public enum NotificationsGate {

    public static let keyBanners       = "qaudion.notifications.banners_enabled"   // already used pre-W405
    public static let keyInAppSound    = "qaudion.notifications.in_app_sound_enabled"
    public static let keyVibration     = "qaudion.notifications.vibration_enabled"
    public static let keyQuietEnabled  = "qaudion.notifications.quiet_hours_enabled"
    public static let keyQuietStartMin = "qaudion.notifications.quiet_hours_start_min"  // minutes since midnight
    public static let keyQuietEndMin   = "qaudion.notifications.quiet_hours_end_min"

    public static var bannersEnabled: Bool { readBool(keyBanners, default: true) }
    public static var inAppSoundEnabled: Bool { readBool(keyInAppSound, default: true) }
    public static var vibrationEnabled: Bool { readBool(keyVibration, default: true) }
    public static var quietHoursEnabled: Bool { readBool(keyQuietEnabled, default: false) }
    public static var quietStartMinutes: Int {
        return UserDefaults.standard.object(forKey: keyQuietStartMin) as? Int ?? (22 * 60)  // 22:00 default
    }
    public static var quietEndMinutes: Int {
        return UserDefaults.standard.object(forKey: keyQuietEndMin) as? Int ?? (8 * 60)     // 08:00 default
    }

    /// True when the current local time falls inside the user's
    /// configured quiet-hours window. Handles wrap-around midnight.
    public static var isQuietNow: Bool {
        guard quietHoursEnabled else { return false }
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: Date())
        let nowMin = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let s = quietStartMinutes
        let e = quietEndMinutes
        if s == e { return false }
        if s < e { return nowMin >= s && nowMin < e }
        // Wrap-around: e.g. 22:00 → 08:00 next day
        return nowMin >= s || nowMin < e
    }

    public static func setInAppSound(_ value: Bool) { UserDefaults.standard.set(value, forKey: keyInAppSound) }
    public static func setVibration(_ value: Bool)  { UserDefaults.standard.set(value, forKey: keyVibration) }
    public static func setQuietHoursEnabled(_ value: Bool) { UserDefaults.standard.set(value, forKey: keyQuietEnabled) }
    public static func setQuietStart(minutes: Int) { UserDefaults.standard.set(minutes, forKey: keyQuietStartMin) }
    public static func setQuietEnd(minutes: Int)   { UserDefaults.standard.set(minutes, forKey: keyQuietEndMin) }

    private static func readBool(_ key: String, default fallback: Bool) -> Bool {
        if let raw = UserDefaults.standard.object(forKey: key) as? Bool { return raw }
        return fallback
    }
}
