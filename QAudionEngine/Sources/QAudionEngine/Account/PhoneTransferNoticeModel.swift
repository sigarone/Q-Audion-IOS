import Combine
import Foundation

/// State behind the holder's banner for a pending phone-number transfer. The server is the source of
/// truth: every entry point (launch, return to the foreground, the WebSocket notice) calls `refresh()`,
/// which asks the server for the list and shows what it returns. The only action is cancelling.
///
/// Rules, each pinned by `PhoneTransferNoticeModelTests`:
///  - an empty list shows nothing;
///  - the device clock never removes an entry: whatever the server lists is shown, so a clock that runs
///    ahead cannot hide a live transfer from its holder;
///  - requests do not overlap: a `throttled` refresh (foreground, reconnect) asked while a request runs
///    shares it; one that must not be missed (the WebSocket notice, launch, retry, the read after a
///    cancel) queues ONE new request that starts after the running one ends, because the running one may
///    have started before the transfer existed. A request left over from before a `reset()` is never
///    shared: whoever asks after the reset gets a read of their own;
///  - `throttled` refreshes are skipped within `minRefreshInterval` of the last request that started,
///    measured on a clock that keeps counting while the device sleeps (`SleepAwareClock`), so the first
///    return to the foreground after a night asleep always reads. A rejected session keeps that threshold;
///    a `reset()` (another account, a lock, a wipe) clears it;
///  - nothing is read while the app is locked (`setLocked`), and the state is dropped when it locks;
///  - a 404 on the list hides the entry, with no message; a 404 on a cancel hides it too and the read that
///    follows decides whether it is still there; a cancel refused with another 4xx also reads the list
///    again, and the entry keeps the error only if it is still listed;
///  - any other failure keeps the entry and raises a neutral `problem`, so the action can be retried;
///    a failed list refresh with nothing on screen stays silent, since there is nothing to retry;
///  - a rejected session (`BCryptoError.unauthorized`) clears the state silently;
///  - a cancelled entry never comes back, even if a list request started before the cancel answers later;
///  - an answer that arrives after `reset()` (a list or a cancel) changes nothing, and a failed cancel can
///    only raise `.cancelFailed` for the entry still on screen; every successful read clears the problem;
///  - the cancel flag is set at the first tap (`requestCancel()` is synchronous) and stays up until the read
///    that follows the cancel has ended, so a second tap is ignored throughout;
///  - no error text, URL or transfer id is logged or kept: `problem` is a plain case.
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
    private let minRefreshInterval: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private var refreshGeneration = 0
    /// Bumped by `reset()` only: tells apart an answer that belongs to the account or session that left.
    private var epoch = 0
    private var inFlightEpoch = 0
    private var locked = false
    private var cancelledIds: Set<String> = []
    private var inFlight: Task<Void, Never>?
    private var rerunRequested = false
    private var lastStartedAt: TimeInterval?

    public init(
        api: PhoneTransferApi,
        minRefreshInterval: TimeInterval = 30,
        clock: @escaping @Sendable () -> TimeInterval = { SleepAwareClock.seconds() }
    ) {
        self.api = api
        self.minRefreshInterval = minRefreshInterval
        self.clock = clock
    }

    /// The entry to show: the one that expires first.
    public var current: PhoneTransferPending? {
        transfers.min { $0.expiresAt < $1.expiresAt }
    }

    /// Asks the server for the pending transfers and shows the result.
    public func refresh(throttled: Bool = false) async {
        guard !locked else { return }
        if let running = inFlight {
            // A request from before a reset belongs to someone else, and an unthrottled ask may be about
            // a transfer newer than the running request: both queue a request of their own.
            if !throttled || inFlightEpoch != epoch { rerunRequested = true }
            await running.value
            return
        }
        if throttled, let last = lastStartedAt, clock() - last < minRefreshInterval { return }
        inFlightEpoch = epoch
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRefreshes()
        }
        inFlight = task
        await task.value
    }

    /// The cancel button: the flag that disables it is set before this returns, so a second tap does
    /// nothing; the request itself runs in the background.
    public func requestCancel() {
        guard let target = beginCancel() else { return }
        Task { [weak self] in
            await self?.finishCancel(target)
        }
    }

    /// Cancels the entry on screen. On success (or a 404) the entry is hidden and the list is read
    /// again; on any other failure the entry stays and `problem` is `.cancelFailed` (after reading the
    /// list again when the cancel was refused).
    public func cancel() async {
        guard let target = beginCancel() else { return }
        await finishCancel(target)
    }

    /// The screen is locked (true) or unlocked (false). Locking drops the state; while locked nothing is
    /// read. The caller asks for a read after unlocking.
    public func setLocked(_ value: Bool) {
        locked = value
        if value { reset() }
    }

    /// Drops everything: sign-out, wipe, app lock, change of account. The next read is not held back.
    public func reset() {
        dropState()
        lastStartedAt = nil
    }

    /// Empties the state and disowns every request and cancel still running. Keeps the read threshold.
    private func dropState() {
        epoch += 1
        refreshGeneration += 1
        transfers = []
        problem = nil
        isCancelling = false
        cancelledIds = []
        rerunRequested = false
    }

    private func beginCancel() -> PhoneTransferPending? {
        guard !isCancelling, let target = current else { return nil }
        isCancelling = true
        problem = nil
        return target
    }

    private func finishCancel(_ target: PhoneTransferPending) async {
        let startedIn = epoch
        let outcome = await cancelOnServer(id: target.id)
        // The account or session that asked is gone: its answer changes nothing.
        guard startedIn == epoch else { return }
        // `isCancelling` stays up through the read that follows: a second tap would send a second cancel.
        switch outcome {
        case .cancelled:
            forget(id: target.id)
            await refresh()
        case .alreadyGone:
            hide(id: target.id)
            await refresh()
        case .rejected:
            await refresh()
            if startedIn == epoch, isListed(target.id) { problem = .cancelFailed }
        case .failed:
            if isListed(target.id) { problem = .cancelFailed }
        case .signedOut:
            dropState()
        }
        // A reset during the read already cleared the flag, and may have let a new session start its own.
        if startedIn == epoch { isCancelling = false }
    }

    private func isListed(_ id: String) -> Bool {
        transfers.contains { $0.id == id }
    }

    private func runRefreshes() async {
        repeat {
            rerunRequested = false
            inFlightEpoch = epoch
            lastStartedAt = clock()
            await loadOnce()
        } while rerunRequested
        inFlight = nil
    }

    private func loadOnce() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let list = try await api.fetchPending()
            guard generation == refreshGeneration else { return }
            transfers = list.filter { !cancelledIds.contains($0.id) }
            problem = nil
        } catch {
            guard generation == refreshGeneration else { return }
            if Self.isNotFound(error) {
                transfers = []
                problem = nil
            } else if Self.isSignedOut(error) {
                dropState()
            } else if !transfers.isEmpty {
                problem = .refreshFailed
            }
        }
    }

    private enum CancelOutcome {
        case cancelled
        case alreadyGone
        case rejected
        case failed
        case signedOut
    }

    private func cancelOnServer(id: String) async -> CancelOutcome {
        do {
            try await api.cancel(id: id)
            return .cancelled
        } catch {
            if Self.isNotFound(error) { return .alreadyGone }
            if Self.isSignedOut(error) { return .signedOut }
            if Self.isRefusal(error) { return .rejected }
            return .failed
        }
    }

    /// Takes `id` off the screen and invalidates any list request still in flight; the next read decides
    /// whether it comes back.
    private func hide(id: String) {
        refreshGeneration += 1
        transfers.removeAll { $0.id == id }
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

    /// A 4xx that says the request itself was refused (the transfer is no longer cancellable), as opposed
    /// to a failure that may pass: not a rejected session, not 404, not a timeout or a rate limit.
    private static func isRefusal(_ error: Error) -> Bool {
        guard let rest = error as? BCryptoError, case .httpError(let status) = rest else { return false }
        return (400..<500).contains(status) && ![401, 404, 408, 429].contains(status)
    }

    private static func isSignedOut(_ error: Error) -> Bool {
        guard let rest = error as? BCryptoError else { return false }
        if case .unauthorized = rest { return true }
        return false
    }
}

/// Seconds on a clock that keeps counting while the device sleeps (unlike `ProcessInfo.systemUptime`),
/// so an interval measured with it also spans a night with the phone locked.
public enum SleepAwareClock {
    private static let origin = ContinuousClock.now

    public static func seconds() -> TimeInterval {
        // `origin` first: its lazy initialisation must happen before `now` is read, never after it.
        let start = origin
        let elapsed = ContinuousClock.now - start
        return TimeInterval(elapsed.components.seconds) + TimeInterval(elapsed.components.attoseconds) / 1e18
    }
}
