import Foundation

/// CPU time used by this process so far, user plus system, summed over all its threads.
///
/// `getrusage(RUSAGE_SELF)` and not `task_info`: one call, no Mach port or thread list to walk, and its total
/// already covers the live threads (the ONNX Runtime pools included) as well as the ones that have exited. It is
/// the quantity the system's background CPU limit is about (CPU seconds of the process over a wall-clock
/// window), so the governor compares like with like. Costs a few microseconds.
enum ProcessCpu {
    static func seconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}

/// Thins out one periodic check while the app is in the background and the process is using too much CPU.
///
/// Why: the system ends a background app that averages too much CPU over a minute (80% of one core over 60 s).
/// The contact-voice check and the Tier 1 deepfake check are the heaviest recurring work of a call, so when the
/// process-wide average gets near half of that limit they run less often, until the load comes down.
///
/// What it does, per decision (one per scheduled tick, asked before the work):
/// - In the foreground it never acts and never measures: it always says "run". The flag is read at every
///   decision.
/// - In the background it keeps the (time, process CPU) samples of the current background stretch and
///   computes the average CPU, in cores, over the last `horizonSeconds`. It judges only once the stretch has
///   `minSpanSeconds` of history, so a single heavy tick at the start of a stretch cannot trip it.
/// - Hysteresis: it starts holding checks back when the average is above `highCores`, and stops only when it is
///   below `lowCores`, so a load hovering around one value does not make it flip on every tick.
/// - A floor: even while holding back, a check is let through when `floorSeconds` have passed since the last
///   one that ran. The check is thinned, never turned off.
///
/// What it costs: while holding back, a check runs at most once per `floorSeconds`, and what the check reports
/// needs several consecutive results (a suspect voice after about 2 samples, a changed one after about 4, a
/// reference learnt over 16: `SpeakerChangeDetector`) takes that many floors: of the order of 1 min, 2 min and
/// 8 min at the standard 30 s floor, against 6 s, 12 s and 48 s in the foreground.
///
/// What it does NOT do: it holds back whole checks only. It does not change what a check computes, the models,
/// the thresholds or the verdicts, and a held check delivers nothing, so the caller's last score and any run of
/// consecutive results stay exactly as they were. It does not look at which part of the process is using the CPU.
///
/// Each check owns its own instance (the measurement is process-wide, the decision and the floor are per check).
/// Thread-safe.
final class BackgroundCpuGovernor: @unchecked Sendable {
    typealias Clock = @Sendable () -> Double
    typealias CpuMeter = @Sendable () -> Double?

    struct Config: Equatable {
        /// Length of the averaging window.
        var horizonSeconds: Double
        /// Least history (within the current background stretch) before the average is trusted.
        var minSpanSeconds: Double
        /// Average CPU, in cores, above which checks are held back.
        var highCores: Double
        /// Average CPU, in cores, below which they resume. Lower than `highCores`.
        var lowCores: Double
        /// While holding back, a check still runs at least this often.
        var floorSeconds: Double
        /// A summary is due after this much background time, besides at every change of state.
        var summarySeconds: Double

        /// 0.50 core is half of the system limit (0.80 core over 60 s), 0.40 core leaves a 0.10 core band for the
        /// hysteresis; 30 s is the window the limit's minute is judged on in practice; 20 s of history before the
        /// first judgement; a check at least every 30 s.
        static let standard = Config(
            horizonSeconds: 30, minSpanSeconds: 20, highCores: 0.50, lowCores: 0.40,
            floorSeconds: 30, summarySeconds: 30)
    }

    /// What happened since the previous summary. `cpuPercent` is the last measured average, as a percentage of ONE
    /// core (it can pass 100 on a multi-threaded process).
    struct Summary: Equatable {
        let background: Bool
        let cpuPercent: Int
        let ran: Int
        let skipped: Int
        /// True while checks are being held back (in the closing summary of a background stretch: whether they were
        /// when it ended).
        let high: Bool

        /// "[Voice] bg=1 every=10 cpu=42 skip=3 run=2 high=0". Whole numbers and words the phone-log shipper
        /// already admits (scripts/test_ship_ios_display_vocab.py pins this shape: keep both in sync).
        func logLine(label: String, everySeconds: Double? = nil) -> String {
            var line = "[\(label)] bg=\(background ? 1 : 0)"
            if let everySeconds { line += " every=\(Int(everySeconds.rounded()))" }
            line += " cpu=\(cpuPercent) skip=\(skipped) run=\(ran) high=\(high ? 1 : 0)"
            return line
        }
    }

    struct Decision: Equatable {
        let run: Bool
        let summary: Summary?
        static let proceed = Decision(run: true, summary: nil)
    }

    /// Counts since this governor was built, for tests and diagnostics.
    struct Totals: Equatable {
        var ran = 0
        var skipped = 0
    }

    static let uptimeSeconds: Clock = { ProcessInfo.processInfo.systemUptime }

    private struct Sample {
        let time: Double
        let cpu: Double
    }

    private let config: Config
    private let flag: AppBackgroundFlag
    private let clock: Clock
    private let cpuSeconds: CpuMeter
    private let lock = NSLock()

    private var episodeOpen = false
    private var episodeEntries = -1
    private var samples: [Sample] = []
    private var high = false
    private var lastAverage: Double?
    private var lastRunAt: Double?
    private var lastSummaryAt = 0.0
    private var ran = 0
    private var skipped = 0
    private var allTime = Totals()

    init(
        config: Config = .standard,
        flag: AppBackgroundFlag = .shared,
        clock: @escaping Clock = BackgroundCpuGovernor.uptimeSeconds,
        cpuSeconds: @escaping CpuMeter = { ProcessCpu.seconds() }
    ) {
        self.config = config
        self.flag = flag
        self.clock = clock
        self.cpuSeconds = cpuSeconds
    }

    var totals: Totals { lock.lock(); defer { lock.unlock() }; return allTime }

    /// True while checks are being held back.
    var isHoldingBack: Bool { lock.lock(); defer { lock.unlock() }; return high }

    /// Asked once per scheduled tick, before its work. `run == false`: skip the tick entirely and keep the last
    /// result. `summary`, when present, is to be logged by the caller.
    func decide() -> Decision {
        let background = flag.isInBackground
        let entries = flag.backgroundEntryCount
        lock.lock(); defer { lock.unlock() }

        // Never acts in the foreground. A background stretch that just ended is closed with one summary.
        guard background else { return Decision(run: true, summary: closeEpisodeLocked()) }

        let now = clock()
        if !episodeOpen || entries != episodeEntries { openEpisodeLocked(entries: entries, now: now) }

        var transitioned = false
        if let cpu = cpuSeconds() {
            if let last = samples.last, now < last.time { samples.removeAll() }
            samples.append(Sample(time: now, cpu: cpu))
            // Keep one sample at or before the start of the window, so the span reaches back to it.
            while samples.count >= 2 && samples[1].time <= now - config.horizonSeconds {
                samples.removeFirst()
            }
            if let oldest = samples.first, now - oldest.time > 0, now - oldest.time >= config.minSpanSeconds {
                let average = max(0, (cpu - oldest.cpu) / (now - oldest.time))
                lastAverage = average
                if high {
                    if average < config.lowCores { high = false; transitioned = true }
                } else if average > config.highCores {
                    high = true
                    transitioned = true
                }
            }
        } else {
            // No reading: the history is no longer continuous, so it starts again once readings come back.
            samples.removeAll()
        }
        // Not measurable (or too little history): no judgement, the check runs.

        var run = true
        if high, let last = lastRunAt, now - last < config.floorSeconds { run = false }
        if run {
            lastRunAt = now
            ran += 1
            allTime.ran += 1
        } else {
            skipped += 1
            allTime.skipped += 1
        }

        var summary: Summary?
        if transitioned || now - lastSummaryAt >= config.summarySeconds, let average = lastAverage {
            summary = Summary(
                background: true, cpuPercent: Self.percent(average), ran: ran, skipped: skipped, high: high)
            lastSummaryAt = now
            ran = 0
            skipped = 0
        }
        return Decision(run: run, summary: summary)
    }

    private func openEpisodeLocked(entries: Int, now: Double) {
        episodeOpen = true
        episodeEntries = entries
        samples.removeAll()
        high = false
        lastAverage = nil
        lastRunAt = nil
        lastSummaryAt = now
        ran = 0
        skipped = 0
    }

    private func closeEpisodeLocked() -> Summary? {
        guard episodeOpen else { return nil }
        episodeOpen = false
        let summary: Summary?
        if let average = lastAverage, ran + skipped > 0 {
            summary = Summary(
                background: false, cpuPercent: Self.percent(average), ran: ran, skipped: skipped, high: high)
        } else {
            summary = nil
        }
        samples.removeAll()
        high = false
        lastAverage = nil
        ran = 0
        skipped = 0
        return summary
    }

    private static func percent(_ cores: Double) -> Int {
        Int(min(9999, max(0, (cores * 100).rounded())))
    }
}
