import Foundation

/// The chunk the log shipper is currently trying to get to the server, kept as one fixed payload until the
/// server confirms it. Retrying the SAME bytes under the SAME file name (instead of rebuilding a chunk from
/// the backlog each time) is what lets a cut-short upload be continued from the server's offset, and keeps a
/// retry from creating a second copy of lines the server already holds.
///
/// Pure value type: no clock, no I/O. The owner (the shipper's worker actor) is the only writer.
public struct LiveLogUploadState: Equatable, Sendable {

    public struct Pending: Equatable, Sendable {
        public let filename: String
        public let data: Data
        /// Highest ring sequence number the payload contains: the cursor to confirm.
        public let lastSeq: Int64
        /// The upload created for this payload on the server, once an attempt got that far.
        public fileprivate(set) var fileId: String?
        public fileprivate(set) var attempts: Int
    }

    public enum FailureOutcome: Equatable, Sendable {
        /// Keep the payload; the next attempt continues it.
        case retrySame
        /// The server refuses this payload for good (malformed or too large): give it up so the queue moves on.
        case discard
    }

    public private(set) var pending: Pending?

    public init() {}

    public var hasPending: Bool { return pending != nil }

    /// Fix a new payload as the pending one. Ignored while another is still waiting for its confirmation.
    public mutating func start(filename: String, data: Data, lastSeq: Int64) {
        guard pending == nil else { return }
        pending = Pending(filename: filename, data: data, lastSeq: lastSeq, fileId: nil, attempts: 0)
    }

    /// Put back a payload that was saved before a restart. Ignored while another one is pending.
    public mutating func restore(filename: String, data: Data, lastSeq: Int64, fileId: String?) {
        guard pending == nil else { return }
        pending = Pending(filename: filename, data: data, lastSeq: lastSeq, fileId: fileId, attempts: 0)
    }

    /// The payload for the next attempt (the same one every time until it is confirmed or given up), with the
    /// attempt counted. Nil when nothing is pending.
    public mutating func nextAttempt() -> Pending? {
        guard pending != nil else { return nil }
        pending?.attempts += 1
        return pending
    }

    /// An attempt created (or found) the server-side upload: later attempts continue it.
    public mutating func noteFileId(_ fileId: String) {
        pending?.fileId = fileId
    }

    /// The upload the server holds is gone or does not match: the next attempt creates a new one.
    public mutating func forgetFileId() {
        pending?.fileId = nil
    }

    /// An attempt failed with `status` (nil for a network error or a timeout).
    @discardableResult
    public mutating func noteFailure(status: Int?) -> FailureOutcome {
        if let code = status, UploadRetryPolicy.rejectedStatuses.contains(code) {
            pending = nil
            return .discard
        }
        return .retrySame
    }

    /// The server confirmed everything up to `seq`. Returns true when that settled the pending payload.
    @discardableResult
    public mutating func confirm(throughSeq seq: Int64) -> Bool {
        guard let current = pending, current.lastSeq <= seq else { return false }
        pending = nil
        return true
    }

    /// Consent withdrawn or the run stopped: nothing is kept.
    public mutating func reset() {
        pending = nil
    }
}
