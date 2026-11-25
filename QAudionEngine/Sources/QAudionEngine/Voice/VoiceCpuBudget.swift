import Foundation

/// `VoiceCpuBudget`: ONE object for the process. It keeps the busy intervals that the components report (the contact engine's
/// own are the window embeddings and the VAD calls; the owner continuity monitor and the call integrity monitor report theirs
/// from their own threads). `total` is the busy time inside `(now - window, now]` with every interval clipped to it, and a
/// window may start only while it is below `limitNs`, which is `budget_total_core x window_s` rounded to a whole nanosecond.
///
/// Thread safe: `add` may come from any thread (the reporting components), `total` and `room` are read by the engine's worker.
/// An interval that ended more than two windows before the latest reading is forgotten: no reading at or after that instant can
/// change, and the margin of one more window covers a reading that a worker makes a little behind its own latest one. Times
/// are on the tap clock (nanoseconds, one clock for every reporter).
final class VoiceCpuBudget: @unchecked Sendable {
    private static let nsPerSecond: Int64 = 1_000_000_000

    private let windowNs: Int64
    let limitNs: Int64
    private let lock = NSLock()
    private var starts: [Int64] = []
    private var ends: [Int64] = []
    private var latest: Int64?
    /// The size at which the next pruning is tried; it doubles when a pruning frees little.
    private var pruneAt = 256

    init(cpu: VoiceCpuConstants) {
        windowNs = Int64(cpu.windowS) * Self.nsPerSecond
        limitNs = Int64((cpu.budgetTotalCore * Double(cpu.windowS) * Double(Self.nsPerSecond)).rounded())
        starts.reserveCapacity(256)
        ends.reserveCapacity(256)
    }

    /// A busy interval `[startNs, endNs)` of `who` (a label for the logs; the budget does not tell the components apart).
    func add(who: String, startNs: Int64, endNs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if starts.count >= pruneAt {
            prune()
            pruneAt = max(256, 2 * starts.count)
        }
        starts.append(startNs)
        ends.append(endNs)
    }

    /// The busy time inside `(now - window, now]`.
    func total(_ nowNs: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        if let seen = latest {
            latest = max(seen, nowNs)
        } else {
            latest = nowNs
        }
        let lo = nowNs - windowNs
        var t: Int64 = 0
        for i in 0..<starts.count {
            let d = min(ends[i], nowNs) - max(starts[i], lo)
            if d > 0 {
                t += d
            }
        }
        return t
    }

    /// True while a window may start at `nowNs`.
    func room(_ nowNs: Int64) -> Bool {
        total(nowNs) < limitNs
    }

    private func prune() {
        guard let seen = latest else { return }
        let cut = seen - 2 * windowNs
        var keptStarts: [Int64] = []
        var keptEnds: [Int64] = []
        keptStarts.reserveCapacity(starts.count)
        keptEnds.reserveCapacity(ends.count)
        for i in 0..<starts.count where ends[i] > cut {
            keptStarts.append(starts[i])
            keptEnds.append(ends[i])
        }
        starts = keptStarts
        ends = keptEnds
    }
}
