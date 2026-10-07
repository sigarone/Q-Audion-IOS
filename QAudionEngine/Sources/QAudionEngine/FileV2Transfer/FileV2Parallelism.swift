import Foundation

/// A caller error in the numbers that configure the transfer layer (a negative memory, a negative cap). Not a protocol
/// condition and never a wire code.
public enum FileV2ConfigError: Error, Equatable, Sendable {
    case invalidArgument(String)
}

/// Memory budget of a transfer: `min(cap, memory / 6)`, with the cap at 6 x `FileV2Wire.partSize` (6 x 8 388 736 bytes,
/// the real part size), so that the server's `parallelism` of 6 fits on a roomy device and a smaller `memory / 6` is the
/// floor that lowers it. At most `floor(budget / (partSize + perWorkerExtraBytes))` parts are in memory at once, and at
/// least one: a transfer must always be able to move.
///
/// `perWorkerExtraBytes` is what each worker holds besides the sealed part, if the pipeline keeps it (for instance the
/// plaintext chunk, 1 MiB); the pipeline decides and passes it. `memoryMiB` is the memory the app may use, in MiB (on
/// iOS the available memory of the process), injected so the rule runs in a test.
public struct FileV2MemBudget: Sendable, Equatable {
    /// 6 x `FileV2Wire.partSize`.
    public static let defaultCapBytes: Int64 = 6 * Int64(FileV2Wire.partSize)

    public let budgetBytes: Int64
    public let maxParallelism: Int

    public init(memoryMiB: Int, capBytes: Int64 = FileV2MemBudget.defaultCapBytes,
                perWorkerExtraBytes: Int64 = 0) throws {
        guard memoryMiB >= 0 else { throw FileV2ConfigError.invalidArgument("memoryMiB") }
        guard capBytes >= 0 else { throw FileV2ConfigError.invalidArgument("capBytes") }
        guard perWorkerExtraBytes >= 0 else { throw FileV2ConfigError.invalidArgument("perWorkerExtraBytes") }

        let (bytes, overflow) = Int64(memoryMiB).multipliedReportingOverflow(by: 1 << 20)
        let sixth = (overflow ? Int64.max : bytes) / 6
        budgetBytes = min(capBytes, sixth)

        let (unit, unitOverflow) = Int64(FileV2Wire.partSize).addingReportingOverflow(perWorkerExtraBytes)
        let workers = budgetBytes / (unitOverflow ? Int64.max : unit)
        maxParallelism = max(1, workers > Int64(Int32.max) ? Int(Int32.max) : Int(workers))
    }
}

/// Retries of one part: backoff 1, 2, 4, 8 seconds plus jitter, `Retry-After` (with the same jitter, so many clients do
/// not come back together) when the server gives one, at most `maxAttempts` tries.
///
/// The rule for `Retry-After` is the same on the three platforms:
///
/// - up to `FileV2Wire.maxRetryAfterSeconds` (300) it is honoured, plus a jitter of at most 25 percent of the value, and the
///   TOTAL wait never exceeds `maxWaitMs` (300 000 ms), so a server that asks for the maximum is waited for exactly that;
/// - above 300 there is NO automatic wait: `nextDelayMs` returns `nil` (not the capped 300 s). The caller then pauses the
///   transfer or fails it with a reason the user sees; a server that asks for an hour is not hammered every five minutes, and
///   the user is not left with a transfer that looks alive and does nothing.
public struct FileV2RetryPolicy: Sendable {
    /// The longest single wait, in milliseconds: 300 seconds, jitter included.
    public static let maxWaitMs: Int64 = Int64(FileV2Wire.maxRetryAfterSeconds) * 1000

    public let maxAttempts: Int
    private let jitter: @Sendable (Int64) -> Int64

    /// `jitter` receives the base delay in milliseconds and returns the extra milliseconds, clamped here to `0...base/4`
    /// (at most 25 percent). The default is uniform in `0...base/4`.
    public init(maxAttempts: Int = 5, jitter: @escaping @Sendable (Int64) -> Int64 = FileV2RetryPolicy.defaultJitter) {
        self.maxAttempts = maxAttempts
        self.jitter = jitter
    }

    public static let defaultJitter: @Sendable (Int64) -> Int64 = { base in
        Int64.random(in: 0...max(0, base / 4))
    }

    /// The wait before the next try after `failedAttempts` failures (1-based), or `nil` when no automatic wait is allowed:
    /// the attempts are spent (the transfer then pauses with `network`, it does not fail), or `retryAfterSeconds` is above
    /// `FileV2Wire.maxRetryAfterSeconds` (the pipeline tells the two apart by comparing it with that constant, and pauses or
    /// fails with its reason). `retryAfterSeconds` from the server replaces the backoff base; a negative value is ignored.
    public func nextDelayMs(failedAttempts: Int, retryAfterSeconds: Int?) -> Int64? {
        guard failedAttempts < maxAttempts else { return nil }
        let base: Int64
        if let seconds = retryAfterSeconds, seconds >= 0 {
            if seconds > FileV2Wire.maxRetryAfterSeconds { return nil }
            base = Int64(seconds) * 1000
        } else {
            let shift = min(max(failedAttempts - 1, 0), 3)
            base = Int64(1000) << Int64(shift)
        }
        let extra = min(max(jitter(base), 0), base / 4)
        return min(base + extra, FileV2RetryPolicy.maxWaitMs)
    }
}

/// Numbers for telemetry (no ids, no names).
public struct FileV2ParallelismStats: Sendable, Equatable {
    public let finalParallelism: Int
    public let changes: Int
    public let meanGoodputBytesPerSecond: Double

    public init(finalParallelism: Int, changes: Int, meanGoodputBytesPerSecond: Double) {
        self.finalParallelism = finalParallelism
        self.changes = changes
        self.meanGoodputBytesPerSecond = meanGoodputBytesPerSecond
    }
}

/// Adaptive parallelism (design 2.3.1), pure: no clock, no threads, the caller passes the time.
///
/// The time is a DURATION clock: feed every `nowMs`, `startedMs` and `startMs` from `FileV2Clock.monotonicMs()`, never from
/// the wall clock (`nowMs()`): a wall clock that is set back during a transfer would make a window last 1 ms (a goodput of
/// 33 GB/s) or freeze the rule. As a second line of defence, a window that cannot be timed (it ends at or before its start)
/// is dropped without a measurement, and a change of P that lies in the future of the current time is brought back to it.
///
/// Start: `P0` from the server, ceiling = min(server `max_parallelism`, 8, memory budget, 3 on a metered network, the
/// direction cap: 4 for downloads). Every `window` completed parts the aggregate goodput of the window (bytes per second)
/// is measured. The rule "goodput at least 15 percent more at P+1 means P+1" is read as a probe: the first window is the
/// baseline, the next one runs at P+1; it is kept (and the next probe started) when its goodput is at least 15 percent
/// above the baseline, otherwise P goes back and stays for `holdWindows` (4) windows before the next probe. Any part error
/// halves P (minimum 1) and restarts the measurement.
///
/// One halving per window (debounce): a network drop fails every part in flight at once, and that must cost one halving,
/// not a collapse from 6 to 1. The caller passes the start time of each part: a part that STARTED before the last change
/// of P says nothing about the current P, so its failure does not halve again and its completion is not counted in the
/// probe window.
///
/// Not thread-safe: the caller serialises the calls (one actor, one lock). A value type, so a copy is a snapshot.
///
/// Per-part timeouts (for the HTTP client): see `FileV2PartTimeout`.
public struct FileV2AdaptiveParallelism: Sendable {
    public static let window = 4
    public static let gain = 1.15
    public static let holdWindows = 4
    /// Never more than 8 parts in flight, whatever the server says.
    public static let hardCeiling = 8
    /// The ceiling on a metered network (cellular with data saver, a hotspot).
    public static let meteredCeiling = 3
    /// The ceiling of a download: the receiver holds parts in memory and the server paces it.
    public static let downloadCeiling = 4

    public let ceiling: Int
    public private(set) var current: Int
    public private(set) var changes = 0

    private enum Phase { case measure, probe, hold }

    private var phase = Phase.measure
    private var holdCount = 0
    private var baseline = 0.0
    private var windowStartMs: Int64
    private var lastChangeMs: Int64
    private var windowBytes: Int64 = 0
    private var windowParts = 0
    private var goodputSum = 0.0
    private var goodputWindows = 0

    public init(serverParallelism: Int, serverMaxParallelism: Int, memoryCap: Int, metered: Bool = false,
                directionCap: Int = FileV2AdaptiveParallelism.hardCeiling, startMs: Int64) {
        let meteredCap = metered ? FileV2AdaptiveParallelism.meteredCeiling : Int.max
        let ceiling = max(1, min(serverMaxParallelism, FileV2AdaptiveParallelism.hardCeiling, memoryCap, directionCap, meteredCap))
        self.ceiling = ceiling
        self.current = min(max(serverParallelism, 1), ceiling)
        self.windowStartMs = startMs
        self.lastChangeMs = startMs
    }

    /// A part completed; `startedMs` is when it was started.
    public mutating func onPartDone(bytes: Int64, nowMs: Int64, startedMs: Int64) {
        if lastChangeMs > nowMs { lastChangeMs = nowMs }   // the clock went back: a change cannot be in the future
        if startedMs < lastChangeMs { return }     // started under another P: not a sample of the current one
        let (sum, overflow) = windowBytes.addingReportingOverflow(max(0, bytes))
        windowBytes = overflow ? Int64.max : sum
        windowParts += 1
        if windowParts < FileV2AdaptiveParallelism.window { return }
        let (elapsed, elapsedOverflow) = nowMs.subtractingReportingOverflow(windowStartMs)
        if elapsedOverflow || elapsed <= 0 {
            // a window that ends at or before its start cannot be timed (a clock that stood still or went back): no
            // measurement, no change of P; the next window starts now
            windowStartMs = nowMs
            windowBytes = 0
            windowParts = 0
            return
        }
        let goodput = Double(windowBytes) * 1000.0 / Double(elapsed)
        goodputSum += goodput
        goodputWindows += 1
        windowStartMs = nowMs
        windowBytes = 0
        windowParts = 0
        switch phase {
        case .measure:
            baseline = goodput
            probe(nowMs)
        case .probe:
            if goodput >= baseline * FileV2AdaptiveParallelism.gain {
                baseline = goodput
                probe(nowMs)
            } else {
                move(current - 1, nowMs)
                phase = .hold
                holdCount = 0
            }
        case .hold:
            baseline = goodput
            holdCount += 1
            if holdCount >= FileV2AdaptiveParallelism.holdWindows { probe(nowMs) }
        }
    }

    /// A part failed (timeout, 5xx, 429, I/O error); `startedMs` is when it was started.
    public mutating func onPartFailed(nowMs: Int64, startedMs: Int64) {
        if lastChangeMs > nowMs { lastChangeMs = nowMs }   // the clock went back: a change cannot be in the future
        if startedMs < lastChangeMs { return }     // one halving per window: this part was already in flight at the last change
        move(max(1, current / 2), nowMs)
        phase = .measure
        windowStartMs = nowMs
        windowBytes = 0
        windowParts = 0
    }

    public func stats() -> FileV2ParallelismStats {
        FileV2ParallelismStats(finalParallelism: current, changes: changes,
                               meanGoodputBytesPerSecond: goodputWindows == 0 ? 0.0 : goodputSum / Double(goodputWindows))
    }

    private mutating func probe(_ nowMs: Int64) {
        if current < ceiling {
            move(current + 1, nowMs)
            phase = .probe
        } else {
            phase = .hold
            holdCount = 0
        }
    }

    private mutating func move(_ target: Int, _ nowMs: Int64) {
        if target != current {
            current = target
            lastChangeMs = nowMs
            changes += 1
        }
    }
}

/// What the HTTP client of a part must know about time (the numbers are the server's: `FILES_V2_PARTS_PROTOCOL.md`).
///
/// The server cuts a part body that stalls below 8000 bytes per second for a whole 30-second window, so the slowest part
/// it still accepts, 8 MiB at the floor, takes about 17.5 minutes. A fixed total timeout shorter than that would cancel a
/// legitimate upload on a slow network; the timeout of a part is therefore an IDLE deadline that slides while bytes move
/// (`FileV2ProgressDeadline`), and a total time limit, if there is one, must not be below `slowestLegitimateSeconds`.
public enum FileV2PartTimeout {
    /// The slowest rate the server still accepts, in bytes per second (64 kbit/s).
    public static let serverFloorBytesPerSecond: Int = 8000
    /// The window below the floor rate after which the server cuts the body, in seconds.
    public static let serverGraceSeconds: Int = 30
    /// `ceil(partSize / serverFloorBytesPerSecond)`: 1049 seconds, 17.5 minutes.
    public static let slowestLegitimateSeconds: Int =
        (FileV2Wire.partSize + serverFloorBytesPerSecond - 1) / serverFloorBytesPerSecond
}

/// A deadline that slides while the transfer moves: expired when no byte has moved for `idleLimitMs`. Pure: the caller
/// passes the time (from `FileV2Clock.monotonicMs()`, like every duration), and serialises the calls.
public struct FileV2ProgressDeadline: Sendable, Equatable {
    public let idleLimitMs: Int64
    private var lastProgressMs: Int64

    public init(idleLimitMs: Int64, startMs: Int64) {
        self.idleLimitMs = max(1, idleLimitMs)
        self.lastProgressMs = startMs
    }

    /// `bytes` moved at `nowMs`: the deadline slides. Nothing moved (`bytes` 0 or less) changes nothing.
    public mutating func progress(bytes: Int, nowMs: Int64) {
        if bytes > 0 && nowMs > lastProgressMs { lastProgressMs = nowMs }
    }

    /// True when no byte has moved for `idleLimitMs`.
    public func isExpired(nowMs: Int64) -> Bool {
        let (idle, overflow) = nowMs.subtractingReportingOverflow(lastProgressMs)
        return overflow ? nowMs > lastProgressMs : idle >= idleLimitMs
    }

    /// The instant at which the deadline expires if nothing moves from now on.
    public var expiresAtMs: Int64 {
        let (instant, overflow) = lastProgressMs.addingReportingOverflow(idleLimitMs)
        return overflow ? Int64.max : instant
    }
}
