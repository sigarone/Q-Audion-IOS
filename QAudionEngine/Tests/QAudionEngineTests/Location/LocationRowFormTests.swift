import XCTest
@testable import QAudionEngine

/// What a message row holds for a location message, the fixed labels that stand for it, and the card state decided from the row and the
/// live-share store (docs/LOCATION_SHARING.md 1.3 and 1.5). Pure logic.
final class LocationRowFormTests: XCTestCase {

    private let sid = Data((0..<16).map { UInt8($0 + 1) })
    private let key = Data((32..<64).map { UInt8($0) })

    private func fix(lat: Double = 45.4642110, lon: Double = 9.1899820, accuracy: Double = 12) -> LocationFix {
        LocationFix(latitude: lat, longitude: lon, horizontalAccuracy: accuracy, elapsedMs: 3_000, approximate: false)
    }

    private func pinBody() throws -> String {
        switch LocationCodec.buildPin(fix: fix()) {
        case .success(let text): return text
        case .failure(let refusal): throw XCTSkip("builder refused: \(refusal)")
        }
    }

    private func liveBody(duration: Int64 = 3_600) throws -> String {
        switch LocationCodec.buildLiveStart(fix: fix(), sid: sid, key: key, startedAt: 1_000, duration: duration) {
        case .success(let text): return text
        case .failure(let refusal): throw XCTSkip("builder refused: \(refusal)")
        }
    }

    // MARK: The local form of a live row

    func testTheLocalFormHasNoKeyAndNoPosition() throws {
        let start = LocationLiveStart(sid: sid, key: key, startedAt: 1_000, duration: 3_600)
        let local = LocationRowForm.localForm(of: start)
        XCTAssertEqual(local, #"{"qa_loc":1,"m":"live","sid":"\#(sid.base64EncodedString())","st":1000,"du":3600}"#)
        XCTAssertFalse(local.contains(key.base64EncodedString()), "the key is never in a row")
        XCTAssertFalse(local.contains("\"k\""))
        XCTAssertFalse(local.contains("\"lat\""))
        XCTAssertTrue(LocationCodec.hasLocationPrefix(local))
        XCTAssertTrue(LocationCodec.isLiveBody(Data(local.utf8)))
    }

    func testTheLocalFormReadsBack() throws {
        let local = LocationRowForm.localForm(sid: sid, startedAt: 1_234, duration: 900)
        guard case .live(let row)? = LocationRowForm.parse(local) else { return XCTFail("not a live row") }
        XCTAssertEqual(row.sid, sid)
        XCTAssertEqual(row.startedAt, 1_234)
        XCTAssertEqual(row.duration, 900)
    }

    /// The local form is never accepted as a body from the wire: it has no position, so the codec rejects it. A peer cannot make a card
    /// by sending a local form.
    func testTheLocalFormIsNotAWireBody() {
        let local = LocationRowForm.localForm(sid: sid, startedAt: 1_000, duration: 3_600)
        XCTAssertEqual(LocationCodec.recognize(local, channel: .chat), .rejected(.badLocation))
    }

    func testAFullLiveBodyReadsBackWithoutItsKey() throws {
        // The sender's row between the send and the echo still holds the full body: only the three facts are taken from it.
        guard case .live(let row)? = LocationRowForm.parse(try liveBody()) else { return XCTFail("not a live row") }
        XCTAssertEqual(row.sid, sid)
        XCTAssertEqual(row.startedAt, 1_000)
        XCTAssertEqual(row.duration, 3_600)
    }

    func testAPinReadsBackFromItsBody() throws {
        let body = try pinBody()
        guard case .pin(let position)? = LocationRowForm.parse(body) else { return XCTFail("not a pin") }
        XCTAssertEqual(position.latE7, 454_642_110)
        XCTAssertEqual(position.lonE7, 91_899_820)
        XCTAssertEqual(position.accuracy, 12)
        XCTAssertNotNil(LocationRowForm.pin(of: body))
        XCTAssertNil(LocationRowForm.pin(of: LocationRowForm.localForm(sid: sid, startedAt: 1, duration: 60)))
    }

    func testTextThatIsNotARowDoesNotParse() {
        XCTAssertNil(LocationRowForm.parse("ciao"))
        XCTAssertNil(LocationRowForm.parse(#"{"qa_loc":1,"m":"pin"}"#))
        XCTAssertNil(LocationRowForm.parse(#"{"qa_loc":1,"m":"live","sid":"AAAA","st":1,"du":60}"#))
        // A local form with an extra member is not a local form (a key or a position must never ride in it).
        let withKey = #"{"qa_loc":1,"m":"live","sid":"\#(sid.base64EncodedString())","st":1000,"du":3600,"k":"\#(key.base64EncodedString())"}"#
        XCTAssertNil(LocationRowForm.parse(withKey))
    }

    // MARK: Fixed labels

    func testLabelsStandForEveryFormAndNeverShowADigitOfAPosition() throws {
        let bodies: [String] = [
            try pinBody(),
            try liveBody(),
            LocationRowForm.localForm(sid: sid, startedAt: 1_000, duration: 3_600),
            #"{"qa_loc":1,"m":"pin","lat":454642110,"lon":91899820,"acc":12,"age":3,"ap":0,"extra":true"#,  // truncated: unreadable
            #"{"qa_loc":2,"lat":454642110,"lon":91899820}"#
        ]
        for body in bodies {
            let shown = MessageReplyCodec.shownText(ofBody: body)
            XCTAssertTrue(shown == LocationLabels.text(.pin) || shown == LocationLabels.text(.live), "shown: \(shown)")
            for digits in ["454642110", "91899820", "45.46", "9.18"] {
                XCTAssertFalse(shown.contains(digits))
            }
        }
        XCTAssertEqual(MessageReplyCodec.shownText(ofBody: try pinBody()), LocationLabels.text(.pin))
        XCTAssertEqual(MessageReplyCodec.shownText(ofBody: try liveBody()), LocationLabels.text(.live))
        XCTAssertEqual(MessageReplyCodec.shownText(ofBody: "ciao"), "ciao")
    }

    func testTheLabelLookupCanBeLocalised() {
        let original = LocationLabels.text
        defer { LocationLabels.text = original }
        LocationLabels.text = { label in label == .pin ? "pin!" : "live!" }
        XCTAssertEqual(MessageReplyCodec.shownText(ofBody: #"{"qa_loc":1,"m":"pin"}"#), "pin!")
    }

    // MARK: The card

    private func view(state: LiveShareState, noCard: Bool = false, withPosition: Bool = true) -> LiveShareView {
        let position = withPosition ? LiveSharePosition(latE7: 5, lonE7: 6, accuracy: 7, approximate: true, fixAt: 90) : nil
        return LiveShareView(id: "c1", state: state, reason: state == .ended ? .expired : nil, endAt: 5_000,
                             lastCounter: 3, lastFrameAt: 100, position: position, noCard: noCard)
    }

    func testAPinIsAPinForBothSides() throws {
        let body = try pinBody()
        for outgoing in [true, false] {
            let card = LocationCardResolver.resolve(rowText: body, outgoing: outgoing, ownShareEndAt: nil, view: nil)
            XCTAssertEqual(card.kind, .pin)
            XCTAssertEqual(card.own, outgoing)
            XCTAssertEqual(card.latE7, 454_642_110)
            XCTAssertEqual(card.accuracy, 12)
            XCTAssertTrue(card.hasPosition)
        }
    }

    func testAnOwnLiveRowIsActiveOnlyWhileTheShareRuns() throws {
        let local = LocationRowForm.localForm(sid: sid, startedAt: 1_000, duration: 3_600)
        let running = LocationCardResolver.resolve(rowText: local, outgoing: true, ownShareEndAt: 4_600, view: nil)
        XCTAssertEqual(running.kind, .liveActive)
        XCTAssertTrue(running.own)
        XCTAssertEqual(running.endAt, 4_600)
        XCTAssertFalse(running.hasPosition, "the sender's card shows no position")
        let over = LocationCardResolver.resolve(rowText: local, outgoing: true, ownShareEndAt: nil, view: nil)
        XCTAssertEqual(over.kind, .liveEnded)
        XCTAssertFalse(over.hasPosition)
    }

    func testAReceivedLiveRowFollowsTheStore() throws {
        let local = LocationRowForm.localForm(sid: sid, startedAt: 1_000, duration: 3_600)
        let active = LocationCardResolver.resolve(rowText: local, outgoing: false, ownShareEndAt: nil, view: view(state: .active))
        XCTAssertEqual(active.kind, .liveActive)
        XCTAssertEqual(active.latE7, 5)
        XCTAssertEqual(active.lastUpdateAt, 100)
        XCTAssertEqual(active.endAt, 5_000)
        XCTAssertTrue(active.approximate)

        let stale = LocationCardResolver.resolve(rowText: local, outgoing: false, ownShareEndAt: nil, view: view(state: .stale))
        XCTAssertEqual(stale.kind, .liveStale)
        XCTAssertTrue(stale.hasPosition, "a stale share keeps its last position")

        let ended = LocationCardResolver.resolve(rowText: local, outgoing: false, ownShareEndAt: nil,
                                                 view: view(state: .ended, withPosition: false))
        XCTAssertEqual(ended.kind, .liveEnded)
        XCTAssertFalse(ended.hasPosition)

        // No record at all (a row restored from a backup, or read on a device that never held the share): ended, no position.
        let none = LocationCardResolver.resolve(rowText: local, outgoing: false, ownShareEndAt: nil, view: nil)
        XCTAssertEqual(none.kind, .liveEnded)

        // A share ended by a delete for everyone shows no card at all, which the row's own delete path takes care of: never a position.
        let deleted = LocationCardResolver.resolve(rowText: local, outgoing: false, ownShareEndAt: nil,
                                                   view: view(state: .active, noCard: true))
        XCTAssertEqual(deleted.kind, .liveEnded)
        XCTAssertFalse(deleted.hasPosition)
    }

    func testARowThatDoesNotReadBackIsUnreadable() {
        let card = LocationCardResolver.resolve(rowText: "ciao", outgoing: false, ownShareEndAt: nil, view: nil)
        XCTAssertEqual(card.kind, .unreadable)
        XCTAssertFalse(card.hasPosition)
    }

    func testTheTypesThatHoldAPositionDescribeThemselvesWithoutOne() throws {
        let card = LocationCardResolver.resolve(rowText: try pinBody(), outgoing: false, ownShareEndAt: nil, view: nil)
        XCTAssertEqual(String(describing: card), "LocationCardState(redacted)")
        XCTAssertEqual("\(card)", "LocationCardState(redacted)")
        let form = try XCTUnwrap(LocationRowForm.parse(try pinBody()))
        XCTAssertEqual(String(describing: form), "LocationRowForm(redacted)")
    }
}
