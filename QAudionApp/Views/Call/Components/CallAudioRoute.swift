import AVFoundation
import AVKit
import SwiftUI

/// Where the call audio is playing, for the icon and the spoken text of the dock's audio button.
enum CallAudioRoute: Equatable, Sendable {
    case earpiece
    case speaker
    case wired
    case bluetooth
    case car

    /// The route of a list of output ports (the first one that names a route wins; the phone receiver is the default).
    static func from(portTypes: [AVAudioSession.Port]) -> CallAudioRoute {
        for port in portTypes {
            switch port {
            case .carAudio:
                return .car
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
                return .bluetooth
            case .headphones, .usbAudio:
                return .wired
            case .builtInSpeaker:
                return .speaker
            default:
                continue
            }
        }
        return .earpiece
    }

    /// The route the shared audio session is on right now.
    static func current() -> CallAudioRoute {
        let ports: [AVAudioSession.Port] = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType }
        return from(portTypes: ports)
    }

    var icon: String {
        switch self {
        case .earpiece: return "phone.fill"
        case .speaker: return "speaker.wave.3.fill"
        case .wired, .bluetooth: return "headphones"
        case .car: return "car.fill"
        }
    }

    /// The name spoken after "Audio output:".
    var spokenName: String {
        switch self {
        case .earpiece: return CallControlText.routeEarpiece
        case .speaker: return CallControlText.routeSpeaker
        case .wired: return CallControlText.routeWired
        case .bluetooth: return CallControlText.routeBluetooth
        case .car: return CallControlText.routeCar
        }
    }
}

/// The system route picker behind the dock's audio button of the group call. The group call is hands-free and keeps the
/// loudspeaker (the app re-asserts it as the remote audio starts), so the button does not toggle the earpiece: it opens the
/// system list of outputs and leaves the choice, and the audio session, to the system.
///
/// An invisible `AVRoutePickerView` sits over the button; a touch lands on it and opens the list. VoiceOver activates the
/// button itself, which asks the same picker to open.
struct SystemRoutePickerOverlay: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.backgroundColor = .clear
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        SystemRoutePicker.register(picker)
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        SystemRoutePicker.register(uiView)
    }
}

@MainActor
enum SystemRoutePicker {
    private static weak var current: AVRoutePickerView?

    static func register(_ picker: AVRoutePickerView) {
        current = picker
    }

    /// Opens the list of outputs (the same as a touch on the picker).
    static func present() {
        guard let picker = current else { return }
        for case let button as UIButton in picker.subviews {
            button.sendActions(for: .touchUpInside)
            return
        }
    }
}
