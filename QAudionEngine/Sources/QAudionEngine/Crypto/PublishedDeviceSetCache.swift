import Foundation

/// Where the device ids the server currently publishes for a contact come from.
public protocol PublishedDeviceSource: Sendable {
    /// What the contact publishes, or nil when unknown (network failure, 404, no device ids). Never throws.
    func published(peerUserId: String) async -> PublishedDevices?
}

/// Short-lived per-peer cache of the server's published device set, used only to drop stale reinstall rows from the CONTACT shield
/// (`IdentityShieldRules.withoutStaleDevices`).
///
/// A success is kept `ttlMs` (10 minutes); a failure is remembered only `failureTtlMs` (60 seconds), so a dead network is not hammered
/// by every list refresh, and reads as unknown (every row counts). While a refresh is under way readers keep using `lastKnown`, so an
/// expiry never flips the shield to "every row counts"; and a refetch that returns an equal set changes nothing and announces nothing.
public final class PublishedDeviceSetCache: @unchecked Sendable {

    /// Posted when the set of a peer CHANGED (`userInfo["peerId"]`). An observer only records the peer and returns.
    public static let didChangeNotification = Notification.Name("qaudion.publishedDeviceSet.didChange")

    public static let ttlMs: Int64 = 10 * 60_000
    public static let failureTtlMs: Int64 = 60_000
    public static let fetchTimeoutMs: Int64 = 5_000

    private struct Entry {
        let value: PublishedDevices?
        let atMs: Int64
    }

    private enum Start {
        case cached(PublishedDevices?)
        case fetching(Task<PublishedDevices?, Never>)
    }

    private let source: PublishedDeviceSource
    private let nowMs: @Sendable () -> Int64
    private let announce: Bool
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<PublishedDevices?, Never>] = [:]

    /// `nowMs` must be a monotonic clock (the default is the process uptime): it only measures how old an entry is.
    public init(
        source: PublishedDeviceSource,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) },
        announceChanges: Bool = true
    ) {
        self.source = source
        self.nowMs = nowMs
        self.announce = announceChanges
    }

    /// The last set fetched for the peer, fresh or not (nil after a failed fetch or before any).
    public func lastKnown(peerUserId: String) -> PublishedDevices? {
        lock.lock(); defer { lock.unlock() }
        return entries[peerUserId]?.value
    }

    public func isFresh(peerUserId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[peerUserId] else { return false }
        return isFresh(e)
    }

    /// The set for the peer: from the cache while fresh, else fetched (bounded by `fetchTimeoutMs`); `force` skips the cache. One fetch
    /// per peer at a time: a second caller waits for the first.
    @discardableResult
    public func get(peerUserId: String, force: Bool = false) async -> PublishedDevices? {
        switch begin(peerUserId: peerUserId, force: force) {
        case .cached(let value):
            return value
        case .fetching(let task):
            return await task.value
        }
    }

    /// The locked, synchronous part of `get`: a fresh entry, a fetch already running, or a new fetch.
    private func begin(peerUserId: String, force: Bool) -> Start {
        lock.lock(); defer { lock.unlock() }
        if !force, let e = entries[peerUserId], isFresh(e) { return .cached(e.value) }
        if let running = inFlight[peerUserId] { return .fetching(running) }
        let source = self.source
        let timeout = Self.fetchTimeoutMs
        let task = Task { [weak self] () -> PublishedDevices? in
            let fetched: PublishedDevices?? = await Self.withTimeout(milliseconds: timeout) {
                await source.published(peerUserId: peerUserId)
            }
            let flat: PublishedDevices? = fetched ?? nil
            let value: PublishedDevices? = (flat?.deviceIds.isEmpty ?? true) ? nil : flat
            self?.finish(peerUserId: peerUserId, value: value)
            return value
        }
        inFlight[peerUserId] = task
        return .fetching(task)
    }

    private func finish(peerUserId: String, value: PublishedDevices?) {
        lock.lock()
        let old = entries[peerUserId]?.value
        entries[peerUserId] = Entry(value: value, atMs: nowMs())
        inFlight.removeValue(forKey: peerUserId)
        lock.unlock()
        if old != value && announce {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil, userInfo: ["peerId": peerUserId])
        }
    }

    private func isFresh(_ e: Entry) -> Bool {
        nowMs() - e.atMs < (e.value != nil ? Self.ttlMs : Self.failureTtlMs)
    }

    /// Runs `work`, returning nil when it does not finish within `milliseconds`.
    private static func withTimeout<T: Sendable>(milliseconds: Int64, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { Optional(await work()) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(milliseconds, 0)) * 1_000_000)
                return nil
            }
            let first: T?? = await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }
}
