import XCTest
#if canImport(AVFoundation)
import AVFoundation
#endif
@testable import QAudionEngine

/// Call sounds: the settings and their defaults, the ringtone id to file mapping and its fallbacks, which cues play
/// for which settings, the excerpt and the fallback of the imported ringtone, and (where AVFoundation is there) the
/// conversion itself.
final class CallSoundsTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "callsounds-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - settings

    func testDefaults() {
        let s = CallSoundSettings.defaults
        XCTAssertEqual(s.ringVolume, 1)
        XCTAssertEqual(s.inCallVolume, 1)
        XCTAssertTrue(s.connectionSoundEnabled)
        XCTAssertTrue(s.endSoundsEnabled)
        XCTAssertTrue(s.ringHapticsEnabled)
        XCTAssertNil(s.customFileName)
        XCTAssertNil(s.customDisplayName)
        XCTAssertEqual(s.customStartSeconds, 0)
    }

    func testAFreshStoreHasTheDefaultsAndTheDefaultRingtone() {
        let store = SettingsStore(defaults: freshDefaults())
        XCTAssertEqual(store.loadCallSounds(), CallSoundSettings.defaults)
        let resolution = CallSoundCatalog.resolve(ringtoneId: store.loadNotifications().ringtoneId, customAvailable: false)
        XCTAssertEqual(resolution.effectiveId, "qaudion-default")
        XCTAssertEqual(resolution.callKitFileName, "qaudion_ringtone.caf")
        XCTAssertEqual(resolution.bundledLoopResource, "qaudion_ringtone_unit")
        XCTAssertFalse(resolution.usedFallback, "the stored default is not a failure")
    }

    func testStoreRoundTrip() {
        let store = SettingsStore(defaults: freshDefaults())
        let saved = CallSoundSettings(ringVolume: 0.4, inCallVolume: 0.7, connectionSoundEnabled: false, endSoundsEnabled: false,
                                      ringHapticsEnabled: false, customFileName: "qa_custom_ring.caf",
                                      customDisplayName: "Song", customStartSeconds: 42)
        store.saveCallSounds(saved)
        XCTAssertEqual(store.loadCallSounds(), saved)
    }

    func testVolumesAreClamped() {
        let s = CallSoundSettings(ringVolume: 3, inCallVolume: -1)
        XCTAssertEqual(s.ringVolume, 1)
        XCTAssertEqual(s.inCallVolume, 0)
        XCTAssertEqual(CallSoundSettings(ringVolume: .nan).ringVolume, 1)
    }

    func testAStoredBlobWithMissingFieldsKeepsTheDefaultsForThem() throws {
        let json = Data(#"{"ringVolume":0.25}"#.utf8)
        let s = try JSONDecoder().decode(CallSoundSettings.self, from: json)
        XCTAssertEqual(s.ringVolume, 0.25)
        XCTAssertEqual(s.inCallVolume, 1)
        XCTAssertTrue(s.connectionSoundEnabled)
        XCTAssertTrue(s.endSoundsEnabled)
        XCTAssertTrue(s.ringHapticsEnabled)
    }

    func testResetAllClearsTheCallSounds() {
        let store = SettingsStore(defaults: freshDefaults())
        store.saveCallSounds(CallSoundSettings(ringVolume: 0.1))
        store.resetAll()
        XCTAssertEqual(store.loadCallSounds(), CallSoundSettings.defaults)
    }

    // MARK: - ringtone id to file

    func testEveryBundledIdMapsToItsFiles() {
        XCTAssertEqual(CallSoundCatalog.ringtoneIds, ["vetro", "impulso", "arpeggio", "calore", "digitale", "legno", "duetto"])
        for id in CallSoundCatalog.ringtoneIds {
            let r = CallSoundCatalog.resolve(ringtoneId: id, customAvailable: false)
            XCTAssertEqual(r.effectiveId, id)
            XCTAssertEqual(r.callKitFileName, "qa_ring_\(id).caf")
            XCTAssertEqual(r.bundledLoopResource, "qa_loop_\(id)")
            XCTAssertNil(r.fallbackReason)
            XCTAssertFalse(r.isCustom)
        }
    }

    func testTheDefaultIsTodaysRingtoneForTheStoredDefaultAndForAnEmptyId() {
        for stored in ["qaudion-default", ""] {
            let r = CallSoundCatalog.resolve(ringtoneId: stored, customAvailable: false)
            XCTAssertEqual(r.effectiveId, CallSoundCatalog.defaultRingtoneId)
            XCTAssertEqual(r.callKitFileName, "qaudion_ringtone.caf")
            XCTAssertEqual(r.bundledLoopResource, "qaudion_ringtone_unit")
            XCTAssertNil(r.fallbackReason)
        }
        XCTAssertFalse(CallSoundCatalog.ringtoneIds.contains(CallSoundCatalog.defaultRingtoneId))
    }

    func testAnUnknownIdFallsBackToTheDefault() {
        let r = CallSoundCatalog.resolve(ringtoneId: "nope", customAvailable: true)
        XCTAssertEqual(r.effectiveId, "qaudion-default")
        XCTAssertEqual(r.callKitFileName, "qaudion_ringtone.caf")
        XCTAssertEqual(r.fallbackReason, .unknownId)
    }

    func testCustomResolvesToTheImportedFileOnlyWhenItIsThere() {
        let there = CallSoundCatalog.resolve(ringtoneId: "custom", customAvailable: true)
        XCTAssertTrue(there.isCustom)
        XCTAssertEqual(there.callKitFileName, CallSoundCatalog.customFileName)
        XCTAssertNil(there.bundledLoopResource)
        XCTAssertNil(there.fallbackReason)

        let gone = CallSoundCatalog.resolve(ringtoneId: "custom", customAvailable: false)
        XCTAssertEqual(gone.effectiveId, "qaudion-default")
        XCTAssertEqual(gone.callKitFileName, "qaudion_ringtone.caf")
        XCTAssertEqual(gone.fallbackReason, .customMissing)
        XCTAssertTrue(gone.usedFallback)
    }

    func testTheCallKitRingtoneNamesAreCafFilesCallKitCanFind() {
        for id in CallSoundCatalog.ringtoneIds {
            XCTAssertTrue(CallSoundCatalog.callKitFileName(forBundledId: id).hasSuffix(".caf"))
        }
        XCTAssertTrue(CallSoundCatalog.defaultCallKitFileName.hasSuffix(".caf"))
        XCTAssertTrue(CallSoundCatalog.customFileName.hasSuffix(".caf"))
    }

    // MARK: - cue gating

    func testWithTheDefaultsEveryCueIsAudible() {
        for kind in CallCueKind.allCases {
            XCTAssertTrue(CallCueGate.shouldPlay(kind, settings: .defaults), "\(kind)")
            XCTAssertEqual(CallCueGate.gain(kind, settings: .defaults), 1)
        }
    }

    func testTheConnectionSwitchGatesTheStartTickTheConnectingLoopTheKeyExchangeAndTheConnectedChime() {
        let s = CallSoundSettings(connectionSoundEnabled: false)
        for kind in [CallCueKind.dialingTick, .connecting, .keyExchange, .connected] {
            XCTAssertFalse(CallCueGate.shouldPlay(kind, settings: s), "\(kind)")
            XCTAssertEqual(CallCueGate.gain(kind, settings: s), 0)
        }
        for kind in [CallCueKind.ringback, .ended, .busy] {
            XCTAssertTrue(CallCueGate.shouldPlay(kind, settings: s), "\(kind)")
        }
    }

    func testTheEndSwitchGatesTheEndedChimeAndTheBusyTone() {
        let s = CallSoundSettings(endSoundsEnabled: false)
        XCTAssertFalse(CallCueGate.shouldPlay(.ended, settings: s))
        XCTAssertFalse(CallCueGate.shouldPlay(.busy, settings: s))
        for kind in [CallCueKind.dialingTick, .connecting, .ringback, .keyExchange, .connected] {
            XCTAssertTrue(CallCueGate.shouldPlay(kind, settings: s), "\(kind)")
        }
    }

    func testTheInLineVolumeIsTheGainAndZeroIsSilent() {
        let half = CallSoundSettings(inCallVolume: 0.5)
        XCTAssertEqual(CallCueGate.gain(.ringback, settings: half), 0.5)
        XCTAssertEqual(CallCueGate.gain(.ended, settings: half), 0.5)
        let silent = CallSoundSettings(inCallVolume: 0)
        for kind in CallCueKind.allCases { XCTAssertFalse(CallCueGate.shouldPlay(kind, settings: silent), "\(kind)") }
    }

    func testTheRingbackIsNeverSwitchedOffByTheSwitches() {
        let s = CallSoundSettings(connectionSoundEnabled: false, endSoundsEnabled: false)
        XCTAssertTrue(CallCueGate.isEnabled(.ringback, settings: s))
    }

    func testEveryCueNamesADistinctBundledFileAndOnlyTheSetupCuesLoop() {
        let names = Set(CallCueKind.allCases.map { $0.resourceName })
        XCTAssertEqual(names.count, CallCueKind.allCases.count)
        XCTAssertEqual(Set(CallCueKind.allCases.filter { $0.loops }), [.connecting, .ringback, .keyExchange])
    }

    #if canImport(AVFoundation)
    func testThePlayerCuesMapToTheKinds() {
        typealias Cue = QAudionRingtonePlayer.Cue
        XCTAssertEqual(Cue.outgoingRing.kind, .connecting)
        XCTAssertEqual(Cue.confirmedRingback.kind, .ringback)
        XCTAssertEqual(Cue.keyExchange.kind, .keyExchange)
        XCTAssertEqual(Cue.callConnected.kind, .connected)
        XCTAssertEqual(Cue.callEnded.kind, .ended)
        XCTAssertEqual(Cue.busy.kind, .busy)
        XCTAssertEqual(Cue.dialingTick.kind, .dialingTick)
    }

    /// A switched-off cue is not started and says so; a missing file is a logged failure, never a crash.
    func testThePlayerSkipsADisabledCueAndLogsAMissingFile() {
        let player = QAudionRingtonePlayer()
        var lines: [(String, Bool)] = []
        player.log = { lines.append(($0, $1)) }

        player.settingsProvider = { CallSoundSettings(connectionSoundEnabled: false) }
        XCTAssertFalse(player.play(.callConnected))
        XCTAssertTrue(lines.contains { $0.0.contains("skip") && $0.0.contains("connected") && !$0.1 })

        lines.removeAll()
        player.settingsProvider = { .defaults }
        player.resourceURL = { _ in nil }
        XCTAssertFalse(player.loop(.confirmedRingback))
        XCTAssertTrue(lines.contains { $0.0.contains("fail") && $0.0.contains("missing_file") && $0.1 })
        player.stop()
    }
    #endif

    // MARK: - bundled files

    private func repoRoot(file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("QAudionApp/Resources/CallSounds").path) { return dir }
        }
        throw XCTSkip("repository root not found")
    }

    /// Every file the catalog names is in the app's resources, and listed in project.yml.
    func testEveryNamedFileIsBundledAndListedInTheProjectSpec() throws {
        let root = try repoRoot()
        let dir = root.appendingPathComponent("QAudionApp/Resources/CallSounds")
        let spec = try String(contentsOf: root.appendingPathComponent("QAudionApp/project.yml"), encoding: .utf8)
        var files: [String] = []
        let legacy = root.appendingPathComponent("QAudionApp/Resources")
        for old in [CallSoundCatalog.defaultCallKitFileName, CallSoundCatalog.defaultLoopResourceName + ".caf"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent(old).path), old)
            XCTAssertTrue(spec.contains("Resources/\(old)"), "\(old) is not in project.yml")
        }
        for id in CallSoundCatalog.ringtoneIds {
            files.append(CallSoundCatalog.callKitFileName(forBundledId: id))
            files.append(CallSoundCatalog.loopResourceName(forBundledId: id) + ".caf")
        }
        files += CallCueKind.allCases.map { $0.resourceName + ".caf" }
        for file in files {
            let url = dir.appendingPathComponent(file)
            let attributes: [FileAttributeKey: Any] = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let size: Int = (attributes[.size] as? Int) ?? 0
            XCTAssertGreaterThan(size, 0, "\(file) is missing or empty")
            XCTAssertTrue(spec.contains("Resources/CallSounds/\(file)"), "\(file) is not in project.yml")
        }
    }

    // MARK: - imported ringtone: excerpt

    func testAShortFileIsUsedWhole() {
        XCTAssertEqual(CustomRingtone.maxStart(sourceSeconds: 12), 0)
        XCTAssertEqual(CustomRingtone.excerpt(sourceSeconds: 12, requestedStart: 5), CustomRingtone.Excerpt(start: 0, duration: 12))
    }

    func testALongFileIsCutToThirtySecondsAndTheStartIsClamped() {
        XCTAssertEqual(CustomRingtone.maxStart(sourceSeconds: 200), 170)
        XCTAssertEqual(CustomRingtone.excerpt(sourceSeconds: 200, requestedStart: 40), CustomRingtone.Excerpt(start: 40, duration: 30))
        XCTAssertEqual(CustomRingtone.excerpt(sourceSeconds: 200, requestedStart: 500), CustomRingtone.Excerpt(start: 170, duration: 30))
        XCTAssertEqual(CustomRingtone.excerpt(sourceSeconds: 200, requestedStart: -4), CustomRingtone.Excerpt(start: 0, duration: 30))
        XCTAssertEqual(CustomRingtone.excerpt(sourceSeconds: 200, requestedStart: .nan).start, 0)
    }

    func testAnEmptySourceHasNoExcerpt() {
        XCTAssertEqual(CustomRingtone.excerpt(sourceSeconds: 0, requestedStart: 0).duration, 0)
        XCTAssertEqual(CustomRingtone.excerpt(sourceSeconds: .infinity, requestedStart: 0).duration, 0)
    }

    // MARK: - imported ringtone: fallback

    func testASuccessfulImportSelectsTheImportedFile() {
        let file = CustomRingtone.ImportedFile(displayName: "Song", startSeconds: 12)
        let sel = CustomRingtone.applyImport(.success(file), settings: .defaults, ringtoneId: "legno")
        XCTAssertEqual(sel.ringtoneId, "custom")
        XCTAssertEqual(sel.settings.customFileName, CallSoundCatalog.customFileName)
        XCTAssertEqual(sel.settings.customDisplayName, "Song")
        XCTAssertEqual(sel.settings.customStartSeconds, 12)
        XCTAssertNil(sel.notice)
    }

    func testAFailedImportFallsBackToTheDefaultWithANoteAndForgetsTheFile() {
        let before = CallSoundSettings(ringVolume: 0.3, customFileName: "qa_custom_ring.caf", customDisplayName: "Old", customStartSeconds: 9)
        for error in [CustomRingtone.ImportError.unreadable, .tooShort, .writeFailed] {
            let sel = CustomRingtone.applyImport(.failure(error), settings: before, ringtoneId: "custom")
            XCTAssertEqual(sel.ringtoneId, "qaudion-default")
            XCTAssertEqual(sel.notice, .conversionFailed)
            XCTAssertNil(sel.settings.customFileName)
            XCTAssertNil(sel.settings.customDisplayName)
            XCTAssertEqual(sel.settings.customStartSeconds, 0)
            XCTAssertEqual(sel.settings.ringVolume, 0.3, "the other settings are untouched")
        }
    }

    func testAFailedImportKeepsThePreviousWorkingRingtone() {
        let before = CallSoundSettings(customFileName: "qa_custom_ring.caf", customDisplayName: "Old", customStartSeconds: 9)
        let sel = CustomRingtone.applyImport(.failure(.unreadable), settings: before, ringtoneId: "custom", previousCustomUsable: true)
        XCTAssertEqual(sel.ringtoneId, "custom")
        XCTAssertEqual(sel.settings, before)
        XCTAssertEqual(sel.notice, .keptPrevious)

        let other = CustomRingtone.applyImport(.failure(.tooLarge), settings: before, ringtoneId: "legno", previousCustomUsable: true)
        XCTAssertEqual(other.ringtoneId, "legno", "the choice that was in force stays")
        XCTAssertEqual(other.settings.customFileName, "qa_custom_ring.caf")

        let none = CustomRingtone.applyImport(.failure(.unreadable), settings: before, ringtoneId: "custom", previousCustomUsable: false)
        XCTAssertEqual(none.ringtoneId, "qaudion-default")
        XCTAssertNil(none.settings.customFileName)
    }

    func testTheSourceSizeIsCapped() {
        XCTAssertFalse(CustomRingtone.sourceSizeAllowed(0))
        XCTAssertTrue(CustomRingtone.sourceSizeAllowed(5_000_000))
        XCTAssertTrue(CustomRingtone.sourceSizeAllowed(200 * 1024 * 1024))
        XCTAssertFalse(CustomRingtone.sourceSizeAllowed(200 * 1024 * 1024 + 1))
    }

    func testAProtectedFileHasItsOwnNote() {
        let sel = CustomRingtone.applyImport(.failure(.protectedContent), settings: .defaults, ringtoneId: "duetto")
        XCTAssertEqual(sel.ringtoneId, "qaudion-default")
        XCTAssertEqual(sel.notice, .protectedContent)
    }

    func testAMissingImportedFileIsReconciledToTheDefaultOnce() {
        let stored = CallSoundSettings(customFileName: "qa_custom_ring.caf", customDisplayName: "Song")
        let gone = CustomRingtone.reconcile(ringtoneId: "custom", settings: stored, customFileExists: false)
        XCTAssertEqual(gone.ringtoneId, "qaudion-default")
        XCTAssertEqual(gone.notice, .customUnavailable)
        XCTAssertNil(gone.settings.customFileName)

        let there = CustomRingtone.reconcile(ringtoneId: "custom", settings: stored, customFileExists: true)
        XCTAssertEqual(there.ringtoneId, "custom")
        XCTAssertNil(there.notice)

        let other = CustomRingtone.reconcile(ringtoneId: "legno", settings: stored, customFileExists: false)
        XCTAssertEqual(other.ringtoneId, "legno")
        XCTAssertNil(other.notice)
    }

    // MARK: - imported ringtone: conversion

    #if canImport(AVFoundation)
    private func writeTestTone(seconds: Double, sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(file.processingFormat.channelCount) {
            let data = try XCTUnwrap(buffer.floatChannelData?[channel])
            for i in 0..<Int(frames) { data[i] = 0.4 * sinf(Float(i) * 2 * .pi * 440 / Float(sampleRate)) }
        }
        try file.write(from: buffer)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("callsounds-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A file shorter than 30 s is used whole: a start offset has nothing to skip (the excerpt is clamped to
    /// `maxStart`, which is 0 here), so the output is the full 2 s.
    func testAShortStereoFileIsConvertedWholeToAMonoCaf() async throws {
        let dir = try tempDir()
        let source = dir.appendingPathComponent("tone.wav")
        try writeTestTone(seconds: 2, sampleRate: 44_100, to: source)
        let dest = dir.appendingPathComponent("Sounds/out.caf")

        let seconds = try await CustomRingtoneConverter.convert(source: source, startSeconds: 0.5, destination: dest)
        XCTAssertEqual(seconds, 2.0, accuracy: 0.1)
        let out = try AVAudioFile(forReading: dest)
        XCTAssertEqual(out.processingFormat.channelCount, 1)
        XCTAssertEqual(out.processingFormat.sampleRate, CustomRingtoneConverter.outputSampleRate)
        XCTAssertEqual(Double(out.length) / out.processingFormat.sampleRate, 2.0, accuracy: 0.1)
    }

    /// Just over the limit: the start offset applies (here 0.5 s of 31 s) and the output is exactly 30 s, never more.
    func testTheStartOffsetOfAFileJustOverTheLimitIsHonoredAndTheOutputIsThirtySeconds() async throws {
        let dir = try tempDir()
        let source = dir.appendingPathComponent("tone31.wav")
        try writeTestTone(seconds: 31, sampleRate: 8_000, to: source)
        let dest = dir.appendingPathComponent("out.caf")

        let seconds = try await CustomRingtoneConverter.convert(source: source, startSeconds: 0.5, destination: dest)
        XCTAssertEqual(seconds, 30, accuracy: 0.1)
        let out = try AVAudioFile(forReading: dest)
        XCTAssertLessThanOrEqual(Double(out.length) / out.processingFormat.sampleRate, 30.001)
    }

    func testALongFileIsCutToThirtySeconds() async throws {
        let dir = try tempDir()
        let source = dir.appendingPathComponent("long.wav")
        try writeTestTone(seconds: 45, sampleRate: 8_000, to: source)
        let dest = dir.appendingPathComponent("out.caf")

        let duration = try await CustomRingtoneConverter.sourceDuration(of: source)
        XCTAssertEqual(duration, 45, accuracy: 0.1)
        let seconds = try await CustomRingtoneConverter.convert(source: source, startSeconds: 10, destination: dest)
        XCTAssertEqual(seconds, 30, accuracy: 0.1)
        XCTAssertLessThanOrEqual(seconds, CallSoundCatalog.maxRingtoneSeconds + 0.001)
    }

    /// Not audio: the conversion fails with `unreadable`, leaves no file behind, and the fallback selects the default.
    func testAFileThatIsNotAudioFailsAndFallsBackToTheDefault() async throws {
        let dir = try tempDir()
        let source = dir.appendingPathComponent("fake.mp3")
        try Data("this is not audio".utf8).write(to: source)
        let dest = dir.appendingPathComponent("out.caf")

        var failure: CustomRingtone.ImportError?
        do {
            _ = try await CustomRingtoneConverter.convert(source: source, startSeconds: 0, destination: dest)
            XCTFail("a text file must not convert")
        } catch {
            failure = error as? CustomRingtone.ImportError
        }
        XCTAssertEqual(failure, .unreadable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))

        let sel = CustomRingtone.applyImport(.failure(try XCTUnwrap(failure)), settings: .defaults, ringtoneId: "custom")
        XCTAssertEqual(sel.ringtoneId, "qaudion-default")
        XCTAssertEqual(sel.notice, .conversionFailed)
    }

    func testAFailedConversionKeepsThePreviousImportedFile() async throws {
        let dir = try tempDir()
        let dest = dir.appendingPathComponent("out.caf")
        try Data("previous".utf8).write(to: dest)
        let source = dir.appendingPathComponent("fake.wav")
        try Data("junk".utf8).write(to: source)
        do {
            _ = try await CustomRingtoneConverter.convert(source: source, startSeconds: 0, destination: dest)
            XCTFail("junk must not convert")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: dest), Data("previous".utf8))
    }
    #endif

    // MARK: - app wiring (source invariants)

    private func appSource(_ path: String, file: StaticString = #filePath) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try String(contentsOf: candidate, encoding: .utf8)
                return raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
        }
        throw XCTSkip("\(path) not found")
    }

    func testEveryAcceptPathStopsTheRingAtTheTopOfPerformAcceptIncoming() throws {
        let code = try appSource("QAudionApp/AppState.swift")
        XCTAssertTrue(code.contains("if self.refuseStaleAnswer(uuid: uuid) { return false } stopInAppRingtone()"),
                      "every accepted call stops the in-app ring right after the stale-answer check")
    }

    func testTheSessionFlagIsClearedAtTeardownAndTheEndedChimeIsOnlyForConnectedOrRungCalls() throws {
        let code = try appSource("QAudionApp/AppState.swift")
        XCTAssertTrue(code.contains("if playsEndedCue { playCallCue(.callEnded) }"))
        XCTAssertGreaterThanOrEqual(code.components(separatedBy: "outgoingAudioSessionReady = false").count - 1, 2,
                                    "cleared at the start of a call and again at teardown")
        XCTAssertTrue(code.contains("case .active, .encrypted: return true case .ringing: return originalCallRole == .caller"),
                      "declining an incoming call plays no ended chime")
    }

    func testTheRingDoesNotTouchTheSessionInACallAndHonorsTheMasterHapticsSwitch() throws {
        let ring = try appSource("QAudionApp/Services/CallRingPlayback.swift")
        XCTAssertTrue(ring.contains("if inCall() { playSingleChime() return }"))
        XCTAssertTrue(ring.contains("settings.ringHapticsEnabled && HapticFeedback.masterEnabled"))
        XCTAssertTrue(ring.contains("guard !inCall() else {"), "the preview refuses to play during a call")
        XCTAssertFalse(ring.contains("session.category"), "a call is decided from the app state, not from the session category")
    }
}
