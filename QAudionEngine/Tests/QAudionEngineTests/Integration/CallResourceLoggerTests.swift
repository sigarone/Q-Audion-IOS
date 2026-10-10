import XCTest
@testable import QAudionEngine

/// A world the tests move by hand: the wall clock and the process CPU seconds.
private final class ResourceWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 1_000.0
    private var cpu = 50.0
    private var cpuAvailable = true

    var time: Double { lock.lock(); defer { lock.unlock() }; return now }

    /// Moves the clock by `seconds` and the process CPU by `cores` x `seconds`.
    func advance(_ seconds: Double, cores: Double) {
        lock.lock()
        now += seconds
        cpu += cores * seconds
        lock.unlock()
    }

    func setCpuAvailable(_ available: Bool) {
        lock.lock(); cpuAvailable = available; lock.unlock()
    }

    var clock: CallResourceLogger.Clock {
        return { [self] in self.time }
    }

    var meter: CallResourceLogger.CpuMeter {
        return { [self] in
            self.lock.lock(); defer { self.lock.unlock() }
            return self.cpuAvailable ? self.cpu : nil
        }
    }
}

/// Stand-in for the dispatch timer: remembers every (first delay, period) it was armed with and lets a test fire
/// the live timer by hand. A cancelled timer never fires, as with the real one.
private final class ResourceFakeArm: @unchecked Sendable {
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

    /// Fires the handler of the timer armed at `index` even if it was cancelled: a fire that was already queued
    /// when the timer was cancelled.
    func fireStale(at index: Int) {
        lock.lock()
        let handler = entries[index].handler
        lock.unlock()
        handler()
    }
}

private final class ResourceLines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ line: String) { lock.lock(); all.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return all }
}

/// The device as the app layer would read it, set by the test; the answer is either immediate or held until the
/// test releases it (the real reader hops to the main thread).
private final class ResourceDevice: @unchecked Sendable {
    private let lock = NSLock()
    private var current = CallResourceLine.Device(applicationState: 0, locked: false, thermalState: 0, lowPowerMode: false)
    private var held: [@Sendable (CallResourceLine.Device) -> Void] = []
    private var holding = false
    private var reads = 0

    var device: CallResourceLine.Device {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var holdAnswers: Bool {
        get { lock.lock(); defer { lock.unlock() }; return holding }
        set { lock.lock(); holding = newValue; lock.unlock() }
    }

    var reader: CallResourceLogger.DeviceReader {
        return { [self] deliver in
            self.lock.lock()
            self.reads += 1
            let now = self.current
            if self.holding {
                self.held.append { _ in deliver(now) }
                self.lock.unlock()
            } else {
                self.lock.unlock()
                deliver(now)
            }
        }
    }

    /// Delivers every held answer, in the order they were asked.
    func releaseHeld() {
        lock.lock()
        let pending = held
        held = []
        let latest = current
        lock.unlock()
        for deliver in pending { deliver(latest) }
    }
}

final class CallResourceLoggerTests: XCTestCase {

    private let world = ResourceWorld()
    private let fake = ResourceFakeArm()
    private let sink = ResourceLines()
    private let device = ResourceDevice()

    private func makeLogger() -> CallResourceLogger {
        CallResourceLogger(
            intervalSeconds: 15,
            queue: DispatchQueue(label: "test.call-resource"),
            clock: world.clock,
            cpuSeconds: world.meter,
            arm: fake.arm,
            readDevice: device.reader,
            emit: { [sink] in sink.add($0) })
    }

    // MARK: Format

    func testLineFormatWithTypicalValues() {
        let d = CallResourceLine.Device(applicationState: 0, locked: false, thermalState: 0, lowPowerMode: false)
        XCTAssertEqual(CallResourceLine.line(cpuPercent: 42, device: d), "[Call] cpu=42 st=0 lock=0 therm=0 low=0")
    }

    func testLineFormatEveryStateAndFlag() {
        for state in 0...2 {
            for locked in [false, true] {
                for thermal in 0...3 {
                    for low in [false, true] {
                        let d = CallResourceLine.Device(
                            applicationState: state, locked: locked, thermalState: thermal, lowPowerMode: low)
                        XCTAssertEqual(
                            CallResourceLine.line(cpuPercent: 7, device: d),
                            "[Call] cpu=7 st=\(state) lock=\(locked ? 1 : 0) therm=\(thermal) low=\(low ? 1 : 0)")
                    }
                }
            }
        }
    }

    func testLineFormatCpuExtremes() {
        let d = CallResourceLine.Device(applicationState: 2, locked: true, thermalState: 3, lowPowerMode: true)
        XCTAssertEqual(CallResourceLine.line(cpuPercent: 0, device: d), "[Call] cpu=0 st=2 lock=1 therm=3 low=1")
        XCTAssertEqual(CallResourceLine.line(cpuPercent: 9999, device: d), "[Call] cpu=9999 st=2 lock=1 therm=3 low=1")
        // Out of range values are held to the printed range, the same as the governor's summary line.
        XCTAssertEqual(CallResourceLine.line(cpuPercent: 123_456, device: d), "[Call] cpu=9999 st=2 lock=1 therm=3 low=1")
        XCTAssertEqual(CallResourceLine.line(cpuPercent: -5, device: d), "[Call] cpu=0 st=2 lock=1 therm=3 low=1")
    }

    func testAnswerLineFormatEveryStateAndLock() {
        for state in 0...2 {
            for locked in [false, true] {
                XCTAssertEqual(
                    CallResourceLine.answerLine(applicationState: state, locked: locked),
                    "[Call] answer st=\(state) lock=\(locked ? 1 : 0)")
            }
        }
        XCTAssertEqual(CallResourceLine.answerLine(applicationState: 2, locked: true), "[Call] answer st=2 lock=1")
        XCTAssertEqual(CallResourceLine.answerLine(applicationState: 0, locked: false), "[Call] answer st=0 lock=0")
    }

    func testPercentIsDeltaCpuOverDeltaTime() {
        XCTAssertEqual(CallResourceLine.percent(cpuSeconds: 6.3, wallSeconds: 15), 42)
        XCTAssertEqual(CallResourceLine.percent(cpuSeconds: 15, wallSeconds: 15), 100)
        XCTAssertEqual(CallResourceLine.percent(cpuSeconds: 37.5, wallSeconds: 15), 250)
        XCTAssertEqual(CallResourceLine.percent(cpuSeconds: 0, wallSeconds: 15), 0)
        XCTAssertEqual(CallResourceLine.percent(cpuSeconds: 1, wallSeconds: 0), 0)
        XCTAssertEqual(CallResourceLine.percent(cpuSeconds: 1, wallSeconds: -3), 0)
        XCTAssertEqual(CallResourceLine.percent(cpuSeconds: -1, wallSeconds: 15), 0)
        XCTAssertEqual(CallResourceLine.percent(cpuSeconds: 1_000_000, wallSeconds: 1), 9999)
        XCTAssertEqual(CallResourceLine.percent(cpuSeconds: 1, wallSeconds: Double.nan), 0)
    }

    // MARK: Start, cadence, end

    func testOpeningLineIsEmittedAtStartWithEmptyInterval() {
        let logger = makeLogger()
        device.device = .init(applicationState: 2, locked: true, thermalState: 1, lowPowerMode: false)
        logger.update(callActive: true)
        XCTAssertEqual(sink.lines, ["[Call] cpu=0 st=2 lock=1 therm=1 low=0"])
        XCTAssertEqual(fake.armed, [.init(firstDelay: 15, interval: 15)])
    }

    func testOneLineEveryFifteenSecondsWithCpuOverTheLastInterval() {
        let logger = makeLogger()
        logger.update(callActive: true)
        XCTAssertEqual(sink.lines.count, 1)

        // First sample is measured from the start of the call: 0.42 core for 15 s.
        world.advance(15, cores: 0.42)
        fake.fireLive()
        // The next one only looks at its own interval: 1.5 cores for 15 s.
        world.advance(15, cores: 1.5)
        fake.fireLive()
        // And a quiet one.
        world.advance(15, cores: 0)
        fake.fireLive()

        XCTAssertEqual(sink.lines, [
            "[Call] cpu=0 st=0 lock=0 therm=0 low=0",
            "[Call] cpu=42 st=0 lock=0 therm=0 low=0",
            "[Call] cpu=150 st=0 lock=0 therm=0 low=0",
            "[Call] cpu=0 st=0 lock=0 therm=0 low=0",
        ])
    }

    func testCadenceDoesNotDependOnTheAppState() {
        let logger = makeLogger()
        logger.update(callActive: true)
        for state in [0, 1, 2, 2, 0] {
            device.device = .init(applicationState: state, locked: state == 2, thermalState: 0, lowPowerMode: false)
            world.advance(15, cores: 0.1)
            fake.fireLive()
        }
        XCTAssertEqual(sink.lines.count, 6)
        XCTAssertEqual(
            sink.lines.dropFirst().map { $0.split(separator: " ")[2] },
            ["st=0", "st=1", "st=2", "st=2", "st=0"])
        XCTAssertEqual(device.readCount, 6)
    }

    func testClosingLineIsEmittedAtEndWithTheLastPartialInterval() {
        let logger = makeLogger()
        logger.update(callActive: true)
        world.advance(15, cores: 0.2)
        fake.fireLive()
        // The call ends 5 s later, using 0.6 core over those 5 s.
        world.advance(5, cores: 0.6)
        device.device = .init(applicationState: 1, locked: false, thermalState: 2, lowPowerMode: true)
        logger.update(callActive: false)

        XCTAssertEqual(sink.lines, [
            "[Call] cpu=0 st=0 lock=0 therm=0 low=0",
            "[Call] cpu=20 st=0 lock=0 therm=0 low=0",
            "[Call] cpu=60 st=1 lock=0 therm=2 low=1",
        ])
    }

    // MARK: One timer per call

    func testNoTimerLeftAfterTheEndAndNoFurtherLines() {
        let logger = makeLogger()
        logger.update(callActive: true)
        XCTAssertEqual(fake.liveCount, 1)
        XCTAssertTrue(logger.isRunning)
        logger.update(callActive: false)
        XCTAssertEqual(fake.liveCount, 0)
        XCTAssertFalse(logger.isRunning)

        let count = sink.lines.count
        world.advance(15, cores: 1)
        fake.fireLive()
        XCTAssertEqual(sink.lines.count, count)
    }

    func testRepeatedUpdatesDoNotStackTimersOrDuplicateLines() {
        let logger = makeLogger()
        logger.update(callActive: true)
        logger.update(callActive: true)
        logger.update(callActive: true)
        XCTAssertEqual(fake.armed.count, 1)
        XCTAssertEqual(fake.liveCount, 1)
        XCTAssertEqual(sink.lines.count, 1)

        logger.update(callActive: false)
        logger.update(callActive: false)
        XCTAssertEqual(sink.lines.count, 2)
        XCTAssertEqual(fake.liveCount, 0)
    }

    func testStopWithoutStartDoesNothing() {
        let logger = makeLogger()
        logger.update(callActive: false)
        XCTAssertTrue(sink.lines.isEmpty)
        XCTAssertEqual(device.readCount, 0)
        XCTAssertTrue(fake.armed.isEmpty)
    }

    func testAnotherCallStartsFreshWithItsOwnTimerAndBaseline() {
        let logger = makeLogger()
        logger.update(callActive: true)
        world.advance(15, cores: 0.5)
        fake.fireLive()
        logger.update(callActive: false)

        // Time and CPU pass between the calls; none of it may count in the next call.
        world.advance(600, cores: 0.9)
        logger.update(callActive: true)
        XCTAssertEqual(fake.armed.count, 2)
        XCTAssertEqual(fake.liveCount, 1)
        world.advance(15, cores: 0.1)
        fake.fireLive()

        let last = sink.lines.suffix(2)
        XCTAssertEqual(Array(last), ["[Call] cpu=0 st=0 lock=0 therm=0 low=0", "[Call] cpu=10 st=0 lock=0 therm=0 low=0"])
        XCTAssertEqual(fake.liveCount, 1)
    }

    func testAFireQueuedBeforeTheEndNeverPrintsAfterIt() {
        let logger = makeLogger()
        logger.update(callActive: true)
        logger.update(callActive: false)
        let count = sink.lines.count

        // The old timer's fire was already queued when it was cancelled.
        world.advance(15, cores: 1)
        fake.fireStale(at: 0)
        XCTAssertEqual(sink.lines.count, count)

        // The same fire arriving during the NEXT call is not that call's tick either.
        logger.update(callActive: true)
        let afterStart = sink.lines.count
        fake.fireStale(at: 0)
        XCTAssertEqual(sink.lines.count, afterStart)
    }

    func testADeviceReadingStillOnItsWayWhenTheCallEndsIsDropped() {
        let logger = makeLogger()
        logger.update(callActive: true)
        world.advance(15, cores: 0.3)

        device.holdAnswers = true
        fake.fireLive()                       // tick: reading requested, not answered yet
        logger.update(callActive: false)      // call ends: closing reading requested too
        XCTAssertEqual(sink.lines.count, 1)   // only the opening line so far
        device.holdAnswers = false
        device.releaseHeld()

        // The tick's late answer is dropped; the closing line is kept.
        XCTAssertEqual(sink.lines.count, 2)
        XCTAssertEqual(sink.lines[1], "[Call] cpu=0 st=0 lock=0 therm=0 low=0")
    }

    // MARK: Meter

    func testNoCpuReadingGivesZeroAndRecoversOnTheNextInterval() {
        let logger = makeLogger()
        logger.update(callActive: true)

        world.setCpuAvailable(false)
        world.advance(15, cores: 0.5)
        fake.fireLive()
        world.setCpuAvailable(true)
        // No baseline yet after a missing reading: still 0, then measured from here.
        world.advance(15, cores: 0.5)
        fake.fireLive()
        world.advance(15, cores: 0.5)
        fake.fireLive()

        XCTAssertEqual(sink.lines.map { String($0.split(separator: " ")[1]) }, ["cpu=0", "cpu=0", "cpu=0", "cpu=50"])
    }
}
