import XCTest
@testable import QAudionEngine

/// W-GLARE (2026-08-25) — parity tests for the mutual-dial tiebreak. The
/// verdicts here pin the EXACT rule Android runs in its call_incoming
/// collector: lexicographic compare of the two call ids (Kotlin
/// `String.compareTo` semantics — UTF-16 code units, then length); the side
/// whose OUTGOING id is greater wins and suppresses the incoming, the loser
/// tears down its outgoing with reason "glare" and lets the incoming ring.
/// Any divergence between the platforms elects two winners (both calls
/// survive) or two losers (both die) — exactly the failure this test guards.
final class GlareDecisionsTests: XCTestCase {

    func test_notGlare_whenNoOutgoingCall() {
        XCTAssertEqual(GlareDecisions.resolve(outgoingCallId: nil, incomingCallId: "abc"),
                       .notGlare)
        XCTAssertEqual(GlareDecisions.resolve(outgoingCallId: "", incomingCallId: "abc"),
                       .notGlare)
    }

    func test_notGlare_whenEmptyIncomingId() {
        XCTAssertEqual(GlareDecisions.resolve(outgoingCallId: "abc", incomingCallId: ""),
                       .notGlare)
    }

    /// Same id = ICE-restart / replay of our own call, NOT glare — mirrors
    /// Android's `glareOutgoingId != event.callId` guard (exact,
    /// case-sensitive equality).
    func test_notGlare_whenSameCallId() {
        XCTAssertEqual(GlareDecisions.resolve(outgoingCallId: "same-id", incomingCallId: "same-id"),
                       .notGlare)
    }

    func test_winner_whenOutgoingIdGreater() {
        XCTAssertEqual(
            GlareDecisions.resolve(outgoingCallId: "ffffffff", incomingCallId: "00000000"),
            .winnerSuppressIncoming)
    }

    func test_loser_whenOutgoingIdSmaller() {
        XCTAssertEqual(
            GlareDecisions.resolve(outgoingCallId: "00000000", incomingCallId: "ffffffff"),
            .loserYieldToIncoming)
    }

    /// The two sides of one glare must elect exactly one winner: A compares
    /// (a_out, b_out) while B compares (b_out, a_out) — mirrored inputs must
    /// give mirrored verdicts, for many random UUID-shaped pairs.
    func test_exactlyOneWinnerAcrossBothSides() {
        for _ in 0..<200 {
            let a = UUID().uuidString.lowercased()
            let b = UUID().uuidString.lowercased()
            guard a != b else { continue }
            let sideA = GlareDecisions.resolve(outgoingCallId: a, incomingCallId: b)
            let sideB = GlareDecisions.resolve(outgoingCallId: b, incomingCallId: a)
            switch (sideA, sideB) {
            case (.winnerSuppressIncoming, .loserYieldToIncoming),
                 (.loserYieldToIncoming, .winnerSuppressIncoming):
                break
            default:
                XCTFail("both sides agreed wrongly: a=\(a) b=\(b) A=\(sideA) B=\(sideB)")
            }
        }
    }

    // MARK: - Kotlin compareTo semantics pins

    /// Kotlin compares UTF-16 code units: '0'(0x30) < 'A'(0x41) < 'a'(0x61).
    /// Case MATTERS — an uppercase iOS-minted id against a lowercase Android
    /// one must order the same way on both platforms.
    func test_ordering_isUtf16CodeUnitOrder() {
        XCTAssertTrue(GlareDecisions.isOutgoingGreater("a", than: "A"))
        XCTAssertTrue(GlareDecisions.isOutgoingGreater("A", than: "0"))
        XCTAssertFalse(GlareDecisions.isOutgoingGreater("0", than: "A"))
    }

    /// Kotlin: shared prefix → longer string is greater.
    func test_ordering_longerWinsOnSharedPrefix() {
        XCTAssertTrue(GlareDecisions.isOutgoingGreater("abc-1", than: "abc"))
        XCTAssertFalse(GlareDecisions.isOutgoingGreater("abc", than: "abc-1"))
    }

    /// For the ASCII hex/UUID ids both platforms mint, the hand-rolled
    /// ordering must agree with plain Swift `>` (sanity — the two only
    /// diverge on non-ASCII, which no call id ever contains).
    func test_ordering_agreesWithSwiftOnAsciiIds() {
        for _ in 0..<100 {
            let a = UUID().uuidString.lowercased()
            let b = UUID().uuidString.lowercased()
            XCTAssertEqual(GlareDecisions.isOutgoingGreater(a, than: b), a > b,
                           "diverged on a=\(a) b=\(b)")
        }
    }
}
