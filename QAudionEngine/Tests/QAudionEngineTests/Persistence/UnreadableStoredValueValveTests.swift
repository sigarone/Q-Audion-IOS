import XCTest
@testable import QAudionEngine

/// Pins the safety valve for a persisted value that stays unreadable: the pure
/// verdict (`UnreadableStoredValuePolicy`) and the marker / quarantine
/// bookkeeping (`UnreadableStoredValueValve`) against a throw-away
/// `UserDefaults` suite. The valve is what keeps a store that refuses to
/// overwrite unreadable bytes from being blocked forever, without ever
/// deleting them or reacting to a short outage.
final class UnreadableStoredValueValveTests: XCTestCase {

    private let windowMs: Int64 = 24 * 60 * 60 * 1000
    private let minuteMs: Int64 = 60 * 1000
    private let hourMs: Int64 = 60 * 60 * 1000
    /// A plausible epoch-millisecond instant (2026).
    private let t0: Int64 = 1_780_000_000_000
    private let key = "test.value.v1"

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    private struct Fixture {
        let defaults: UserDefaults
        let valve: UnreadableStoredValueValve
    }

    private func makeFixture() -> Fixture {
        let suite = "test.unreadablevalve.\(UUID().uuidString)"
        suiteNames.append(suite)
        UserDefaults().removePersistentDomain(forName: suite)
        // Suite name is a freshly generated, well-formed non-empty string; UserDefaults(suiteName:) never returns nil for it.
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suite)!
        let valve = UnreadableStoredValueValve(defaults: defaults, valueKey: key, maxAgeMs: windowMs)
        return Fixture(defaults: defaults, valve: valve)
    }

    private func marker(_ fixture: Fixture) -> Int64? {
        guard let raw = fixture.defaults.object(forKey: fixture.valve.markerKey) as? NSNumber else { return nil }
        return raw.int64Value
    }

    // MARK: - Pure verdict

    func test_verdict_noMarker_startsTheWindow() {
        let verdict = UnreadableStoredValuePolicy.verdict(nowMs: t0, firstUnreadableAtMs: nil, maxAgeMs: windowMs)
        XCTAssertEqual(verdict, .startWindow)
    }

    func test_verdict_shortOutage_keeps() {
        let sameInstant = UnreadableStoredValuePolicy.verdict(nowMs: t0, firstUnreadableAtMs: t0, maxAgeMs: windowMs)
        let tenMinutes = UnreadableStoredValuePolicy.verdict(
            nowMs: t0 + 10 * minuteMs, firstUnreadableAtMs: t0, maxAgeMs: windowMs)
        let almostADay = UnreadableStoredValuePolicy.verdict(
            nowMs: t0 + 23 * hourMs, firstUnreadableAtMs: t0, maxAgeMs: windowMs)
        XCTAssertEqual(sameInstant, .keep)
        XCTAssertEqual(tenMinutes, .keep)
        XCTAssertEqual(almostADay, .keep)
    }

    func test_verdict_windowEnd_isExclusive() {
        let atWindow = UnreadableStoredValuePolicy.verdict(
            nowMs: t0 + windowMs, firstUnreadableAtMs: t0, maxAgeMs: windowMs)
        let oneMsPast = UnreadableStoredValuePolicy.verdict(
            nowMs: t0 + windowMs + 1, firstUnreadableAtMs: t0, maxAgeMs: windowMs)
        XCTAssertEqual(atWindow, .keep)
        XCTAssertEqual(oneMsPast, .quarantine)
    }

    func test_verdict_longOutage_quarantines() {
        let threeDays = UnreadableStoredValuePolicy.verdict(
            nowMs: t0 + 3 * windowMs, firstUnreadableAtMs: t0, maxAgeMs: windowMs)
        XCTAssertEqual(threeDays, .quarantine)
    }

    func test_verdict_clockMovedBack_restartsTheWindow() {
        let oneMsBack = UnreadableStoredValuePolicy.verdict(
            nowMs: t0 - 1, firstUnreadableAtMs: t0, maxAgeMs: windowMs)
        let yearBack = UnreadableStoredValuePolicy.verdict(
            nowMs: t0 - 365 * windowMs, firstUnreadableAtMs: t0, maxAgeMs: windowMs)
        XCTAssertEqual(oneMsBack, .startWindow)
        XCTAssertEqual(yearBack, .startWindow)
    }

    func test_verdict_implausibleMarker_isIgnored() {
        let now: Int64 = t0 + 10 * windowMs
        let floorMs: Int64 = UnreadableStoredValuePolicy.minPlausibleMarkerMs
        let implausible: [Int64] = [0, -5, 1, 42, Int64.min, floorMs - 1]
        for candidate in implausible {
            let verdict = UnreadableStoredValuePolicy.verdict(nowMs: now, firstUnreadableAtMs: candidate, maxAgeMs: windowMs)
            XCTAssertEqual(verdict, .startWindow, "marker \(candidate) must not count as an observation instant")
        }
        // The floor itself is a usable instant.
        let atFloor = UnreadableStoredValuePolicy.verdict(
            nowMs: floorMs + windowMs + 1, firstUnreadableAtMs: floorMs, maxAgeMs: windowMs)
        XCTAssertEqual(atFloor, .quarantine)
    }

    func test_verdict_overflowingDistance_isIgnored() {
        // Int64.min - 1_000_000_000_000 overflows: must restart, not trap.
        let verdict = UnreadableStoredValuePolicy.verdict(
            nowMs: Int64.min, firstUnreadableAtMs: UnreadableStoredValuePolicy.minPlausibleMarkerMs, maxAgeMs: windowMs)
        XCTAssertEqual(verdict, .startWindow)
    }

    // MARK: - Persisted contract

    func test_companionKeys_areDerivedFromTheValueKey() {
        let fixture = makeFixture()
        XCTAssertEqual(fixture.valve.valueKey, "test.value.v1")
        XCTAssertEqual(fixture.valve.markerKey, "test.value.v1.unreadable_since")
        XCTAssertEqual(fixture.valve.quarantineKey, "test.value.v1.quarantine")
    }

    // MARK: - Marker bookkeeping

    func test_firstFailure_startsTheWindow_andLeavesTheBytes() {
        let fixture = makeFixture()
        fixture.defaults.set("sealed-blob", forKey: key)

        let outcome = fixture.valve.noteUnreadable(nowMs: t0)

        XCTAssertEqual(outcome, .blocked)
        XCTAssertEqual(marker(fixture), t0)
        XCTAssertEqual(fixture.defaults.string(forKey: key), "sealed-blob")
        XCTAssertNil(fixture.defaults.object(forKey: fixture.valve.quarantineKey))
    }

    func test_temporaryFailure_neverQuarantines() {
        let fixture = makeFixture()
        fixture.defaults.set("sealed-blob", forKey: key)
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: t0), .blocked)

        // Failed reads every minute for the first hour, then hourly up to and
        // including the exact end of the window: every one stays blocked.
        var offsets: [Int64] = []
        for minute in 1...60 {
            offsets.append(Int64(minute) * minuteMs)
        }
        for hour in 2...24 {
            offsets.append(Int64(hour) * hourMs)
        }
        for offset in offsets {
            let outcome = fixture.valve.noteUnreadable(nowMs: t0 + offset)
            XCTAssertEqual(outcome, .blocked, "offset \(offset) ms must not quarantine")
        }

        XCTAssertEqual(fixture.defaults.string(forKey: key), "sealed-blob")
        XCTAssertNil(fixture.defaults.object(forKey: fixture.valve.quarantineKey))
        // The marker is the FIRST observation, never rewritten by later failures.
        XCTAssertEqual(marker(fixture), t0)
    }

    func test_successfulRead_clearsTheMarker_andRestartsTheWindow() {
        let fixture = makeFixture()
        fixture.defaults.set("sealed-blob", forKey: key)
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: t0), .blocked)
        XCTAssertEqual(marker(fixture), t0)

        fixture.valve.noteReadable()
        XCTAssertNil(marker(fixture))

        // A failure two windows later is a FIRST failure again, not a
        // continuation of the old one.
        let later: Int64 = t0 + 2 * windowMs
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: later), .blocked)
        XCTAssertEqual(marker(fixture), later)
        XCTAssertEqual(fixture.defaults.string(forKey: key), "sealed-blob")
        XCTAssertNil(fixture.defaults.object(forKey: fixture.valve.quarantineKey))
    }

    func test_noteReadable_withoutMarker_changesNothing() {
        let fixture = makeFixture()
        fixture.defaults.set("sealed-blob", forKey: key)
        fixture.valve.noteReadable()
        XCTAssertNil(marker(fixture))
        XCTAssertEqual(fixture.defaults.string(forKey: key), "sealed-blob")
    }

    func test_corruptMarker_startsANewWindow_insteadOfQuarantining() {
        let fixture = makeFixture()
        fixture.defaults.set("sealed-blob", forKey: key)
        let now: Int64 = t0 + 5 * windowMs

        fixture.defaults.set("garbage", forKey: fixture.valve.markerKey)
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: now), .blocked)
        XCTAssertEqual(marker(fixture), now)

        fixture.defaults.set(true, forKey: fixture.valve.markerKey)
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: now), .blocked)
        XCTAssertEqual(marker(fixture), now)

        XCTAssertEqual(fixture.defaults.string(forKey: key), "sealed-blob")
        XCTAssertNil(fixture.defaults.object(forKey: fixture.valve.quarantineKey))
    }

    // MARK: - Quarantine

    func test_unreadableForLongerThanTheWindow_movesTheTextAside() {
        let fixture = makeFixture()
        fixture.defaults.set("sealed-blob", forKey: key)
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: t0), .blocked)

        let outcome = fixture.valve.noteUnreadable(nowMs: t0 + windowMs + 1)

        XCTAssertEqual(outcome, .quarantined)
        XCTAssertNil(fixture.defaults.object(forKey: key), "the store starts empty")
        XCTAssertEqual(fixture.defaults.string(forKey: fixture.valve.quarantineKey), "sealed-blob")
        XCTAssertNil(marker(fixture))
    }

    func test_unreadableForLongerThanTheWindow_movesALegacyBlobAside() {
        let fixture = makeFixture()
        let blob = Data([0x00, 0x01, 0x02, 0xFE, 0xFF])
        fixture.defaults.set(blob, forKey: key)
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: t0), .blocked)

        let outcome = fixture.valve.noteUnreadable(nowMs: t0 + 2 * windowMs)

        XCTAssertEqual(outcome, .quarantined)
        XCTAssertNil(fixture.defaults.object(forKey: key))
        XCTAssertEqual(fixture.defaults.data(forKey: fixture.valve.quarantineKey), blob)
        XCTAssertNil(marker(fixture))
    }

    func test_quarantine_keepsOnlyTheLatestValue() {
        let fixture = makeFixture()
        fixture.defaults.set("first-blob", forKey: key)
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: t0), .blocked)
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: t0 + windowMs + 1), .quarantined)
        XCTAssertEqual(fixture.defaults.string(forKey: fixture.valve.quarantineKey), "first-blob")

        // The store writes something new which later turns unreadable too.
        let t1: Int64 = t0 + 5 * windowMs
        fixture.defaults.set("second-blob", forKey: key)
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: t1), .blocked)
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: t1 + windowMs + 1), .quarantined)

        XCTAssertNil(fixture.defaults.object(forKey: key))
        XCTAssertEqual(fixture.defaults.string(forKey: fixture.valve.quarantineKey), "second-blob")
    }

    func test_afterQuarantine_aNewUnreadableValueGetsAFreshWindow() {
        let fixture = makeFixture()
        fixture.defaults.set("first-blob", forKey: key)
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: t0), .blocked)
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: t0 + windowMs + 1), .quarantined)

        // Reading the now-empty store is a success.
        fixture.valve.noteReadable()

        let t1: Int64 = t0 + windowMs + 10 * minuteMs
        fixture.defaults.set("second-blob", forKey: key)
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: t1), .blocked)
        XCTAssertEqual(marker(fixture), t1)
        XCTAssertEqual(fixture.defaults.string(forKey: key), "second-blob")
    }

    func test_valueGoneBeforeTheMove_clearsTheMarker_withoutQuarantiningAnything() {
        let fixture = makeFixture()
        fixture.defaults.set("sealed-blob", forKey: key)
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: t0), .blocked)
        fixture.defaults.removeObject(forKey: key)

        let outcome = fixture.valve.noteUnreadable(nowMs: t0 + windowMs + 1)

        XCTAssertEqual(outcome, .quarantined)
        XCTAssertNil(fixture.defaults.object(forKey: fixture.valve.quarantineKey))
        XCTAssertNil(marker(fixture))
    }

    func test_unsupportedStoredType_isNeverRemoved() {
        let fixture = makeFixture()
        // Neither text nor a blob: the copy cannot be confirmed, so the
        // original must stay exactly where it is.
        fixture.defaults.set(42, forKey: key)
        XCTAssertEqual(fixture.valve.noteUnreadable(nowMs: t0), .blocked)

        let outcome = fixture.valve.noteUnreadable(nowMs: t0 + windowMs + 1)

        XCTAssertEqual(outcome, .quarantineFailed)
        XCTAssertEqual(fixture.defaults.integer(forKey: key), 42)
        XCTAssertEqual(marker(fixture), t0)
    }
}
