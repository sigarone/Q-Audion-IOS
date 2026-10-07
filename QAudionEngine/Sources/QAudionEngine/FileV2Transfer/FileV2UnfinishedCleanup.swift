import Foundation

/// The cleanup of the account's leftover unfinished objects: the ones a send that died with its app left behind.
///
/// Every unfinished object counts against the account's quota and its 10 slots until it is deleted or the server's own cleanup
/// removes it (6 hours after its last part, 24 hours after its creation): a send that was killed half way would otherwise keep
/// both for hours.
///
/// An unfinished object is NOT necessarily a leftover: it may be the live upload of another device of the same account. So only
/// the objects that have seen no part for `leftoverIdleMs` are deleted, one by one, never the bulk route; a younger one waits for
/// the server's own retention. The activity time is the server's clock and the comparison uses ours, so the margin is wide on
/// purpose (the same rule as the Desktop and Android clients). The routes need no entitlement, only ever concern the caller's own
/// objects, and never touch a completed object, so a file already announced to a recipient is not affected.
public enum FileV2UnfinishedCleanup {

    /// An unfinished object idle for at least this long is a leftover.
    public static let leftoverIdleMs: Int64 = 30 * 60_000
    /// Pages of the list read at most: an account holds at most 10 unfinished objects, so one page is normal.
    public static let maxPages = 5
    static let pageSize = 100

    /// Lists the account's unfinished objects and deletes, one by one, those idle for `leftoverIdleMs` or more. Returns how many were
    /// deleted (0 when there was nothing to do). Best effort: a failure of the list or of a delete (after the retries of the transfer
    /// base) stops the cleanup and returns what was deleted so far, the server's own cleanup is the safety net; an object that is
    /// already gone (404) is skipped. Only the cancellation of the task is thrown.
    public static func run(server: FileV2Server, clock: FileV2Clock = FileV2SystemClock(),
                           policy: FileV2RetryPolicy = FileV2RetryPolicy(),
                           sleep: @Sendable (Int64) async throws -> Void = FileV2Retry.realSleep) async throws -> Int {
        var deleted = 0
        var cursor: String?
        do {
            for _ in 0..<maxPages {
                let after = cursor
                let page = try await FileV2Retry.run(op: .listUnfinished, policy: policy, sleep: sleep) {
                    try await server.listUnfinished(limit: pageSize, after: after)
                }
                for item in page.objects where clock.nowMs() - item.activityMs >= leftoverIdleMs {
                    do {
                        try await FileV2Retry.run(op: .delete, policy: policy, sleep: sleep) {
                            try await server.delete(obj: item.obj)
                        }
                        deleted += 1
                    } catch let failure as FileV2Failure where failure.server?.status == 404 {
                        continue    // already gone (the server's own cleanup, or another run): nothing to delete
                    }
                }
                guard let next = page.next else { break }
                cursor = next
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return deleted
        }
        return deleted
    }
}
