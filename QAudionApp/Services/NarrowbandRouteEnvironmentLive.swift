import AVFoundation
import Foundation
import QAudionEngine

/// IN-CALL NARROWBAND BLUETOOTH NOTICE (2026-10-22) -- the real route, clock and timers behind
/// `NarrowbandBluetoothWatcher`: `AVAudioSession` for the input port and the sample rate, the system uptime for the clock,
/// `NotificationCenter` for route changes and the main run loop for the timers. Everything is delivered on the main
/// thread, which is what the watcher expects. The decisions are not here (they are in the engine and tested there).
final class LiveNarrowbandRouteEnvironment: NarrowbandRouteEnvironment {

    var now: Double {
        return ProcessInfo.processInfo.systemUptime
    }

    func readRoute() -> NarrowbandRouteReading {
        let session = AVAudioSession.sharedInstance()
        let inputPort: String? = session.currentRoute.inputs.first?.portType.rawValue
        let rate: Double = session.sampleRate
        return NarrowbandRouteReading(inputPort: inputPort, sampleRateHz: rate)
    }

    func observeRouteChanges(_ handler: @escaping () -> Void) -> NarrowbandCancel {
        let observer: NSObjectProtocol = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            handler()
        }
        return {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func repeating(every seconds: Double, _ action: @escaping () -> Void) -> NarrowbandCancel {
        let timer = Timer(timeInterval: seconds, repeats: true) { _ in
            action()
        }
        RunLoop.main.add(timer, forMode: .common)
        return {
            timer.invalidate()
        }
    }

    func once(after seconds: Double, _ action: @escaping () -> Void) -> NarrowbandCancel {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            action()
        }
        RunLoop.main.add(timer, forMode: .common)
        return {
            timer.invalidate()
        }
    }
}
