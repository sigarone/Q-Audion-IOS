import XCTest
@testable import QAudionEngine

final class EarlyRejectedOfferBookTests: XCTestCase {

    private let call = "91B7807D-0000-4000-8000-000000000001"
    private let peer = "peer-a"

    private func appState() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("QAudionApp/AppState.swift"), encoding: .utf8)
    }

    /// Invalid OFFER first: the call announced afterwards by the same peer ends, once.
    func testInvalidOfferFirstEndsTheAnnouncedCallOnce() {
        var book = EarlyRejectedOfferBook()
        book.note(callId: call, senderId: peer, nowMs: 1_000)
        XCTAssertTrue(book.consume(callId: call.lowercased(), senderId: peer, nowMs: 2_000))
        XCTAssertFalse(book.consume(callId: call, senderId: peer, nowMs: 2_100), "consumed once")
    }

    /// Valid OFFER first (or no OFFER): nothing is noted, the call is untouched.
    func testValidOfferFirstIsUnaffected() {
        var book = EarlyRejectedOfferBook()
        XCTAssertFalse(book.consume(callId: call, senderId: peer, nowMs: 1_000))
        book.note(callId: call, senderId: peer, nowMs: 1_000)
        book.clear(callId: call, senderId: peer)
        XCTAssertFalse(book.consume(callId: call, senderId: peer, nowMs: 1_500), "a valid OFFER supersedes the drop")
    }

    /// Another sender or another call never matches: a third party cannot end someone else's call.
    func testOnlyTheSameCallAndSenderMatches() {
        var book = EarlyRejectedOfferBook()
        book.note(callId: call, senderId: "intruder", nowMs: 1_000)
        XCTAssertFalse(book.consume(callId: call, senderId: peer, nowMs: 1_100))
        XCTAssertFalse(book.consume(callId: "other-call", senderId: "intruder", nowMs: 1_100))
        XCTAssertTrue(book.consume(callId: call, senderId: "intruder", nowMs: 1_100))
    }

    func testEntriesExpireAndAreBounded() {
        var book = EarlyRejectedOfferBook()
        book.note(callId: call, senderId: peer, nowMs: 0)
        XCTAssertFalse(book.consume(callId: call, senderId: peer, nowMs: EarlyRejectedOfferBook.ttlMs))
        for i in 0..<(EarlyRejectedOfferBook.capacity + 3) {
            book.note(callId: "c\(i)", senderId: peer, nowMs: 10)
        }
        XCTAssertFalse(book.consume(callId: "c0", senderId: peer, nowMs: 11), "oldest entries are evicted")
        XCTAssertTrue(book.consume(callId: "c\(EarlyRejectedOfferBook.capacity + 2)", senderId: peer, nowMs: 11))
    }

    func testForgetDropsTheCall() {
        var book = EarlyRejectedOfferBook()
        book.note(callId: call, senderId: peer, nowMs: 0)
        book.forget(callId: call)
        XCTAssertFalse(book.consume(callId: call, senderId: peer, nowMs: 1))
    }

    /// AppState wiring: the drop notes the call only when no valid OFFER is held, a valid OFFER clears it, and
    /// `call_incoming` consumes it right after the ring setup, before any WebRTC controller is built.
    func testAppStateWiring() throws {
        let app = try appState()
        let route = try XCTUnwrap(app.range(of: "private func routeInboundAndroidOffer(parsed: AndroidHandshakeEnvelope.Parsed, senderId: String) {"))
        let body = String(app[route.upperBound...].prefix(7_000))
        let drop = try XCTUnwrap(body.range(of: "earlyRejectedOffers.note(callId: parsed.callId, senderId: senderId"))
        let clear = try XCTUnwrap(body.range(of: "earlyRejectedOffers.clear(callId: parsed.callId, senderId: senderId)"))
        let hold = try XCTUnwrap(body.range(of: "bufferOfferReplay(senderId: senderId, callId: parsed.callId)"))
        XCTAssertLessThan(drop.lowerBound, clear.lowerBound)
        XCTAssertLessThan(clear.lowerBound, hold.lowerBound)
        XCTAssertTrue(body.contains("if !holdsValid {"))

        let consume = try XCTUnwrap(app.range(of: "if self.consumeEarlyRejectedOffer(callId: callIdStr, senderId: senderId) {"))
        let tail = String(app[consume.upperBound...].prefix(600))
        XCTAssertTrue(tail.contains("handleHandshakeFatal(callId: callIdStr, reason: CallCloseReason.peerIncompatible.rawValue)"))
        XCTAssertTrue(tail.contains("return"))
        let before = String(app[..<consume.lowerBound].suffix(400))
        XCTAssertTrue(before.contains("integration.setLocallyRinging(true)"))
        let route2 = try XCTUnwrap(app.range(of: "self.routeIncomingWebRtcOffer(\n                                callerId: senderId,\n                                sdp: sdp,", range: consume.upperBound..<app.endIndex)
            ?? app.range(of: "self.routeIncomingWebRtcOffer(", range: consume.upperBound..<app.endIndex))
        XCTAssertLessThan(consume.lowerBound, route2.lowerBound, "no controller is built for the rejected call")
    }
}
