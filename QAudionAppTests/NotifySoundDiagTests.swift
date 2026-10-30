import XCTest
import UserNotifications
@testable import QAudionApp

/// The `notifsnd` diagnostics: the words, the line format, the extension's breadcrumb list and that the log redactor
/// leaves the lines as they are.
final class NotifySoundDiagTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let name = "notifsnd.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func crumb(_ step: String = "rewritten", time: Int = 1_730_300_000) -> NotifySoundDiag.Breadcrumb {
        NotifySoundDiag.Breadcrumb(step: step, enabled: true, keyPresent: false, soundId: "system", kindBefore: "default",
                                   kindAfter: "default", muted: false, interruption: "timesens", origSound: true, time: time)
    }

    // MARK: - Words

    func testSoundKindMapping() {
        XCTAssertEqual(NotifySoundDiag.kind(MessageSound.silent), "silent")
        XCTAssertEqual(NotifySoundDiag.kind(MessageSound.systemDefault), "default")
        XCTAssertEqual(NotifySoundDiag.kind(MessageSound.bundled(fileName: "qa_msg_goccia.wav")), "named")
    }

    func testContentSoundKindMapping() {
        XCTAssertEqual(NotifySoundDiag.kind(of: nil), "silent")
        XCTAssertEqual(NotifySoundDiag.kind(of: UNNotificationSound.default), "default")
        let named = UNNotificationSound(named: UNNotificationSoundName(rawValue: MessageAlertSoundFile.fileName))
        XCTAssertEqual(NotifySoundDiag.kind(of: named), "named")
    }

    /// A sound decoded from a push or from an archive is not the default singleton nor the instance the app builds.
    func testContentSoundKindOfNonSingletonSounds() throws {
        func roundTrip(_ sound: UNNotificationSound) throws -> UNNotificationSound {
            let data = try NSKeyedArchiver.archivedData(withRootObject: sound, requiringSecureCoding: true)
            return try XCTUnwrap(try NSKeyedUnarchiver.unarchivedObject(ofClass: UNNotificationSound.self, from: data))
        }
        let named = UNNotificationSound(named: UNNotificationSoundName(rawValue: "qa_msg.wav"))
        let namedCopy = try roundTrip(named)
        XCTAssertFalse(namedCopy === named)
        XCTAssertEqual(NotifySoundDiag.info(of: named).kind, "named")
        XCTAssertEqual(NotifySoundDiag.info(of: named).snd, "qa_msg.wav")
        XCTAssertEqual(NotifySoundDiag.info(of: namedCopy).kind, "named")
        XCTAssertEqual(NotifySoundDiag.info(of: namedCopy).snd, "qa_msg.wav")

        let defaultCopy = try roundTrip(UNNotificationSound.default)
        XCTAssertFalse(defaultCopy === UNNotificationSound.default)
        XCTAssertEqual(NotifySoundDiag.info(of: defaultCopy).kind, "default")
        XCTAssertEqual(NotifySoundDiag.info(of: defaultCopy).snd, "default")
        XCTAssertEqual(NotifySoundDiag.info(of: nil).snd, "none")

        XCTAssertEqual(NotifySoundDiag.soundFileName(in: "<UNNotificationSound: 0x1; name: qa_msg.wav>"), "qa_msg.wav")
        XCTAssertNil(NotifySoundDiag.soundFileName(in: "<UNNotificationSound: 0x1; type: default>"))
    }

    func testSettingWords() {
        XCTAssertEqual(NotifySoundDiag.setting(.enabled), "on")
        XCTAssertEqual(NotifySoundDiag.setting(.disabled), "off")
        XCTAssertEqual(NotifySoundDiag.setting(.notSupported), "na")
        XCTAssertEqual(NotifySoundDiag.authorization(.authorized), "authorized")
        XCTAssertEqual(NotifySoundDiag.alertStyle(.banner), "banner")
        XCTAssertEqual(NotifySoundDiag.interruption(.timeSensitive), "timesens")
    }

    func testAudioNamesAndVolume() {
        XCTAssertEqual(NotifySoundDiag.shortAudioName("AVAudioSessionCategoryPlayAndRecord"), "playandrecord")
        XCTAssertEqual(NotifySoundDiag.shortAudioName("AVAudioSessionModeVoiceChat"), "voicechat")
        XCTAssertEqual(NotifySoundDiag.shortAudioName("AVAudioSessionModeDefault"), "default")
        XCTAssertEqual(NotifySoundDiag.shortAudioName(""), "none")
        XCTAssertEqual(NotifySoundDiag.volumeText(0.44), "0.4")
        XCTAssertEqual(NotifySoundDiag.volumeText(1), "1.0")
        XCTAssertEqual(NotifySoundDiag.volumeText(-1), "-1")
        XCTAssertEqual(NotifySoundDiag.volumeText(.nan), "-1")
    }

    // MARK: - Lines

    func testLineFormat() {
        let line = NotifySoundDiag.line([("path", "local"), ("enabled", "1"), ("keyPresent", "0"), ("kind", "named")])
        XCTAssertEqual(line, "notifsnd path=local enabled=1 keyPresent=0 kind=named")
        XCTAssertEqual(NotifySoundDiag.line(head: "file", [("action", "remove"), ("exists", "0"), ("bytes", "0")]),
                       "notifsnd file action=remove exists=0 bytes=0")
    }

    func testOnlyClosedCharactersEnterALine() {
        let line = NotifySoundDiag.line([("kind", "Anna Rossi <a@b.c> secret=abc"), ("x y", "1")])
        XCTAssertFalse(line.contains(" Rossi"))
        XCTAssertFalse(line.contains("@"))
        XCTAssertFalse(line.contains("<"))
        XCTAssertEqual(NotifySoundDiag.sanitized(String(repeating: "a", count: 80)).count, 24)
        XCTAssertEqual(NotifySoundDiag.line(entry: "path=nse step=x secret: tok@en"), "notifsnd path=nse step=x secret toknen")
    }

    func testBreadcrumbEntryFields() {
        XCTAssertEqual(
            crumb().entry,
            "path=nse step=rewritten t=1730300000 enabled=1 keyPresent=0 soundId=system kindBefore=default "
            + "kindAfter=default muted=0 lvl=timesens origSound=1 sndBefore=none snd=none")
    }

    /// The egress redactor must not flatten any field of any line the diagnostics produce.
    func testLogRedactorLeavesTheLinesAlone() {
        let lines = [
            NotifySoundDiag.line([("path", "local"), ("enabled", "1"), ("keyPresent", "1"), ("legacy", "1"),
                                  ("soundId", "system"), ("kind", "default"), ("quiet", "0"), ("banners", "1"), ("group", "1")]),
            NotifySoundDiag.line([("path", "local"), ("drop", "blocked")]),
            NotifySoundDiag.line([("path", "fg"), ("banner", "1"), ("playKind", "default"), ("plan", "systemSound"),
                                  ("busy", "1"), ("cat", "playandrecord"), ("mode", "voicechat"), ("vol", "0.4"),
                                  ("playOk", "-1"), ("fallback", "0")]),
            NotifySoundDiag.line(head: "settings", [
                ("auth", "authorized"), ("alert", "on"), ("sound", "on"), ("badge", "on"), ("lock", "on"),
                ("center", "on"), ("banner", "banner"), ("timeSens", "on"), ("scheduled", "off"),
                ("critical", "na"), ("directMsg", "on")]),
            NotifySoundDiag.line(head: "file", [("action", "copyBundled"), ("exists", "1"), ("bytes", "88244")]),
            NotifySoundDiag.line(entry: crumb("donateFailed").entry),
        ]
        for line in lines {
            XCTAssertEqual(LogRedactor.redactStructured(line), line, "flattened: \(line)")
            XCTAssertEqual(LogRedactor.redact(line), line, "flattened: \(line)")
        }
    }

    /// Every sound id of the catalog and every audio session name the app can meet survive the redactor.
    func testRedactorOverCatalogIdsAndAudioNames() {
        let ids = [MessageSoundCatalog.systemId] + MessageSoundCatalog.bundledIds
        for id in ids {
            let line = NotifySoundDiag.line([("path", "local"), ("enabled", "1"), ("keyPresent", "1"), ("legacy", "1"),
                                             ("soundId", id), ("kind", "named"), ("quiet", "0"), ("banners", "1"), ("group", "1")])
            XCTAssertEqual(LogRedactor.redactStructured(line), line, "flattened: " + line)
            var c = crumb(); c.soundId = id; c.snd = "qa_msg.wav"; c.sndBefore = "default"
            let entry = NotifySoundDiag.line(entry: c.entry)
            XCTAssertEqual(LogRedactor.redactStructured(entry), entry, "flattened: " + entry)
        }
        let categories = ["AVAudioSessionCategoryAmbient", "AVAudioSessionCategorySoloAmbient", "AVAudioSessionCategoryPlayback",
                          "AVAudioSessionCategoryRecord", "AVAudioSessionCategoryPlayAndRecord", "AVAudioSessionCategoryMultiRoute"]
        let modes = ["AVAudioSessionModeDefault", "AVAudioSessionModeVoiceChat", "AVAudioSessionModeVideoChat",
                     "AVAudioSessionModeGameChat", "AVAudioSessionModeVideoRecording", "AVAudioSessionModeMeasurement",
                     "AVAudioSessionModeMoviePlayback", "AVAudioSessionModeSpokenAudio", "AVAudioSessionModeVoicePrompt"]
        for cat in categories {
            for mode in modes {
                let line = NotifySoundDiag.line([("path", "fg"), ("banner", "1"), ("playKind", "default"), ("plan", "systemSound"),
                                                 ("busy", "1"), ("cat", NotifySoundDiag.shortAudioName(cat)),
                                                 ("mode", NotifySoundDiag.shortAudioName(mode)), ("vol", "0.4"),
                                                 ("playOk", "-1"), ("fallback", "0")])
                XCTAssertEqual(LogRedactor.redactStructured(line), line, "flattened: " + line)
            }
        }
    }

    // MARK: - Breadcrumb list

    func testAppendingKeepsTheNewestTwenty() {
        var list: [String] = []
        for i in 0..<25 { list = NotifySoundDiag.appending("e\(i)", to: list) }
        XCTAssertEqual(list.count, 20)
        XCTAssertEqual(list.first, "e5")
        XCTAssertEqual(list.last, "e24")
        XCTAssertEqual(NotifySoundDiag.appending("b", to: ["a"], cap: 5), ["a", "b"])
        XCTAssertEqual(NotifySoundDiag.appending("c", to: ["a", "b"], cap: 2), ["b", "c"])
    }

    func testRecordPendingAndDiscard() {
        let d = defaults()
        XCTAssertEqual(NotifySoundDiag.pending(defaults: d), [])
        for i in 0..<22 { NotifySoundDiag.record(crumb(time: i), defaults: d) }
        let stored = NotifySoundDiag.pending(defaults: d)
        XCTAssertEqual(stored.count, NotifySoundDiag.breadcrumbCap)
        XCTAssertTrue(stored.first!.contains(" t=2 "))
        XCTAssertTrue(stored.last!.contains(" t=21 "))

        // The app read 20, the extension added one meanwhile: only the read ones go.
        NotifySoundDiag.record(crumb(time: 99), defaults: d)
        NotifySoundDiag.discard(first: NotifySoundDiag.breadcrumbCap, defaults: d)
        let rest = NotifySoundDiag.pending(defaults: d)
        XCTAssertEqual(rest.count, 1)
        XCTAssertTrue(rest[0].contains(" t=99 "))
        NotifySoundDiag.discard(first: 5, defaults: d)
        XCTAssertEqual(NotifySoundDiag.pending(defaults: d), [])
    }

    // MARK: - Sound file and store

    func testFileStateOfMissingAndExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notifsnd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var settings = MessageSoundSettings.default
        XCTAssertEqual(MessageAlertSoundFile.fileState(for: settings, in: dir),
                       MessageAlertSoundFile.FileState(action: "remove", exists: false, bytes: 0))
        settings.soundEnabled = false
        let silence = MessageAlertSoundFile.silentWAV()
        try silence.write(to: dir.appendingPathComponent(MessageAlertSoundFile.fileName))
        XCTAssertEqual(MessageAlertSoundFile.fileState(for: settings, in: dir),
                       MessageAlertSoundFile.FileState(action: "writeSilence", exists: true, bytes: silence.count))
        XCTAssertEqual(MessageAlertSoundFile.fileState(for: settings, in: nil).exists, false)
    }

    func testStoreSnapshotKeyPresence() {
        let d = defaults()
        let store = MessageSoundStore(defaults: d)
        let before = store.snapshot(legacyInAppSound: false)
        XCTAssertFalse(before.keyPresent)
        XCTAssertFalse(before.settings.soundEnabled)
        store.save(.default)
        let after = store.snapshot(legacyInAppSound: false)
        XCTAssertTrue(after.keyPresent)
        XCTAssertTrue(after.settings.soundEnabled)
    }
}
