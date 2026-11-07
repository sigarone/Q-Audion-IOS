import AVFoundation
import Foundation

/// Whether the phone is connected to a car, readable from any thread at the moment an incoming call arrives.
///
/// Two signals are combined. The CarPlay scene (`CarPlayBridge.carPlayConnected()` / `carPlayDisconnected()`) is the
/// one that does not depend on the audio session: the car creates the scene as soon as it connects, before any call
/// has made the session active. The audio route (`AVAudioSession` outputs and available inputs of type `.carAudio`)
/// is the older signal and stays for a car that is connected but has not started the app's scene, which is also what
/// `AppState` used before; it can read empty while the session is inactive, which is why it is not the only one.
enum CarPlayLink {

    /// Where the "connected" answer came from. The raw value is what the log line prints.
    enum Source: String, Equatable {
        case none
        case scene
        case route
        case both
    }

    struct Reading: Equatable {
        let connected: Bool
        let source: Source
    }

    /// Pure combination of the two signals.
    static func combine(scene: Bool, route: Bool) -> Reading {
        switch (scene, route) {
        case (true, true): return Reading(connected: true, source: .both)
        case (true, false): return Reading(connected: true, source: .scene)
        case (false, true): return Reading(connected: true, source: .route)
        case (false, false): return Reading(connected: false, source: .none)
        }
    }

    // MARK: - Scene signal

    /// A flag behind a lock, so the scene (main actor) can set it and the WebSocket and PushKit closures (any queue)
    /// can read it without an actor hop.
    private final class SceneFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static let sceneFlag = SceneFlag()

    /// Called by `CarPlayBridge` when the car connects and disconnects.
    static func setSceneConnected(_ connected: Bool) { sceneFlag.set(connected) }

    static var sceneConnected: Bool { sceneFlag.get() }

    // MARK: - Route signal

    /// True when an output or an available input of the shared audio session is a car. Both are read: the current
    /// route has no outputs worth trusting while the session is inactive, the available inputs are listed from the
    /// hardware that is attached.
    static func routeShowsCarPlay() -> Bool {
        let session = AVAudioSession.sharedInstance()
        if session.currentRoute.outputs.contains(where: { $0.portType == .carAudio }) { return true }
        return session.availableInputs?.contains(where: { $0.portType == .carAudio }) ?? false
    }

    // MARK: - Reading

    static func read() -> Reading {
        combine(scene: sceneConnected, route: routeShowsCarPlay())
    }
}

/// How a one-to-one call that arrives over the WebSocket is presented.
enum WsIncomingPresentation: Equatable {
    /// The call is reported to CallKit: the system call UI, and CarPlay, show it. No in-app ring sound.
    case callKit
    /// W520 single dialer: the app is in front, so only its own banner and ring are used and CallKit is not told.
    case inAppOnly

    /// A call in front of the user with no car uses the app's own ring. Every other case goes to CallKit: in the
    /// background nothing else can show it, and a car shows calls only through CallKit.
    static func decide(foreground: Bool, carPlay: Bool) -> WsIncomingPresentation {
        (foreground && !carPlay) ? .inAppOnly : .callKit
    }
}
