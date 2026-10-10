import Foundation

/// Numeric diagnostics of a call, one short line at a time. Keys and numbers only, built from words the phone-log
/// shipper already admits (`scripts/ship-ios-logs.py`; `scripts/test_ship_ios_display_vocab.py` pins these exact
/// shapes: keep both in sync).
///
/// During the call, `line`: "[Call] cpu=42 st=0 lock=0 therm=0 low=0"
/// - `cpu`: process CPU over the last interval, as a percentage of ONE core (it can pass 100 on a multi-threaded
///   process), whole number, capped at 9999.
/// - `st`: raw application state (0 active, 1 inactive, 2 background).
/// - `lock`: 1 when protected data is not available, 0 when it is.
/// - `therm`: raw thermal state (0 nominal, 1 fair, 2 serious, 3 critical).
/// - `low`: 1 when Low Power Mode is on.
///
/// When the user answers an incoming call, `answerLine`: "[Call] answer st=0 lock=0" (`st` and `lock` as above).
public enum CallResourceLine {
    /// What the app layer reads from the device (UIKit and ProcessInfo). Plain values, so the engine does not
    /// depend on UIKit and a test can use any combination.
    public struct Device: Equatable, Sendable {
        public var applicationState: Int
        /// True when protected data is not available.
        public var locked: Bool
        public var thermalState: Int
        public var lowPowerMode: Bool

        public init(applicationState: Int, locked: Bool, thermalState: Int, lowPowerMode: Bool) {
            self.applicationState = applicationState
            self.locked = locked
            self.thermalState = thermalState
            self.lowPowerMode = lowPowerMode
        }
    }

    /// The line printed once when an incoming call is answered.
    public static func answerLine(applicationState: Int, locked: Bool) -> String {
        "[Call] answer st=\(applicationState) lock=\(locked ? 1 : 0)"
    }

    static func line(cpuPercent: Int, device: Device) -> String {
        "[Call] cpu=\(min(9999, max(0, cpuPercent))) st=\(device.applicationState) lock=\(device.locked ? 1 : 0)"
            + " therm=\(device.thermalState) low=\(device.lowPowerMode ? 1 : 0)"
    }

    /// CPU seconds used over `wallSeconds` of wall clock, as a whole percentage of one core. An empty or negative
    /// interval, or a negative CPU delta, gives 0.
    static func percent(cpuSeconds: Double, wallSeconds: Double) -> Int {
        guard wallSeconds > 0, cpuSeconds > 0 else { return 0 }
        let value = (cpuSeconds / wallSeconds * 100).rounded()
        return value.isFinite ? Int(min(9999, max(0, value))) : 0
    }
}

/// Logs `CallResourceLine` while a call is active: once when the call becomes active, then every
/// `intervalSeconds`, and once more when it ends. Diagnostic only: it reads and prints, it never acts, and it
/// does not depend on the app state (the app state is one of the values it reports).
///
/// One timer per call. `update(callActive:)` is idempotent: it starts the timer on the first `true` and stops it on
/// the first `false`, so the caller can pass the call state on every transition without tracking anything. A tick
/// whose device reading was still on its way when the call ended is dropped, so a tick is never logged after the
/// final line, and a new call never inherits the old one's timer or baseline.
///
/// CPU: `getrusage` (the same meter as `BackgroundCpuGovernor`, `ProcessCpu`) read at the tick, divided by the
/// wall time since the previous sample; the first sample of a call is measured from the start of the call. The
/// opening line has an empty interval behind it, so its `cpu` is 0 by construction; it is there for the other
/// four values.
///
/// The device values come from `readDevice`, which the app layer implements. It is asked on the timer's queue
/// and delivers its answer when it has it: UIKit's `applicationState` and `isProtectedDataAvailable` must be read
/// on the main thread, so the app hops there asynchronously (never `DispatchQueue.main.sync`, which deadlocks when
/// already on main).
///
/// Thread-safe.
public final class CallResourceLogger: @unchecked Sendable {
    public static let intervalSeconds: Double = 15

    /// Asked for the device values. Calls `deliver` once, from any thread, now or later.
    public typealias DeviceReader = @Sendable (_ deliver: @escaping @Sendable (CallResourceLine.Device) -> Void) -> Void

    typealias Clock = @Sendable () -> Double
    typealias CpuMeter = @Sendable () -> Double?
    typealias Emit = @Sendable (String) -> Void

    private let intervalSeconds: Double
    private let queue: DispatchQueue
    private let clock: Clock
    private let cpuSeconds: CpuMeter
    private let arm: BackgroundAwareTimer.Arm
    private let readDevice: DeviceReader
    private let emit: Emit

    private let lock = NSLock()
    private var running = false
    /// Bumped at every start and stop, so a tick belongs to exactly one call.
    private var epoch = 0
    private var cancelTimer: (() -> Void)?
    private var lastTime = 0.0
    private var lastCpu: Double?

    /// The production logger: every 15 s, printed through the stdout tee.
    public convenience init(readDevice: @escaping DeviceReader) {
        self.init(
            intervalSeconds: CallResourceLogger.intervalSeconds,
            queue: DispatchQueue(label: "qaudion.call-resource", qos: .utility),
            clock: BackgroundCpuGovernor.uptimeSeconds,
            cpuSeconds: { ProcessCpu.seconds() },
            arm: BackgroundAwareTimer.dispatchArm,
            readDevice: readDevice,
            emit: { print($0) })
    }

    init(
        intervalSeconds: Double,
        queue: DispatchQueue,
        clock: @escaping Clock,
        cpuSeconds: @escaping CpuMeter,
        arm: @escaping BackgroundAwareTimer.Arm,
        readDevice: @escaping DeviceReader,
        emit: @escaping Emit
    ) {
        self.intervalSeconds = intervalSeconds
        self.queue = queue
        self.clock = clock
        self.cpuSeconds = cpuSeconds
        self.arm = arm
        self.readDevice = readDevice
        self.emit = emit
    }

    /// True while a call's timer is armed.
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Starts logging on the first `true`, stops (with a final line) on the first `false`. Repeats do nothing.
    public func update(callActive: Bool) {
        if callActive { start() } else { stop() }
    }

    func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        epoch += 1
        let mine = epoch
        lastTime = clock()
        lastCpu = cpuSeconds()
        cancelTimer = arm(queue, intervalSeconds, intervalSeconds) { [weak self] in self?.tick(epoch: mine) }
        lock.unlock()
        report(cpuPercent: 0, onlyIfEpoch: nil)
    }

    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        epoch += 1
        let cancel = cancelTimer
        cancelTimer = nil
        let cpu = takeSampleLocked()
        lock.unlock()
        cancel?()
        report(cpuPercent: cpu, onlyIfEpoch: nil)
    }

    private func tick(epoch mine: Int) {
        lock.lock()
        guard running, epoch == mine else { lock.unlock(); return }
        let cpu = takeSampleLocked()
        lock.unlock()
        report(cpuPercent: cpu, onlyIfEpoch: mine)
    }

    /// CPU over the time since the previous sample (or the start of the call), and the new baseline. `lock` held.
    private func takeSampleLocked() -> Int {
        let now = clock()
        let reading = cpuSeconds()
        defer { lastTime = now; lastCpu = reading }
        guard let cpu = reading, let previous = lastCpu else { return 0 }
        return CallResourceLine.percent(cpuSeconds: cpu - previous, wallSeconds: now - lastTime)
    }

    private func isCurrent(_ mine: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running && epoch == mine
    }

    /// Asks for the device values and prints the line when they arrive. A tick (`onlyIfEpoch` set) that arrives
    /// after its call ended prints nothing; the opening and closing lines always print.
    private func report(cpuPercent: Int, onlyIfEpoch expected: Int?) {
        let emit = self.emit
        readDevice { [weak self] device in
            if let expected {
                guard let self, self.isCurrent(expected) else { return }
            }
            emit(CallResourceLine.line(cpuPercent: cpuPercent, device: device))
        }
    }
}
