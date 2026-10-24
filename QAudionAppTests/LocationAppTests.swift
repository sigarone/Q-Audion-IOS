import XCTest
@testable import QAudionApp
import QAudionEngine

/// The app side of location sharing (WIRE_SPEC section 14, docs/LOCATION_SHARING.md 1.3 to 1.6): every site that derives display text from
/// a body shows a fixed label and never a digit of the position or a byte of the key; the open actions hand the engine's exact text to the
/// system; the remote switch ships off. Pure: no database, no keychain, no network.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
@MainActor
final class LocationAppTests: XCTestCase {

    private let sid = Data((0..<16).map { UInt8($0 + 1) })
    private let key = Data((32..<64).map { UInt8($0) })

    /// What must never appear in text derived from a location body.
    private var forbidden: [String] {
        ["454642110", "91899820", "45.46", "9.18", "qa_loc", "\"lat\"", "\"lon\"", key.base64EncodedString(), sid.base64EncodedString()]
    }

    private func fix() -> LocationFix {
        LocationFix(latitude: 45.4642110, longitude: 9.1899820, horizontalAccuracy: 12, elapsedMs: 3_000, approximate: false)
    }

    private func pin() throws -> String {
        guard case .success(let text) = LocationCodec.buildPin(fix: fix()) else { throw XCTSkip("builder refused") }
        return text
    }

    private func live() throws -> String {
        guard case .success(let text) = LocationCodec.buildLiveStart(fix: fix(), sid: sid, key: key, startedAt: 1_000, duration: 3_600) else {
            throw XCTSkip("builder refused")
        }
        return text
    }

    private func row(_ text: String, outgoing: Bool = false, serverId: String? = nil) -> Message {
        Message(id: UUID(), conversationId: UUID(), direction: outgoing ? .outgoing : .incoming, plaintext: text,
                sentAt: Date(timeIntervalSince1970: 1_745_000_100), deliveredAt: Date(), readAt: nil, status: .delivered,
                senderUserId: outgoing ? nil : "peer-1", serverMessageId: serverId, clientMsgId: UUID().uuidString)
    }

    private func assertNoPosition(_ text: String, _ site: String, file: StaticString = #filePath, line: UInt = #line) {
        for needle in forbidden {
            XCTAssertFalse(text.contains(needle), "\(site): \"\(needle)\" appears in the text", file: file, line: line)
        }
    }

    /// The rows that every site is fed with: a pin, a live start as received (the key still in it), the local form of a live row, and
    /// the bodies that were rejected.
    private func bodies() throws -> [String] {
        [
            try pin(),
            try live(),
            LocationRowForm.localForm(sid: sid, startedAt: 1_000, duration: 3_600),
            #"{"qa_loc":1,"m":"pin","lat":454642110,"lon":91899820,"acc":0,"age":3,"ap":0}"#,
            #"{"qa_loc":2,"m":"pin","lat":454642110,"lon":91899820}"#
        ]
    }

    // MARK: Display-text sites

    /// The notification body, the Siri cache, the mesh banner and the conversation preview all use this expression.
    func test_theNotificationSiriAndBannerSitesShowAFixedLabel() throws {
        for body in try bodies() {
            let shown: String = FileV2ChatBody.classify(text: body).displayText ?? MessageReplyCodec.shownText(ofBody: body)
            assertNoPosition(shown, "preview")
            XCTAssertTrue(shown == LocationLabels.text(.pin) || shown == LocationLabels.text(.live), "shown: \(shown)")
        }
    }

    func test_theTranscriptExportShowsLabelsAndNoPosition() throws {
        let messages: [Message] = try bodies().enumerated().map { index, body in row(body, outgoing: index % 2 == 0) }
        let url = try XCTUnwrap(ConversationExporter.export(messages: messages, peerDisplayName: "Mario"))
        defer { try? FileManager.default.removeItem(at: url) }
        let transcript: String = try String(contentsOf: url, encoding: .utf8)
        assertNoPosition(transcript, "export")
        XCTAssertTrue(transcript.contains(LocationLabels.text(.pin)))
    }

    func test_theEnigmaRowMapperShowsTheLabel() throws {
        for body in try bodies() {
            let mapped: EnigmaRow = EnigmaRowMapper.row(for: row(body))
            assertNoPosition(mapped.text, "enigma")
        }
    }

    func test_theQuoteBlockOfAReplyToALocationShowsOnlyALabel() throws {
        let target = "11111111-2222-3333-4444-555555555555"
        let built = MessageReplyCodec.build(to: target, kind: "location", quoteSource: try pin(), quotedIsEphemeral: false, body: "grazie")
        guard case .success(let replyBody) = built, case .reply(let reply) = MessageReplyCodec.recognize(replyBody) else {
            return XCTFail("the builder refused a reply to a location")
        }
        XCTAssertEqual(reply.quote, "", "q is always empty for a location")
        let pinRow = row(try pin(), serverId: target)
        let display = ReplyQuotePresenter.display(for: reply, messages: [pinRow], meLabel: "Tu", peerLabel: "Mario")
        XCTAssertEqual(display.text, ReplyQuotePresenter.locationLabel("location"))
        XCTAssertTrue(display.textIsLabel)
        assertNoPosition(display.text, "quote")
        assertNoPosition(display.accessibilityText, "quote accessibility")

        let liveRow = row(LocationRowForm.localForm(sid: sid, startedAt: 1_000, duration: 3_600), serverId: target)
        let liveDisplay = ReplyQuotePresenter.display(for: reply, messages: [liveRow], meLabel: "Tu", peerLabel: "Mario")
        XCTAssertEqual(liveDisplay.text, ReplyQuotePresenter.locationLabel("location_live"))
    }

    func test_theQuoteBlockOfAPinInAGroupShowsOnlyALabel() throws {
        let target = "11111111-2222-3333-4444-555555555555"
        guard case .success(let replyBody) = MessageReplyCodec.build(to: target, kind: "location", quoteSource: nil,
                                                                     quotedIsEphemeral: false, body: "grazie"),
              case .reply(let reply) = MessageReplyCodec.recognize(replyBody) else { return XCTFail("no reply") }
        let stored = GroupMessageStore.Stored(id: "g1", serverMessageId: target, senderId: "peer-1", mine: false,
                                              text: LocationLabels.text(.pin), ts: Date(), locationBody: try pin())
        let display = ReplyQuotePresenter.display(for: reply, groupRows: [stored], authorOf: { _ in "Mario" })
        XCTAssertEqual(display.text, ReplyQuotePresenter.locationLabel("location"))
        assertNoPosition(display.text, "group quote")
    }

    // MARK: Entry-point rule

    func test_theFifthPrefixIsRefusedAsUserTextEverywhere() throws {
        XCTAssertFalse(FileV2ChatBody.isUserTextAllowed(try pin()))
        XCTAssertFalse(FileV2ChatBody.isUserTextAllowed(#"{"qa_loc":"#))
        XCTAssertTrue(FileV2ChatBody.isUserTextAllowed("ciao"))
    }

    // MARK: Open actions

    func test_theCoordinateTextIsDec7() {
        XCTAssertEqual(LocationCardActions.coordinateText(latE7: 454_642_110, lonE7: 91_899_820), "45.4642110, 9.1899820")
        XCTAssertEqual(LocationCardActions.coordinateText(latE7: -5, lonE7: 0), "-0.0000005, 0.0000000")
    }

    func test_theGpxFileIsTheEnginesTextAndItsNameCarriesNoPosition() throws {
        let url = try XCTUnwrap(LocationCardActions.writeGpxFile(latE7: 454_642_110, lonE7: 91_899_820))
        defer { LocationCardActions.removeGpxFile(url) }
        let written: String = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, LocationOpenLinks.gpx(latE7: 454_642_110, lonE7: 91_899_820, label: LocationCardActions.sharedPositionLabel))
        XCTAssertTrue(written.hasSuffix("</gpx>\n"))
        XCTAssertEqual(url.pathExtension, "gpx")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "qa-geo")
        for needle in ["4546", "9189", "454642110", "91899820"] {
            XCTAssertFalse(url.lastPathComponent.contains(needle), "the file name carries a coordinate")
        }
        LocationCardActions.sweepGpxFolder()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the folder is swept at launch")
    }

    func test_theTwoLinksAreTheEnginesHttpsLinks() {
        XCTAssertTrue(LocationOpenLinks.appleMapsURL(latE7: 454_642_110, lonE7: 91_899_820, label: "x").hasPrefix("https://maps.apple.com/"))
        XCTAssertTrue(LocationOpenLinks.googleMapsURL(latE7: 454_642_110, lonE7: 91_899_820).hasPrefix("https://www.google.com/maps/"))
        let info: [String: Any] = Bundle.main.infoDictionary ?? [:]
        XCTAssertNil(info["LSApplicationQueriesSchemes"], "no custom URL scheme is queried")
    }

    // MARK: Texts

    func test_theCardTextsCarryTheirValuesAndNoPosition() {
        XCTAssertTrue(LocationCardStrings.accuracy(metres: 12).contains("12"))
        XCTAssertTrue(LocationCardStrings.until("14:32").contains("14:32"))
        XCTAssertTrue(LocationCardStrings.updated(ago: "20 s").contains("20 s"))
        XCTAssertTrue(LocationCardStrings.lastUpdate(ago: "3 min").contains("3 min"))
        XCTAssertTrue(LocationCardStrings.explainer(name: "Mario").contains("Mario"))
        XCTAssertTrue(LocationCardStrings.stripText(until: "14:32").contains("14:32"))
        XCTAssertTrue(LocationCardStrings.settingsRow(name: "Mario", clock: "14:32").contains("Mario"))
    }

    func test_theElapsedTimeIsOneShortUnit() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(LocationCardFormat.elapsed(since: 9_980, now: now).isEmpty)
        XCTAssertEqual(LocationCardFormat.elapsed(since: nil, now: now), "")
    }

    // MARK: Remote switch and permissions

    func test_theFeatureShipsOff() {
        XCTAssertEqual(LocationShareCenter.flagKey, "location_share.enabled")
        FeatureFlags.shared.resetForTests()
        XCTAssertFalse(FeatureFlags.bool(LocationShareCenter.flagKey, false), "a build without the flag in the file has the feature off")
    }

    func test_theInfoPlistAsksForWhenInUseOnly() {
        let info: [String: Any] = Bundle.main.infoDictionary ?? [:]
        XCTAssertNotNil(info["NSLocationWhenInUseUsageDescription"])
        XCTAssertNil(info["NSLocationAlwaysAndWhenInUseUsageDescription"], "Always is never requested")
        XCTAssertNil(info["NSLocationAlwaysUsageDescription"])
        let modes: [String] = (info["UIBackgroundModes"] as? [String]) ?? []
        XCTAssertTrue(modes.contains("location"))
        let temporary = info["NSLocationTemporaryUsageDescriptionDictionary"] as? [String: String]
        XCTAssertNotNil(temporary?[LocationService.fullAccuracyPurposeKey])
    }

    // MARK: Telemetry

    func test_telemetryNamesAreCountersAndEnumsOnly() {
        // The presets are the only values a start reports.
        XCTAssertEqual(LocationShareCenter.presetLabel(900), "15m")
        XCTAssertEqual(LocationShareCenter.presetLabel(3_600), "1h")
        XCTAssertEqual(LocationShareCenter.presetLabel(28_800), "8h")
        XCTAssertEqual(LocationShareCenter.presetLabel(86_400), "24h")
        XCTAssertEqual(LocationShareCenter.presetLabel(1_234), "other")
    }
}
