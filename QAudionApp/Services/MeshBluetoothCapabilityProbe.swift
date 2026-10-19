import CoreBluetooth

/// Read-only Bluetooth capability/power probe for the mesh antenna row —
/// entirely independent of `MeshRuntime`/`BleMeshTransport`.
///
/// W-MESHDEAD (2026-08-15): `BleMeshTransport`'s `CBCentralManager`/
/// `CBPeripheralManager` are only ever constructed inside its own `start()`,
/// so a user whose phone has Bluetooth authorization denied, or the system
/// radio off, saw the EXACT SAME dead "Spenta" antenna row as a user who had
/// simply not switched the mesh on, with no way to tell the two apart and
/// nothing tappable that explained or fixed either one ("si clicca il
/// monolite che non fa nulla e segnala spento" — reported live).
///
/// This probe reads the real CoreBluetooth authorization + power state on
/// its own tiny `CBCentralManager`. It waits for the user's one-time mesh
/// consent (`MeshConsent`): the mesh sheet calls `start()` only once the
/// consent is accepted, because constructing a `CBCentralManager` with a
/// delegate is what makes iOS ask for the Bluetooth permission, and nothing
/// may ask for it before the user said yes. It never scans or advertises
/// (that stays `BleMeshTransport`'s job, only once the consent AND this
/// device's radio both actually allow it) — this class exists purely so the
/// UI can tell the user WHICH of "Bluetooth is off" or "permission was
/// denied" is actually true, and give both a real fix (a button that opens
/// Settings) instead of a silent no-op.
@MainActor
final class MeshBluetoothCapabilityProbe: NSObject, ObservableObject, CBCentralManagerDelegate {
    enum Status: Equatable {
        /// Constructed but CoreBluetooth hasn't reported in yet (also the
        /// resting `.resetting`/`.unknown` states — both transient).
        case checking
        case unsupported
        /// Either `CBManager.authorization` was already denied/restricted
        /// BEFORE a manager was even created, or a live manager's `.state`
        /// reported `.unauthorized` after the user revoked it mid-session.
        case authorizationDenied
        case poweredOff
        case ready
    }

    @Published private(set) var status: Status = .checking

    private var manager: CBCentralManager?

    /// Idempotent — safe to call from `onAppear` every time the sheet opens.
    func start() {
        guard manager == nil else { return }
        // A pure read: CBManager.authorization does NOT itself trigger the
        // system permission prompt (only constructing a CBCentralManager
        // WITH A DELEGATE does that, below) — checking it first means a user
        // who already said no is shown the real reason without the OS
        // silently re-evaluating anything behind their back.
        switch CBCentralManager.authorization {
        case .denied, .restricted:
            status = .authorizationDenied
            return
        default:
            break
        }
        // CBCentralManagerOptionShowPowerAlertKey: false — this probe reads
        // state for OUR OWN UI to explain; the system's own "Bluetooth is
        // off" alert would be a second, redundant prompt on top of the one
        // this row already renders.
        manager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor [weak self] in
            self?.applyState(state)
        }
    }

    private func applyState(_ state: CBManagerState) {
        switch state {
        case .poweredOn: status = .ready
        case .poweredOff: status = .poweredOff
        case .unauthorized: status = .authorizationDenied
        case .unsupported: status = .unsupported
        case .resetting, .unknown: status = .checking
        @unknown default: status = .checking
        }
    }
}
