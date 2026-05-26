import Foundation

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

    private init() {}

    /// Call exactly once when CallState first transitions into
    /// `.active` (or `.encrypted` if the encrypted edge fires first).
    /// Idempotent within the same call_id: a second call with the
    /// same id is a no-op so the encrypted/active race doesn't
    /// double-fire.
    public func recordConnected(callId: String?, peerPrefix: String, sasSource: String) {
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
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self = self else { return }
                guard self.currentCallId == callId else { return }
                self.heartbeats += 1
                let uptimeMs = Int64(Date().timeIntervalSince1970 * 1000) - self.connectedAtMs
                TelemetryService.shared.emit(
                    kind: "call.media.heartbeat",
                    callId: callId,
                    attrs: [
                        "tick": self.heartbeats,
                        "uptime_ms": uptimeMs
                    ]
                )
            }
        }
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
    }
}
