import AVFoundation

/// Whether the audio route of the phone uses a Bluetooth device: the second fact (next to "a call is active") that
/// makes the mesh suspend discovery (docs/mesh/MESH_LINK_SPEC.md section 2.1).
///
/// Any Bluetooth port counts, on the input or on the output: a hands-free link (`bluetoothHFP`, the car kit and the
/// classic headset), LE Audio and Made-for-iPhone hearing aids (`bluetoothLE`), and the stereo profile
/// (`bluetoothA2DP`). Built-in ports, wired headsets, USB, AirPlay and `carAudio` (a wired or wireless CarPlay
/// session, which carries its audio outside the Bluetooth radio) do not.
enum MeshAudioRoute {

    /// The port types that are Bluetooth.
    static let bluetoothPorts: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]

    /// True if any of the ports is a Bluetooth port.
    static func usesBluetooth(inputs: [AVAudioSession.Port], outputs: [AVAudioSession.Port]) -> Bool {
        inputs.contains { bluetoothPorts.contains($0) } || outputs.contains { bluetoothPorts.contains($0) }
    }

    /// True if the route has a Bluetooth input or a Bluetooth output.
    static func usesBluetooth(_ route: AVAudioSessionRouteDescription) -> Bool {
        usesBluetooth(inputs: route.inputs.map(\.portType), outputs: route.outputs.map(\.portType))
    }

    /// The route right now. Reads `currentRoute`, which does not activate the session and can wait on the audio system:
    /// call it from the main thread only (`MeshRuntime`), never from the Bluetooth queue of the transport, which gets
    /// the answer handed over together with the call state.
    static func currentRouteUsesBluetooth() -> Bool {
        usesBluetooth(AVAudioSession.sharedInstance().currentRoute)
    }

    /// Runs `handler` on the main thread whenever the audio route changes. The caller reads the route in the handler
    /// (`currentRouteUsesBluetooth()`) and keeps the returned token for as long as it wants the changes.
    static func observeChanges(_ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { _ in handler() }
    }
}
