import XCTest
import AVFoundation
import QAudionEngine
import UIKit
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

    func testDefaultStoreLivesInTheNotificationGroup() {
        XCTAssertEqual(MessageSoundStore.appGroupId, "group.com.bcrypto.qaudion.notify")
        let shared = MessageSoundStore.sharedDefaults
        let keys = [MessageSoundStore.keyEnabled, MessageSoundStore.keySoundId, MessageSoundStore.keyHaptic]
        let before = keys.map { shared.object(forKey: $0) }
        addTeardownBlock {
            for (key, value) in zip(keys, before) {
                if let value { shared.set(value, forKey: key) } else { shared.removeObject(forKey: key) }
            }
        }
        MessageSoundStore().save(MessageSoundSettings(soundEnabled: false, soundId: "nota", hapticEnabled: false))
        XCTAssertEqual(MessageSoundStore.current.soundId, "nota")
        XCTAssertFalse(MessageSoundStore.current.hapticEnabled)
        // Nothing is written to the standard domain when the group suite exists (it falls back only when the suite is nil).
        if UserDefaults(suiteName: MessageSoundStore.appGroupId) != nil {
            XCTAssertNil(UserDefaults.standard.object(forKey: MessageSoundStore.keySoundId))
        }
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

    // MARK: - Preview

    func testPreviewPlaysTheChosenFile() {
        let sound = MessageSound.bundled(fileName: "qa_msg_nota.wav")
        XCTAssertEqual(MessageSoundPreviewPolicy.plan(for: sound, inCall: false),
                       .player(.bundled(fileName: "qa_msg_nota.wav")))
    }

    func testPreviewOfTheSystemChoicePlaysTheSystemToneFile() {
        XCTAssertEqual(MessageSoundPreviewPolicy.plan(for: .systemDefault, inCall: false), .player(.systemTone))
    }

    func testPreviewNeverTouchesTheSessionDuringACall() {
        for sound in [MessageSound.systemDefault, .bundled(fileName: "qa_msg_goccia.wav")] {
            XCTAssertEqual(MessageSoundPreviewPolicy.plan(for: sound, inCall: true), .callSafe(sound))
        }
    }

    func testPreviewOfSilenceIsNothing() {
        XCTAssertEqual(MessageSoundPreviewPolicy.plan(for: .silent, inCall: false), .none)
        XCTAssertEqual(MessageSoundPreviewPolicy.plan(for: .silent, inCall: true), .none)
    }

    func testVolumeIsPersistedAndClamped() {
        let store = MessageSoundStore(defaults: freshDefaults())
        XCTAssertEqual(store.load(legacyInAppSound: true).volume, 1.0)
        store.save(MessageSoundSettings(soundEnabled: true, soundId: "nota", hapticEnabled: true, volume: 0.4))
        XCTAssertEqual(store.load(legacyInAppSound: true).volume, 0.4, accuracy: 0.0001)
        store.save(MessageSoundSettings(soundEnabled: true, soundId: "nota", hapticEnabled: true, volume: 7))
        XCTAssertEqual(store.load(legacyInAppSound: true).volume, 1.0)
        XCTAssertEqual(MessageSoundVolume.clamped(-1), 0)
        XCTAssertEqual(MessageSoundVolume.clamped(.nan), 1.0)
    }

    func testPreviewAndInAppSoundUseTheChosenVolume() {
        let s = MessageSoundSettings(soundEnabled: true, soundId: "nota", hapticEnabled: true, volume: 0.3)
        XCTAssertEqual(MessageSoundPreviewPolicy.playerVolume(for: s), 0.3, accuracy: 0.0001)
        let sound = MessageSound.bundled(fileName: "qa_msg_nota.wav")
        XCTAssertEqual(MessageSoundPlayback.plan(for: sound, volume: 0.3, busy: false),
                       .player(.bundled(fileName: "qa_msg_nota.wav"), volume: 0.3))
        XCTAssertEqual(MessageSoundPlayback.plan(for: sound, volume: 0, busy: false), .none)
        XCTAssertEqual(MessageSoundPlayback.plan(for: .silent, volume: 1, busy: false), .none)
    }

    func testInAppMessageSoundNeverTouchesASessionDuringACallOrRing() {
        for sound in [MessageSound.systemDefault, .bundled(fileName: "qa_msg_goccia.wav")] {
            XCTAssertEqual(MessageSoundPlayback.plan(for: sound, volume: 0.5, busy: true), .systemSound)
        }
    }

    @MainActor
    func testRingStartStopsEveryRegisteredPreview() {
        final class Owner {}
        let a = Owner(), b = Owner()
        var stopped = 0
        SoundPreviewCoordinator.register(a) { stopped += 1 }
        SoundPreviewCoordinator.register(b) { stopped += 1 }
        SoundPreviewCoordinator.stopAll()
        XCTAssertEqual(stopped, 2)
        XCTAssertEqual(SoundPreviewCoordinator.activeCount, 0)
        SoundPreviewCoordinator.stopAll()
        XCTAssertEqual(stopped, 2)
    }

    @MainActor
    func testPreviewIsReleasedWhenTheAppResignsActive() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).wav")
        try MessageAlertSoundFile.silentWAV().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = RingPreviewPlayer(inCall: { false })
        player.play(id: "x", url: url, volume: 0.5, minimumVolume: 0)
        try XCTSkipIf(player.playingId == nil, "no audio output in this environment")
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        let released = expectation(description: "released")
        Task { @MainActor in
            while player.playingId != nil { try? await Task.sleep(nanoseconds: 20_000_000) }
            released.fulfill()
        }
        wait(for: [released], timeout: 3)
    }

    @MainActor
    func testPreviewDoesNotStartDuringACall() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).wav")
        try MessageAlertSoundFile.silentWAV().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = RingPreviewPlayer(inCall: { true })
        player.play(id: "x", url: url, volume: 1)
        XCTAssertNil(player.playingId)
        XCTAssertEqual(SoundPreviewCoordinator.activeCount, 0)
    }

    func testOneCallPredicate() {
        // (callOrRingActive, noCallInFlight) -> in flight. A CallKit ring with an idle callState is
        // callOrRingActive == false but noCallInFlight == false: it counts.
        XCTAssertFalse(AppAudioSession.callOrRingInFlight(callOrRingActive: false, noCallInFlight: true))
        XCTAssertTrue(AppAudioSession.callOrRingInFlight(callOrRingActive: false, noCallInFlight: false))
        XCTAssertTrue(AppAudioSession.callOrRingInFlight(callOrRingActive: true, noCallInFlight: true))
        XCTAssertTrue(AppAudioSession.callOrRingInFlight(callOrRingActive: true, noCallInFlight: false))
    }

    func testShortSoundsOnlyTakeAnIdleAudioSession() {
        func idle(_ c: AVAudioSession.Category, _ m: AVAudioSession.Mode, call: Bool = false, audio: Bool = false) -> Bool {
            AppAudioSession.isIdle(category: c, mode: m, callInFlight: call, callAudioActive: audio)
        }
        XCTAssertTrue(idle(.ambient, .default))
        XCTAssertTrue(idle(.soloAmbient, .default))
        // The call category is idle only with no call or ring in flight and no call audio running.
        XCTAssertTrue(idle(.playAndRecord, .voiceChat))
        XCTAssertFalse(idle(.playAndRecord, .voiceChat, call: true))
        XCTAssertFalse(idle(.playAndRecord, .voiceChat, audio: true))
        XCTAssertFalse(idle(.ambient, .default, call: true))
        // Voice note playback, voice note recording, voice unlock.
        XCTAssertFalse(idle(.playback, .spokenAudio))
        XCTAssertFalse(idle(.playAndRecord, .default))
        XCTAssertFalse(idle(.record, .measurement))
    }

    func testSessionIsGivenBackOnlyIfStillOurs() {
        let mine = RingAudioSession.Config(category: .playback, mode: .default, options: [.duckOthers])
        XCTAssertTrue(RingAudioSession.stillOurs(current: mine, applied: mine))
        // iOS may add options of its own; only ducking is compared.
        let withExtra = RingAudioSession.Config(category: .playback, mode: .default, options: [.duckOthers, .mixWithOthers])
        XCTAssertTrue(RingAudioSession.stillOurs(current: withExtra, applied: mine))
        // A voice note took the session.
        let voiceNote = RingAudioSession.Config(category: .playback, mode: .spokenAudio, options: [.duckOthers])
        XCTAssertFalse(RingAudioSession.stillOurs(current: voiceNote, applied: mine))
        // A call took it.
        let call = RingAudioSession.Config(category: .playAndRecord, mode: .voiceChat, options: [])
        XCTAssertFalse(RingAudioSession.stillOurs(current: call, applied: mine))
        XCTAssertFalse(RingAudioSession.stillOurs(current: mine, applied: nil))
    }

    func testEndAfterARingStillDeactivatesWhenWebRTCChangedTheCategory() {
        typealias S = RingAudioSession
        // Ours: deactivate and reset the category.
        XCTAssertEqual(S.endAction(callInFlight: false, callAudioActive: false, stillOurs: true, inCallCategory: false),
                       .deactivateAndReset)
        // Declined or missed ring, WebRTC pre-warm already set play-and-record/voice-chat: music must resume.
        XCTAssertEqual(S.endAction(callInFlight: false, callAudioActive: false, stillOurs: false, inCallCategory: true),
                       .deactivateOnly)
        // A voice note or the voice unlock has the session: untouched.
        XCTAssertEqual(S.endAction(callInFlight: false, callAudioActive: false, stillOurs: false, inCallCategory: false),
                       .none)
        // A call or ring in flight, or call audio running: never touched.
        XCTAssertEqual(S.endAction(callInFlight: true, callAudioActive: false, stillOurs: true, inCallCategory: true), .none)
        XCTAssertEqual(S.endAction(callInFlight: false, callAudioActive: true, stillOurs: false, inCallCategory: true), .none)
        XCTAssertTrue(S.isCallCategory(.init(category: .playAndRecord, mode: .voiceChat, options: [])))
        XCTAssertFalse(S.isCallCategory(.init(category: .playAndRecord, mode: .default, options: [])))
    }

    func testPendingRestoreWaitsForTheCallToEndThenRunsOnce() {
        typealias S = RingAudioSession
        func step(gen: Int = 3, call: Bool, audio: Bool = false, ours: Bool = true, callCat: Bool = false,
                  left: Int = 5) -> S.RestoreStep {
            S.restoreStep(token: 3, currentGeneration: gen, callInFlight: call, callAudioActive: audio,
                          stillOurs: ours, inCallCategory: callCat, attemptsLeft: left)
        }
        // The call is still ringing at +1.5 s: look again.
        XCTAssertEqual(step(call: true), .retry)
        XCTAssertEqual(step(call: false, audio: true), .retry)
        // The ring ended without a call taking audio: restore once (reset if still ours).
        XCTAssertEqual(step(call: false), .run(.deactivateAndReset))
        XCTAssertEqual(step(call: false, ours: false, callCat: true), .run(.deactivateOnly))
        XCTAssertEqual(step(call: false, ours: false, callCat: false), .run(.none))
        // A newer begin owns the session now, or the attempts ran out: drop.
        XCTAssertEqual(step(gen: 4, call: false), .drop)
        XCTAssertEqual(step(call: true, left: 0), .drop)
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
