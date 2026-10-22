import Foundation
@preconcurrency import CallKit
import QAudionEngine

/// The calls of the whole device as CallKit reports them to any app, without an entitlement: a cellular call, a call
/// of another app and the calls of this app. It is the first fact behind the Bluetooth mesh pause
/// (docs/mesh/MESH_LINK_SPEC.md section 2.1); the definition of a call that counts (connected, ringing excluded) is
/// `MeshCallDefinition`, in the engine.
///
/// It observes only while the mesh antenna is on (`start()` / `stop()`), and lists nothing otherwise: with the
/// antenna off no fact about the device's calls is needed or read.
///
/// Main thread only: the observer delivers on the main queue and `snapshot()` is read there, never on the
/// Bluetooth queue of the transport.
@MainActor
final class MeshSystemCalls: NSObject, CXCallObserverDelegate {

    private var observer: CXCallObserver?

    /// Runs on the main thread after any call started, connected, was put on hold or ended.
    var onChange: (@MainActor () -> Void)?

    /// Starts observing the calls of the device. Does nothing if it already does.
    func start() {
        guard observer == nil else { return }
        let created = CXCallObserver()
        created.setDelegate(self, queue: .main)
        observer = created
        // The list of calls reaches a new observer asynchronously, so a radio that starts during a call may read an
        // empty list first: read once more after it has had time to arrive.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.observer != nil else { return }
            self.onChange?()
        }
    }

    /// Stops observing; `snapshot()` is empty from now on.
    func stop() {
        observer?.setDelegate(nil, queue: nil)
        observer = nil
    }

    /// The calls the system knows right now, as the pure definition reads them.
    func snapshot() -> [MeshCallDefinition.SystemCall] {
        let calls = observer?.calls ?? []
        return calls.map { MeshCallDefinition.SystemCall(hasConnected: $0.hasConnected, hasEnded: $0.hasEnded) }
    }

    // CXCallObserverDelegate is not actor-isolated; the callback arrives on the main queue and hops to the main actor
    // the same way the transport delegate of `MeshRuntime` does.
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor in
            self.onChange?()
        }
    }
}
