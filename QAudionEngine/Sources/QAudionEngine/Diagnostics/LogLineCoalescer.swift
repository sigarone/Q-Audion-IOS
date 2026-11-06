import Foundation

/// Collapses runs of identical log lines before they are shipped. A line that repeats (same level, tag and
/// message) IMMEDIATELY after its twin, within `window` seconds of the first line of the run, is not shipped
/// again: the first line goes out once with " (xN)" appended, N being the size of the run. Only adjacent
/// lines merge (a, a becomes "a (x2)"; a, b, a stays three lines), so the shipped order is exactly the
/// original order.
///
/// Pure function over one batch: no clock, no state between batches. A run keeps the sequence number of its
/// LAST line, so the output stays ascending and a confirmation keyed by sequence number covers every line
/// the run replaced.
public enum LogLineCoalescer {

    public static let windowSeconds: TimeInterval = 1.0

    public struct Input: Equatable, Sendable {
        public let seq: Int64
        public let timestamp: Date
        public let level: String
        public let tag: String
        public let message: String
        public let disposable: Bool

        public init(seq: Int64, timestamp: Date, level: String, tag: String, message: String, disposable: Bool = false) {
            self.seq = seq
            self.timestamp = timestamp
            self.level = level
            self.tag = tag
            self.message = message
            self.disposable = disposable
        }
    }

    public struct Output: Equatable, Sendable {
        /// Sequence number of the last line the entry stands for.
        public let seq: Int64
        public let timestamp: Date
        public let level: String
        public let tag: String
        public let message: String
        public let disposable: Bool
        /// How many original lines the entry stands for (1 when nothing was collapsed).
        public let count: Int
    }

    private struct Run {
        let first: Input
        var lastSeq: Int64
        var count: Int
    }

    public static func coalesce(_ inputs: [Input], window: TimeInterval = LogLineCoalescer.windowSeconds) -> [Output] {
        var runs: [Run] = []
        var lastKey: String?
        for input in inputs {
            var key: String = input.level
            key += "\u{1}"
            key += input.tag
            key += "\u{1}"
            key += input.message
            if key == lastKey, let index = runs.indices.last,
               input.timestamp.timeIntervalSince(runs[index].first.timestamp) < window {
                runs[index].count += 1
                runs[index].lastSeq = input.seq
            } else {
                lastKey = key
                runs.append(Run(first: input, lastSeq: input.seq, count: 1))
            }
        }
        return runs.map { (run: Run) -> Output in
            var message: String = run.first.message
            if run.count > 1 {
                message += " (x"
                message += String(run.count)
                message += ")"
            }
            return Output(seq: run.lastSeq, timestamp: run.first.timestamp, level: run.first.level,
                          tag: run.first.tag, message: message, disposable: run.first.disposable, count: run.count)
        }
    }
}
