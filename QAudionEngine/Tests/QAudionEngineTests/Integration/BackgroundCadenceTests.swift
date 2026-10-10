import XCTest
@testable import QAudionEngine

private final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ line: String) { lock.lock(); all.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return all }
}

/// A stand-in for the dispatch timer: remembers every (first delay, period) it was armed with, and lets a test
/// fire the live timer by hand. A cancelled timer never fires, as with the real one.
private final class FakeArm: @unchecked Sendable {
    struct Armed: Equatable {
        let firstDelay: Double
        let interval: Double
    }

    private final class Entry {
        let handler: @Sendable () -> Void
        var cancelled = false
        init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var log: [Armed] = []

    var armed: [Armed] { lock.lock(); defer { lock.unlock() }; return log }
    var cancelledCount: Int { lock.lock(); defer { lock.unlock() }; return entries.filter { $0.cancelled }.count }
    var liveCount: Int { lock.lock(); defer { lock.unlock() }; return entries.filter { !$0.cancelled }.count }

    var arm: BackgroundAwareTimer.Arm {
        return { [self] _, firstDelay, interval, handler in
            self.lock.lock()
            let entry = Entry(handler)
            self.entries.append(entry)
            self.log.append(Armed(firstDelay: firstDelay, interval: interval))
            self.lock.unlock()
            return { [self] in
                self.lock.lock()
                entry.cancelled = true
                self.lock.unlock()
            }
        }
    }

    /// Fires every live timer once (there is at most one).
    func fireLive() {
        lock.lock()
        let live = entries.filter { !$0.cancelled }.map { $0.handler }
        lock.unlock()
        for handler in live { handler() }
    }
}

/// The contact-voice check keeps running in the background but less often (10 s instead of 3 s), and the period
/// follows the app's state at the moment it changes: going to the background does not leave foreground-rate
/// fires behind, and coming back does not wait out the long period.
final class BackgroundCadenceTests: XCTestCase {

    private let queue = DispatchQueue(label: "test.background-cadence")
    /// The flag's observer holds the timer weakly, so a timer nobody keeps would vanish at once.
    private var keepAlive: [BackgroundAwareTimer] = []

    @discardableResult
    private func makeTimer(
        flag: AppBackgroundFlag, fake: FakeArm, ticks: TickCounter = TickCounter(), sink: LineSink = LineSink()
    ) -> BackgroundAwareTimer {
        let timer = BackgroundAwareTimer(
            queue: queue,
            flag: flag,
            foregroundSeconds: 3,
            backgroundSeconds: 10,
            arm: fake.arm,
            onCadence: { background, every in
                sink.add(ContactVoiceVerifier.cadenceLine(background: background, everySeconds: every))
            },
            handler: { ticks.bump() }
        )
        keepAlive.append(timer)
        return timer
    }

    // MARK: - AppBackgroundFlag observers

    func testObserversAreToldOnlyOfARealChange() {
        let flag = AppBackgroundFlag()
        let sink = LineSink()
        _ = flag.addChangeObserver { background in sink.add(background ? "bg" : "fg") }
        flag.set(isInBackground: false)   // already foreground: not a change
        flag.set(isInBackground: true)
        flag.set(isInBackground: true)    // repeated: not a change
        flag.set(isInBackground: false)
        XCTAssertEqual(sink.lines, ["bg", "fg"])
    }

    func testARemovedObserverIsNotTold() {
        let flag = AppBackgroundFlag()
        let sink = LineSink()
        let id = flag.addChangeObserver { _ in sink.add("told") }
        flag.set(isInBackground: true)
        flag.removeChangeObserver(id)
        flag.set(isInBackground: false)
        XCTAssertEqual(sink.lines, ["told"])
    }

    func testAnObserverMayReadTheFlagWhileBeingTold() {
        // The flag's lock is released before observers run: reading it back from a handler must not deadlock.
        let flag = AppBackgroundFlag()
        let sink = LineSink()
        _ = flag.addChangeObserver { _ in sink.add(flag.isInBackground ? "bg" : "fg") }
        flag.set(isInBackground: true)
        XCTAssertEqual(sink.lines, ["bg"])
    }

    // MARK: - BackgroundAwareTimer

    func testItStartsAtTheForegroundPeriod() {
        let flag = AppBackgroundFlag()
        let fake = FakeArm()
        makeTimer(flag: flag, fake: fake).start()
        XCTAssertEqual(fake.armed, [FakeArm.Armed(firstDelay: 3, interval: 3)])
    }

    func testItStartsAtTheBackgroundPeriodWhenTheAppIsAlreadyInTheBackground() {
        let flag = AppBackgroundFlag()
        flag.set(isInBackground: true)
        let fake = FakeArm()
        makeTimer(flag: flag, fake: fake).start()
        XCTAssertEqual(fake.armed, [FakeArm.Armed(firstDelay: 10, interval: 10)])
    }

    func testTheChangeOfTheFlagReArmsAtOnceAndTheOldTimerIsCancelled() {
        let flag = AppBackgroundFlag()
        let fake = FakeArm()
        makeTimer(flag: flag, fake: fake).start()

        flag.set(isInBackground: true)
        XCTAssertEqual(fake.armed.last, FakeArm.Armed(firstDelay: 10, interval: 10))
        XCTAssertEqual(fake.cancelledCount, 1)
        XCTAssertEqual(fake.liveCount, 1, "one live timer at any time")

        // Back in the foreground: the first fire is one FOREGROUND period away, not what was left of the long one.
        flag.set(isInBackground: false)
        XCTAssertEqual(fake.armed.last, FakeArm.Armed(firstDelay: 3, interval: 3))
        XCTAssertEqual(fake.armed.count, 3)
        XCTAssertEqual(fake.cancelledCount, 2)
        XCTAssertEqual(fake.liveCount, 1)
    }

    func testARepeatedNotificationDoesNotReArm() {
        let flag = AppBackgroundFlag()
        let fake = FakeArm()
        makeTimer(flag: flag, fake: fake).start()
        flag.set(isInBackground: true)
        flag.set(isInBackground: true)
        XCTAssertEqual(fake.armed.count, 2)
    }

    func testTheHandlerKeepsFiringInTheBackground() {
        // Never off: after the switch to the long period the check still runs.
        let flag = AppBackgroundFlag()
        let fake = FakeArm()
        let ticks = TickCounter()
        makeTimer(flag: flag, fake: fake, ticks: ticks).start()
        flag.set(isInBackground: true)
        fake.fireLive()
        fake.fireLive()
        XCTAssertEqual(ticks.value, 2)
    }

    func testStopCancelsTheTimerAndStopsFollowingTheFlag() {
        let flag = AppBackgroundFlag()
        let fake = FakeArm()
        let ticks = TickCounter()
        let timer = makeTimer(flag: flag, fake: fake, ticks: ticks)
        timer.start()
        timer.stop()
        XCTAssertEqual(fake.liveCount, 0)
        flag.set(isInBackground: true)
        flag.set(isInBackground: false)
        XCTAssertEqual(fake.armed.count, 1, "no re-arm after stop")
        fake.fireLive()
        XCTAssertEqual(ticks.value, 0)
    }

    func testStartTwiceArmsOnce() {
        let flag = AppBackgroundFlag()
        let fake = FakeArm()
        let timer = makeTimer(flag: flag, fake: fake)
        timer.start()
        timer.start()
        XCTAssertEqual(fake.armed.count, 1)
    }

    func testItCanBeStartedAgainAfterStop() {
        let flag = AppBackgroundFlag()
        let fake = FakeArm()
        let timer = makeTimer(flag: flag, fake: fake)
        timer.start()
        timer.stop()
        flag.set(isInBackground: true)
        timer.start()
        XCTAssertEqual(fake.armed.last, FakeArm.Armed(firstDelay: 10, interval: 10))
        XCTAssertEqual(fake.liveCount, 1)
    }

    func testEveryArmingIsReportedWithTheActivePeriod() {
        let flag = AppBackgroundFlag()
        let fake = FakeArm()
        let sink = LineSink()
        makeTimer(flag: flag, fake: fake, sink: sink).start()
        flag.set(isInBackground: true)
        flag.set(isInBackground: true)    // not a change: no line
        flag.set(isInBackground: false)
        XCTAssertEqual(sink.lines, ["[Voice] bg=0 every=3", "[Voice] bg=1 every=10", "[Voice] bg=0 every=3"])
    }

    // MARK: - the production timer

    func testTheDispatchTimerFiresAndStopsFiringOnceCancelled() {
        let ticks = TickCounter()
        let fired = expectation(description: "fired")
        fired.assertForOverFulfill = false
        let cancel = BackgroundAwareTimer.dispatchArm(queue, 0.01, 0.01) {
            ticks.bump()
            fired.fulfill()
        }
        wait(for: [fired], timeout: 5)
        cancel()
        queue.sync {}
        let afterCancel = ticks.value
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(ticks.value, afterCancel, "a cancelled timer must not fire again")
    }

    // MARK: - ContactVoiceVerifier

    func testThePeriodsOfTheVerifier() {
        XCTAssertEqual(ContactVoiceVerifier.scoreIntervalSeconds, 3, "foreground: unchanged")
        XCTAssertGreaterThanOrEqual(ContactVoiceVerifier.backgroundScoreIntervalSeconds, 9)
        XCTAssertLessThanOrEqual(ContactVoiceVerifier.backgroundScoreIntervalSeconds, 12)
    }

    private func makeVerifier(flag: AppBackgroundFlag, fake: FakeArm) -> ContactVoiceVerifier {
        ContactVoiceVerifier(
            embedder: DeterministicTestEmbedder(),
            store: VoiceprintStore(backing: InMemoryVoiceprintBacking()),
            cohortNormalizer: nil,
            backgroundFlag: flag,
            foregroundIntervalSeconds: ContactVoiceVerifier.scoreIntervalSeconds,
            backgroundIntervalSeconds: ContactVoiceVerifier.backgroundScoreIntervalSeconds,
            armTimer: fake.arm
        )
    }

    func testTheVerifierFollowsTheFlagWhileACallIsActive() {
        let flag = AppBackgroundFlag()
        let fake = FakeArm()
        let verifier = makeVerifier(flag: flag, fake: fake)
        let fg = ContactVoiceVerifier.scoreIntervalSeconds
        let bg = ContactVoiceVerifier.backgroundScoreIntervalSeconds

        XCTAssertTrue(fake.armed.isEmpty, "nothing runs without an active contact")
        verifier.setActiveContact("alice")
        XCTAssertEqual(fake.armed, [FakeArm.Armed(firstDelay: fg, interval: fg)])

        flag.set(isInBackground: true)
        XCTAssertEqual(fake.armed.last, FakeArm.Armed(firstDelay: bg, interval: bg))
        flag.set(isInBackground: false)
        XCTAssertEqual(fake.armed.last, FakeArm.Armed(firstDelay: fg, interval: fg))
        XCTAssertEqual(fake.liveCount, 1)

        // The fire reaches the scoring pass without trouble (no audio yet: it ends at once).
        fake.fireLive()
        verifier.deactivate()
    }

    func testTheVerifierStopsFollowingTheFlagWhenTheCallEnds() {
        let flag = AppBackgroundFlag()
        let fake = FakeArm()
        let verifier = makeVerifier(flag: flag, fake: fake)
        verifier.setActiveContact("alice")
        verifier.deactivate()
        XCTAssertEqual(fake.liveCount, 0)
        let armedBefore = fake.armed.count
        flag.set(isInBackground: true)
        XCTAssertEqual(fake.armed.count, armedBefore, "an ended call must not be re-armed by the flag")
    }

    func testTheVerifierStartedInTheBackgroundUsesTheLongPeriodFromTheStart() {
        let flag = AppBackgroundFlag()
        flag.set(isInBackground: true)
        let fake = FakeArm()
        let verifier = makeVerifier(flag: flag, fake: fake)
        verifier.setActiveContact("bob")
        let bg = ContactVoiceVerifier.backgroundScoreIntervalSeconds
        XCTAssertEqual(fake.armed, [FakeArm.Armed(firstDelay: bg, interval: bg)])
        verifier.deactivate()
    }

    func testSwitchingContactReArmsAndLeavesOneLiveTimer() {
        let flag = AppBackgroundFlag()
        let fake = FakeArm()
        let verifier = makeVerifier(flag: flag, fake: fake)
        verifier.setActiveContact("alice")
        verifier.setActiveContact("bob")
        XCTAssertEqual(fake.liveCount, 1)
        flag.set(isInBackground: true)
        XCTAssertEqual(fake.liveCount, 1, "the first contact's timer must not be left following the flag")
        verifier.deactivate()
    }
}
