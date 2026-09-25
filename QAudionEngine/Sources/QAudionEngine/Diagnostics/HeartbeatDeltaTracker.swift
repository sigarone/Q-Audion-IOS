import Foundation

/// W-HBTELEM (2026-09-21) — call-health attributes for the 5 s `call.media.heartbeat`
/// telemetry event, iOS side of the cross-platform spec (identical attribute names on
/// Android). Additive only: an old server ignores keys it does not know, an old client
/// simply never sends them.
///
/// Why: the 2026-09-20 call-quality analysis could not tie ANY counter to what a person
/// heard, because the iPhone heartbeat carried only `tick` and `uptime_ms` and the jitter
/// buffer / loss / FEC counters were print-only (`RX playout pu/un/ov/hd/cc/dp`,
/// `fec fr/ff`) or read by nothing. Everything here maps to a counter that already
/// exists; nothing new is measured on the audio path.
///
/// Conventions: `_d` = count since the previous heartbeat of the same call, `_now` =
/// instantaneous value, `_max` = maximum inside the window. An attribute the platform has
/// no counter for is left out (never sent as 0).
public enum HeartbeatAttribute {
    public static let rxFramesD = "rx_frames_d"
    public static let txFramesD = "tx_frames_d"
    /// W-DCWEDGE (2026-09-25) — frames the DataChannel back-pressure gate DROPPED in the
    /// window (encrypted, sent on no leg). Same name as Android's `tx_gate_drop_d`, whose
    /// total also counts mute / evict / key / closed sheds; on iOS it is the DataChannel
    /// sheds only (no other tx gate counts).
    public static let txGateDropD = "tx_gate_drop_d"
    public static let rxGapD = "rx_gap_d"
    public static let jbUnderrunD = "jb_underrun_d"
    public static let jbOverrunD = "jb_overrun_d"
    public static let jbHardDropD = "jb_hard_drop_d"
    public static let jbSilenceDropD = "jb_silence_drop_d"
    public static let jbConcealedD = "jb_concealed_d"
    public static let jbStretchD = "jb_stretch_d"
    public static let jbDepthNow = "jb_depth_now"
    public static let jbTargetNow = "jb_target_now"
    public static let iatMaxMs = "iat_max_ms"
    public static let fecRecD = "fec_rec_d"
    public static let mainStallMsMax = "main_stall_ms_max"
    public static let transport = "transport"
    // Marker event (`DisturbanceMarker`).
    public static let sinceStartMs = "since_start_ms"
    public static let source = "source"
}

/// Cumulative counters and instantaneous readings taken at one heartbeat. A nil field is
/// a counter that is not available right now (no audio engine yet, no call engine).
public struct HeartbeatSnapshot: Equatable, Sendable {

    // Sealed audio frames by transport, cumulative for the call (`dcmux tx/rx` line).
    public var rxFramesDc: Int64 = 0
    public var rxFramesWs: Int64 = 0
    public var txFramesDc: Int64 = 0
    public var txFramesWs: Int64 = 0

    /// Cumulative frames the DataChannel back-pressure gate dropped (W-DCWEDGE): NOT in
    /// `txFramesDc`. Nil = the caller has no such counter (the attribute is left out).
    public var txGateDrop: Int64?

    /// Cumulative frames missing by sequence gap (`rxLossSnapshot().lost`). Not
    /// monotonic: a late frame that fills a gap lowers it.
    public var rxGapLost: Int64?

    // Playout jitter buffer, cumulative (`PlayoutStats`, the `RX playout` line).
    public var jbUnderruns: Int64?
    public var jbOverruns: Int64?
    public var jbHardDrops: Int64?
    public var jbSilenceDrops: Int64?
    public var jbConcealed: Int64?
    public var jbStretch: Int64?

    /// Cumulative frames recovered by FEC (`fec fr=`).
    public var fecRecovered: Int64?

    // Instantaneous / per-window readings, reported as they are.
    public var jbDepthNow: Int?
    public var jbTargetNow: Int?
    public var interArrivalMaxMs: Int?

    /// True when the call's audio rides the native SRTP path, where the sealed-frame
    /// counters above legitimately stay at 0. It labels `transport` as `srtp` and makes the
    /// tracker leave `rx_frames_d` / `tx_frames_d` out (no counter, not "0 frames").
    public var nativeSrtpActive: Bool?

    /// Largest amount the heartbeat timer fired late in this window, in ms.
    public var mainStallMsMax: Int64?

    public init() {}
}

/// The heartbeat attributes of one completed window.
public struct HeartbeatWindow: Equatable, Sendable {
    public let numbers: [String: Int64]
    public let transport: String?

    public var isEmpty: Bool {
        return numbers.isEmpty && transport == nil
    }

    /// Ready to merge into the telemetry attrs: numbers as `Int64`, `transport` as a
    /// fixed short string. Nothing else, ever (no ids, no free text).
    public func attributes() -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in numbers {
            out[key] = value
        }
        if let label = transport {
            out[HeartbeatAttribute.transport] = label
        }
        return out
    }
}

/// Turns cumulative snapshots into per-window deltas.
///
/// Rules:
///  * The baseline is the previous snapshot of the SAME call: `reset(baseline:)` at
///    connect (nil when the counters are not readable yet), `reset(baseline: nil)` at
///    the end. With no baseline the first `advance` reports no deltas, only the
///    instantaneous readings, and becomes the baseline.
///  * A delta is never negative. A cumulative counter that goes DOWN between two
///    snapshots was restarted (a new audio engine, a playout reset, a counter reset at
///    call setup): the current value is then the count since the restart.
///  * `rxGapLost` is not monotonic (a late frame fills a gap), so a decrease is not a
///    restart there: the window simply reports 0, the same convention the PLP loss
///    reporter uses.
///  * A counter missing from either snapshot yields no attribute.
///  * While the CURRENT snapshot is on the native SRTP path the sealed-frame counters are not
///    applicable, so `rx_frames_d` / `tx_frames_d` are omitted (never sent as 0). A call that
///    falls back from native SRTP to the sealed path reports them again from that window on.
public struct HeartbeatDeltaTracker: Equatable, Sendable {

    private var previous: HeartbeatSnapshot?

    public init() {}

    public var hasBaseline: Bool {
        return previous != nil
    }

    public mutating func reset(baseline: HeartbeatSnapshot?) {
        previous = baseline
    }

    public mutating func advance(to current: HeartbeatSnapshot) -> HeartbeatWindow {
        var numbers: [String: Int64] = [:]
        var transport: String?

        if let prev = previous {
            let rxDc = HeartbeatDeltaTracker.monotonicDelta(current.rxFramesDc, prev.rxFramesDc)
            let rxWs = HeartbeatDeltaTracker.monotonicDelta(current.rxFramesWs, prev.rxFramesWs)
            let txDc = HeartbeatDeltaTracker.monotonicDelta(current.txFramesDc, prev.txFramesDc)
            let txWs = HeartbeatDeltaTracker.monotonicDelta(current.txFramesWs, prev.txFramesWs)
            // On the native SRTP path the sealed-frame counters never move (the protection runs
            // inside libwebrtc), so they would read 0 for a call that is carrying audio. That is
            // "no counter", not "no frames": the attribute is left out, and `transport` says why.
            if current.nativeSrtpActive != true {
                numbers[HeartbeatAttribute.rxFramesD] = rxDc + rxWs
                numbers[HeartbeatAttribute.txFramesD] = txDc + txWs
                // Same reasoning: the drop counter belongs to the sealed DataChannel path.
                if let drop = HeartbeatDeltaTracker.optionalMonotonicDelta(current.txGateDrop, prev.txGateDrop) {
                    numbers[HeartbeatAttribute.txGateDropD] = drop
                }
            }
            transport = HeartbeatDeltaTracker.transportLabel(dcFrames: rxDc + txDc,
                                                             wsFrames: rxWs + txWs,
                                                             nativeSrtp: current.nativeSrtpActive)

            if let gap = HeartbeatDeltaTracker.flooredDelta(current.rxGapLost, prev.rxGapLost) {
                numbers[HeartbeatAttribute.rxGapD] = gap
            }
            if let value = HeartbeatDeltaTracker.optionalMonotonicDelta(current.jbUnderruns, prev.jbUnderruns) {
                numbers[HeartbeatAttribute.jbUnderrunD] = value
            }
            if let value = HeartbeatDeltaTracker.optionalMonotonicDelta(current.jbOverruns, prev.jbOverruns) {
                numbers[HeartbeatAttribute.jbOverrunD] = value
            }
            if let value = HeartbeatDeltaTracker.optionalMonotonicDelta(current.jbHardDrops, prev.jbHardDrops) {
                numbers[HeartbeatAttribute.jbHardDropD] = value
            }
            if let value = HeartbeatDeltaTracker.optionalMonotonicDelta(current.jbSilenceDrops, prev.jbSilenceDrops) {
                numbers[HeartbeatAttribute.jbSilenceDropD] = value
            }
            if let value = HeartbeatDeltaTracker.optionalMonotonicDelta(current.jbConcealed, prev.jbConcealed) {
                numbers[HeartbeatAttribute.jbConcealedD] = value
            }
            if let value = HeartbeatDeltaTracker.optionalMonotonicDelta(current.jbStretch, prev.jbStretch) {
                numbers[HeartbeatAttribute.jbStretchD] = value
            }
            if let value = HeartbeatDeltaTracker.optionalMonotonicDelta(current.fecRecovered, prev.fecRecovered) {
                numbers[HeartbeatAttribute.fecRecD] = value
            }
        }

        // Instantaneous readings do not need a baseline.
        if let depth = current.jbDepthNow {
            numbers[HeartbeatAttribute.jbDepthNow] = Int64(depth)
        }
        if let target = current.jbTargetNow {
            numbers[HeartbeatAttribute.jbTargetNow] = Int64(target)
        }
        if let iat = current.interArrivalMaxMs {
            numbers[HeartbeatAttribute.iatMaxMs] = Int64(max(iat, 0))
        }
        if let stall = current.mainStallMsMax {
            numbers[HeartbeatAttribute.mainStallMsMax] = max(stall, 0)
        }

        previous = current
        return HeartbeatWindow(numbers: numbers, transport: transport)
    }

    // MARK: - Pure helpers

    /// Count since `prev` for a cumulative counter that only grows; a drop means the
    /// counter restarted, so `cur` is the count since the restart. Never negative.
    static func monotonicDelta(_ cur: Int64, _ prev: Int64) -> Int64 {
        if cur >= prev { return cur - prev }
        return max(cur, 0)
    }

    static func optionalMonotonicDelta(_ cur: Int64?, _ prev: Int64?) -> Int64? {
        guard let now = cur, let before = prev else { return nil }
        return monotonicDelta(now, before)
    }

    /// Delta for a counter that can fall without having restarted. Never negative.
    static func flooredDelta(_ cur: Int64?, _ prev: Int64?) -> Int64? {
        guard let now = cur, let before = prev else { return nil }
        return max(now - before, 0)
    }

    /// Short fixed label for where the window's audio frames went. Nil when no sealed
    /// frames moved and the call is not known to be on the native SRTP path.
    static func transportLabel(dcFrames: Int64, wsFrames: Int64, nativeSrtp: Bool?) -> String? {
        if dcFrames > 0 && wsFrames > 0 { return "dc+ws" }
        if dcFrames > 0 { return "dc" }
        if wsFrames > 0 { return "ws" }
        if nativeSrtp == true { return "srtp" }
        return nil
    }
}

/// How late a fixed-interval timer fired, i.e. how long the thread that runs it was
/// blocked. This is the whole definition of `main_stall_ms_max`: the heartbeat timer fires
/// on the main thread every 5 s, so an overshoot of that interval is time the main thread
/// could not run it. It only sees a stall that overlaps the timer's due instant.
public enum HeartbeatTiming {

    /// `max(0, elapsed - nominal)` in whole milliseconds; 0 for anything not finite.
    public static func timerDriftMs(elapsedSeconds: Double, nominalSeconds: Double) -> Int64 {
        if !elapsedSeconds.isFinite || !nominalSeconds.isFinite { return 0 }
        let drift = elapsedSeconds - nominalSeconds
        if drift <= 0 { return 0 }
        return Int64((drift * 1000.0).rounded())
    }
}
