import XCTest
@testable import QAudionEngine

/// W-B10PAYREQ (2026-09-02) — coverage for `BCryptoError.paymentRequired`
/// and its `userFacingMessage` (2026-09-01 stability audit, item B10: a
/// server-side 402 entitlement denial previously reached every call site as
/// the generic `httpError(402)`, with no dedicated case and no user-facing
/// text). Pure value-type assertions only — no networking, no URLSession —
/// so this needs none of `BCryptoRestClient`'s pinned-session machinery to
/// run, unlike `PinnedSessionPolicyTests` in this same folder.
final class BCryptoErrorPaymentRequiredTests: XCTestCase {

    /// `.paymentRequired` must get its OWN dedicated string, not the
    /// generic fallback every other case shares — that generic fallback is
    /// exactly the "no dedicated UX" gap this fix exists to close.
    func test_paymentRequired_hasADedicatedNonGenericMessage() {
        let generic = BCryptoError.decodingError.userFacingMessage
        let paymentRequired = BCryptoError.paymentRequired.userFacingMessage

        XCTAssertNotEqual(paymentRequired, generic)
        XCTAssertFalse(paymentRequired.isEmpty)
    }

    /// Every OTHER case still resolves to some non-empty string (the shared
    /// generic fallback) — `userFacingMessage` must never crash or return
    /// empty text for a case it doesn't special-case.
    func test_everyOtherCase_fallsBackToTheGenericMessage() {
        let generic = BCryptoError.decodingError.userFacingMessage
        let otherCases: [BCryptoError] = [
            .invalidUrl, .httpError(500), .decodingError, .unauthorized,
            .notFound, .certPinningFailed, .server("x"),
            .unexpectedAccountApiImplementation,
        ]
        for c in otherCases {
            XCTAssertEqual(c.userFacingMessage, generic)
        }
    }
}
