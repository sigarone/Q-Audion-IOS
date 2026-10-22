import Combine
import Foundation
import QAudionEngine

/// IN-CALL NARROWBAND BLUETOOTH NOTICE (2026-10-22) -- what the three call screens (1:1 audio, 1:1 video, group) draw the
/// banner from: one instance for the app, publishing whether the banner is up. The watching itself (the route observer,
/// the one-second look that runs only on a Bluetooth hands-free input, the settle time, the dismissal, the log lines)
/// is `NarrowbandBluetoothWatcher` in the engine, unit-tested with a fake route and clock; this class gives it the real
/// route (`LiveNarrowbandRouteEnvironment`) and the real log, and republishes its answer.
///
/// Primitives and closures only, never an `AppState` parameter (CLAUDE.md section 16): `AppState` tells it which call is
/// up (`setCall`) and gives it the one thing it cannot do itself (`usePhone`).
///
/// One call, one set of memories: the key of the call (`NarrowbandBluetoothCallScope`) decides when the dismissal and the
/// counters start over, so a call that follows another, or a 1:1 call that is promoted to a group, starts clean.
///
/// Telemetry: `audioroute nb_banner shown=1 sr=<Hz>` when the banner goes up (at most five per call) and
/// `audioroute nb_switch tap=1` for the tap.
@MainActor
final class NarrowbandBluetoothBannerModel: ObservableObject {

    static let shared = NarrowbandBluetoothBannerModel()

    /// Whether the banner is up right now.
    @Published private(set) var isVisible: Bool = false

    /// "Use the phone": `AppState` moves the call audio to the built-in microphone and to the phone's own output for this
    /// kind of call (the receiver on a 1:1 call, the loudspeaker on a group call).
    var usePhone: (() -> Void)?

    private let watcher: NarrowbandBluetoothWatcher

    private init() {
        let watcher = NarrowbandBluetoothWatcher(
            environment: LiveNarrowbandRouteEnvironment(),
            writeLine: { line in RTLog.info("call", line) }
        )
        self.watcher = watcher
        watcher.onVisibilityChange = { [weak self] visible in
            self?.isVisible = visible
        }
        watcher.usePhone = { [weak self] in
            self?.usePhone?()
        }
    }

    /// The key of the call that is up (`NarrowbandBluetoothCallScope.key`), nil when none is. Idempotent for the same key.
    func setCall(key: String?) {
        watcher.setCall(key: key)
    }

    /// The close button: the banner stays away for the rest of the call.
    func dismiss() {
        watcher.dismiss()
    }

    /// "Use the phone": not a dismissal. The banner goes away when the route follows, and comes back if the user returns
    /// to a headset that is still narrowband; if the session refuses it stays.
    func switchToPhone() {
        watcher.switchToPhone()
    }
}
