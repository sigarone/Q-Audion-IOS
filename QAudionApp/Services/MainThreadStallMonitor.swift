import Foundation
import UIKit

/// W-STALLMARK (2026-10-02) — marks main-thread stalls during a call in the phone log:
/// `hang ms=<n> site=1 background=<0|1>` (RTLog tag "call"; a shape the phone-log shipper
/// keeps verbatim, pinned in `scripts/test_ship_ios_redactor_hardening.py`).
///
/// Why: the 2026-10-02 group-call analysis had a 5 s gap in the iPhone's log right after
/// the hand-over and no way to tell a frozen main thread from an app sent to the
/// background (the scene-phase lines finally showed the latter). This makes the next
/// trace say it directly.
///
/// A utility-queue timer pings the main queue every 250 ms; a ping answered `thresholdMs`
/// or more late is a stall of that length. One line per stall, written once the main
/// thread answers, so the length is the real one. `background=1`: the app was in the
/// background when the main thread answered (a suspension, not a stall). Runs only while
/// a call (1:1 or group) is live: `AppState.updateIdleTimer` switches it.
final class MainThreadStallMonitor: @unchecked Sendable {
    static let shared = MainThreadStallMonitor()

    private let queue = DispatchQueue(label: "com.qaudion.app.stall-monitor", qos: .utility)
    private let interval: DispatchTimeInterval = .milliseconds(250)
    private let thresholdMs = 1000
    // Touched on `queue` only.
    private var timer: DispatchSourceTimer?
    private var pingSentAt: UInt64 = 0

    private init() {}

    func setActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if active { self.start() } else { self.stop() }
        }
    }

    private func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        pingSentAt = 0
        source.resume()
    }

    private func stop() {
        timer?.cancel()
        timer = nil
        pingSentAt = 0
    }

    private func tick() {
        // The previous ping is still waiting for the main thread: that IS the stall,
        // measured when it is answered.
        guard pingSentAt == 0 else { return }
        let sentAt = DispatchTime.now().uptimeNanoseconds
        pingSentAt = sentAt
        DispatchQueue.main.async { [weak self] in
            let answeredAt = DispatchTime.now().uptimeNanoseconds
            let background: Bool = MainActor.assumeIsolated {
                UIApplication.shared.applicationState == .background
            }
            self?.queue.async { [weak self] in
                self?.answered(sentAt: sentAt, answeredAt: answeredAt, background: background)
            }
        }
    }

    private func answered(sentAt: UInt64, answeredAt: UInt64, background: Bool) {
        // Stopped (or restarted) while this ping was in flight: not ours to report.
        guard pingSentAt == sentAt, timer != nil else { return }
        pingSentAt = 0
        guard answeredAt > sentAt else { return }
        let lagMs = Int((answeredAt - sentAt) / 1_000_000)
        guard lagMs >= thresholdMs else { return }
        RTLog.warn("call", "hang ms=\(lagMs) site=1 background=\(background ? 1 : 0)")
    }
}
