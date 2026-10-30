import Foundation
import UserNotifications

/// Diagnostics for the sound of message notifications. Pure formatting plus a tiny breadcrumb list in the notify App
/// Group, because the notification extension cannot send logs: it leaves one short entry per alert and the app reads
/// them back at launch and when it returns to the foreground. Every field is a closed word, a flag or a number: no
/// names, ids, texts or tokens. Foundation and UserNotifications only: the extension compiles this file directly.
enum NotifySoundDiag {

    /// Prefix of every line.
    static let prefix = "notifsnd"
    /// Key (in the notify App Group defaults) of the extension's breadcrumbs.
    static let breadcrumbsKey = "qaudion.notifsnd.breadcrumbs"
    /// Most breadcrumbs kept; the oldest go first.
    static let breadcrumbCap = 20

    // MARK: - Words

    /// `silent`, `default` or `named` for a sound the app decided.
    static func kind(_ sound: MessageSound) -> String {
        switch sound {
        case .silent: return "silent"
        case .systemDefault: return "default"
        case .bundled: return "named"
        }
    }

    /// The same words for the sound of a content (nil is silent). `other` when it is none of the sounds the app uses.
    static func kind(of sound: UNNotificationSound?) -> String { info(of: sound).kind }

    /// The kind of a content sound plus a short sanitized form of it (snd: the file name, default, none). A sound
    /// decoded from a push is not the default singleton, so equality alone is not enough: the description is read too.
    static func info(of sound: UNNotificationSound?) -> (kind: String, snd: String) {
        guard let sound else { return ("silent", "none") }
        let text = String(describing: sound) + " " + sound.debugDescription
        let lower = text.lowercased()
        if let name = soundFileName(in: text) { return ("named", sanitized(name)) }
        let fixed = sanitized(MessageAlertSoundFile.fileName)
        if lower.contains("qa_msg") { return ("named", fixed) }
        let named = UNNotificationSound(named: UNNotificationSoundName(rawValue: MessageAlertSoundFile.fileName))
        if sound.isEqual(named) { return ("named", fixed) }
        if sound.isEqual(UNNotificationSound.default) || lower.contains("default") { return ("default", "default") }
        return ("other", sanitized(String(describing: sound).replacingOccurrences(of: "UNNotificationSound", with: "")))
    }

    /// A sound file name (qa_msg.wav) found in a description, if any.
    static func soundFileName(in text: String) -> String? {
        guard let range = text.range(of: "[A-Za-z0-9_-]+\\.(wav|caf|aiff|aif|mp3|m4a)", options: .regularExpression) else { return nil }
        return String(text[range])
    }

    static func flag(_ value: Bool) -> String { value ? "1" : "0" }

    static func setting(_ value: UNNotificationSetting) -> String {
        switch value {
        case .notSupported: return "na"
        case .disabled: return "off"
        case .enabled: return "on"
        @unknown default: return "unk"
        }
    }

    static func authorization(_ value: UNAuthorizationStatus) -> String {
        switch value {
        case .notDetermined: return "undetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unk"
        }
    }

    static func alertStyle(_ value: UNAlertStyle) -> String {
        switch value {
        case .none: return "none"
        case .banner: return "banner"
        case .alert: return "alert"
        @unknown default: return "unk"
        }
    }

    @available(iOS 15.0, *)
    static func interruption(_ value: UNNotificationInterruptionLevel) -> String {
        switch value {
        case .passive: return "passive"
        case .active: return "active"
        case .timeSensitive: return "timesens"
        case .critical: return "critical"
        @unknown default: return "unk"
        }
    }

    /// `AVAudioSessionCategoryPlayAndRecord` -> `playandrecord`.
    static func shortAudioName(_ raw: String) -> String {
        var name = raw
        for prefix in ["AVAudioSessionCategory", "AVAudioSessionMode"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        let short = sanitized(name.lowercased())
        return short.isEmpty ? "none" : short
    }

    /// Volume rounded to one decimal, as text (`0.4`), `-1` when unknown.
    static func volumeText(_ value: Float) -> String {
        guard value.isFinite, value >= 0 else { return "-1" }
        return String(format: "%.1f", (Double(value) * 10).rounded() / 10)
    }

    /// Only letters, digits and `_ . -`, at most 24 characters: nothing else can enter a line.
    static func sanitized(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        return String(text.filter { allowed.contains($0) }.prefix(24))
    }

    // MARK: - Lines

    /// `k1=v1 k2=v2 ...` with sanitized keys and values, in the caller's order.
    static func body(_ fields: [(String, String)]) -> String {
        fields.map { "\(sanitized($0.0))=\(sanitized($0.1))" }.joined(separator: " ")
    }

    /// A stored entry as a log line: the prefix, then the entry with anything but letters, digits, `_ . - =` and spaces removed.
    static func line(entry: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-= ")
        return prefix + " " + String(entry.filter { allowed.contains($0) }.prefix(300))
    }

    /// The whole log message: the prefix, then the fields.
    static func line(_ fields: [(String, String)]) -> String { "\(prefix) \(body(fields))" }

    /// A line that starts with a bare word (`settings`, `file`) before the fields.
    static func line(head: String, _ fields: [(String, String)]) -> String { "\(prefix) \(sanitized(head)) \(body(fields))" }

    // MARK: - Extension breadcrumbs

    /// What the extension did with one alert.
    struct Breadcrumb: Equatable {
        /// `generic`, `rewritten`, `donated`, `donateFailed` or `expired`.
        var step: String
        var enabled: Bool
        var keyPresent: Bool
        var soundId: String
        var kindBefore: String
        var kindAfter: String
        var muted: Bool
        /// `passive`, `active`, `timesens` or `critical`.
        var interruption: String
        var origSound: Bool
        /// Short sanitized form of the sound before and after (qa_msg.wav, default, none).
        var sndBefore: String = "none"
        var snd: String = "none"
        /// Unix time in seconds.
        var time: Int

        /// The fields as the stored entry and the log line carry them.
        var fields: [(String, String)] {
            [("path", "nse"), ("step", step), ("t", String(time)), ("enabled", flag(enabled)),
             ("keyPresent", flag(keyPresent)), ("soundId", soundId), ("kindBefore", kindBefore),
             ("kindAfter", kindAfter), ("muted", flag(muted)), ("lvl", interruption), ("origSound", flag(origSound)),
             ("sndBefore", sndBefore), ("snd", snd)]
        }

        /// The stored form: the fields, without the prefix.
        var entry: String { body(fields) }

        static func == (lhs: Breadcrumb, rhs: Breadcrumb) -> Bool { lhs.entry == rhs.entry }
    }

    /// `list` plus `entry`, keeping the newest `cap` entries.
    static func appending(_ entry: String, to list: [String], cap: Int = breadcrumbCap) -> [String] {
        var result = list
        result.append(entry)
        if result.count > cap { result.removeFirst(result.count - cap) }
        return result
    }

    private static func groupDefaults() -> UserDefaults? { UserDefaults(suiteName: MessageSoundStore.appGroupId) }

    /// Adds a breadcrumb to the group defaults. Synchronous, one read and one write, no lock; never throws.
    static func record(_ crumb: Breadcrumb, defaults: UserDefaults? = nil) {
        guard let defaults = defaults ?? groupDefaults() else { return }
        let list = defaults.stringArray(forKey: breadcrumbsKey) ?? []
        defaults.set(appending(crumb.entry, to: list), forKey: breadcrumbsKey)
    }

    /// The stored entries, oldest first.
    static func pending(defaults: UserDefaults? = nil) -> [String] {
        (defaults ?? groupDefaults())?.stringArray(forKey: breadcrumbsKey) ?? []
    }

    /// Removes the first `count` entries (the ones already read). Best effort: the extension and the app read and write
    /// the list without a lock, so a breadcrumb written at the same moment can be lost. That is fine for diagnostics.
    static func discard(first count: Int, defaults: UserDefaults? = nil) {
        guard let defaults = defaults ?? groupDefaults(), count > 0 else { return }
        let rest = Array((defaults.stringArray(forKey: breadcrumbsKey) ?? []).dropFirst(count))
        if rest.isEmpty { defaults.removeObject(forKey: breadcrumbsKey) } else { defaults.set(rest, forKey: breadcrumbsKey) }
    }
}
