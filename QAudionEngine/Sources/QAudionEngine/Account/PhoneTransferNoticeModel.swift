import Combine
import Foundation

/// State behind the holder's banner for a pending phone-number transfer. The server is the source of
/// truth: every entry point (launch, return to the foreground, the WebSocket notice) calls `refresh()`,
/// which asks the server for the list and shows what it returns. The only action is `cancel()`.
///
/// Rules, each pinned by `PhoneTransferNoticeModelTests`:
///  - an empty list, or only expired entries, shows nothing;
///  - a 404 on the list or on a cancel hides the entry, with no message;
///  - any other failure keeps the entry and raises a neutral `problem`, so the action can be retried;
///    a failed list refresh with nothing on screen stays silent, since there is nothing to retry;
///  - a rejected session (`BCryptoError.unauthorized`) clears the state silently;
///  - a cancelled entry never comes back, even if a list request started before the cancel answers later.
@MainActor
public final class PhoneTransferNoticeModel: ObservableObject {
    public enum Problem: Equatable, Sendable {
        case refreshFailed
        case cancelFailed
    }

    @Published public private(set) var transfers: [PhoneTransferPending] = []
    @Published public private(set) var problem: Problem?
    @Published public private(set) var isCancelling = false

    private let api: PhoneTransferApi
    private let now: @Sendable () -> Date
    private var refreshGeneration = 0
    private var cancelledIds: Set<String> = []

    public init(api: PhoneTransferApi, now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.now = now
    }

    /// The entry to show at `date`: the one that expires first among those not yet expired.
    public func current(at date: Date) -> PhoneTransferPending? {
        transfers
            .filter { !$0.isExpired(at: date) }
            .min { $0.expiresAt < $1.expiresAt }
    }

    /// Asks the server for the pending transfers and shows the result.
    public func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let list = try await api.fetchPending()
            guard generation == refreshGeneration else { return }
            let reference = now()
            transfers = list.filter { !$0.isExpired(at: reference) && !cancelledIds.contains($0.id) }
            if problem == .refreshFailed { problem = nil }
        } catch {
            guard generation == refreshGeneration else { return }
            if Self.isNotFound(error) {
                transfers = []
                if problem == .refreshFailed { problem = nil }
            } else if Self.isSignedOut(error) {
                reset()
            } else if !transfers.isEmpty {
                problem = .refreshFailed
            }
        }
    }

    /// Cancels the entry on screen. On success (or a 404) the entry is hidden and the list is read
    /// again; on any other failure the entry stays and `problem` is `.cancelFailed`.
    public func cancel() async {
        guard !isCancelling, let target = current(at: now()) else { return }
        isCancelling = true
        problem = nil
        let outcome = await cancelOnServer(id: target.id)
        isCancelling = false
        switch outcome {
        case .gone:
            forget(id: target.id)
            await refresh()
        case .failed:
            problem = .cancelFailed
        case .signedOut:
            reset()
        }
    }

    /// Drops everything: called when the signed-in account changes.
    public func reset() {
        refreshGeneration += 1
        transfers = []
        problem = nil
        cancelledIds = []
    }

    private enum CancelOutcome {
        case gone
        case failed
        case signedOut
    }

    private func cancelOnServer(id: String) async -> CancelOutcome {
        do {
            try await api.cancel(id: id)
            return .gone
        } catch {
            if Self.isNotFound(error) { return .gone }
            if Self.isSignedOut(error) { return .signedOut }
            return .failed
        }
    }

    /// Hides `id` for good and invalidates any list request still in flight.
    private func forget(id: String) {
        refreshGeneration += 1
        cancelledIds.insert(id)
        transfers.removeAll { $0.id == id }
    }

    private static func isNotFound(_ error: Error) -> Bool {
        guard let rest = error as? BCryptoError else { return false }
        switch rest {
        case .notFound: return true
        case .httpError(let status): return status == 404
        default: return false
        }
    }

    private static func isSignedOut(_ error: Error) -> Bool {
        guard let rest = error as? BCryptoError else { return false }
        if case .unauthorized = rest { return true }
        return false
    }
}
