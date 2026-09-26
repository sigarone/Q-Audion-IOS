import XCTest
@testable import QAudionEngine

/// W-NATIVESRTPFMTP (2026-09-26) — the native-SRTP heartbeat's fmtp fields:
/// only allowlisted keys with short ASCII-digit values, one flat token each;
/// no peer-chosen text ever reaches the log line. Same style as
/// `AudioSdpSummaryTests`.
final class FmtpLogTokensTests: XCTestCase {

    func test_typicalOpusLine_flatTokensInAllowlistOrder() {
        XCTAssertEqual(
            FmtpLogTokens.tokens("useinbandfec=1;minptime=10;cbr=1;maxaveragebitrate=32000"),
            ["fmtp_minptime=10", "fmtp_useinbandfec=1", "fmtp_cbr=1", "fmtp_maxaveragebitrate=32000"])
    }

    func test_nilOrEmpty_isEmpty() {
        XCTAssertEqual(FmtpLogTokens.tokens(nil), [])
        XCTAssertEqual(FmtpLogTokens.tokens(""), [])
        XCTAssertEqual(FmtpLogTokens.tokens(";;"), [])
    }

    /// THE property: a key the allowlist does not name is dropped, whatever
    /// its value — the key text is the peer's.
    func test_unknownKeys_areDropped() {
        XCTAssertEqual(
            FmtpLogTokens.tokens("minptime=10;stereo=1;x-peer-note=12345;evil key=1"),
            ["fmtp_minptime=10"])
    }

    /// Non-numeric, signed, decimal, non-ASCII-digit, empty or oversized
    /// values are dropped; nothing of them is echoed.
    func test_nonNumericOrOversizedValues_areDropped() {
        let line = "minptime=10ms;ptime=-20;maxptime=1.5;useinbandfec=\u{0661};cbr=;maxaveragebitrate=12345678"
        XCTAssertEqual(FmtpLogTokens.tokens(line), [])
    }

    /// Nested separators in a value can never survive (the shape the shipper
    /// cannot protect).
    func test_nestedSeparatorsInValue_areDropped() {
        XCTAssertEqual(FmtpLogTokens.tokens("minptime=10=20;cbr=1 useinbandfec=1"), [])
    }

    func test_whitespaceAndCase_areNormalised() {
        XCTAssertEqual(FmtpLogTokens.tokens(" MinPTime = 10 ; CBR=1 "), ["fmtp_minptime=10", "fmtp_cbr=1"])
    }

    /// A repeated key keeps its first valid occurrence only.
    func test_repeatedKey_firstValidOccurrenceWins() {
        XCTAssertEqual(FmtpLogTokens.tokens("minptime=abc;minptime=10;minptime=20"), ["fmtp_minptime=10"])
    }

    func test_sevenDigits_isTheLimit() {
        XCTAssertEqual(FmtpLogTokens.tokens("maxaveragebitrate=1234567"), ["fmtp_maxaveragebitrate=1234567"])
    }
}
