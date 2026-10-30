import AVFoundation
import Foundation
import UserNotifications
import QAudionEngine

/// Sends the `notifsnd` diagnostics lines to the runtime log. Only closed words, flags and numbers (see
/// `NotifySoundDiag`): no names, ids, texts or tokens. Reads only; nothing here changes what a notification does.
@MainActor
enum NotifySoundDiagLog {

    private static let tag = "notif"
    private static var lastReport: Date?

    private static func send(_ fields: [(String, String)]) {
        RTLog.info(tag, NotifySoundDiag.line(fields))
    }

    // MARK: - Local banner

    /// A local message banner is about to be scheduled with `sound`.
    static func local(sound: MessageSound) {
        let legacy = NotificationsGate.inAppSoundEnabled
        let snapshot = MessageSoundStore().snapshot(legacyInAppSound: legacy)
        send([("path", "local"),
              ("enabled", NotifySoundDiag.flag(snapshot.settings.soundEnabled)),
              ("keyPresent", NotifySoundDiag.flag(snapshot.keyPresent)),
              ("legacy", NotifySoundDiag.flag(legacy)),
              ("soundId", snapshot.settings.soundId),
              ("kind", NotifySoundDiag.kind(sound)),
              ("quiet", NotifySoundDiag.flag(NotificationsGate.isQuietNow)),
              ("banners", NotifySoundDiag.flag(NotificationsGate.bannersEnabled)),
              ("group", NotifySoundDiag.flag(MessageSoundStore.groupAvailable))])
    }

    /// A local message banner was dropped (`blocked`, `quiet`).
    static func localDrop(_ reason: String) {
        send([("path", "local"), ("drop", reason)])
    }

    // MARK: - In front

    /// A message alert is being presented while the app is in front. `audio` is the state of the audio session before
    /// the app played anything.
    static func foreground(banner: Bool, sound: MessageSound, outcome: MessageSoundPlayback.Outcome?, audio: AudioState) {
        send([("path", "fg"),
              ("banner", NotifySoundDiag.flag(banner)),
              ("playKind", NotifySoundDiag.kind(sound)),
              ("plan", outcome?.plan ?? "none"),
              ("busy", NotifySoundDiag.flag(outcome?.busy ?? false)),
              ("cat", audio.category),
              ("mode", audio.mode),
              ("vol", audio.volume),
              ("playOk", String(outcome?.playOk ?? -1)),
              ("fallback", NotifySoundDiag.flag(outcome?.fallback ?? false))])
    }

    /// A message alert was not presented in front (`blocked`).
    static func foregroundDrop(_ reason: String) {
        send([("path", "fg"), ("drop", reason)])
    }

    struct AudioState {
        let category: String
        let mode: String
        let volume: String
    }

    static func audioState() -> AudioState {
        let session = AVAudioSession.sharedInstance()
        return AudioState(category: NotifySoundDiag.shortAudioName(session.category.rawValue),
                          mode: NotifySoundDiag.shortAudioName(session.mode.rawValue),
                          volume: NotifySoundDiag.volumeText(session.outputVolume))
    }

    private static func logFile(_ state: MessageAlertSoundFile.FileState) {
        RTLog.info(tag, NotifySoundDiag.line(head: "file", [
            ("action", state.action), ("exists", NotifySoundDiag.flag(state.exists)), ("bytes", String(state.bytes))]))
    }

    // MARK: - Launch and return to the foreground

    /// Logs the notification settings of the system, the state of `qa_msg.wav` and the breadcrumbs the extension left.
    /// `file` is the state after a sync the caller just did: that line is always logged. The rest (file looked at,
    /// breadcrumbs, settings) is rate-limited, since launch and the first "active" phase come together.
    static func report(file: MessageAlertSoundFile.FileState? = nil) {
        if let file { logFile(file) }
        if let last = lastReport, Date().timeIntervalSince(last) < 5 { return }
        lastReport = Date()

        if file == nil {
            logFile(MessageAlertSoundFile.fileState(
                for: MessageSoundStore.current, in: MessageAlertSoundFile.soundsDirectory()))
        }

        let crumbs = NotifySoundDiag.pending()
        for crumb in crumbs { RTLog.info(tag, NotifySoundDiag.line(entry: crumb)) }
        NotifySoundDiag.discard(first: crumbs.count)

        Task { @MainActor in
            let s = await UNUserNotificationCenter.current().notificationSettings()
            RTLog.info(tag, NotifySoundDiag.line(head: "settings", [
                ("auth", NotifySoundDiag.authorization(s.authorizationStatus)),
                ("alert", NotifySoundDiag.setting(s.alertSetting)),
                ("sound", NotifySoundDiag.setting(s.soundSetting)),
                ("badge", NotifySoundDiag.setting(s.badgeSetting)),
                ("lock", NotifySoundDiag.setting(s.lockScreenSetting)),
                ("center", NotifySoundDiag.setting(s.notificationCenterSetting)),
                ("banner", NotifySoundDiag.alertStyle(s.alertStyle)),
                ("timeSens", NotifySoundDiag.setting(s.timeSensitiveSetting)),
                ("scheduled", NotifySoundDiag.setting(s.scheduledDeliverySetting)),
                ("critical", NotifySoundDiag.setting(s.criticalAlertSetting)),
                ("directMsg", NotifySoundDiag.setting(s.directMessagesSetting))]))
        }
    }
}
