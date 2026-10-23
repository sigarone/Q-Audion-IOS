import XCTest
@testable import QAudionEngine

/// The live side of the narrowband Bluetooth notice, driven end to end with a fake route, a fake clock and fake timers:
/// when it watches and when it does not (the periodic look runs only on a Bluetooth hands-free input), when the banner
/// shows (one second after the link turned narrowband, between periodic looks too), how it hides, how a dismissal
/// belongs to the call and not to a screen, the log lines and the tap. The rules themselves are in
/// `NarrowbandBluetoothBannerTests`; the screens and `AVAudioSession` are not reachable here and are only pinned there.

// MARK: - Fakes

/// A route, a clock and timers that only move when the test says so. Times are multiples of a quarter second, so the
/// arithmetic is exact.
private final class FakeRouteEnvironment: NarrowbandRouteEnvironment {

    static let builtIn = NarrowbandRouteReading(inputPort: "MicrophoneBuiltIn", sampleRateHz: 48_000)
    static let narrowband = NarrowbandRouteReading(inputPort: "BluetoothHFP", sampleRateHz: 8_000)
    static let wideband = NarrowbandRouteReading(inputPort: "BluetoothHFP", sampleRateHz: 16_000)
    static let unreadableRate = NarrowbandRouteReading(inputPort: "BluetoothHFP", sampleRateHz: 0)

    private final class Scheduled {
        var due: Double
        let period: Double?
        let action: () -> Void
        init(due: Double, period: Double?, action: @escaping () -> Void) {
            self.due = due
            self.period = period
            self.action = action
        }
    }

    private(set) var now: Double = 1_000
    var reading: NarrowbandRouteReading = FakeRouteEnvironment.builtIn

    /// How many times the route was read.
    private(set) var readCount = 0
    /// How many periodic timers were ever created.
    private(set) var periodicStarts = 0

    private var scheduled: [Scheduled] = []
    private var observers: [Int: () -> Void] = [:]
    private var nextObserverId = 0

    var routeObserverCount: Int { observers.count }
    var periodicCount: Int { scheduled.filter { $0.period != nil }.count }
    var oneShotCount: Int { scheduled.filter { $0.period == nil }.count }

    func readRoute() -> NarrowbandRouteReading {
        readCount += 1
        return reading
    }

    func observeRouteChanges(_ handler: @escaping () -> Void) -> NarrowbandCancel {
        let id = nextObserverId
        nextObserverId += 1
        observers[id] = handler
        return { [weak self] in self?.observers[id] = nil }
    }

    func repeating(every seconds: Double, _ action: @escaping () -> Void) -> NarrowbandCancel {
        periodicStarts += 1
        return add(Scheduled(due: now + seconds, period: seconds, action: action))
    }

    func once(after seconds: Double, _ action: @escaping () -> Void) -> NarrowbandCancel {
        return add(Scheduled(due: now + seconds, period: nil, action: action))
    }

    private func add(_ item: Scheduled) -> NarrowbandCancel {
        scheduled.append(item)
        return { [weak self] in self?.scheduled.removeAll { $0 === item } }
    }

    /// The route becomes `newReading` and the route observers are told.
    func routeChanges(to newReading: NarrowbandRouteReading) {
        reading = newReading
        for handler in Array(observers.values) { handler() }
    }

    /// Moves the clock forward and runs, in order, every timer that falls due on the way.
    func advance(by seconds: Double) {
        let target = now + seconds
        while let next = scheduled.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
            now = max(now, next.due)
            if let period = next.period {
                next.due += period
            } else {
                scheduled.removeAll { $0 === next }
            }
            next.action()
        }
        now = target
    }
}

/// What the watcher told its owner.
private final class Recorder {
    var lines: [String] = []
    var visibility: [Bool] = []
    var usePhoneCalls = 0
}

final class NarrowbandBluetoothWatcherTests: XCTestCase {

    private let oneToOne = NarrowbandBluetoothCallScope.oneToOne
    private let shownLine = "audioroute nb_banner shown=1 sr=8000"
    private let tapLine = "audioroute nb_switch tap=1"

    private func make() -> (FakeRouteEnvironment, NarrowbandBluetoothWatcher, Recorder) {
        let environment = FakeRouteEnvironment()
        let recorder = Recorder()
        let watcher = NarrowbandBluetoothWatcher(
            environment: environment,
            writeLine: { recorder.lines.append($0) },
            onVisibilityChange: { recorder.visibility.append($0) }
        )
        watcher.usePhone = { recorder.usePhoneCalls += 1 }
        return (environment, watcher, recorder)
    }

    // MARK: - when it watches

    func testNothingIsWatchedBeforeACallIsUp() {
        let (environment, watcher, recorder) = make()
        watcher.setCall(key: nil)
        watcher.evaluate()
        environment.routeChanges(to: FakeRouteEnvironment.narrowband)
        environment.advance(by: 30)
        XCTAssertEqual(environment.routeObserverCount, 0)
        XCTAssertEqual(environment.periodicCount, 0)
        XCTAssertEqual(environment.oneShotCount, 0)
        XCTAssertEqual(environment.readCount, 0)
        XCTAssertTrue(recorder.lines.isEmpty)
        XCTAssertTrue(recorder.visibility.isEmpty)
    }

    /// On a phone route there is one route observer for the whole call and no timer at all: nothing wakes the app.
    func testOnTheBuiltInRouteThereIsNoPeriodicWork() {
        let (environment, watcher, _) = make()
        watcher.setCall(key: oneToOne)
        XCTAssertEqual(environment.routeObserverCount, 1)
        XCTAssertEqual(environment.periodicCount, 0)
        XCTAssertEqual(environment.oneShotCount, 0)
        XCTAssertEqual(environment.readCount, 1)
        environment.advance(by: 120)
        XCTAssertEqual(environment.readCount, 1, "no look without a route change")
        XCTAssertEqual(environment.periodicStarts, 0)
    }

    func testAHandsFreeInputIsLookedAtOnceASecond() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.wideband
        watcher.setCall(key: oneToOne)
        XCTAssertEqual(environment.periodicCount, 1)
        XCTAssertEqual(environment.oneShotCount, 0, "nothing is counting down on a wideband link")
        let before = environment.readCount
        environment.advance(by: 5)
        XCTAssertEqual(environment.readCount, before + 5)
        XCTAssertTrue(recorder.visibility.isEmpty)
    }

    func testThePeriodicLookFollowsTheInputAndTheObserverStaysForTheWholeCall() {
        let (environment, watcher, _) = make()
        watcher.setCall(key: oneToOne)
        XCTAssertEqual(environment.periodicCount, 0)

        environment.routeChanges(to: FakeRouteEnvironment.wideband)
        XCTAssertEqual(environment.periodicCount, 1)

        environment.routeChanges(to: FakeRouteEnvironment.builtIn)
        XCTAssertEqual(environment.periodicCount, 0, "left Bluetooth hands-free: the timer is gone")
        let reads = environment.readCount
        environment.advance(by: 30)
        XCTAssertEqual(environment.readCount, reads)
        XCTAssertEqual(environment.routeObserverCount, 1, "the route observer stays for the whole call")

        environment.routeChanges(to: FakeRouteEnvironment.narrowband)
        XCTAssertEqual(environment.periodicCount, 1, "back on hands-free: a timer again")
        XCTAssertEqual(environment.routeObserverCount, 1)
        XCTAssertEqual(environment.periodicStarts, 2)
    }

    func testRepeatedRouteChangesOnHandsFreeDoNotStackTimers() {
        let (environment, watcher, _) = make()
        environment.reading = FakeRouteEnvironment.wideband
        watcher.setCall(key: oneToOne)
        for _ in 0..<4 { environment.routeChanges(to: FakeRouteEnvironment.wideband) }
        XCTAssertEqual(environment.periodicStarts, 1)
        XCTAssertEqual(environment.periodicCount, 1)
    }

    func testBluetoothMusicAndOtherInputsAreNotLookedAt() {
        let (environment, watcher, _) = make()
        watcher.setCall(key: oneToOne)
        for port in ["BluetoothA2DPOutput", "BluetoothLE", "HeadsetMic", "CarAudio", "USBAudio"] {
            environment.routeChanges(to: NarrowbandRouteReading(inputPort: port, sampleRateHz: 8_000))
            XCTAssertEqual(environment.periodicCount, 0, port)
            XCTAssertEqual(environment.oneShotCount, 0, port)
        }
    }

    // MARK: - when it shows

    /// The link turns narrowband at a moment that falls between two periodic looks: the banner is up one second later,
    /// not at the next look after that.
    func testItShowsOneSecondAfterTheLinkTurnedNarrowbandBetweenPeriodicLooks() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.wideband
        watcher.setCall(key: oneToOne)
        environment.advance(by: 1.5) // the periodic look ran at 1.0
        environment.routeChanges(to: FakeRouteEnvironment.narrowband)
        XCTAssertEqual(environment.oneShotCount, 1)

        environment.advance(by: 0.5) // 2.0: the periodic look, 0.5 s into the count
        XCTAssertEqual(recorder.visibility, [])
        environment.advance(by: 0.25)
        XCTAssertEqual(recorder.visibility, [])
        environment.advance(by: 0.25) // 1.0 s after the link turned narrowband
        XCTAssertEqual(recorder.visibility, [true])
        XCTAssertEqual(recorder.lines, [shownLine])
        XCTAssertTrue(watcher.isVisible)
        XCTAssertEqual(environment.oneShotCount, 0, "nothing left to wait for")
    }

    func testACallThatStartsOnANarrowbandHeadsetShowsItOneSecondLater() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        watcher.setCall(key: oneToOne)
        XCTAssertEqual(recorder.visibility, [])
        environment.advance(by: 0.75)
        XCTAssertEqual(recorder.visibility, [])
        environment.advance(by: 0.25)
        XCTAssertEqual(recorder.visibility, [true])
        XCTAssertEqual(recorder.lines, [shownLine])
    }

    func testItDoesNotReportTheSameVisibilityTwiceAndLogsOnceForOneAppearance() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        watcher.setCall(key: oneToOne)
        environment.advance(by: 10)
        XCTAssertEqual(recorder.visibility, [true])
        XCTAssertEqual(recorder.lines, [shownLine])
        environment.routeChanges(to: FakeRouteEnvironment.narrowband)
        XCTAssertEqual(recorder.visibility, [true])
    }

    func testALinkThatSettlesWidebandNeverShows() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        watcher.setCall(key: oneToOne)
        environment.advance(by: 0.5)
        environment.routeChanges(to: FakeRouteEnvironment.wideband)
        XCTAssertEqual(environment.oneShotCount, 0, "the count is over")
        environment.advance(by: 10)
        XCTAssertEqual(recorder.visibility, [])
        XCTAssertTrue(recorder.lines.isEmpty)
    }

    func testABreakInTheCountRestartsTheSettleTime() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        watcher.setCall(key: oneToOne)
        environment.advance(by: 0.5)
        environment.routeChanges(to: FakeRouteEnvironment.unreadableRate)
        environment.advance(by: 0.25)
        environment.routeChanges(to: FakeRouteEnvironment.narrowband)
        environment.advance(by: 0.75)
        XCTAssertEqual(recorder.visibility, [], "1.0 s since the first look, but only 0.75 s since the break")
        environment.advance(by: 0.25)
        XCTAssertEqual(recorder.visibility, [true])
    }

    // MARK: - when it hides

    func testItHidesAtOnceWhenTheRouteLeavesTheHeadset() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        watcher.setCall(key: oneToOne)
        environment.advance(by: 1)
        XCTAssertEqual(recorder.visibility, [true])

        environment.routeChanges(to: FakeRouteEnvironment.builtIn)
        XCTAssertEqual(recorder.visibility, [true, false])
        XCTAssertFalse(watcher.isVisible)
        XCTAssertEqual(environment.periodicCount, 0)
    }

    func testItHidesWhenTheLinkComesUpWidebandWithoutAnyRouteChange() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        watcher.setCall(key: oneToOne)
        environment.advance(by: 1)
        XCTAssertEqual(recorder.visibility, [true])

        environment.reading = FakeRouteEnvironment.wideband // no notification: only the periodic look sees it
        environment.advance(by: 1)
        XCTAssertEqual(recorder.visibility, [true, false])
    }

    func testAnUnreadableRateHidesABannerThatIsUp() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        watcher.setCall(key: oneToOne)
        environment.advance(by: 1)
        environment.routeChanges(to: FakeRouteEnvironment.unreadableRate)
        XCTAssertEqual(recorder.visibility, [true, false])
    }

    func testItShowsAgainAfterTheFullSettleTimeWhenTheHeadsetIsChosenAgain() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        watcher.setCall(key: oneToOne)
        environment.advance(by: 1)
        environment.routeChanges(to: FakeRouteEnvironment.builtIn)
        environment.advance(by: 10)
        environment.routeChanges(to: FakeRouteEnvironment.narrowband)
        environment.advance(by: 0.75)
        XCTAssertEqual(recorder.visibility, [true, false])
        environment.advance(by: 0.25)
        XCTAssertEqual(recorder.visibility, [true, false, true])
        XCTAssertEqual(recorder.lines, [shownLine, shownLine])
    }

    // MARK: - the dismissal

    func testDismissHidesItAndStopsEveryScheduledLook() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        watcher.setCall(key: oneToOne)
        environment.advance(by: 1)
        watcher.dismiss()
        XCTAssertEqual(recorder.visibility, [true, false])
        XCTAssertEqual(environment.periodicCount, 0, "nothing left to watch for this call")
        XCTAssertEqual(environment.oneShotCount, 0)
        XCTAssertEqual(environment.routeObserverCount, 1, "the observer is the call's, not the banner's")

        // away from the headset and back: still dismissed, still no timer
        environment.routeChanges(to: FakeRouteEnvironment.builtIn)
        environment.routeChanges(to: FakeRouteEnvironment.narrowband)
        XCTAssertEqual(environment.periodicCount, 0)
        XCTAssertEqual(environment.oneShotCount, 0)
        let reads = environment.readCount
        environment.advance(by: 60)
        XCTAssertEqual(environment.readCount, reads)
        XCTAssertEqual(recorder.visibility, [true, false])
        XCTAssertEqual(recorder.lines, [shownLine])
    }

    func testDismissBeforeItShowsKeepsItAway() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        watcher.setCall(key: oneToOne)
        XCTAssertEqual(environment.oneShotCount, 1)
        watcher.dismiss()
        XCTAssertEqual(environment.oneShotCount, 0)
        XCTAssertEqual(environment.periodicCount, 0)
        environment.advance(by: 30)
        XCTAssertEqual(recorder.visibility, [])
        XCTAssertTrue(recorder.lines.isEmpty)
    }

    /// The dismissal is the call's: another screen appearing for the same call asks for the same key and finds the
    /// banner closed; only another call starts clean.
    func testTheDismissalBelongsToTheCallAndNotToAScreen() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        watcher.setCall(key: oneToOne)
        environment.advance(by: 1)
        watcher.dismiss()

        // the 1:1 screen goes away and comes back, the video screen appears: the app says again that the 1:1 call is up
        watcher.setCall(key: oneToOne)
        watcher.setCall(key: oneToOne)
        environment.advance(by: 30)
        XCTAssertEqual(recorder.visibility, [true, false])
        XCTAssertEqual(environment.routeObserverCount, 1)
    }

    func testACallPromotedToAGroupStartsClean() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        watcher.setCall(key: oneToOne)
        environment.advance(by: 1)
        watcher.dismiss()
        XCTAssertEqual(recorder.visibility, [true, false])

        let group = NarrowbandBluetoothCallScope.key(oneToOneLive: true, groupCallId: "grp-1")
        watcher.setCall(key: group)
        XCTAssertEqual(recorder.visibility, [true, false], "the new call has not shown anything yet")
        XCTAssertEqual(environment.routeObserverCount, 1, "one observer, never two")
        XCTAssertEqual(environment.periodicCount, 1)
        environment.advance(by: 1)
        XCTAssertEqual(recorder.visibility, [true, false, true])
        XCTAssertEqual(recorder.lines, [shownLine, shownLine])
    }

    // MARK: - the end of the call

    func testTheEndOfTheCallTakesTheBannerDownAndCancelsEverything() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        watcher.setCall(key: oneToOne)
        environment.advance(by: 1)
        XCTAssertEqual(recorder.visibility, [true])

        watcher.setCall(key: nil)
        XCTAssertEqual(recorder.visibility, [true, false])
        XCTAssertFalse(watcher.isVisible)
        XCTAssertEqual(environment.routeObserverCount, 0)
        XCTAssertEqual(environment.periodicCount, 0)
        XCTAssertEqual(environment.oneShotCount, 0)

        let reads = environment.readCount
        environment.routeChanges(to: FakeRouteEnvironment.narrowband)
        environment.advance(by: 30)
        watcher.evaluate()
        XCTAssertEqual(environment.readCount, reads, "no call, no look")
        XCTAssertEqual(recorder.visibility, [true, false])
    }

    func testTheEndOfACallThatNeverShowedReportsNothing() {
        let (_, watcher, recorder) = make()
        watcher.setCall(key: oneToOne)
        watcher.setCall(key: nil)
        XCTAssertEqual(recorder.visibility, [])
    }

    func testTheNextCallStartsWithItsOwnLineCount() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        let cap = NarrowbandBluetoothBannerState.maxShownLinesPerCall
        watcher.setCall(key: oneToOne)
        for _ in 0..<(cap + 2) {
            environment.advance(by: 1)
            environment.routeChanges(to: FakeRouteEnvironment.builtIn)
            environment.routeChanges(to: FakeRouteEnvironment.narrowband)
        }
        XCTAssertEqual(recorder.lines.count, cap)
        watcher.setCall(key: nil)
        watcher.setCall(key: oneToOne)
        environment.advance(by: 1)
        XCTAssertEqual(recorder.lines.count, cap + 1)
    }

    // MARK: - the log lines and the tap

    func testTheShownLineIsWrittenAtMostFiveTimesPerCallWhileTheBannerKeepsFollowingTheLink() {
        let (environment, watcher, recorder) = make()
        let flaps = NarrowbandBluetoothBannerState.maxShownLinesPerCall + 3
        for _ in 0..<flaps {
            environment.routeChanges(to: FakeRouteEnvironment.builtIn)
            watcher.setCall(key: oneToOne)
            environment.routeChanges(to: FakeRouteEnvironment.narrowband)
            environment.advance(by: 1)
            environment.routeChanges(to: FakeRouteEnvironment.builtIn)
        }
        XCTAssertEqual(recorder.lines.count, NarrowbandBluetoothBannerState.maxShownLinesPerCall)
        XCTAssertEqual(recorder.visibility.filter { $0 }.count, flaps, "the banner itself kept following the link")
    }

    func testTheTapWritesItsLineEveryTimeAsksForThePhoneAndIsNotADismissal() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        watcher.setCall(key: oneToOne)
        environment.advance(by: 1)

        watcher.switchToPhone()
        XCTAssertEqual(recorder.usePhoneCalls, 1)
        XCTAssertEqual(recorder.lines, [shownLine, tapLine])
        XCTAssertTrue(watcher.isVisible, "the route did not move: the banner stays")

        watcher.switchToPhone()
        XCTAssertEqual(recorder.lines, [shownLine, tapLine, tapLine])
        XCTAssertEqual(recorder.usePhoneCalls, 2)
    }

    /// The phone takes the call: the banner goes with the route. The user goes back to the headset: it is not dismissed,
    /// so it comes back once the link has held for the settle time.
    func testAfterTheSwitchTheBannerFollowsTheRouteAndComesBackWithTheHeadset() {
        let (environment, watcher, recorder) = make()
        environment.reading = FakeRouteEnvironment.narrowband
        watcher.setCall(key: oneToOne)
        environment.advance(by: 1)
        watcher.usePhone = { environment.reading = FakeRouteEnvironment.builtIn } // the session moved, no notification yet

        watcher.switchToPhone()
        XCTAssertEqual(recorder.visibility, [true, false], "the look after the tap sees the new route")
        XCTAssertEqual(environment.periodicCount, 0)

        environment.routeChanges(to: FakeRouteEnvironment.narrowband)
        environment.advance(by: 1)
        XCTAssertEqual(recorder.visibility, [true, false, true])
    }

    func testTheOwnerIsToldNothingWhenNoOneListens() {
        let environment = FakeRouteEnvironment()
        let watcher = NarrowbandBluetoothWatcher(environment: environment, writeLine: { _ in }, onVisibilityChange: { _ in })
        watcher.switchToPhone() // no usePhone set, no call: nothing to do, nothing to fail
        watcher.dismiss()
        XCTAssertFalse(watcher.isVisible)
    }
}
