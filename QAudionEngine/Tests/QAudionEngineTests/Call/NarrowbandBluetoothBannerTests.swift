import XCTest
@testable import QAudionEngine

/// The narrowband Bluetooth notice of the call screens: when it shows (route type and sample rate), how it hides and how
/// it is dismissed, its two log lines, its texts in the String Catalog and the wiring of the three call screens.
///
/// The decisions and the log lines are pure and tested directly. The views, `AppState` and the audio session cannot be
/// driven here, so the texts and the wiring are pinned as source invariants (the same choice `CallMinimizeWiringTests`
/// makes): they fail when someone removes or re-routes a piece. They do not prove the banner looks right on a device.
final class NarrowbandBluetoothBannerTests: XCTestCase {

    private let hfp = NarrowbandBluetoothPolicy.handsFreeInputPort

    // MARK: - the decision: route type + sample rate -> show / hide

    func testHandsFreeAtEightKilohertzIsNarrowband() {
        XCTAssertTrue(NarrowbandBluetoothPolicy.isNarrowbandHandsFree(inputPort: hfp, sampleRateHz: 8000))
    }

    func testHandsFreeBelowEightKilohertzIsNarrowband() {
        XCTAssertTrue(NarrowbandBluetoothPolicy.isNarrowbandHandsFree(inputPort: hfp, sampleRateHz: 7999))
        XCTAssertTrue(NarrowbandBluetoothPolicy.isNarrowbandHandsFree(inputPort: hfp, sampleRateHz: 4000))
    }

    /// The session reports a Double; 8000.4 is the 8 kHz link, 8001 is not.
    func testTheRateIsRoundedToWholeHertz() {
        XCTAssertTrue(NarrowbandBluetoothPolicy.isNarrowbandHandsFree(inputPort: hfp, sampleRateHz: 8000.4))
        XCTAssertFalse(NarrowbandBluetoothPolicy.isNarrowbandHandsFree(inputPort: hfp, sampleRateHz: 8001))
    }

    func testWidebandHandsFreeNeverShows() {
        XCTAssertFalse(NarrowbandBluetoothPolicy.isNarrowbandHandsFree(inputPort: hfp, sampleRateHz: 16000))
        XCTAssertFalse(NarrowbandBluetoothPolicy.isNarrowbandHandsFree(inputPort: hfp, sampleRateHz: 24000))
        XCTAssertFalse(NarrowbandBluetoothPolicy.isNarrowbandHandsFree(inputPort: hfp, sampleRateHz: 48000))
    }

    /// An unknown rate is not a narrowband rate.
    func testAnUnreadableRateNeverShows() {
        for rate in [0.0, -1.0, -8000.0, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertFalse(NarrowbandBluetoothPolicy.isNarrowbandHandsFree(inputPort: hfp, sampleRateHz: rate), "rate \(rate)")
        }
    }

    /// Only a hands-free INPUT counts. The other Bluetooth profiles, the built-in microphone and a missing input are
    /// never narrowband hands-free, whatever the rate.
    func testOnlyAHandsFreeInputCounts() {
        let others: [String?] = [nil, "", "MicrophoneBuiltIn", "BluetoothA2DPOutput", "BluetoothLE", "HeadsetMic",
                                 "CarAudio", "USBAudio", "Receiver", "Speaker", "bluetoothhfp", "BluetoothHFP "]
        for port in others {
            XCTAssertFalse(NarrowbandBluetoothPolicy.isNarrowbandHandsFree(inputPort: port, sampleRateHz: 8000),
                           "port \(String(describing: port))")
        }
    }

    /// The port string is the raw value `noteAudioRoute` reads from the session (the same one the `profile=1` of the
    /// `audioroute` line is derived from), so the banner and the line can never disagree about what hands-free is.
    func testThePortIsTheOneTheRouteLineCallsHandsFree() {
        XCTAssertEqual(hfp, "BluetoothHFP")
        XCTAssertEqual(CallRouteDiagnostics.bluetoothProfile(outputPort: nil, inputPort: hfp), 1)
        XCTAssertEqual(CallRouteDiagnostics.inputCode(hfp), 3)
    }

    // MARK: - the state: settle, hide, show again, dismiss

    private func narrowband(_ state: inout NarrowbandBluetoothBannerState, at now: Double) -> NarrowbandBluetoothBannerState.Change {
        return state.observe(inputPort: hfp, sampleRateHz: 8000, now: now)
    }

    private func builtIn(_ state: inout NarrowbandBluetoothBannerState, at now: Double) -> NarrowbandBluetoothBannerState.Change {
        return state.observe(inputPort: "MicrophoneBuiltIn", sampleRateHz: 48000, now: now)
    }

    func testItStartsHidden() {
        let state = NarrowbandBluetoothBannerState()
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.isDismissed)
    }

    func testItShowsOnlyAfterTheRouteHasHeldForTheSettleTime() {
        var state = NarrowbandBluetoothBannerState()
        XCTAssertEqual(narrowband(&state, at: 100.0), .unchanged)
        XCTAssertFalse(state.isVisible)
        XCTAssertEqual(narrowband(&state, at: 100.5), .unchanged)
        XCTAssertFalse(state.isVisible)
        XCTAssertEqual(narrowband(&state, at: 100.0 + NarrowbandBluetoothBannerState.settleSeconds),
                       .shown(sampleRateHz: 8000, log: true))
        XCTAssertTrue(state.isVisible)
    }

    /// What the watcher schedules its settle look for: the end of the running count, and nothing once there is nothing
    /// left to wait for (broken count, banner up, dismissed).
    func testTheShowDeadlineIsTheEndOfTheRunningCount() {
        var state = NarrowbandBluetoothBannerState()
        XCTAssertNil(state.showDeadline)
        _ = narrowband(&state, at: 100)
        XCTAssertEqual(state.showDeadline, 100 + NarrowbandBluetoothBannerState.settleSeconds)
        _ = narrowband(&state, at: 100.5)
        XCTAssertEqual(state.showDeadline, 101, "later looks do not move it")
        _ = builtIn(&state, at: 100.75)
        XCTAssertNil(state.showDeadline, "the count is broken")
        _ = narrowband(&state, at: 101)
        XCTAssertEqual(state.showDeadline, 102)
        _ = narrowband(&state, at: 102)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.showDeadline, "the banner is up")
        _ = builtIn(&state, at: 103)
        _ = narrowband(&state, at: 104)
        XCTAssertEqual(state.showDeadline, 105)
        _ = state.dismiss()
        XCTAssertNil(state.showDeadline, "dismissed for the call")
        state.reset()
        XCTAssertNil(state.showDeadline)
    }

    /// One `shown` per appearance: a banner that is up reports nothing on the observations that follow (one log line).
    func testItReportsShownOnlyOnce() {
        var state = NarrowbandBluetoothBannerState()
        _ = narrowband(&state, at: 0)
        XCTAssertEqual(narrowband(&state, at: 2), .shown(sampleRateHz: 8000, log: true))
        XCTAssertEqual(narrowband(&state, at: 3), .unchanged)
        XCTAssertEqual(narrowband(&state, at: 4), .unchanged)
        XCTAssertTrue(state.isVisible)
    }

    /// A link that reports 8 kHz for a moment and then settles at 16 kHz must not flash the banner.
    func testAProvisionalRateThatBecomesWidebandNeverShows() {
        var state = NarrowbandBluetoothBannerState()
        XCTAssertEqual(narrowband(&state, at: 0), .unchanged)
        XCTAssertEqual(state.observe(inputPort: hfp, sampleRateHz: 16000, now: 0.4), .unchanged)
        // Narrowband again: the settle time starts over from here.
        XCTAssertEqual(narrowband(&state, at: 0.5), .unchanged)
        XCTAssertEqual(narrowband(&state, at: 1.2), .unchanged)
        XCTAssertFalse(state.isVisible)
        XCTAssertEqual(state.observe(inputPort: hfp, sampleRateHz: 16000, now: 1.3), .unchanged)
        XCTAssertFalse(state.isVisible)
    }

    func testItHidesWhenTheRouteChanges() {
        var state = NarrowbandBluetoothBannerState()
        _ = narrowband(&state, at: 0)
        XCTAssertEqual(narrowband(&state, at: 2), .shown(sampleRateHz: 8000, log: true))
        XCTAssertEqual(builtIn(&state, at: 3), .hidden)
        XCTAssertFalse(state.isVisible)
        // Hidden already: nothing more to report.
        XCTAssertEqual(builtIn(&state, at: 4), .unchanged)
    }

    func testItHidesWhenTheLinkComesUpWideband() {
        var state = NarrowbandBluetoothBannerState()
        _ = narrowband(&state, at: 0)
        _ = narrowband(&state, at: 2)
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.observe(inputPort: hfp, sampleRateHz: 16000, now: 3), .hidden)
        XCTAssertFalse(state.isVisible)
    }

    /// Choosing Bluetooth again later (narrowband again) shows it again: the automatic hide is not a dismissal.
    func testItShowsAgainWhenBluetoothIsChosenAgain() {
        var state = NarrowbandBluetoothBannerState()
        _ = narrowband(&state, at: 0)
        XCTAssertEqual(narrowband(&state, at: 2), .shown(sampleRateHz: 8000, log: true))
        XCTAssertEqual(builtIn(&state, at: 3), .hidden)
        XCTAssertFalse(state.isDismissed)
        XCTAssertEqual(narrowband(&state, at: 10), .unchanged)
        XCTAssertEqual(narrowband(&state, at: 11.5), .shown(sampleRateHz: 8000, log: true))
        XCTAssertTrue(state.isVisible)
    }

    func testDismissHidesItForTheRestOfTheCall() {
        var state = NarrowbandBluetoothBannerState()
        _ = narrowband(&state, at: 0)
        _ = narrowband(&state, at: 2)
        XCTAssertEqual(state.dismiss(), .hidden)
        XCTAssertFalse(state.isVisible)
        XCTAssertTrue(state.isDismissed)
        // Still narrowband: stays away.
        XCTAssertEqual(narrowband(&state, at: 5), .unchanged)
        XCTAssertEqual(narrowband(&state, at: 50), .unchanged)
        // Away from Bluetooth and back: still dismissed for this call.
        XCTAssertEqual(builtIn(&state, at: 60), .unchanged)
        XCTAssertEqual(narrowband(&state, at: 70), .unchanged)
        XCTAssertEqual(narrowband(&state, at: 80), .unchanged)
        XCTAssertFalse(state.isVisible)
    }

    func testDismissBeforeItShowsKeepsItAway() {
        var state = NarrowbandBluetoothBannerState()
        _ = narrowband(&state, at: 0)
        XCTAssertEqual(state.dismiss(), .unchanged)
        XCTAssertEqual(narrowband(&state, at: 5), .unchanged)
        XCTAssertFalse(state.isVisible)
    }

    func testANewCallStartsWithNothingDismissed() {
        var state = NarrowbandBluetoothBannerState()
        _ = narrowband(&state, at: 0)
        _ = narrowband(&state, at: 2)
        _ = state.dismiss()
        state.reset()
        XCTAssertFalse(state.isDismissed)
        XCTAssertFalse(state.isVisible)
        XCTAssertEqual(narrowband(&state, at: 100), .unchanged)
        XCTAssertEqual(narrowband(&state, at: 102), .shown(sampleRateHz: 8000, log: true))
    }

    func testAnUnreadableRateHidesABannerThatIsUp() {
        var state = NarrowbandBluetoothBannerState()
        _ = narrowband(&state, at: 0)
        _ = narrowband(&state, at: 2)
        XCTAssertEqual(state.observe(inputPort: hfp, sampleRateHz: 0, now: 3), .hidden)
    }

    /// An unreadable rate is not narrowband: it breaks the settle count like any other non-narrowband look, so the banner
    /// that follows needs a full settle time of its own.
    func testAnUnreadableRateRestartsTheSettleCount() {
        var state = NarrowbandBluetoothBannerState()
        XCTAssertEqual(narrowband(&state, at: 0), .unchanged)
        XCTAssertEqual(state.observe(inputPort: hfp, sampleRateHz: 0, now: 0.5), .unchanged)
        XCTAssertEqual(narrowband(&state, at: 0.75), .unchanged)
        XCTAssertEqual(narrowband(&state, at: 1.5), .unchanged)
        XCTAssertFalse(state.isVisible)
        XCTAssertEqual(narrowband(&state, at: 1.75), .shown(sampleRateHz: 8000, log: true))
    }

    /// A banner that comes back after a hide waits the full settle time again.
    func testItNeedsTheFullSettleTimeAgainAfterAHide() {
        var state = NarrowbandBluetoothBannerState()
        _ = narrowband(&state, at: 0)
        XCTAssertEqual(narrowband(&state, at: 1), .shown(sampleRateHz: 8000, log: true))
        XCTAssertEqual(builtIn(&state, at: 2), .hidden)
        XCTAssertEqual(narrowband(&state, at: 3), .unchanged)
        XCTAssertEqual(narrowband(&state, at: 3.5), .unchanged)
        XCTAssertEqual(narrowband(&state, at: 4), .shown(sampleRateHz: 8000, log: true))
    }

    /// The `shown` line is written for the first five appearances of a call; the banner keeps following the link after that.
    func testTheShownLineIsCappedPerCall() {
        var state = NarrowbandBluetoothBannerState()
        var clock = 0.0
        var logged = 0
        for round in 0..<(NarrowbandBluetoothBannerState.maxShownLinesPerCall + 3) {
            XCTAssertEqual(narrowband(&state, at: clock), .unchanged, "round \(round)")
            clock += NarrowbandBluetoothBannerState.settleSeconds
            let change = narrowband(&state, at: clock)
            let shouldLog = round < NarrowbandBluetoothBannerState.maxShownLinesPerCall
            XCTAssertEqual(change, .shown(sampleRateHz: 8000, log: shouldLog), "round \(round)")
            if case .shown(_, let writeLine) = change, writeLine { logged += 1 }
            XCTAssertTrue(state.isVisible, "round \(round)")
            clock += 1
            XCTAssertEqual(builtIn(&state, at: clock), .hidden, "round \(round)")
            clock += 1
        }
        XCTAssertEqual(logged, NarrowbandBluetoothBannerState.maxShownLinesPerCall)
        XCTAssertEqual(NarrowbandBluetoothBannerState.maxShownLinesPerCall, 5)
        // A new call gets its lines back.
        state.reset()
        _ = narrowband(&state, at: clock)
        XCTAssertEqual(narrowband(&state, at: clock + 1), .shown(sampleRateHz: 8000, log: true))
    }

    // MARK: - what one call is

    /// A 1:1 call is one call, a group call is another, and the group wins while the hand-over keeps both up: a 1:1 call
    /// promoted to a group is a new call, so its key changes and the banner starts clean.
    func testACallPromotedToAGroupIsANewCall() {
        let oneToOne = NarrowbandBluetoothCallScope.key(oneToOneLive: true, groupCallId: nil)
        let handOver = NarrowbandBluetoothCallScope.key(oneToOneLive: true, groupCallId: "grp-1")
        let groupOnly = NarrowbandBluetoothCallScope.key(oneToOneLive: false, groupCallId: "grp-1")
        XCTAssertEqual(oneToOne, NarrowbandBluetoothCallScope.oneToOne)
        XCTAssertNotNil(handOver)
        XCTAssertNotEqual(oneToOne, handOver)
        XCTAssertEqual(handOver, groupOnly, "the 1:1 leg going away in the hand-over changes nothing")
    }

    func testTwoGroupCallsAreTwoCalls() {
        XCTAssertNotEqual(NarrowbandBluetoothCallScope.key(oneToOneLive: false, groupCallId: "grp-1"),
                          NarrowbandBluetoothCallScope.key(oneToOneLive: false, groupCallId: "grp-2"))
    }

    func testNoCallHasNoKey() {
        XCTAssertNil(NarrowbandBluetoothCallScope.key(oneToOneLive: false, groupCallId: nil))
    }

    func testTheRateOfTheLineIsTheRateThatMadeTheBanner() {
        var state = NarrowbandBluetoothBannerState()
        _ = state.observe(inputPort: hfp, sampleRateHz: 7999.6, now: 0)
        XCTAssertEqual(state.observe(inputPort: hfp, sampleRateHz: 7999.6, now: 2), .shown(sampleRateHz: 8000, log: true))
    }

    // MARK: - the log lines

    func testTheBannerLine() {
        XCTAssertEqual(NarrowbandBluetoothLines.shown(sampleRateHz: 8000), "audioroute nb_banner shown=1 sr=8000")
        XCTAssertEqual(NarrowbandBluetoothLines.shown(sampleRateHz: 4000), "audioroute nb_banner shown=1 sr=4000")
    }

    func testTheSwitchLine() {
        XCTAssertEqual(NarrowbandBluetoothLines.switchTap, "audioroute nb_switch tap=1")
    }

    /// Numbers only after the markers, and every key=value token short enough for the in-app redactor's residual sweep
    /// (20 characters or more of `[A-Za-z0-9+/=_-]` are masked): the same bound `CallMetricsRedactionTests` checks.
    func testTheLinesAreNumericAndShort() throws {
        let lines: [String] = [
            NarrowbandBluetoothLines.shown(sampleRateHz: 8000),
            NarrowbandBluetoothLines.shown(sampleRateHz: 99_999),
            NarrowbandBluetoothLines.switchTap,
        ]
        let numeric = try NSRegularExpression(pattern: "^[a-z_]+=[0-9]+$")
        for line in lines {
            XCTAssertTrue(line.hasPrefix("audioroute nb_"), line)
            for token in line.split(separator: " ") where token.contains("=") {
                XCTAssertLessThanOrEqual(token.count, 19, line)
                let text = String(token)
                let range = NSRange(text.startIndex..., in: text)
                XCTAssertNotNil(numeric.firstMatch(in: text, range: range), "not key=<number>: " + text)
            }
        }
    }

    func testTheShownLineClampsTheRate() {
        XCTAssertEqual(NarrowbandBluetoothLines.shown(sampleRateHz: 5_000_000), "audioroute nb_banner shown=1 sr=99999")
    }

    // MARK: - reading the source

    private struct SourceNotFound: Error, CustomStringConvertible {
        let path: String
        var description: String { "source file not found: \(path)" }
    }

    private func sourceURL(
        _ relativePath: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        XCTFail("\(relativePath) not found from \(file): the source invariants cannot run", file: file, line: line)
        throw SourceNotFound(path: relativePath)
    }

    /// `relativePath` (from the repository root), line comments stripped and every run of whitespace collapsed to one space.
    private func code(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let url = try sourceURL(relativePath, file: file, line: line)
        let raw = try String(contentsOf: url, encoding: .utf8)
        let withoutComments = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let r = line.range(of: "//") { return line[line.startIndex..<r.lowerBound] }
                return line
            }
            .joined(separator: "\n")
        return withoutComments.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - the texts

    private let languages = ["it", "en", "de", "es", "fr", "pt-BR"]
    private let keys = [
        "call.bt_narrowband.message",
        "call.bt_narrowband.use_phone",
        "call.bt_narrowband.use_phone_hint",
        "call.bt_narrowband.dismiss_a11y",
    ]

    private func catalogStrings() throws -> [String: Any] {
        let url = try sourceURL("QAudionApp/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: Any])
    }

    private func value(_ strings: [String: Any], _ key: String, _ language: String) throws -> String {
        let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing key: \(key)")
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
        let one = try XCTUnwrap(localizations[language] as? [String: Any], "missing language \(language) for \(key)")
        let unit = try XCTUnwrap(one["stringUnit"] as? [String: Any], key)
        return try XCTUnwrap(unit["value"] as? String, key)
    }

    /// Every language the catalog ships has every string, translated and not empty, and no string carries a placeholder
    /// (the texts are fixed, nothing is interpolated into them).
    func testEveryStringHasEveryLanguage() throws {
        let strings = try catalogStrings()
        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing key: \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            XCTAssertEqual(Set(localizations.keys), Set(languages), key)
            for language in languages {
                let text = try value(strings, key, language)
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(key) \(language)")
                XCTAssertFalse(text.contains("%"), "\(key) \(language) has a placeholder")
                let one = try XCTUnwrap(localizations[language] as? [String: Any])
                let unit = try XCTUnwrap(one["stringUnit"] as? [String: Any])
                XCTAssertEqual(unit["state"] as? String, "translated", "\(key) \(language)")
            }
        }
    }

    /// The set of languages is the one the whole catalog ships (a language added to the catalog later must be added here
    /// and to the strings above).
    func testTheCatalogShipsNoOtherLanguage() throws {
        let strings = try catalogStrings()
        var seen = Set<String>()
        for (_, raw) in strings {
            guard let entry = raw as? [String: Any], let localizations = entry["localizations"] as? [String: Any] else { continue }
            for language in localizations.keys { seen.insert(language) }
        }
        XCTAssertEqual(seen, Set(languages))
    }

    func testTheItalianAndEnglishTexts() throws {
        let strings = try catalogStrings()
        XCTAssertEqual(try value(strings, "call.bt_narrowband.message", "it"),
                       "Bluetooth a banda stretta: voce di qualità ridotta")
        XCTAssertEqual(try value(strings, "call.bt_narrowband.message", "en"),
                       "Narrowband Bluetooth: reduced voice quality")
        XCTAssertEqual(try value(strings, "call.bt_narrowband.use_phone", "it"), "Usa il telefono")
        XCTAssertEqual(try value(strings, "call.bt_narrowband.use_phone", "en"), "Use phone")
    }

    /// The default value written in the view is the Italian text of the catalog, so a build that cannot read the catalog
    /// still shows the source language.
    func testTheViewDefaultsAreTheItalianTexts() throws {
        let strings = try catalogStrings()
        let source = try code("QAudionApp/Views/Call/NarrowbandBluetoothBanner.swift")
        for key in keys {
            let italian = try value(strings, key, "it")
            let call = "String(localized: \"\(key)\", defaultValue: \"\(italian)\","
            XCTAssertTrue(source.contains(call), "the view does not default \(key) to its Italian text")
        }
    }

    // MARK: - the wiring

    /// The three call screens draw the banner; none draws it twice.
    func testEveryCallScreenDrawsTheBanner() throws {
        for path in ["QAudionApp/Views/Call/LiveInCallScreen.swift",
                     "QAudionApp/Views/VideoCallView.swift",
                     "QAudionApp/Views/GroupCallView.swift"] {
            let source = try code(path)
            XCTAssertEqual(source.components(separatedBy: "NarrowbandBluetoothBanner(").count - 1, 1, path)
        }
    }

    /// The 1:1 audio screen puts it in the layout (a top inset), not over the content.
    func testTheAudioScreenPutsItInATopInset() throws {
        let source = try code("QAudionApp/Views/Call/LiveInCallScreen.swift")
        XCTAssertTrue(source.contains(".safeAreaInset(edge: .top, spacing: 0) { NarrowbandBluetoothBanner() }"))
    }

    /// `AppState` tells the model which call is up (the scope key of the engine: a group call is its own call, so a
    /// promoted 1:1 call starts clean), from the two call-state observers, and gives it "use the phone". The model hands
    /// everything else to the engine's watcher with the real route; the watcher itself is tested behaviourally in
    /// `NarrowbandBluetoothWatcherTests`.
    func testTheAppFeedsTheModelAndTheModelHandsOverToTheWatcher() throws {
        let appState = try code("QAudionApp/AppState.swift")
        XCTAssertTrue(appState.contains("NarrowbandBluetoothCallScope.key(oneToOneLive: oneToOneLive, groupCallId: groupCallId)"))
        XCTAssertTrue(appState.contains("NarrowbandBluetoothBannerModel.shared.setCall(key: key)"))
        XCTAssertGreaterThanOrEqual(appState.components(separatedBy: "updateNarrowbandBluetoothMonitor()").count - 1, 3)
        XCTAssertTrue(appState.contains("NarrowbandBluetoothBannerModel.shared.usePhone ="))

        let model = try code("QAudionApp/Services/NarrowbandBluetoothBannerModel.swift")
        XCTAssertTrue(model.contains("NarrowbandBluetoothWatcher( environment: LiveNarrowbandRouteEnvironment(),"))
        XCTAssertTrue(model.contains("writeLine: { line in RTLog.info(\"call\", line) }"))
        XCTAssertTrue(model.contains("watcher.setCall(key: key)"))
        XCTAssertTrue(model.contains("watcher.dismiss()"))
        XCTAssertTrue(model.contains("watcher.switchToPhone()"))
        XCTAssertTrue(model.contains("self?.isVisible = visible"))

        // The real route: the first input port of the session route and the session sample rate, on the main run loop.
        let live = try code("QAudionApp/Services/NarrowbandRouteEnvironmentLive.swift")
        XCTAssertTrue(live.contains("session.currentRoute.inputs.first?.portType.rawValue"))
        XCTAssertTrue(live.contains("session.sampleRate"))
        XCTAssertTrue(live.contains("AVAudioSession.routeChangeNotification"))
        XCTAssertTrue(live.contains("ProcessInfo.processInfo.systemUptime"))
        XCTAssertTrue(live.contains("RunLoop.main.add(timer, forMode: .common)"))
    }

    /// "Use the phone" ends on the receiver in a 1:1 call (audio or video; the speaker button is turned off first, and the
    /// two call screens follow the app's speaker state) and on the loudspeaker in a group call, as on Android. In both the
    /// output preference is in place before the input moves, and nothing is asserted again later by a timer.
    func testUsePhoneTargetsTheReceiverOnA1To1CallAndTheLoudspeakerOnAGroupCall() throws {
        let appState = try code("QAudionApp/AppState.swift")
        let start = try XCTUnwrap(appState.range(of: "func narrowbandUsePhone() {"))
        let end = try XCTUnwrap(appState.range(of: "private func setGroupLoudspeakerPreference() {", range: start.upperBound..<appState.endIndex))
        let body = String(appState[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("if groupLive { setGroupLoudspeakerPreference() } else if callSpeakerOn { setSpeaker(false) }"))
        XCTAssertTrue(body.contains("BuiltInRouteSwitch.useBuiltInMicAndReceiver()"))
        let preference = try XCTUnwrap(body.range(of: "setGroupLoudspeakerPreference()"))
        let speakerOff = try XCTUnwrap(body.range(of: "setSpeaker(false)"))
        let routeSwitch = try XCTUnwrap(body.range(of: "BuiltInRouteSwitch.useBuiltInMicAndReceiver()"))
        XCTAssertTrue(preference.lowerBound < routeSwitch.lowerBound, "the loudspeaker preference is set before the route moves")
        XCTAssertTrue(speakerOff.lowerBound < routeSwitch.lowerBound, "the speaker button is turned off before the route moves")
        XCTAssertFalse(body.contains("asyncAfter"), "no timed re-assert")
        XCTAssertFalse(appState.contains("reassertGroupLoudspeakerAfterRouteSwitch"))

        // The group preference is the soft loudspeaker (category option, override cleared), whatever the output is now.
        let afterEnd = appState[end.lowerBound...]
        let preferenceEnd = try XCTUnwrap(afterEnd.range(of: "func routeGroupCallAudioToSpeaker() {"))
        let preferenceBody = String(afterEnd[..<preferenceEnd.lowerBound])
        XCTAssertTrue(preferenceBody.contains("NativeAudioSessionGate.applySpeakerRoute(speakerOn: true, hardOverride: false)"))
        XCTAssertTrue(preferenceBody.contains(".defaultToSpeaker"))
        XCTAssertTrue(preferenceBody.contains("try session.overrideOutputAudioPort(.none)"))
        XCTAssertFalse(preferenceBody.contains("builtInReceiver"), "it does not wait for the receiver to be the output")

        let audio = try code("QAudionApp/Views/Call/LiveInCallScreen.swift")
        XCTAssertTrue(audio.contains(".onChange(of: appState.callSpeakerOn) { value in speakerOn = value }"))
        let video = try code("QAudionApp/Views/VideoCallView.swift")
        XCTAssertTrue(video.contains(".onChange(of: appState.callSpeakerOn) { value in isSpeaker = value }"))
    }

    /// "Use the phone" is the two session calls and nothing else: the built-in microphone becomes the preferred input and
    /// the output override is cleared. The category, its options and the mode are not touched.
    func testTheSwitchIsOnlyThePreferredInputAndTheClearedOverride() throws {
        let source = try code("QAudionEngine/Sources/QAudionEngine/Audio/BuiltInRouteSwitch.swift")
        XCTAssertTrue(source.contains("$0.portType == .builtInMic"))
        XCTAssertTrue(source.contains("try session.setPreferredInput(builtInMic)"))
        XCTAssertTrue(source.contains("try session.overrideOutputAudioPort(.none)"))
        XCTAssertFalse(source.contains("setCategory("))
        XCTAssertFalse(source.contains("setActive("))
        XCTAssertFalse(source.contains("overrideOutputAudioPort(.speaker)"))
        // On a manual-audio-mode call the two calls run under RTCAudioSession's configuration lock.
        XCTAssertTrue(source.contains("NativeAudioSessionGate.isArmed"))
        XCTAssertTrue(source.contains("rtcSession.lockForConfiguration()"))
        XCTAssertTrue(source.contains("rtcSession.unlockForConfiguration()"))
    }
}
