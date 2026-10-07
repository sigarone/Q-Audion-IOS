import Foundation

/// The cleanup of the account's unfinished objects, for the first call after a login (the app never remembers a transfer
/// across a restart, so every unfinished object it finds at start belongs to a transfer that is over).
///
/// Every unfinished object counts against the account's quota and its 10 slots until it is deleted or the server's cleanup
/// removes it (6 hours after its last part, 24 hours after its creation): a send that was killed half way would otherwise
/// keep both for hours. The routes need no entitlement, they only ever concern the caller's own objects, and they never touch
/// a completed object, so a file already announced to a recipient is not affected.
public enum FileV2UnfinishedCleanup {

    /// Lists the account's unfinished objects and, when there are any, deletes them all. Returns how many were deleted (0 when
    /// there was nothing). The two requests follow the retry rules of the transfer base; a failure is thrown as `FileV2Failure`
    /// and is the caller's to ignore (the cleanup is best effort and runs again at the next start).
    public static func run(server: FileV2Server, policy: FileV2RetryPolicy = FileV2RetryPolicy(),
                           sleep: @Sendable (Int64) async throws -> Void = FileV2Retry.realSleep) async throws -> Int {
        let page = try await FileV2Retry.run(op: .listUnfinished, policy: policy, sleep: sleep) {
            try await server.listUnfinished(limit: 100, after: nil)
        }
        guard !page.objects.isEmpty else { return 0 }
        let result = try await FileV2Retry.run(op: .deleteUnfinished, policy: policy, sleep: sleep) {
            try await server.deleteUnfinished()
        }
        return result.deleted
    }
}
