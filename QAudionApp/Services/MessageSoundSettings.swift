import Foundation
import UserNotifications
import AudioToolbox

/// The sound a chat-message notification makes: on or off, which one, and whether the phone vibrates while the app is
/// open. The call ringtone has its own screen and settings; nothing here touches it.
///
/// iOS only plays, for a notification, a file bundled with the app (or one in `Library/Sounds`) or the system default,
/// so the choices are the default plus a few short sounds shipped in `Resources/MessageSounds`.
enum MessageSoundCatalog {

    /// Id of "the system notification sound" (what a notification plays when it names no file).
    static let systemId = "system"
    /// The bundled sounds, in the order the picker shows them after the system one.
    static let bundledIds: [String] = ["goccia", "nota", "tocco", "doppio", "brezza"]
    /// Sound used until the user chooses.
    static let defaultId = systemId

    static func isKnown(_ id: String) -> Bool { id == systemId || bundledIds.contains(id) }

    /// File name of a bundled sound, as `UNNotificationSound(named:)` wants it.
    static func fileName(forBundledId id: String) -> String { "qa_msg_\(id).wav" }

    /// An unknown stored id (a corrupted value) means the default.
    static func normalized(_ id: String) -> String { isKnown(id) ? id : defaultId }
}

/// The user's choices.
struct MessageSoundSettings: Equatable {
    var soundEnabled: Bool
    var soundId: String
    var hapticEnabled: Bool

    static let `default` = MessageSoundSettings(soundEnabled: true, soundId: MessageSoundCatalog.defaultId, hapticEnabled: true)
}

/// What to play for one message notification.
enum MessageSound: Equatable, Sendable {
    case silent
    case systemDefault
    case bundled(fileName: String)

    /// The value for `UNMutableNotificationContent.sound`. A chosen bundled sound goes by the fixed file the app keeps in
    /// `Library/Sounds` (`MessageAlertSoundFile`), the same one the message push names.
    var notificationSound: UNNotificationSound? {
        switch self {
        case .silent: return nil
        case .systemDefault: return .default
        case .bundled: return UNNotificationSound(named: UNNotificationSoundName(rawValue: MessageAlertSoundFile.fileName))
        }
    }
}

/// Pure decisions, so they are tested without a notification center or an audio device.
enum MessageSoundPolicy {

    /// The sound of a message notification. Quiet hours silence it, like every other sound of the app.
    static func sound(for settings: MessageSoundSettings, quietNow: Bool) -> MessageSound {
        guard settings.soundEnabled, !quietNow else { return .silent }
        let id = MessageSoundCatalog.normalized(settings.soundId)
        if id == MessageSoundCatalog.systemId { return .systemDefault }
        return .bundled(fileName: MessageSoundCatalog.fileName(forBundledId: id))
    }

    /// What the app itself does when a message notification is about to be shown while it is in front: the system must
    /// not play the sound the notification names (it would ignore the choice), so the app plays the chosen one.
    struct Foreground: Equatable, Sendable {
        let sound: MessageSound
        let vibrate: Bool
    }

    /// `masterHaptics` is the app-wide vibration switch (Privacy), which stays in force.
    static func foreground(_ settings: MessageSoundSettings, quietNow: Bool, masterHaptics: Bool) -> Foreground {
        Foreground(sound: sound(for: settings, quietNow: quietNow),
                   vibrate: settings.hapticEnabled && masterHaptics && !quietNow)
    }
}

/// Persistence in `UserDefaults`, in the style of `NotificationsGate`. The values live in the notification App Group so
/// the notification extension reads the same choices.
struct MessageSoundStore {

    /// App Group shared with the notification extension.
    static let appGroupId = "group.com.bcrypto.qaudion.notify"

    /// The group's defaults; `.standard` only when the group is not available (simulator or unsigned test builds).
    static var sharedDefaults: UserDefaults { UserDefaults(suiteName: appGroupId) ?? .standard }

    static let keyEnabled = "qaudion.notifications.message_sound_enabled"
    static let keySoundId = "qaudion.notifications.message_sound_id"
    static let keyHaptic  = "qaudion.notifications.message_haptic_enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = MessageSoundStore.sharedDefaults) { self.defaults = defaults }

    /// The stored choices. Until the user changes the on/off switch it follows the older "Suoni in-app" switch
    /// (`legacyInAppSound`), so someone who had sounds off keeps messages silent.
    func load(legacyInAppSound: Bool) -> MessageSoundSettings {
        let enabled = defaults.object(forKey: Self.keyEnabled) as? Bool ?? legacyInAppSound
        let id = MessageSoundCatalog.normalized(defaults.string(forKey: Self.keySoundId) ?? MessageSoundCatalog.defaultId)
        let haptic = defaults.object(forKey: Self.keyHaptic) as? Bool ?? true
        return MessageSoundSettings(soundEnabled: enabled, soundId: id, hapticEnabled: haptic)
    }

    func save(_ settings: MessageSoundSettings) {
        defaults.set(settings.soundEnabled, forKey: Self.keyEnabled)
        defaults.set(MessageSoundCatalog.normalized(settings.soundId), forKey: Self.keySoundId)
        defaults.set(settings.hapticEnabled, forKey: Self.keyHaptic)
    }

    /// The choices as the notification code reads them.
    static var current: MessageSoundSettings {
        MessageSoundStore().load(legacyInAppSound: NotificationsGate.inAppSoundEnabled)
    }
}

/// Plays a bundled message sound through the system sound service: it follows the ringer switch and the system
/// volume like a notification does, and does not touch the audio session of a call.
@MainActor
final class MessageSoundPlayer {

    static let shared = MessageSoundPlayer()
    private var ids: [String: SystemSoundID] = [:]
    /// "Received message" tone of the system, for the system-default choice.
    private let systemSoundId: SystemSoundID = 1007

    func play(_ sound: MessageSound) {
        switch sound {
        case .silent:
            return
        case .systemDefault:
            AudioServicesPlaySystemSound(systemSoundId)
        case .bundled(let fileName):
            if let id = soundId(for: fileName) { AudioServicesPlaySystemSound(id) }
        }
    }

    /// The vibration of the phone (no sound).
    func vibrate() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }

    private func soundId(for fileName: String) -> SystemSoundID? {
        if let cached = ids[fileName] { return cached }
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        var created: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &created) == kAudioServicesNoError else { return nil }
        ids[fileName] = created
        return created
    }
}

/// The file iOS plays for a remote message alert while the app is closed.
///
/// A push can only name a sound by file name, and iOS looks for it in the app's `Library/Sounds` folder and then in the
/// bundle. The push names one fixed file, `qa_msg.wav`, and the app keeps that file equal to the user's choice: a copy
/// of the chosen bundled sound, no file at all for the system sound (iOS then falls back to its default), or a short
/// silent file when the sound is off.
enum MessageAlertSoundFile {

    /// The one name the message push (and the app's own message banner) refers to.
    static let fileName = "qa_msg.wav"

    /// What the file has to be for a given choice.
    enum Action: Equatable {
        case remove
        case writeSilence
        case copyBundled(fileName: String)
    }

    static func action(for settings: MessageSoundSettings) -> Action {
        switch MessageSoundPolicy.sound(for: settings, quietNow: false) {
        case .silent: return .writeSilence
        case .systemDefault: return .remove
        case .bundled(let name): return .copyBundled(fileName: name)
        }
    }

    /// `<app container>/Library/Sounds`.
    static func soundsDirectory() -> URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    /// A short silent WAV in the format of the bundled sounds (44.1 kHz, mono, 16-bit PCM).
    static func silentWAV(milliseconds: Int = 100) -> Data {
        let sampleRate: UInt32 = 44_100
        let samples = Int(sampleRate) * milliseconds / 1000
        let dataSize = UInt32(samples * 2)
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }

    /// Makes `directory/qa_msg.wav` match `settings`. Safe to repeat: the file is only touched when it differs, and a
    /// replacement is atomic, so a push never finds a half-written file. `bundleURL` finds a bundled sound by file name.
    @discardableResult
    static func sync(_ settings: MessageSoundSettings, in directory: URL, bundleURL: (String) -> URL?) -> Bool {
        let target = directory.appendingPathComponent(fileName)
        let fm = FileManager.default
        switch action(for: settings) {
        case .remove:
            guard fm.fileExists(atPath: target.path) else { return true }
            return (try? fm.removeItem(at: target)) != nil
        case .writeSilence:
            return write(silentWAV(), to: target, in: directory)
        case .copyBundled(let name):
            guard let source = bundleURL(name), let data = try? Data(contentsOf: source) else { return false }
            return write(data, to: target, in: directory)
        }
    }

    private static func write(_ data: Data, to target: URL, in directory: URL) -> Bool {
        if let existing = try? Data(contentsOf: target), existing == data { return true }
        do {
            // The system reads this file when the notification sounds, also with the phone locked: readable after the first unlock.
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    /// Brings the real `Library/Sounds` in line with the stored choices. Call at launch and after every change.
    static func syncCurrent() {
        guard let directory = soundsDirectory() else { return }
        sync(MessageSoundStore.current, in: directory) { name in
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            return Bundle.main.url(forResource: base, withExtension: ext)
        }
    }
}
