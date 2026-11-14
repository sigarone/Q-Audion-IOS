import XCTest
import AVFoundation
@testable import QAudionApp

/// The call dock: a compact card with the available secondary controls on top and microphone, audio, video and the red end
/// button below, the same on every call screen. These tests pin the controls of each row in every call state (never an
/// empty cell), that the card is only as tall as its rows, and that the controls taken out of the screens stay out.
final class CallControlDockTests: XCTestCase {

    private let style = CallDockStyle(scheme: .dark, extras: .dark)

    // MARK: - Order of the cells

    func testOneToOneDockHasChatShareAddOverMuteAudioVideoEnd() {
        let rows = CallDockLayout.rows(mode: .oneToOne, available: [.chat, .share, .add, .mute, .audio, .video, .end])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], [.chat, .share, .add])
        XCTAssertEqual(rows[1], [.mute, .audio, .video, .end])
    }

    func testBudsJoinTheTopRowOnlyWhenTheyAreConnected() {
        let withBuds = CallDockLayout.rows(mode: .oneToOne, available: [.chat, .share, .add, .buds])
        XCTAssertEqual(withBuds[0], [.chat, .share, .add, .buds])
        let without = CallDockLayout.rows(mode: .oneToOne, available: [.chat, .share, .add])
        XCTAssertEqual(without[0], [.chat, .share, .add])
    }

    func testGroupDockHasChatShareHandReaction() {
        let rows = CallDockLayout.rows(mode: .group, available: [.chat, .share, .hand, .reaction])
        XCTAssertEqual(rows[0], [.chat, .share, .hand, .reaction])
        XCTAssertEqual(rows[1], [.mute, .audio, .video, .end])
    }

    func testAControlThatIsNotAvailableIsLeftOutAndTheOthersShareTheRow() {
        // Screen sharing is not offered on an iOS group call: the other three controls are the top row.
        let rows = CallDockLayout.rows(mode: .group, available: [.chat, .hand, .reaction])
        XCTAssertEqual(rows[0], [.chat, .hand, .reaction])
        // A 1:1 call without the chat host.
        let oneToOne = CallDockLayout.rows(mode: .oneToOne, available: [.share, .add])
        XCTAssertEqual(oneToOne[0], [.share, .add])
    }

    func testTheTopRowIsExactlyTheAvailableControlsInEveryCombination() {
        let candidates: [CallControlKind] = [.chat, .share, .add, .buds, .hand, .reaction]
        for mode in [CallDockMode.oneToOne, .group] {
            let wanted: [CallControlKind] = mode == .oneToOne ? [.chat, .share, .add, .buds] : [.chat, .share, .hand, .reaction]
            for mask in 0..<(1 << candidates.count) {
                var available: Set<CallControlKind> = [.mute, .audio, .video, .end]
                for (offset, kind) in candidates.enumerated() where mask & (1 << offset) != 0 {
                    available.insert(kind)
                }
                let rows = CallDockLayout.rows(mode: mode, available: available)
                let expectedTop = wanted.filter { available.contains($0) }
                if expectedTop.isEmpty {
                    XCTAssertEqual(rows, [CallDockLayout.bottomRow], "\(mode) \(mask)")
                } else {
                    XCTAssertEqual(rows, [expectedTop, CallDockLayout.bottomRow], "\(mode) \(mask)")
                }
                for row in rows {
                    XCTAssertFalse(row.isEmpty, "\(mode) \(mask): an empty row")
                    XCTAssertEqual(Set(row).count, row.count, "\(mode) \(mask): a control twice in a row")
                }
            }
        }
    }

    func testTheReportButtonIsNotACellOfTheDock() {
        let rows = CallDockLayout.rows(mode: .oneToOne, available: [.chat, .share, .add, .mute, .audio, .video, .end])
        XCTAssertEqual(rows[0], [.chat, .share, .add])
    }

    func testTheEndCellAloneStaysInTheLastColumn() {
        XCTAssertEqual(CallDockLayout.leadingSlots(row: [.end]), 3)
        XCTAssertEqual(CallDockLayout.leadingSlots(row: [.mute, .audio, .video, .end]), 0)
        XCTAssertEqual(CallDockLayout.leadingSlots(row: [.chat, .share]), 0)
        let rows = CallDockItems.assemble(mode: .connecting, items: [CallDockItems.end(style, ended: true, action: {})])
        XCTAssertEqual(rows.map { $0.map { $0.kind } }, [[.end]])
    }

    func testWhileConnectingOnlyTheBottomRowIsDrawn() {
        let rows = CallDockLayout.rows(mode: .connecting, available: [.chat, .share, .add, .mute, .audio, .video, .end])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0], [.mute, .audio, .video, .end])
    }

    func testATopRowWithNothingInItIsNotDrawn() {
        let rows = CallDockLayout.rows(mode: .oneToOne, available: [])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0], [.mute, .audio, .video, .end])
    }

    func testTheEndButtonIsAlwaysTheLastCellOfTheLastRow() {
        let modes: [CallDockMode] = [.connecting, .oneToOne, .group]
        let everything: Set<CallControlKind> = Set(CallControlKind.allCases)
        for mode in modes {
            for available in [Set<CallControlKind>(), [.chat], everything] {
                let rows = CallDockLayout.rows(mode: mode, available: available)
                guard let last = rows.last else {
                    XCTFail("\(mode): no rows")
                    continue
                }
                XCTAssertEqual(last, CallDockLayout.bottomRow, "\(mode)")
                XCTAssertEqual(last.last, .end, "\(mode)")
                for row in rows {
                    XCTAssertFalse(row.isEmpty, "\(mode): no empty row")
                }
                let endCells = rows.flatMap { $0 }.filter { $0 == .end }.count
                XCTAssertEqual(endCells, 1, "\(mode): one end button")
            }
        }
    }

    func testThereIsNoHoldNoVoiceEnhancementAndNoDisturbanceControl() {
        let names: Set<String> = Set(CallControlKind.allCases.map { $0.rawValue })
        XCTAssertEqual(names, ["chat", "share", "add", "buds", "hand", "reaction", "mute", "audio", "video", "end"])
    }

    // MARK: - Items

    func testAssembleFillsTheCellsFromTheItemsByKind() {
        let items: [CallDockItem] = [
            CallDockItems.end(style, action: {}),
            CallDockItems.mute(style, muted: false, action: {}),
            CallDockItems.audio(style, speakerOn: false, action: {}),
            CallDockItems.video(style, callHasVideo: false, cameraOn: false, action: {}),
            CallDockItems.chat(style, action: {}),
            CallDockItems.add(style, action: {}),
        ]
        let rows = CallDockItems.assemble(mode: .oneToOne, items: items)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].map { $0.kind }, [.chat, .add])
        XCTAssertEqual(rows[1].map { $0.kind }, [.mute, .audio, .video, .end])
    }

    func testTheNamesUnderTheButtonsAreFixedAndDoNotChangeWithTheState() {
        XCTAssertEqual(CallDockItems.mute(style, muted: true, action: {}).label,
                       CallDockItems.mute(style, muted: false, action: {}).label)
        XCTAssertEqual(CallDockItems.video(style, callHasVideo: true, cameraOn: true, action: {}).label,
                       CallDockItems.video(style, callHasVideo: false, cameraOn: false, action: {}).label)
        XCTAssertEqual(CallDockItems.hand(style, raised: true, action: {}).label,
                       CallDockItems.hand(style, raised: false, action: {}).label)
        XCTAssertEqual(CallDockItems.share(style, sharing: true, action: {}).label,
                       CallDockItems.share(style, sharing: false, action: {}).label)
    }

    func testTheStateIsReadFromTheAccessibilityText() {
        XCTAssertNotEqual(CallDockItems.mute(style, muted: true, action: {}).accessibilityLabel,
                          CallDockItems.mute(style, muted: false, action: {}).accessibilityLabel)
        XCTAssertNotEqual(CallDockItems.hand(style, raised: true, action: {}).accessibilityLabel,
                          CallDockItems.hand(style, raised: false, action: {}).accessibilityLabel)
        XCTAssertEqual(CallDockItems.video(style, callHasVideo: false, cameraOn: false, action: {}).accessibilityLabel,
                       CallControlText.videoA11yUpgrade)
        XCTAssertEqual(CallDockItems.video(style, callHasVideo: true, cameraOn: true, action: {}).accessibilityLabel,
                       CallControlText.videoA11yOff)
        XCTAssertEqual(CallDockItems.video(style, callHasVideo: true, cameraOn: false, action: {}).accessibilityLabel,
                       CallControlText.videoA11yOn)
    }

    func testTheGroupLeaveAndTheClosedOutgoingScreenKeepTheEndCell() {
        let call = CallDockItems.end(style, action: {})
        let group = CallDockItems.end(style, group: true, action: {})
        let closed = CallDockItems.end(style, ended: true, action: {})
        XCTAssertEqual(call.label, CallControlText.end)
        XCTAssertEqual(group.label, CallControlText.end)
        XCTAssertEqual(group.accessibilityLabel, CallControlText.endA11yGroup)
        XCTAssertEqual(closed.label, CallControlText.close)
        for item in [call, group, closed] {
            XCTAssertEqual(item.kind, .end)
            XCTAssertEqual(item.icon, "phone.down.fill")
        }
    }

    func testAHeldMicrophoneIsShownOffAndDisabled() {
        let held = CallDockItems.mute(style, muted: false, held: true, heldLabel: "held", action: {})
        XCTAssertTrue(held.isDisabled)
        XCTAssertEqual(held.icon, "mic.slash.fill")
        XCTAssertEqual(held.accessibilityLabel, "held")
        XCTAssertFalse(CallDockItems.mute(style, muted: true, action: {}).isDisabled)
    }

    func testAChatBadgeShowsTheNumberOrADot() {
        XCTAssertEqual(CallDockItems.chat(style, unreadCount: 3, action: {}).badge, .count(3))
        XCTAssertEqual(CallDockItems.chat(style, unreadDot: true, action: {}).badge, .dot)
        XCTAssertEqual(CallDockItems.chat(style, action: {}).badge, .hidden)
    }

    // MARK: - Audio route

    func testTheAudioRouteFollowsTheOutputPort() {
        XCTAssertEqual(CallAudioRoute.from(portTypes: [.builtInReceiver]), .earpiece)
        XCTAssertEqual(CallAudioRoute.from(portTypes: [.builtInSpeaker]), .speaker)
        XCTAssertEqual(CallAudioRoute.from(portTypes: [.headphones]), .wired)
        XCTAssertEqual(CallAudioRoute.from(portTypes: [.bluetoothHFP]), .bluetooth)
        XCTAssertEqual(CallAudioRoute.from(portTypes: [.bluetoothA2DP]), .bluetooth)
        XCTAssertEqual(CallAudioRoute.from(portTypes: [.carAudio]), .car)
        XCTAssertEqual(CallAudioRoute.from(portTypes: []), .earpiece)
    }

    func testTheGroupAudioButtonOpensTheSystemRoutePickerAndTheOneToOneButtonSwitches() {
        XCTAssertTrue(CallDockItems.audio(style, route: .speaker, usesRoutePicker: true, action: {}).usesRoutePicker)
        XCTAssertFalse(CallDockItems.audio(style, speakerOn: true, action: {}).usesRoutePicker)
    }

    // MARK: - The screens

    func testEveryCallScreenDrawsTheSharedDock() throws {
        for path in ["QAudionApp/Views/Call/InCallScreen.swift", "QAudionApp/Views/VideoCallView.swift",
                     "QAudionApp/Views/GroupCallView.swift", "QAudionApp/Views/Call/OutgoingCallScreen.swift"] {
            let source = try self.source(path)
            XCTAssertEqual(source.components(separatedBy: "CallControlDock(rows:").count - 1, 1, path)
        }
    }

    func testTheModesOfTheScreens() throws {
        XCTAssertTrue(try source("QAudionApp/Views/Call/InCallScreen.swift").contains("assemble(mode: .oneToOne"))
        XCTAssertTrue(try source("QAudionApp/Views/VideoCallView.swift").contains("assemble(mode: .oneToOne"))
        XCTAssertTrue(try source("QAudionApp/Views/GroupCallView.swift").contains("assemble(mode: .group"))
        let outgoing = try source("QAudionApp/Views/Call/OutgoingCallScreen.swift")
        XCTAssertTrue(outgoing.contains("assemble(mode: .connecting"))
        XCTAssertTrue(outgoing.contains("isDisabled: true"), "the video button is disabled while connecting")
    }

    func testTheRemovedControlsAreGone() throws {
        let screens = ["QAudionApp/Views/Call/InCallScreen.swift", "QAudionApp/Views/Call/LiveInCallScreen.swift",
                       "QAudionApp/Views/VideoCallView.swift", "QAudionApp/Views/GroupCallView.swift",
                       "QAudionApp/Views/Call/OutgoingCallScreen.swift", "QAudionApp/Views/Call/IncomingCallScreen.swift",
                       "QAudionApp/Views/ContentView.swift", "QAudionApp/Views/HomeView.swift"]
        for path in screens {
            let source = try self.source(path)
            for forbidden in ["voiceEnhancement", "VoiceEnhancement", "DisturbanceMarkButton", "onMarkDisturbance",
                              "line.3.horizontal", "pause.fill", "inCallCoverView"] {
                XCTAssertFalse(source.contains(forbidden), "\(path) still has \(forbidden)")
            }
        }
        XCTAssertFalse(try source("QAudionApp/Views/GroupCallView.swift").contains("bubble.left.and.bubble.right"),
                       "the group chat button uses the same chat icon as the 1:1 calls")
        XCTAssertFalse(try source("QAudionApp/Views/VideoCallView.swift").contains("Color.blue"),
                       "the active state of the video controls is a colour token, not blue")
        for gone in ["QAudionApp/Views/InCallView.swift", "QAudionApp/Views/InCallContainer.swift",
                     "QAudionApp/Views/CallView.swift", "QAudionApp/Views/Call/Components/DisturbanceMarkButton.swift"] {
            XCTAssertThrowsError(try sourceURL(gone), "\(gone) is back")
        }
    }

    func testOnlyTheDockChangedTheRestOfTheScreensIsAsItWas() throws {
        let audio = try source("QAudionApp/Views/Call/InCallScreen.swift")
        // The trust bar keeps its security-sheet button (it is in the baseline) and the diagnostics button stays in the
        // transport row.
        XCTAssertFalse(audio.contains("diagnosticsRow"))
        XCTAssertTrue(audio.contains("showSecuritySheet = true"))
        XCTAssertTrue(audio.contains("chart.bar.fill"))
        // The report button is an overlay on the left edge of the peer name row: the top bar takes no report parameter, the
        // dock has no report item, and the call header has no presence text.
        XCTAssertTrue(audio.contains(".overlay(alignment: .leading) {"))
        XCTAssertTrue(audio.contains("reportProblemButton(onReportProblem)"))
        XCTAssertFalse(audio.contains("callTopBar(onReportProblem"))
        XCTAssertTrue(audio.contains("CallControlText.reportA11y"))
        XCTAssertFalse(audio.contains("CallDockItems.report"))
        XCTAssertFalse(audio.contains("presenceLine"))
        XCTAssertFalse(audio.contains("Text(\"online\")"))
        // The group call ring has no "Reply" action, as before the dock.
        let content = try source("QAudionApp/Views/ContentView.swift")
        XCTAssertTrue(content.contains("showReplyAction: false"))
        let video = try source("QAudionApp/Views/VideoCallView.swift")
        XCTAssertTrue(video.contains("CallControlText.reportA11y"))
        XCTAssertTrue(video.contains("chart.bar.fill"))
        for path in ["QAudionApp/Views/Call/InCallScreen.swift", "QAudionApp/Views/VideoCallView.swift",
                     "QAudionApp/Views/GroupCallView.swift"] {
            XCTAssertFalse(try source(path).contains("CallTopBarButton"), path)
        }
        // The group call keeps its own header.
        let group = try source("QAudionApp/Views/GroupCallView.swift")
        XCTAssertTrue(group.contains("BugReporter.shared.requestReport(source: .inGroupCall)"))
        // The incoming call screen is as it was: Decline, Reply, Accept.
        let incoming = try source("QAudionApp/Views/Call/IncomingCallScreen.swift")
        XCTAssertTrue(incoming.contains("showReplyAction"))
        XCTAssertTrue(incoming.contains("onReplyWithMessage"))
        XCTAssertFalse(incoming.contains("CallControlText"))
        // The video call hides the top bar, the trust bar and the dock on a tap, as before.
        XCTAssertTrue(video.contains("showControls"))
        XCTAssertTrue(video.contains(".onTapGesture"))
        XCTAssertTrue(video.contains(".statusBarHidden(!showControls)"))
        // The flip camera is on the local preview, not in the dock.
        XCTAssertTrue(video.contains("CallControlText.flipA11y"))
        XCTAssertFalse(CallControlKind.allCases.map { $0.rawValue }.contains("flip"))
    }

    func testTheDockIsAsTallAsItsRowsAndHasNoFlexibleCell() throws {
        let dock = try source("QAudionApp/Views/Call/Components/CallControlDock.swift")
        // An empty cell used to be a Color.clear that took all the height it was offered and stretched the glass over the
        // whole screen. No cell is a flexible view, and the card is fixed to its ideal height.
        XCTAssertFalse(dock.contains("Color.clear"))
        XCTAssertFalse(dock.contains("minHeight"))
        // The empty slots that keep a lone end button bottom-right have a fixed height of zero.
        XCTAssertTrue(dock.contains(".frame(height: 0)"))
        XCTAssertTrue(dock.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertEqual(CallControlDock.circleSize, 52)
        XCTAssertEqual(CallControlDock.endCircleSize, 64)
        XCTAssertEqual(CallControlDock.cornerRadius, 24)
    }

    // MARK: - Strings

    func testEveryDockStringIsInTheCatalogInAllSixLanguages() throws {
        let data = try Data(contentsOf: sourceURL("QAudionApp/Localizable.xcstrings"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let keys = ["mute", "audio", "video", "chat", "share", "add", "hand", "reaction", "end",
                    "mute_a11y_on", "mute_a11y_off", "audio_a11y",
                    "route_earpiece", "route_speaker", "route_wired", "route_bluetooth", "route_car",
                    "video_a11y_upgrade", "video_a11y_off", "video_a11y_on", "chat_a11y", "chat_a11y_unread",
                    "share_a11y_on", "share_a11y_off", "add_a11y", "hand_a11y_raise", "hand_a11y_lower",
                    "reaction_a11y", "end_a11y", "end_a11y_group", "flip_a11y", "report", "report_a11y"]
        for name in keys {
            let key = "call.control." + name
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for language in ["it", "en", "de", "es", "fr", "pt-BR"] {
                let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String ?? ""
                XCTAssertFalse(value.isEmpty, "\(key) has no \(language) text")
            }
        }
        for gone in ["in_call.disturbance_button", "in_call.disturbance_button_a11y", "Disattiva miglioramento voce",
                     "Attiva miglioramento voce", "video.control.flip", "video.control.speaker"] {
            XCTAssertNil(strings[gone], "\(gone) should be gone from the catalog")
        }
    }

    // MARK: - Source helpers

    private func sourceURL(_ relativePath: String, file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw NSError(domain: "CallControlDockTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "\(relativePath) not found from \(file)"])
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: sourceURL(relativePath), encoding: .utf8)
    }
}
