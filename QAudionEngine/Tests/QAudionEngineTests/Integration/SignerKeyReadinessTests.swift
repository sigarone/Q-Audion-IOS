import XCTest
@testable import QAudionEngine

/// W-SIGNERWAIT — the responder must not give up on the handshake signer key the instant an OFFER
/// lands on a cold start; it waits a bounded time, and the key is resolved when it is USED, never
/// copied when the integration is wired.
///
/// Call b0d7ba30 (2026-10-07): a phone launched by an incoming call wired its responder before its
/// identity could be read, kept the then-nil copy for the whole call and answered every OFFER retry
/// with `sign_unavailable`. Pure logic only — no Keychain, no network, no real clock.
final class SignerKeyReadinessTests: XCTestCase {

    private let key = Data(repeating: 0x42, count: 32)

    /// Counts calls and hands out a key from the Nth read on (1-based); never when `readyAt` is nil.
    private final class Source {
        private let lock = NSLock()
        private let key: Data
        private let readyAt: Int?
        private(set) var reads = 0
        init(key: Data, readyAt: Int?) { self.key = key; self.readyAt = readyAt }
        func read() -> Data? {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            if let at = readyAt, reads >= at { return key }
            return nil
        }
    }

    private final class Sleeps {
        private(set) var slices: [UInt64] = []
        func record(_ ms: UInt64) -> Bool { slices.append(ms); return true }
    }

    // MARK: - The bounded wait

    func testKeyAlreadyThereCostsNothing() async {
        let src = Source(key: key, readyAt: 1)
        let sleeps = Sleeps()
        let r = await SignerKeyReadiness.waitForKey(
            read: { src.read() }, maxWaitMs: 6_000, pollMs: 150, sleep: { sleeps.record($0) })
        XCTAssertEqual(r, SignerKeyReadiness.Outcome(ready: true, waitedMs: 0))
        XCTAssertTrue(sleeps.slices.isEmpty, "a warm call (key readable) must not wait at all")
        XCTAssertEqual(src.reads, 1)
    }

    func testKeyThatAppearsLaterIsPickedUpAndTheWaitStopsThere() async {
        let src = Source(key: key, readyAt: 4)   // reads 1-3 miss, read 4 hits
        let sleeps = Sleeps()
        let r = await SignerKeyReadiness.waitForKey(
            read: { src.read() }, maxWaitMs: 6_000, pollMs: 150, sleep: { sleeps.record($0) })
        XCTAssertEqual(r, SignerKeyReadiness.Outcome(ready: true, waitedMs: 450))
        XCTAssertEqual(sleeps.slices, [150, 150, 150])
        XCTAssertEqual(src.reads, 4)
    }

    func testGivesUpAfterTheLimitAndNeverInventsAKey() async {
        let src = Source(key: key, readyAt: nil)
        let sleeps = Sleeps()
        let r = await SignerKeyReadiness.waitForKey(
            read: { src.read() }, maxWaitMs: 1_000, pollMs: 250, sleep: { sleeps.record($0) })
        XCTAssertEqual(r, SignerKeyReadiness.Outcome(ready: false, waitedMs: 1_000))
        XCTAssertEqual(sleeps.slices, [250, 250, 250, 250])
        XCTAssertEqual(src.reads, 5, "one read per poll plus the last one at the deadline")
    }

    func testTheLastSliceIsTrimmedSoTheLimitIsExact() async {
        let sleeps = Sleeps()
        let r = await SignerKeyReadiness.waitForKey(
            read: { nil }, maxWaitMs: 250, pollMs: 100, sleep: { sleeps.record($0) })
        XCTAssertEqual(sleeps.slices, [100, 100, 50])
        XCTAssertEqual(r.waitedMs, 250)
        XCTAssertFalse(r.ready)
    }

    func testZeroLimitIsASingleRead() async {
        let src = Source(key: key, readyAt: nil)
        let sleeps = Sleeps()
        let r = await SignerKeyReadiness.waitForKey(
            read: { src.read() }, maxWaitMs: 0, pollMs: 150, sleep: { sleeps.record($0) })
        XCTAssertFalse(r.ready)
        XCTAssertEqual(src.reads, 1)
        XCTAssertTrue(sleeps.slices.isEmpty)
    }

    /// A key that is not exactly 32 bytes is no signer key: the wait keeps going, never "ready".
    func testMalformedKeyIsNotReady() async {
        let r = await SignerKeyReadiness.waitForKey(
            read: { Data(repeating: 1, count: 31) }, maxWaitMs: 300, pollMs: 100, sleep: { _ in true })
        XCTAssertFalse(r.ready)
        XCTAssertEqual(r.waitedMs, 300)
    }

    /// A cancelled wait (the call is gone) ends at once.
    func testCancelledSleepEndsTheWait() async {
        let src = Source(key: key, readyAt: nil)
        let r = await SignerKeyReadiness.waitForKey(
            read: { src.read() }, maxWaitMs: 6_000, pollMs: 150, sleep: { _ in false })
        XCTAssertFalse(r.ready)
        XCTAssertEqual(r.waitedMs, 0)
        XCTAssertEqual(src.reads, 1)
    }

    func testTheShippedLimitsAreBoundedAndSane() {
        XCTAssertGreaterThanOrEqual(SignerKeyReadiness.maxWaitMs, 1_000, "long enough for a cold start to settle")
        XCTAssertLessThanOrEqual(SignerKeyReadiness.maxWaitMs, 10_000, "short enough that a ringing call is not held hostage")
        XCTAssertGreaterThan(SignerKeyReadiness.pollMs, 0)
        XCTAssertLessThan(SignerKeyReadiness.pollMs, SignerKeyReadiness.maxWaitMs)
    }

    // MARK: - The integration reads the key at USE

    /// The bug itself: identity ABSENT when the integration is wired, PRESENT when it is used.
    func testSignerKeyIsResolvedAtUseNotCopiedAtWiring() {
        let integ = QAudionCallIntegration()
        let box = KeyBox()
        integ.provideLocalSignerIdentityKey = { box.value }   // wiring: nothing there yet
        XCTAssertNil(integ.localSignerIdentityKey, "no identity yet: no signer, no ACCEPT")

        box.value = key                                       // the identity appears afterwards
        XCTAssertEqual(integ.localSignerIdentityKey, key, "the same integration must see it, without re-wiring")

        box.value = nil                                       // and is not remembered if it goes away
        XCTAssertNil(integ.localSignerIdentityKey)
    }

    func testNoProviderMeansNoSigner() {
        XCTAssertNil(QAudionCallIntegration().localSignerIdentityKey)
    }

    func testIntegrationWaitReturnsAsSoonAsTheKeyAppears() async {
        let integ = QAudionCallIntegration()
        let src = Source(key: key, readyAt: 3)
        integ.provideLocalSignerIdentityKey = { src.read() }
        let ready = await integ.awaitLocalSignerKey(maxWaitMs: 2_000, pollMs: 5)
        XCTAssertTrue(ready)
        XCTAssertEqual(src.reads, 3)
    }

    func testIntegrationWaitGivesUpWithoutAKey() async {
        let integ = QAudionCallIntegration()
        integ.provideLocalSignerIdentityKey = { nil }
        let ready = await integ.awaitLocalSignerKey(maxWaitMs: 30, pollMs: 5)
        XCTAssertFalse(ready, "no key: the handshake still fails closed, never unsigned")
    }

    private final class KeyBox {
        private let lock = NSLock()
        private var stored: Data?
        var value: Data? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}
