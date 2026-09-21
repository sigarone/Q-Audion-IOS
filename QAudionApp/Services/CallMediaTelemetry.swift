import Foundation
import QAudionEngine

/// W548 (iOS parity) — Per-call media lifecycle telemetry.
///
/// Mirror of Android's `CallQualityMonitor.kt`. Three sealed events
/// ship to the maintainer dashboard for every call:
///
///   - `call.media.connected`  — call_id, peer_prefix, sas_source,
///                                started_at_ms
///   - `call.media.heartbeat`  — fires every 5 s while the call
///                                stays in `.active` / `.encrypted`
///                                state. Absence of heartbeats on a
///                                supposedly-long call is the
///                                "process paused mid-call" smoke
///                                test.
///   - `call.media.summary`    — emitted on transition to `.ended`
///                                with duration_ms, heartbeats,
///                                end_reason, suspect_silent
///                                (true when call lasted > 10 s but
///                                only ≤ 1 heartbeat fired).
///
/// W-HBTELEM (2026-09-21) — the heartbeat also carries call-health attributes (jitter
/// buffer, loss, FEC, transport, main-thread stall; see `HeartbeatAttribute`), and
/// `recordDisturbanceMarker()` emits `call.disturbance.marker` when the user taps
/// "Disturbo" on the in-call screen. Both go through the same `TelemetryService.emit`
/// (same consent gate, batching and transport). The deltas are computed by the pure,
/// unit-tested `HeartbeatDeltaTracker`; this class only wires it to the live counters.
///
/// `AppState` calls into the three static entry-points whenever a
/// CallState transition crosses a relevant edge. Holding the state
/// in this dedicated class (instead of AppState fields) keeps the
/// patches to AppState minimal — important because that file is
/// already at the Swift 6 type-checker budget (CLAUDE.md "Hard-won
/// lesson 14").
@MainActor
public final class CallMediaTelemetry {

    public static let shared = CallMediaTelemetry()

    private var currentCallId: String?
    private var connectedAtMs: Int64 = 0
    private var heartbeats: Int = 0
    private var heartbeatTask: Task<Void, Never>?

    /// W-HBTELEM — cumulative call-health counters of the 1:1 call engine, wired once by
    /// `AppState` to `CallService.makeHeartbeatSnapshot()`. Never read for a group call; nil
    /// (before wiring) leaves the heartbeat exactly as it was, plus `main_stall_ms_max`.
    public var heartbeatSnapshotProvider: (@MainActor () -> HeartbeatSnapshot?)?

    private var deltaTracker = HeartbeatDeltaTracker()
    /// True while the tracked call is a group (SFU) call: it has no 1:1 call-health counters, so it
    /// keeps the old heartbeat shape (plus the main-thread stall) and takes no disturbance marker.
    private var isGroupCall: Bool = false
    /// The attributes of the last completed heartbeat window, copied into a marker.
    private var lastWindowAttributes: [String: Any] = [:]
    private var markerDebouncer = DisturbanceMarkerDebouncer()

    /// Nominal heartbeat period, in seconds. `main_stall_ms_max` is how much later than this
    /// the heartbeat timer actually fired.
    private static let heartbeatIntervalSeconds: Double = 5.0

    private init() {}

    /// Call exactly once when CallState first transitions into
    /// `.active` (or `.encrypted` if the encrypted edge fires first).
    /// Idempotent within the same call_id: a second call with the
    /// same id is a no-op so the encrypted/active race doesn't
    /// double-fire.
    public func recordConnected(callId: String?, peerPrefix: String, sasSource: String, isGroup: Bool = false) {
        guard let cid = callId, !cid.isEmpty else { return }
        if cid == currentCallId { return }
        // If a previous call leaked (no Ended observed — rare race),
        // flush its summary first so we don't lose its trace.
        if currentCallId != nil {
            flushSummary(reason: "preempted")
        }
        currentCallId = cid
        connectedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        heartbeats = 0
        // W-HBTELEM — the counters of a NEW call start from their own baseline, never from the
        // previous call's totals.
        isGroupCall = isGroup
        var baseline: HeartbeatSnapshot?
        if !isGroup, let provider = heartbeatSnapshotProvider {
            baseline = provider()
        }
        deltaTracker.reset(baseline: baseline)
        lastWindowAttributes = [:]
        markerDebouncer.reset()
        TelemetryService.shared.emit(
            kind: "call.media.connected",
            callId: cid,
            attrs: [
                "peer_prefix": peerPrefix,
                "sas_source":  sasSource,
                "started_at_ms": connectedAtMs
            ]
        )
        startHeartbeat(callId: cid)
    }

    /// Call when CallState transitions to `.ended` (any reason).
    /// Idempotent — only the first invocation per call_id ships.
    public func recordEnded(callId: String?, reason: String) {
        guard let cid = callId else {
            // We don't know which call ended — flush whatever was
            // pending under the previous id.
            flushSummary(reason: reason)
            return
        }
        guard cid == currentCallId else { return }
        flushSummary(reason: reason)
    }

    // ─── Internals ────────────────────────────────────────────────

    private func startHeartbeat(callId: String) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                // Monotonic clock: how long this sleep REALLY took. The task resumes on the main
                // actor, so any time the main thread was blocked at the deadline shows up as the
                // overshoot of the nominal 5 s (W-HBTELEM `main_stall_ms_max`).
                let sleepStartedAt: Double = ProcessInfo.processInfo.systemUptime
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self = self else { return }
                guard self.currentCallId == callId else { return }
                let elapsedSeconds: Double = ProcessInfo.processInfo.systemUptime - sleepStartedAt
                self.emitHeartbeat(callId: callId, elapsedSeconds: elapsedSeconds)
            }
        }
    }

    /// One heartbeat: the historical `tick` + `uptime_ms`, plus (W-HBTELEM) the call-health
    /// attributes of the window that just ended. Additive only.
    private func emitHeartbeat(callId: String, elapsedSeconds: Double) {
        heartbeats += 1
        let uptimeMs = Int64(Date().timeIntervalSince1970 * 1000) - connectedAtMs
        var attrs: [String: Any] = [
            "tick": heartbeats,
            "uptime_ms": uptimeMs
        ]
        let stallMs: Int64 = HeartbeatTiming.timerDriftMs(elapsedSeconds: elapsedSeconds,
                                                          nominalSeconds: Self.heartbeatIntervalSeconds)
        if !isGroupCall, let provider = heartbeatSnapshotProvider, var snapshot = provider() {
            snapshot.mainStallMsMax = stallMs
            let window: HeartbeatWindow = deltaTracker.advance(to: snapshot)
            for (key, value) in window.attributes() {
                attrs[key] = value
            }
        } else {
            attrs[HeartbeatAttribute.mainStallMsMax] = stallMs
        }
        lastWindowAttributes = attrs
        TelemetryService.shared.emit(
            kind: "call.media.heartbeat",
            callId: callId,
            attrs: attrs
        )
    }

    /// W-HBTELEM — the user tapped "Disturbo": emit `call.disturbance.marker` with the last
    /// completed heartbeat window's attributes. At most one marker per second, whoever calls.
    /// No-op outside a connected 1:1 call.
    public func recordDisturbanceMarker() {
        guard let cid = currentCallId, connectedAtMs > 0, !isGroupCall else { return }
        let nowMono: Double = ProcessInfo.processInfo.systemUptime
        guard markerDebouncer.shouldEmit(now: nowMono) else { return }
        let sinceStartMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) - connectedAtMs
        var depthNow: Int?
        if let provider = heartbeatSnapshotProvider, let snapshot = provider() {
            depthNow = snapshot.jbDepthNow
        }
        let attrs: [String: Any] = DisturbanceMarker.attributes(sinceStartMs: sinceStartMs,
                                                                lastWindowAttributes: lastWindowAttributes,
                                                                jbDepthNow: depthNow)
        TelemetryService.shared.emit(kind: DisturbanceMarker.kind, callId: cid, attrs: attrs)
    }

    private func flushSummary(reason: String) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        guard let cid = currentCallId, connectedAtMs > 0 else {
            currentCallId = nil
            connectedAtMs = 0
            heartbeats = 0
            return
        }
        let durationMs = Int64(Date().timeIntervalSince1970 * 1000) - connectedAtMs
        let suspectSilent = (durationMs > 10_000 && heartbeats <= 1)
        TelemetryService.shared.emit(
            kind: "call.media.summary",
            callId: cid,
            attrs: [
                "duration_ms": durationMs,
                "heartbeats":  heartbeats,
                "end_reason":  reason,
                "suspect_silent": suspectSilent
            ]
        )
        currentCallId = nil
        connectedAtMs = 0
        heartbeats = 0
        deltaTracker.reset(baseline: nil)
        lastWindowAttributes = [:]
    }
}
