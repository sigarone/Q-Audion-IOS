import Foundation

/// Telemetry of location sharing: counters and enums only (WIRE_SPEC 14.10, docs/LOCATION_SHARING.md 1.4).
///
///   loc_pin_sent, loc_live_started{duration_preset}, loc_live_ended{reason}, loc_frames_sent{count},
///   loc_frames_dropped{reason, count}, loc_permission{state}, loc_rejected{code}
///
/// No accuracy value, no `age`, no time of day, no id, never a coordinate. Events go through `TelemetryService`, which sends nothing
/// without the user's consent for operational diagnostics. The per-frame counters are kept in memory and reported when a share ends.
@MainActor
enum LocationTelemetry {

    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var framesSent: Int = 0
        private var framesDropped: [String: Int] = [:]

        func addSent() {
            lock.lock()
            framesSent += 1
            lock.unlock()
        }

        func addDropped(_ reason: String) {
            lock.lock()
            framesDropped[reason, default: 0] += 1
            lock.unlock()
        }

        func take() -> (sent: Int, dropped: [String: Int]) {
            lock.lock()
            let result: (sent: Int, dropped: [String: Int]) = (sent: framesSent, dropped: framesDropped)
            framesSent = 0
            framesDropped = [:]
            lock.unlock()
            return result
        }
    }

    private static let counters = Counters()

    static func pinSent() {
        TelemetryService.shared.emit(kind: "loc_pin_sent")
    }

    static func liveStarted(durationPreset: String) {
        TelemetryService.shared.emit(kind: "loc_live_started", attrs: ["duration_preset": durationPreset])
    }

    /// `reason` is one of a small closed set (`user`, `expired`, `superseded`, `blocked`, `key_changed`, `permission`, `flag_off`,
    /// `logout`, `deleted`, `cleared`, `failed`, `restart`). The frame counters of the share go out with it.
    static func liveEnded(reason: String) {
        TelemetryService.shared.emit(kind: "loc_live_ended", attrs: ["reason": reason])
        flushFrameCounters()
    }

    static func frameSent() {
        counters.addSent()
    }

    static func frameDropped(_ reason: String) {
        counters.addDropped(reason)
    }

    static func permission(state: String) {
        TelemetryService.shared.emit(kind: "loc_permission", attrs: ["state": state])
    }

    static func rejected(_ code: String) {
        TelemetryService.shared.emit(kind: "loc_rejected", attrs: ["code": code])
    }

    private static func flushFrameCounters() {
        let taken = counters.take()
        if taken.sent > 0 {
            TelemetryService.shared.emit(kind: "loc_frames_sent", attrs: ["count": taken.sent])
        }
        for (reason, count) in taken.dropped {
            TelemetryService.shared.emit(kind: "loc_frames_dropped", attrs: ["reason": reason, "count": count])
        }
    }
}
