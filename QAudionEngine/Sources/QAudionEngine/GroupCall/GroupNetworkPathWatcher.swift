import Foundation
import Network

/// Group calls v2 (spec §4.7) — what counts as a network change worth an ICE
/// restart of both PeerConnections. `NWPathMonitor` repeats the same path
/// routinely; only a genuine edge may restart ICE (the same storm lesson the
/// signaling socket already learned): the path coming back after an outage, or
/// the interface in use changing (Wi-Fi <-> cellular, a VPN toggling).
public enum GroupNetworkPathPolicy {

    public struct Snapshot: Equatable, Sendable {
        public let satisfied: Bool
        /// "wifi" | "cellular" | "wired" | "other" | "none"
        public let interface: String

        public init(satisfied: Bool, interface: String) {
            self.satisfied = satisfied
            self.interface = interface
        }
    }

    /// The short reason code for `group.ice_restart` telemetry, or nil when
    /// nothing worth restarting happened. The very first sample (`previous ==
    /// nil`) never restarts: it is just the monitor reporting where we are.
    public static func changeReason(previous: Snapshot?, current: Snapshot) -> String? {
        guard let previous = previous else { return nil }
        if !current.satisfied { return nil }
        if !previous.satisfied { return "path_restored" }
        if previous.interface != current.interface { return "iface_changed" }
        return nil
    }
}

/// What `GroupCallController` needs from a path monitor; tests use a fake.
public protocol GroupPathMonitoring: AnyObject {
    /// `handler(reason)` fires once per genuine change.
    func start(_ handler: @escaping (String) -> Void)
    func stop()
}

/// The real monitor: one `NWPathMonitor`, changes debounced to one per second.
public final class GroupNetworkPathWatcher: GroupPathMonitoring, @unchecked Sendable {

    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var previous: GroupNetworkPathPolicy.Snapshot?
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.bcrypto.qaudion.groupcall.path")
    private let debounceSeconds: Double

    public init(debounceSeconds: Double = 1.0) {
        self.debounceSeconds = debounceSeconds
    }

    public func start(_ handler: @escaping (String) -> Void) {
        stop()
        let path = NWPathMonitor()
        path.pathUpdateHandler = { [weak self] update in
            self?.received(Self.snapshot(of: update), handler: handler)
        }
        lock.lock()
        monitor = path
        previous = nil
        lock.unlock()
        path.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        let old = monitor
        monitor = nil
        previous = nil
        let item = pending
        pending = nil
        lock.unlock()
        item?.cancel()
        old?.cancel()
    }

    private func received(_ snapshot: GroupNetworkPathPolicy.Snapshot, handler: @escaping (String) -> Void) {
        lock.lock()
        let reason = GroupNetworkPathPolicy.changeReason(previous: previous, current: snapshot)
        previous = snapshot
        guard let change = reason else {
            lock.unlock()
            return
        }
        let old = pending
        let item = DispatchWorkItem { handler(change) }
        pending = item
        lock.unlock()
        old?.cancel()
        queue.asyncAfter(deadline: .now() + debounceSeconds, execute: item)
    }

    static func snapshot(of path: NWPath) -> GroupNetworkPathPolicy.Snapshot {
        let interface: String
        if path.usesInterfaceType(.wifi) {
            interface = "wifi"
        } else if path.usesInterfaceType(.cellular) {
            interface = "cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = "wired"
        } else {
            interface = path.status == .satisfied ? "other" : "none"
        }
        return GroupNetworkPathPolicy.Snapshot(satisfied: path.status == .satisfied, interface: interface)
    }
}
