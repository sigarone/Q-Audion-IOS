import Foundation

/// N7 (network-resilience-max, this task) — per-heartbeat INTERVAL telemetry
/// for the native-SRTP audio path, pure and independently testable (no
/// WebRTC/Foundation UI types beyond `Double`/`Int64`/`String` — same
/// discipline as ``RestartIceDecisions``/``SrtpFallbackDecisions``/
/// ``VideoBandwidthCap`` elsewhere in this directory).
///
/// The problem this closes (resilience-assessment.md §4, "Cosa manca" items
/// 1-4): every counter `QAudionWebRtcCallController.pollMediaRttOnce()` reads
/// off `RTCStatsReport` for jitter-buffer delay, concealment, FEC and
/// retransmission is CUMULATIVE-since-call-start (the WebRTC-stats spec's own
/// shape for these fields — `jitterBufferDelay`/`jitterBufferTargetDelay`
/// pair with `jitterBufferEmittedCount` for exactly this reason). Shipping
/// the raw cumulative value on every ~5s heartbeat hides a short, sharp
/// episode inside a slowly-growing lifetime average — the assessment's own
/// example: `in_jbuf_delay_avg_ms` on Android is "a media calcolata
/// dall'inizio della chiamata ... nasconde i picchi". This type turns two
/// consecutive cumulative snapshots into the DELTA over just that interval,
/// which is what actually answers "how is this heartbeat's window looking".
///
/// `CallService.swift` (the app target, which owns the heartbeat's own ~5s
/// cadence and the "keep the previous sample" state — the exact same pattern
/// its own `lastThroughputSample` already uses for the tx/rx kbps rate on the
/// SAME log line) is the caller: it keeps one `NativeAudioIntervalCounters`
/// from the previous heartbeat tick and calls ``NativeAudioHeartbeatDeltas
/// /compute(previous:current:)`` each tick, exactly mirroring how
/// `sampleWireThroughput` already turns two cumulative byte counts into a
/// kbps rate over `dtSec`.
public enum NativeAudioHeartbeatDeltas {

    /// One heartbeat's worth of CUMULATIVE counters read straight off
    /// `RTCStatsReport` (`QAudionWebRtcCallController.NativeAudioSrtpStatsSnapshot`'s
    /// own fields, plus the two already-existing `mediaJitterBufferDelaySec`/
    /// `mediaJitterBufferEmittedCount` properties). `-1` = "no such row in
    /// this report" (every field's existing absent-value convention
    /// throughout this codebase) — never a real negative count.
    public struct IntervalCounters: Equatable, Sendable {
        public var jitterBufferDelaySec: Double
        public var jitterBufferTargetDelaySec: Double
        public var jitterBufferEmittedCount: Int64
        public var concealedSamples: Int64
        public var silentConcealedSamples: Int64
        public var concealmentEvents: Int64
        public var fecPacketsReceived: Int64
        public var fecPacketsDiscarded: Int64
        public var nackCount: Int64
        public var retransmittedPacketsSent: Int64

        public init(jitterBufferDelaySec: Double = -1,
                    jitterBufferTargetDelaySec: Double = -1,
                    jitterBufferEmittedCount: Int64 = -1,
                    concealedSamples: Int64 = -1,
                    silentConcealedSamples: Int64 = -1,
                    concealmentEvents: Int64 = -1,
                    fecPacketsReceived: Int64 = -1,
                    fecPacketsDiscarded: Int64 = -1,
                    nackCount: Int64 = -1,
                    retransmittedPacketsSent: Int64 = -1) {
            self.jitterBufferDelaySec = jitterBufferDelaySec
            self.jitterBufferTargetDelaySec = jitterBufferTargetDelaySec
            self.jitterBufferEmittedCount = jitterBufferEmittedCount
            self.concealedSamples = concealedSamples
            self.silentConcealedSamples = silentConcealedSamples
            self.concealmentEvents = concealmentEvents
            self.fecPacketsReceived = fecPacketsReceived
            self.fecPacketsDiscarded = fecPacketsDiscarded
            self.nackCount = nackCount
            self.retransmittedPacketsSent = retransmittedPacketsSent
        }
    }

    /// The computed INTERVAL result for one heartbeat tick. `-1` (the same
    /// sentinel `IntervalCounters` uses) means "not computable this tick" —
    /// no previous sample yet (first heartbeat of the call), either side
    /// absent (-1), or a counter that went DOWN (the underlying stats object
    /// was replaced — an ICE restart rebuilds the transport/RTP stream stats
    /// from zero — so the two samples are not comparable; never a bogus
    /// negative delta).
    public struct Deltas: Equatable, Sendable {
        /// Average jitter-buffer delay in ms over the interval:
        /// `(currentDelaySec - previousDelaySec) / (currentEmitted -
        /// previousEmitted) * 1000`. `-1` when zero (or negative) new samples
        /// were emitted this interval — nothing to average.
        public var jitterBufferDelayMsAvg: Int
        /// Same averaging, for `jitterBufferTargetDelaySec` (NetEQ's TARGET,
        /// as opposed to the delay actually experienced above).
        public var jitterBufferTargetDelayMsAvg: Int
        public var concealedSamplesDelta: Int64
        /// Concealed samples produced while the sender was silent or in DTX (inside `concealedSamplesDelta`).
        public var silentConcealedSamplesDelta: Int64
        public var concealmentEventsDelta: Int64
        public var fecPacketsReceivedDelta: Int64
        public var fecPacketsDiscardedDelta: Int64
        public var nackCountDelta: Int64
        public var retransmittedPacketsSentDelta: Int64

        public init(jitterBufferDelayMsAvg: Int = -1,
                    jitterBufferTargetDelayMsAvg: Int = -1,
                    concealedSamplesDelta: Int64 = -1,
                 silentConcealedSamplesDelta: Int64 = -1,
                 concealmentEventsDelta: Int64 = -1,
                    fecPacketsReceivedDelta: Int64 = -1,
                    fecPacketsDiscardedDelta: Int64 = -1,
                    nackCountDelta: Int64 = -1,
                    retransmittedPacketsSentDelta: Int64 = -1) {
            self.jitterBufferDelayMsAvg = jitterBufferDelayMsAvg
            self.jitterBufferTargetDelayMsAvg = jitterBufferTargetDelayMsAvg
            self.concealedSamplesDelta = concealedSamplesDelta
            self.silentConcealedSamplesDelta = silentConcealedSamplesDelta
            self.concealmentEventsDelta = concealmentEventsDelta
            self.fecPacketsReceivedDelta = fecPacketsReceivedDelta
            self.fecPacketsDiscardedDelta = fecPacketsDiscardedDelta
            self.nackCountDelta = nackCountDelta
            self.retransmittedPacketsSentDelta = retransmittedPacketsSentDelta
        }
    }

    /// Plain counter delta: `-1` (not `0`) whenever either side is absent
    /// (`-1`) or `current < previous` (a reset) — see `Deltas`' own doc for
    /// why a reset must never surface as a fabricated negative number.
    private static func counterDelta(_ previous: Int64, _ current: Int64) -> Int64 {
        guard previous >= 0, current >= 0, current >= previous else { return -1 }
        return current - previous
    }

    /// `previous == nil` (the first heartbeat this call has ever taken a
    /// sample for) short-circuits to "everything -1" — there is no interval
    /// yet, only a single point.
    public static func compute(previous: IntervalCounters?, current: IntervalCounters) -> Deltas {
        guard let previous else { return Deltas() }

        let emittedDelta = counterDelta(previous.jitterBufferEmittedCount, current.jitterBufferEmittedCount)
        func averageMs(previousDelaySec: Double, currentDelaySec: Double) -> Int {
            guard emittedDelta > 0,
                  previousDelaySec.isFinite, currentDelaySec.isFinite,
                  previousDelaySec >= 0, currentDelaySec >= 0,
                  currentDelaySec >= previousDelaySec else { return -1 }
            let deltaSec = currentDelaySec - previousDelaySec
            // Int(Double) traps on a non-finite or out-of-range value — a
            // telemetry line must never be able to crash a live call.
            let avgMs = (deltaSec / Double(emittedDelta)) * 1000.0
            guard avgMs.isFinite, avgMs < Double(Int32.max) else { return -1 }
            return Int(avgMs.rounded())
        }

        return Deltas(
            jitterBufferDelayMsAvg: averageMs(previousDelaySec: previous.jitterBufferDelaySec,
                                              currentDelaySec: current.jitterBufferDelaySec),
            jitterBufferTargetDelayMsAvg: averageMs(previousDelaySec: previous.jitterBufferTargetDelaySec,
                                                    currentDelaySec: current.jitterBufferTargetDelaySec),
            concealedSamplesDelta: counterDelta(previous.concealedSamples, current.concealedSamples),
            silentConcealedSamplesDelta: counterDelta(previous.silentConcealedSamples, current.silentConcealedSamples),
            concealmentEventsDelta: counterDelta(previous.concealmentEvents, current.concealmentEvents),
            fecPacketsReceivedDelta: counterDelta(previous.fecPacketsReceived, current.fecPacketsReceived),
            fecPacketsDiscardedDelta: counterDelta(previous.fecPacketsDiscarded, current.fecPacketsDiscarded),
            nackCountDelta: counterDelta(previous.nackCount, current.nackCount),
            retransmittedPacketsSentDelta: counterDelta(previous.retransmittedPacketsSent,
                                                        current.retransmittedPacketsSent)
        )
    }

    // MARK: - N7 vocabulary-only encoders (ship-ios-logs.py)

    /// The `local-candidate` stats row's `relayProtocol` string
    /// ("udp"/"tcp"/"tls", only present when `candidateType == "relay"") —
    /// encoded as a small int so the heartbeat line never carries a raw
    /// platform string. Mirrors `QAudionWebRtcCallController
    /// .interfaceTypeCode`'s own established reasoning in this exact
    /// codebase: "this repo's redactor rule ... blobs any non-numeric free
    /// text token ... every other log line in this file already encodes
    /// enum/bool state as an Int for the same reason". `nil`/unrecognized -> 0.
    ///
    /// `4` = the relay was allocated through this call's WSS-TURN bridge
    /// (review fix): such a candidate reports `relayProtocol == "udp"` for
    /// its loopback hop, so without this flag a call that fell back to the
    /// bridge would read as a plain UDP relay. Only meaningful for a relay
    /// candidate, so it never overrides an absent protocol (-> 0).
    public static func relayProtocolCode(_ relayProtocol: String?, viaWssBridge: Bool = false) -> Int {
        switch relayProtocol?.lowercased() {
        case "udp": return viaWssBridge ? 4 : 1
        case "tcp": return viaWssBridge ? 4 : 2
        case "tls": return viaWssBridge ? 4 : 3
        default: return 0
        }
    }

    /// The `local-candidate` stats row's `networkType` string
    /// ("wifi"/"ethernet"/"cellular"/"vpn"/"unknown", best-effort and only
    /// present with the right entitlement) — same numeric-encoding
    /// discipline as ``relayProtocolCode(_:)`` and
    /// `QAudionWebRtcCallController.interfaceTypeCode`.
    public static func networkTypeCode(_ networkType: String?) -> Int {
        switch networkType?.lowercased() {
        case "wifi": return 1
        case "ethernet": return 2
        case "cellular": return 3
        case "vpn": return 4
        case "loopback": return 5
        case "unknown": return 6
        default: return 0
        }
    }
}
