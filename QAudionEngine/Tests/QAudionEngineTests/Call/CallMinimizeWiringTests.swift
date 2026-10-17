import XCTest

/// The call reduced to the "call in progress" bar: that the app uses the rules of `CallMinimizePolicy`.
///
/// The rules themselves (when the reduce button shows, which surface is on screen, how the reduced state moves, the length
/// text) are pinned by `CallMinimizePolicyTests` in the app tests. The views, `AppState` and the call cannot be driven
/// here, so this file pins the WIRING as source invariants, the same choice `InCallChatPolicyTests` and
/// `CallerBusyWiringTests` make: comments are stripped and whitespace collapsed before matching, so only code counts. They
/// do not prove the bar looks right or that the call keeps its audio on a device; they fail when someone removes or
/// re-routes the pieces.
final class CallMinimizeWiringTests: XCTestCase {

    // MARK: - reading the source

    /// The source file was not found: the test FAILS (it never skips).
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
        XCTFail("\(relativePath) not found from \(file): the wiring invariants cannot run", file: file, line: line)
        throw SourceNotFound(path: relativePath)
    }

    /// `relativePath` (from the repository root), line comments stripped and every run of whitespace collapsed to one space.
    private func code(
        _ relativePath: String, file callerFile: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let url = try sourceURL(relativePath, file: callerFile, line: line)
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

    /// The text from the first `start` to the next `end` after it. Both markers must exist.
    private func slice(
        _ source: String, from start: String, to end: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let s = try XCTUnwrap(source.range(of: start), "marker not found: \(start)", file: file, line: line)
        let e = try XCTUnwrap(
            source.range(of: end, range: s.upperBound..<source.endIndex),
            "end marker not found after \(start): \(end)", file: file, line: line)
        return String(source[s.lowerBound..<e.lowerBound])
    }

    // MARK: - the app shows the bar through the policy

    /// `inCallScreens` puts the app with the bar in front of the call screens only when the policy says so; the rest of
    /// the chain (the call screens) is the one that was there.
    func testTheContentViewChoosesTheSurfaceThroughThePolicy() throws {
        let content = try code("QAudionApp/Views/ContentView.swift")
        XCTAssertTrue(
            content.contains("if callSurface == .appWithBar { appWithCallBar } else if showLiveCallScreen {"),
            "the bar branch comes first, then the call screens")
        XCTAssertTrue(
            content.contains(
                "CallMinimizePolicy.surface( isInCall: appState.isInCall, minimized: appState.callScreenMinimized, callState: appState.callState)"),
            "the surface follows the call, the reduced flag and the call state")
    }

    /// The bar sits above the app, the app is the ordinary home, and a tap on the bar goes back through the state.
    func testTheBarSitsAboveTheOrdinaryApp() throws {
        let content = try code("QAudionApp/Views/ContentView.swift")
        let layer = try slice(
            content, from: "private var appWithCallBar: some View {", to: "private func onCallBarTapped()")
        let bar = try XCTUnwrap(layer.range(of: "CallInProgressBar("))
        let home = try XCTUnwrap(layer.range(of: "HomeView()"))
        XCTAssertLessThan(bar.lowerBound, home.lowerBound, "the bar is above the app")
        XCTAssertTrue(layer.contains("onReturn: onCallBarTapped"))
        XCTAssertTrue(layer.contains("elapsedSeconds: { appState.callService.callDurationSeconds }"),
                      "the time is the one the call screen shows")
        let tap = try slice(content, from: "private func onCallBarTapped() {", to: "private func callerOutcomeScreen(")
        XCTAssertTrue(tap.contains("appState.returnToCallScreen()"))
        XCTAssertTrue(tap.contains("CallMinimizeAnimation.animation(reduceMotion: reduceMotion)"))
    }

    /// The root keeps what the other call tests rely on: the in-call stack wins over everything and is wrapped in the chat
    /// host. (`InCallChatPolicyTests` and `CallerBusyWiringTests` pin the exact text; this is the short form.)
    func testTheCallStackStillWinsAndKeepsItsChatHost() throws {
        let content = try code("QAudionApp/Views/ContentView.swift")
        XCTAssertTrue(content.contains("if appState.isInCall { inCallStack } else if"))
        XCTAssertTrue(content.contains("private var inCallStack: some View { InCallChatHost { inCallScreens } }"))
    }

    // MARK: - the state

    func testTheReducedStateIsClearedAtTheBoundariesOfACall() throws {
        let app = try code("QAudionApp/AppState.swift")
        let didSet = try slice(app, from: "@Published var isInCall: Bool = false {", to: "@Published var isVideoCall")
        XCTAssertTrue(
            didSet.contains(
                "callScreenMinimized = CallMinimizePolicy.next( minimized: callScreenMinimized, event: .callBoundary, canMinimize: false)"),
            "the isInCall choke point clears it, whichever of the call paths flipped isInCall")
        XCTAssertTrue(app.contains("@Published private(set) var callScreenMinimized: Bool = false"))
    }

    func testReducingAndReturningGoThroughThePolicy() throws {
        let app = try code("QAudionApp/AppState.swift")
        let reduce = try slice(app, from: "func minimizeCallScreen() {", to: "func returnToCallScreen() {")
        XCTAssertTrue(reduce.contains("CallMinimizePolicy.canMinimize("))
        XCTAssertTrue(reduce.contains("event: .reduceTapped, canMinimize: canReduce"))
        let back = try slice(app, from: "func returnToCallScreen() {", to: "private let callResourceLogger")
        XCTAssertTrue(back.contains("event: .barTapped, canMinimize: false"))
    }

    // MARK: - the button

    /// The reduce button is on the audio call screen only, behind the policy, and reduces through the state.
    func testTheReduceButtonIsOnTheAudioCallScreenBehindThePolicy() throws {
        let live = try code("QAudionApp/Views/Call/LiveInCallScreen.swift")
        XCTAssertTrue(live.contains(".overlay(alignment: .topTrailing) { reduceButtonOverlay }"))
        XCTAssertTrue(live.contains("if canReduceCall { MinimizeCallButton(action: reduceCall)"))
        XCTAssertTrue(live.contains("CallMinimizePolicy.canMinimize( callState: appState.callState, isVideoCall: appState.isVideoCall, remoteScreenSharing: appState.peerScreenShareActive)"))
        XCTAssertTrue(live.contains("appState.minimizeCallScreen()"))
        XCTAssertTrue(live.contains("CallMinimizeAnimation.animation(reduceMotion: reduceMotion)"))

        let video = try code("QAudionApp/Views/VideoCallView.swift")
        XCTAssertFalse(video.contains("MinimizeCallButton"), "the video call is not reduced for now")
    }

    // MARK: - the bar is a window onto the call, not a handle on it

    /// No hang-up, mute, speaker, audio session or CallKit in the bar or in the reduce button: it only shows the call and
    /// brings the call screen back.
    func testTheBarDoesNotTouchTheCall() throws {
        let bar = try code("QAudionApp/Views/Call/CallInProgressBar.swift")
        for forbidden in [
            "endCall", "hangup", "Hangup", "setMuted", "setSpeaker", "AVAudioSession", "CallKit", "callService", "AppState",
        ] {
            XCTAssertFalse(bar.contains(forbidden), "the bar must not touch the call: found \(forbidden)")
        }
    }

    /// The whole bar is one button, with the title and the return label from the catalog.
    func testTheBarIsOneButtonWithItsTwoTexts() throws {
        let bar = try code("QAudionApp/Views/Call/CallInProgressBar.swift")
        XCTAssertEqual(bar.components(separatedBy: "Button(action: onReturn)").count - 1, 1)
        XCTAssertTrue(bar.contains("Text(\"Chiamata in corso\")"))
        XCTAssertTrue(bar.contains("Text(\"Torna alla chiamata\")"))
        XCTAssertTrue(bar.contains("Text(\"Riduci la chiamata\")"))
        XCTAssertTrue(bar.contains(".accessibilityAddTraits(.updatesFrequently)"))
    }

    // MARK: - the banner of the home screen

    /// The thin banner of the home screen is still there; its one condition now also asks the policy, so it is hidden
    /// exactly while the bar is on screen (two markers for one call).
    func testTheHomeBannerStaysAndHidesWhileTheBarShows() throws {
        let home = try code("QAudionApp/Views/HomeView.swift")
        XCTAssertTrue(home.contains("private var inCallBanner: some View {"), "the banner is not removed")
        XCTAssertTrue(home.contains("Text(\"Tocca per rientrare\")"))
        XCTAssertTrue(
            home.contains(
                "if CallMinimizePolicy.showsHomeBanner( isInCall: appState.isInCall, coverPresented: presentingInCall, minimized: appState.callScreenMinimized, callState: appState.callState) { inCallBanner }"),
            "one condition, through the policy")
    }

    // MARK: - back to the call

    /// A tap on the bar only clears the reduced state: the call screen is what is left. It does not choose a tab, a chat or
    /// anything else of the app.
    func testTheBarTapOnlyClearsTheReducedState() throws {
        let content = try code("QAudionApp/Views/ContentView.swift")
        let tap = try slice(content, from: "private func onCallBarTapped() {", to: "private func callerOutcomeScreen(")
        XCTAssertTrue(tap.contains("appState.returnToCallScreen()"))
        for forbidden in ["selectedTab", "chatListOpenRequest", "pendingDeepLinkConversationId"] {
            XCTAssertFalse(tap.contains(forbidden), "found \(forbidden)")
        }
    }

    /// A call button tapped while a call is up (every call button goes through `startCall`) brings the call screen back
    /// when the call is reduced, from the branch that refuses the second call.
    func testARefusedStartBringsTheCallScreenBack() throws {
        let app = try code("QAudionApp/AppState.swift")
        let admission = try slice(
            app, from: "func startCall(contactId: String, video: Bool = false) async {",
            to: "guard let engine = ensureCallEngine(reason: \"startCall\")")
        let refusal = try slice(admission, from: "guard !isInCall else {", to: "return }")
        XCTAssertTrue(
            refusal.contains(
                "callScreenMinimized = CallMinimizePolicy.next( minimized: callScreenMinimized, event: .newCallRefused, canMinimize: false)"))
    }

    // MARK: - the security confirmation

    /// The SAS confirmation is not state of the call screen: it is recorded in `SasVerificationStore` (keychain) and the media
    /// hold is released in `AppState`; the screen reads the store again on every tick. So reducing the call, which unmounts
    /// the screen, and coming back loses nothing. No `@State` of either screen is about the SAS.
    func testTheSasConfirmationDoesNotLiveInTheScreen() throws {
        let live = try code("QAudionApp/Views/Call/LiveInCallScreen.swift")
        XCTAssertTrue(live.contains("SasVerificationStore.shared.recordVerified("))
        XCTAssertTrue(live.contains("SasVerificationStore.shared.isVerified("))
        XCTAssertTrue(live.contains("appState.confirmIdentityAndReleaseMedia()"))
        for path in ["QAudionApp/Views/Call/LiveInCallScreen.swift", "QAudionApp/Views/Call/InCallScreen.swift"] {
            let names = try stateVariableNames(in: try code(path))
            XCTAssertFalse(names.isEmpty, "\(path): the scan found no @State at all")
            for name in names {
                XCTAssertFalse(name.lowercased().contains("sas"), "\(path): @State \(name) is about the SAS")
            }
        }
    }

    /// The names of the `@State` variables of a source (comments already stripped, whitespace collapsed).
    private func stateVariableNames(in source: String) throws -> [String] {
        let pattern = try NSRegularExpression(pattern: "@State (?:private )?var ([A-Za-z0-9_]+)")
        let range = NSRange(source.startIndex..., in: source)
        var names: [String] = []
        for match in pattern.matches(in: source, range: range) {
            if match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: source) {
                names.append(String(source[r]))
            }
        }
        return names
    }

    // MARK: - the texts

    /// The three strings are in the catalog, in the source language. (Other languages are added separately.)
    func testTheCatalogHasTheThreeItalianKeys() throws {
        let url = try sourceURL("QAudionApp/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        for key in ["Chiamata in corso", "Torna alla chiamata", "Riduci la chiamata"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing key: \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            let it = try XCTUnwrap(localizations["it"] as? [String: Any], key)
            let unit = try XCTUnwrap(it["stringUnit"] as? [String: Any], key)
            XCTAssertEqual(unit["value"] as? String, key)
        }
    }
}
