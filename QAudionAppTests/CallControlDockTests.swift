import XCTest
import AVFoundation
@testable import QAudionApp

/// The call dock: two rows of four cells, the same on every call screen, the red end button always the last cell of the
/// bottom row. These tests pin the order of the cells in every call state and that the controls taken out of the screens
/// stay out.
final class CallControlDockTests: XCTestCase {

    private let style = CallDockStyle(scheme: .dark, extras: .dark)

    // MARK: - Order of the cells

    func testOneToOneDockHasChatShareAddOverMuteAudioVideoEnd() {
        let rows = CallDockLayout.rows(mode: .oneToOne, available: [.chat, .share, .add, .mute, .audio, .video, .end])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], [.chat, .share, .add, nil])
        XCTAssertEqual(rows[1], [.mute, .audio, .video, .end])
    }

    func testBudsFillTheFourthCellOnlyWhenTheyAreConnected() {
        let withBuds = CallDockLayout.rows(mode: .oneToOne, available: [.chat, .share, .add, .buds])
        XCTAssertEqual(withBuds[0], [.chat, .share, .add, .buds])
        let without = CallDockLayout.rows(mode: .oneToOne, available: [.chat, .share, .add])
        XCTAssertEqual(without[0], [.chat, .share, .add, nil])
    }

    func testGroupDockHasChatShareHandReaction() {
        let rows = CallDockLayout.rows(mode: .group, available: [.chat, .share, .hand, .reaction])
        XCTAssertEqual(rows[0], [.chat, .share, .hand, .reaction])
        XCTAssertEqual(rows[1], [.mute, .audio, .video, .end])
    }

    func testAControlThatIsNotAvailableLeavesItsCellEmptyAndTheOthersDoNotMove() {
        // Screen sharing is not offered on an iOS group call: Hand and Reaction stay in the third and fourth cell.
        let rows = CallDockLayout.rows(mode: .group, available: [.chat, .hand, .reaction])
        XCTAssertEqual(rows[0], [.chat, nil, .hand, .reaction])
        // A 1:1 call without the chat host: Share and Add stay in the second and third cell.
        let oneToOne = CallDockLayout.rows(mode: .oneToOne, available: [.share, .add])
        XCTAssertEqual(oneToOne[0], [nil, .share, .add, nil])
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
                XCTAssertEqual(last.count, CallDockLayout.columns, "\(mode)")
                XCTAssertEqual(last[CallDockLayout.columns - 1], .end, "\(mode)")
                for row in rows {
                    XCTAssertEqual(row.count, CallDockLayout.columns, "\(mode): every row has four cells")
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
        XCTAssertEqual(rows[0].map { $0?.kind }, [.chat, nil, .add, nil])
        XCTAssertEqual(rows[1].map { $0?.kind }, [.mute, .audio, .video, .end])
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
                              "line.3.horizontal", "showReplyAction", "onReplyWithMessage", "message.fill",
                              "pause.fill", "inCallCoverView"] {
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

    func testTheTopBarCarriesTheShieldAndTheReportButton() throws {
        for path in ["QAudionApp/Views/Call/InCallScreen.swift", "QAudionApp/Views/VideoCallView.swift",
                     "QAudionApp/Views/GroupCallView.swift"] {
            let source = try self.source(path)
            XCTAssertTrue(source.contains("CallControlText.securityA11y"), path)
            XCTAssertTrue(source.contains("CallControlText.reportA11y"), path)
        }
        // The diagnostics are in the security sheet of the audio call and behind the shield of the video call.
        XCTAssertTrue(try source("QAudionApp/Views/Call/InCallScreen.swift").contains("diagnosticsRow"))
        XCTAssertFalse(try source("QAudionApp/Views/Call/InCallScreen.swift").contains("onMarkDisturbance"))
        // The flip camera is on the local preview, not in the dock.
        let video = try source("QAudionApp/Views/VideoCallView.swift")
        XCTAssertTrue(video.contains("CallControlText.flipA11y"))
        XCTAssertFalse(CallControlKind.allCases.map { $0.rawValue }.contains("flip"))
    }

    // MARK: - Strings

    func testEveryDockStringIsInTheCatalogInAllSixLanguages() throws {
        let data = try Data(contentsOf: sourceURL("QAudionApp/Localizable.xcstrings"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let keys = ["mute", "audio", "video", "chat", "share", "add", "hand", "reaction", "end", "decline", "accept",
                    "accept_no_video", "answer_audio_only", "mute_a11y_on", "mute_a11y_off", "audio_a11y",
                    "route_earpiece", "route_speaker", "route_wired", "route_bluetooth", "route_car",
                    "video_a11y_upgrade", "video_a11y_off", "video_a11y_on", "chat_a11y", "chat_a11y_unread",
                    "share_a11y_on", "share_a11y_off", "add_a11y", "hand_a11y_raise", "hand_a11y_lower",
                    "reaction_a11y", "end_a11y", "end_a11y_group", "flip_a11y", "report_a11y", "layout_a11y_grid",
                    "layout_a11y_speaker", "security_a11y"]
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
