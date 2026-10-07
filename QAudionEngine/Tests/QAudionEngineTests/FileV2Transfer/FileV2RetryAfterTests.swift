import XCTest
@testable import QAudionEngine

/// `Retry-After`: delta-seconds and the three HTTP date forms, capped at 300 seconds, read from ASCII bytes.
final class FileV2RetryAfterTests: XCTestCase {

    /// 1994-11-06T08:49:37Z, the date of the RFC 9110 examples.
    private let rfcMoment: Int64 = 784_111_777_000

    private func seconds(_ header: String, now: Int64 = 784_111_777_000) -> Int? {
        FileV2RetryAfter.seconds(from: header, nowMs: now)
    }

    // MARK: delta-seconds

    func testDeltaSeconds() {
        XCTAssertEqual(seconds("0"), 0)
        XCTAssertEqual(seconds("1"), 1)
        XCTAssertEqual(seconds("2"), 2)
        XCTAssertEqual(seconds("60"), 60)
        XCTAssertEqual(seconds("300"), 300)
        XCTAssertEqual(seconds("007"), 7, "leading zeros are digits")
    }

    func testDeltaSecondsAboveTheCapAreTheCap() {
        XCTAssertEqual(FileV2RetryAfter.maxSeconds, 300)
        XCTAssertEqual(seconds("301"), 300)
        XCTAssertEqual(seconds("3600"), 300)
        XCTAssertEqual(seconds("86400"), 300)
        XCTAssertEqual(seconds("9223372036854775807"), 300)
        XCTAssertEqual(seconds("99999999999999999999999999999999"), 300, "too large for an integer: still the cap, no trap")
    }

    func testOnlyDigitsAreDeltaSeconds() {
        for text in ["-1", "+5", "5.5", "1e3", "0x10", "5s", "five", "", " ", "1 2", "١٢"] {
            XCTAssertNil(seconds(text), "'\(text)'")
        }
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(seconds("  42 "), 42)
        XCTAssertEqual(seconds("\t42\t"), 42)
        XCTAssertEqual(seconds(" Sun, 06 Nov 1994 08:50:37 GMT "), 60)
    }

    // MARK: HTTP dates

    func testTheThreeFormsOfAnHTTPDate() {
        let now = rfcMoment
        XCTAssertEqual(seconds("Sun, 06 Nov 1994 08:50:37 GMT", now: now), 60)           // IMF-fixdate
        XCTAssertEqual(seconds("Sunday, 06-Nov-94 08:50:37 GMT", now: now), 60)         // rfc850
        XCTAssertEqual(seconds("Sun Nov  6 08:50:37 1994", now: now), 60)               // asctime, one-digit day padded with a space
        XCTAssertEqual(seconds("Mon Nov 14 08:50:37 1994", now: now), 300, "asctime, two-digit day, a week away: the cap")
    }

    func testADateInThePastOrNowIsZero() {
        XCTAssertEqual(seconds("Sun, 06 Nov 1994 08:49:37 GMT", now: rfcMoment), 0)
        XCTAssertEqual(seconds("Sun, 06 Nov 1994 08:49:36 GMT", now: rfcMoment), 0)
        XCTAssertEqual(seconds("Thu, 01 Jan 1970 00:00:00 GMT", now: rfcMoment), 0)
    }

    func testTheRemainingTimeIsRoundedUp() {
        XCTAssertEqual(seconds("Sun, 06 Nov 1994 08:49:38 GMT", now: rfcMoment), 1)
        XCTAssertEqual(seconds("Sun, 06 Nov 1994 08:49:38 GMT", now: rfcMoment + 1), 1, "999 ms left is one second")
        XCTAssertEqual(seconds("Sun, 06 Nov 1994 08:49:38 GMT", now: rfcMoment + 999), 1)
        XCTAssertEqual(seconds("Sun, 06 Nov 1994 08:49:38 GMT", now: rfcMoment + 1000), 0)
        XCTAssertEqual(seconds("Sun, 06 Nov 1994 08:50:37 GMT", now: rfcMoment - 500), 61)
    }

    func testADateBeyondTheCapIsTheCap() {
        XCTAssertEqual(seconds("Sun, 06 Nov 1994 09:49:37 GMT", now: rfcMoment), 300)
        XCTAssertEqual(seconds("Fri, 31 Dec 9999 23:59:59 GMT", now: rfcMoment), 300)
    }

    func testLeapYearsAndMonthLengths() {
        // 2024-02-29T12:00:00Z is a Thursday
        let noon: Int64 = 1_709_208_000_000
        XCTAssertEqual(seconds("Thu, 29 Feb 2024 12:00:30 GMT", now: noon), 30)
        XCTAssertNil(seconds("Thu, 29 Feb 2023 12:00:30 GMT", now: noon), "2023 has no 29 February")
        XCTAssertNil(seconds("Mon, 31 Apr 2024 12:00:30 GMT", now: noon), "April has 30 days")
        XCTAssertNil(seconds("Thu, 29 Feb 1900 12:00:30 GMT", now: noon), "1900 is not a leap year")
        XCTAssertEqual(seconds("Tue, 29 Feb 2000 00:00:00 GMT", now: 951_782_400_000 - 5_000), 5, "2000 is a leap year")
        XCTAssertEqual(seconds("Fri, 01 Mar 2024 00:00:00 GMT", now: 1_709_251_200_000 - 90_000), 90)
    }

    func testTheTwoDigitYearOfTheObsoleteFormIsReadInTheRightCentury() {
        // now = 2026-10-07: 94 is 1994 (2094 would be 68 years ahead), 30 is 2030 (4 years ahead)
        let now: Int64 = 1_791_330_000_000
        XCTAssertEqual(seconds("Saturday, 04-Oct-94 00:00:00 GMT", now: now), 0)
        XCTAssertEqual(seconds("Monday, 01-Jan-30 00:00:00 GMT", now: now), 300)
        // exactly at the pivot: 2076 is 50 years ahead (kept); 2077 is more than 50 years ahead (read as 1977)
        XCTAssertEqual(seconds("Monday, 01-Jan-76 00:00:00 GMT", now: now), 300)
        XCTAssertEqual(seconds("Saturday, 01-Jan-77 00:00:00 GMT", now: now), 0)
    }

    func testMalformedDatesAreNil() {
        let bad = [
            "Sun, 6 Nov 1994 08:49:37 GMT",              // one-digit day in the fixed form
            "Sun, 06 Nov 94 08:49:37 GMT",               // two-digit year in the fixed form
            "Sun, 06 Nov 1994 08:49:37 UTC",             // not GMT
            "Sun, 06 Nov 1994 08:49:37 gmt",
            "Sun, 06 Nov 1994 08:49:37",                 // no zone
            "Sun, 06 Nov 1994 24:00:00 GMT",             // hour
            "Sun, 06 Nov 1994 08:60:00 GMT",             // minute
            "Sun, 06 Nov 1994 08:49:61 GMT",             // second
            "Sun, 06 Nov 1994 08:49:37 GMT extra",
            "Sun, 00 Nov 1994 08:49:37 GMT",
            "Sun, 32 Nov 1994 08:49:37 GMT",
            "Sun, 06 Foo 1994 08:49:37 GMT",
            "Sun, 06 nov 1994 08:49:37 GMT",             // month names are case-sensitive
            "Sunday, 06 Nov 1994 08:49:37 GMT",          // a long day name needs the obsolete form
            "Sun, 06-Nov-94 08:49:37 GMT",               // a short day name with the obsolete form
            "Foo, 06 Nov 1994 08:49:37 GMT",
            "Sun 06 Nov 1994 08:49:37 GMT",
            "Sun Nov 6 08:49:37 1994",                   // asctime needs the padding space
            "Sun Nov  6 08:49:37 94",
            "2026-10-07T00:00:00Z",
            "Sun,06 Nov 1994 08:49:37 GMT"
        ]
        for text in bad { XCTAssertNil(seconds(text), "'\(text)'") }
    }

    func testNonASCIIAndSurprisingTextNeverTraps() {
        for text in ["Sun, 06 Nov 1994 08:49:37 GMT\u{0}", "é", "Sun, 06 Nov 1994 08:49:37 GMT\u{301}", String(repeating: "9", count: 5000) + "x"] {
            XCTAssertNil(seconds(text), "\(text.count) characters")
        }
    }

    func testAMomentBeforeTheEpochAndAHugeClockDoNotTrap() {
        XCTAssertEqual(seconds("Thu, 01 Jan 1970 00:00:10 GMT", now: -5_000), 15)
        XCTAssertEqual(seconds("Sun, 06 Nov 1994 08:49:37 GMT", now: Int64.max), 0)
        XCTAssertEqual(seconds("Sun, 06 Nov 1994 08:49:37 GMT", now: Int64.min), 300)
    }

    /// The two-digit year of the obsolete form is read against the current year, which comes from the clock: a clock at either end of
    /// the range of an `Int64` must not trap in the century arithmetic.
    func testTheTwoDigitYearRuleNeverTrapsOnAnExtremeClock() {
        for now in [Int64.max, Int64.min, Int64.max - 1, Int64.min + 1, 0, -1, 253_402_300_799_000, -62_135_596_800_000] {
            for year in ["00", "49", "50", "76", "77", "99"] {
                _ = seconds("Sunday, 06-Nov-\(year) 08:49:37 GMT", now: now)
            }
            _ = seconds("Sun, 06 Nov 9999 23:59:59 GMT", now: now)
            _ = seconds("Mon Jan  1 00:00:00 0000", now: now)
        }
    }

    // MARK: Used with the policy

    func testTheParsedValueFeedsThePolicy() {
        let policy = FileV2RetryPolicy(jitter: { _ in 0 })
        let value = seconds("Sun, 06 Nov 1994 08:50:37 GMT")
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 1, retryAfterSeconds: value), 60_000)
        XCTAssertEqual(policy.nextDelayMs(failedAttempts: 1, retryAfterSeconds: seconds("garbage")), 1_000, "unparseable: the backoff")
    }
}
