import XCTest
import UserNotifications
@testable import QAudionApp

/// The choices of the message sound (on/off, which sound, vibration) and how they turn into what a notification plays.
final class MessageSoundSettingsTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "MessageSoundSettingsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Resolution

    func testDefaultSettingsPlayTheSystemSound() {
        XCTAssertEqual(MessageSoundPolicy.sound(for: .default, quietNow: false), .systemDefault)
    }

    func testBundledChoiceResolvesToItsFile() {
        let settings = MessageSoundSettings(soundEnabled: true, soundId: "goccia", hapticEnabled: true)
        XCTAssertEqual(MessageSoundPolicy.sound(for: settings, quietNow: false), .bundled(fileName: "qa_msg_goccia.wav"))
    }

    func testSwitchedOffIsSilent() {
        let settings = MessageSoundSettings(soundEnabled: false, soundId: "nota", hapticEnabled: true)
        XCTAssertEqual(MessageSoundPolicy.sound(for: settings, quietNow: false), .silent)
        XCTAssertNil(MessageSound.silent.notificationSound)
    }

    func testQuietHoursSilenceTheSound() {
        XCTAssertEqual(MessageSoundPolicy.sound(for: .default, quietNow: true), .silent)
    }

    func testUnknownIdFallsBackToTheSystemSound() {
        let settings = MessageSoundSettings(soundEnabled: true, soundId: "does-not-exist", hapticEnabled: true)
        XCTAssertEqual(MessageSoundPolicy.sound(for: settings, quietNow: false), .systemDefault)
        XCTAssertEqual(MessageSoundCatalog.normalized(""), MessageSoundCatalog.systemId)
    }

    func testEveryCatalogIdResolvesToSomethingAudible() {
        for id in [MessageSoundCatalog.systemId] + MessageSoundCatalog.bundledIds {
            let settings = MessageSoundSettings(soundEnabled: true, soundId: id, hapticEnabled: true)
            XCTAssertNotEqual(MessageSoundPolicy.sound(for: settings, quietNow: false), .silent, id)
        }
    }

    func testNotificationSoundForBundledAndSystem() {
        XCTAssertEqual(MessageSound.systemDefault.notificationSound, UNNotificationSound.default)
        XCTAssertNotNil(MessageSound.bundled(fileName: "qa_msg_goccia.wav").notificationSound)
    }

    // MARK: - Foreground

    func testForegroundVibratesOnlyWhenBothSwitchesAreOn() {
        let on = MessageSoundSettings(soundEnabled: true, soundId: "tocco", hapticEnabled: true)
        let off = MessageSoundSettings(soundEnabled: true, soundId: "tocco", hapticEnabled: false)
        XCTAssertTrue(MessageSoundPolicy.foreground(on, quietNow: false, masterHaptics: true).vibrate)
        XCTAssertFalse(MessageSoundPolicy.foreground(on, quietNow: false, masterHaptics: false).vibrate)
        XCTAssertFalse(MessageSoundPolicy.foreground(off, quietNow: false, masterHaptics: true).vibrate)
        XCTAssertFalse(MessageSoundPolicy.foreground(on, quietNow: true, masterHaptics: true).vibrate)
    }

    func testVibrationIsIndependentOfTheSoundSwitch() {
        let soundOff = MessageSoundSettings(soundEnabled: false, soundId: "tocco", hapticEnabled: true)
        let result = MessageSoundPolicy.foreground(soundOff, quietNow: false, masterHaptics: true)
        XCTAssertEqual(result.sound, .silent)
        XCTAssertTrue(result.vibrate)
    }

    // MARK: - Storage

    func testFreshStoreFollowsTheOlderInAppSoundSwitch() {
        let store = MessageSoundStore(defaults: freshDefaults())
        XCTAssertTrue(store.load(legacyInAppSound: true).soundEnabled)
        XCTAssertFalse(store.load(legacyInAppSound: false).soundEnabled)
        XCTAssertTrue(store.load(legacyInAppSound: false).hapticEnabled)
        XCTAssertEqual(store.load(legacyInAppSound: true).soundId, MessageSoundCatalog.systemId)
    }

    func testSavedChoicesWinOverTheOlderSwitch() {
        let store = MessageSoundStore(defaults: freshDefaults())
        store.save(MessageSoundSettings(soundEnabled: true, soundId: "brezza", hapticEnabled: false))
        let loaded = store.load(legacyInAppSound: false)
        XCTAssertEqual(loaded, MessageSoundSettings(soundEnabled: true, soundId: "brezza", hapticEnabled: false))
    }

    func testStoredUnknownIdLoadsAsTheDefault() {
        let defaults = freshDefaults()
        defaults.set("old-sound", forKey: MessageSoundStore.keySoundId)
        XCTAssertEqual(MessageSoundStore(defaults: defaults).load(legacyInAppSound: true).soundId, MessageSoundCatalog.systemId)
    }

    // MARK: - qa_msg.wav in Library/Sounds

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qa-msg-sound-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Fake bundle: every sound is a small file whose bytes name it.
    private func fakeBundle(_ root: URL) -> (String) -> URL? {
        return { name in
            let url = root.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? Data("bundled:\(name)".utf8).write(to: url)
            }
            return url
        }
    }

    func testActionPerChoice() {
        XCTAssertEqual(MessageAlertSoundFile.action(for: .default), .remove)
        XCTAssertEqual(MessageAlertSoundFile.action(for: MessageSoundSettings(soundEnabled: false, soundId: "nota", hapticEnabled: true)), .writeSilence)
        XCTAssertEqual(MessageAlertSoundFile.action(for: MessageSoundSettings(soundEnabled: true, soundId: "nota", hapticEnabled: true)),
                       .copyBundled(fileName: "qa_msg_nota.wav"))
    }

    func testBundledChoiceIsCopiedToTheFixedName() throws {
        let sounds = try tempDir().appendingPathComponent("Sounds")
        let bundle = try tempDir()
        let settings = MessageSoundSettings(soundEnabled: true, soundId: "goccia", hapticEnabled: true)
        XCTAssertTrue(MessageAlertSoundFile.sync(settings, in: sounds, bundleURL: fakeBundle(bundle)))
        let written = try Data(contentsOf: sounds.appendingPathComponent("qa_msg.wav"))
        XCTAssertEqual(written, Data("bundled:qa_msg_goccia.wav".utf8))
    }

    func testChangingTheChoiceReplacesTheFileAndRepeatingIsIdempotent() throws {
        let sounds = try tempDir().appendingPathComponent("Sounds")
        let bundle = try tempDir()
        let lookup = fakeBundle(bundle)
        let target = sounds.appendingPathComponent("qa_msg.wav")
        MessageAlertSoundFile.sync(MessageSoundSettings(soundEnabled: true, soundId: "goccia", hapticEnabled: true), in: sounds, bundleURL: lookup)
        let next = MessageSoundSettings(soundEnabled: true, soundId: "brezza", hapticEnabled: true)
        XCTAssertTrue(MessageAlertSoundFile.sync(next, in: sounds, bundleURL: lookup))
        XCTAssertTrue(MessageAlertSoundFile.sync(next, in: sounds, bundleURL: lookup))
        XCTAssertEqual(try Data(contentsOf: target), Data("bundled:qa_msg_brezza.wav".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sounds.path), ["qa_msg.wav"], "no temporary file is left behind")
    }

    func testSystemSoundRemovesTheFile() throws {
        let sounds = try tempDir().appendingPathComponent("Sounds")
        let lookup = fakeBundle(try tempDir())
        MessageAlertSoundFile.sync(MessageSoundSettings(soundEnabled: true, soundId: "tocco", hapticEnabled: true), in: sounds, bundleURL: lookup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sounds.appendingPathComponent("qa_msg.wav").path))
        XCTAssertTrue(MessageAlertSoundFile.sync(.default, in: sounds, bundleURL: lookup))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sounds.appendingPathComponent("qa_msg.wav").path))
        // Nothing to remove, still fine.
        XCTAssertTrue(MessageAlertSoundFile.sync(.default, in: sounds, bundleURL: lookup))
    }

    func testSoundOffWritesAValidSilentWAV() throws {
        let sounds = try tempDir().appendingPathComponent("Sounds")
        let off = MessageSoundSettings(soundEnabled: false, soundId: "nota", hapticEnabled: true)
        XCTAssertTrue(MessageAlertSoundFile.sync(off, in: sounds, bundleURL: { _ in nil }))
        let data = try Data(contentsOf: sounds.appendingPathComponent("qa_msg.wav"))
        XCTAssertEqual(data, MessageAlertSoundFile.silentWAV())
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(data.count, 44 + 4410 * 2)
        XCTAssertTrue(data.dropFirst(44).allSatisfy { $0 == 0 })
    }

    func testMissingBundledSoundLeavesTheFileAlone() throws {
        let sounds = try tempDir().appendingPathComponent("Sounds")
        let settings = MessageSoundSettings(soundEnabled: true, soundId: "nota", hapticEnabled: true)
        XCTAssertFalse(MessageAlertSoundFile.sync(settings, in: sounds, bundleURL: { _ in nil }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sounds.appendingPathComponent("qa_msg.wav").path))
    }

    func testLocalBannerUsesTheSameFile() {
        XCTAssertNotNil(MessageSound.bundled(fileName: "qa_msg_nota.wav").notificationSound)
        XCTAssertEqual(MessageAlertSoundFile.fileName, "qa_msg.wav")
    }

    // MARK: - Bundle

    func testBundledFilesArePackaged() {
        for id in MessageSoundCatalog.bundledIds {
            let file = MessageSoundCatalog.fileName(forBundledId: id)
            let name = (file as NSString).deletingPathExtension
            let ext = (file as NSString).pathExtension
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: ext), "\(file) is not in the app bundle")
        }
    }
}
