import Foundation

/// CALL-METRICS (2026-10-04) -- pure helpers behind the call-monitoring instrumentation that the
/// call-forensics analysis tool reads: per-interval extremes, the audio-route ledger and route line,
/// the numeric heartbeat lines and the native-path `call.audio.diag` attribute set. Telemetry only:
/// nothing here decides anything about the audio path. Foundation only, so the whole file is unit-tested
/// off-device (`CallMetricsTests`). Field names, units and example lines: docs/TELEMETRY_CALL_METRICS.md.
///
/// RULES THAT EVERY LINE FOLLOWS
///  * A value that was not measured is OMITTED, never printed as -1 / -1000 / 0. The analysis tool
///    reads numbers, and a sentinel would enter its distributions as a real value.
///  * Numbers only (plus the `audiosrtp` / `audioroute` family words): the log shipper's redactor is a
///    fail-closed allow-list, so a free word costs one of its two unknown-word slots.
public enum CallMetricsLines {

    /// ` key=value` when the value exists (>= 0), the empty string when it does not. The leading space is part of the
    /// result so a caller can append it to a line unconditionally. A negative input is the "no such stats row"
    /// convention used all over the call code (-1), not a measurement.
    public static func field(_ key: String, _ value: Int) -> String {
        guard value >= 0 else { return "" }
        return " " + key + "=" + String(value)
    }

    /// Same for a 64-bit counter.
    public static func field(_ key: String, _ value: Int64) -> String {
        guard value >= 0 else { return "" }
        return " " + key + "=" + String(value)
    }

    /// Same for an optional, for the extremes (nil = not measured in this interval).
    public static func field(_ key: String, _ value: Int?) -> String {
        guard let value else { return "" }
        return field(key, value)
    }

    /// Same for an optional 64-bit counter.
    public static func field(_ key: String, _ value: Int64?) -> String {
        guard let value else { return "" }
        return field(key, value)
    }

    /// The per-interval extremes as ` key=value` tokens, in a fixed order, omitting what was not measured:
    /// `rtt_max` (ms, ICE pair RTT), `jitter_max` (ms, RFC 3550 interarrival jitter, same quantity as hb=1 `jitter`),
    /// `rtt_remote_max` (ms, the peer's RTCP view), `lost_max` (packets newly counted lost within one 1 s sample),
    /// `plc_max` (concealed samples within one 1 s sample), `sample` (number of 1 s samples the extremes cover).
    public static func extremesFields(_ e: IntervalExtremes) -> String {
        var out: String = ""
        out += field("rtt_max", e.rttMaxMs)
        out += field("jitter_max", e.jitterMaxMs)
        out += field("rtt_remote_max", e.remoteRttMaxMs)
        out += field("lost_max", e.lostMax)
        out += field("plc_max", e.plcMax)
        if e.samples > 0 { out += field("sample", e.samples) }
        return out
    }

    /// `audiosrtp hb=2 ...`: the resilience line of the native-SRTP heartbeat. Every argument that is negative is
    /// omitted (no previous sample, no stats row, counter reset), and the extremes of the interval are appended.
    /// Order and names of the pre-existing fields are unchanged, so an old parser keeps working.
    public static func hb2(rttMs: Int, jitterBufferMs: Int, targetMs: Int, plc: Int64,
                           fecRecv: Int64, fecDrop: Int64, nack: Int64,
                           remoteLossPermille: Int, remoteRttMs: Int,
                           relayCode: Int, networkTypeCode: Int,
                           extremes: IntervalExtremes) -> String {
        var out: String = "audiosrtp hb=2"
        out += field("rtt", rttMs)
        out += field("jitter_ms", jitterBufferMs)
        out += field("target_ms", targetMs)
        out += field("plc", plc)
        out += field("fec_recv", fecRecv)
        out += field("fec_drop", fecDrop)
        out += field("nack", nack)
        out += field("remote_loss", remoteLossPermille)
        out += field("remote_rtt", remoteRttMs)
        out += field("relay", relayCode)
        out += field("network_type", networkTypeCode)
        out += extremesFields(extremes)
        return out
    }

    /// `audiosrtp hb=4 plc_silent_ms=<ms> plc_hear_ms=<ms> plc_event=<n>`: concealment of the interval split into the part
    /// produced while the sender was silent or in DTX (inbound `silentConcealedSamples`, not heard as a fault) and the
    /// AUDIBLE part (concealed minus silent). `plc` of hb=2 is the TOTAL and so is inflated by a quiet peer. Samples are
    /// converted to ms at 48 kHz (Opus clock) so the values stay under 6 digits: the shipper allows two numbers of 6+
    /// digits per line. Omitted when either counter is missing or the pair is inconsistent (silent > concealed).
    public static func hb4(concealedDelta: Int64, silentDelta: Int64, eventsDelta: Int64) -> String? {
        var out: String = "audiosrtp hb=4"
        if concealedDelta >= 0, silentDelta >= 0, silentDelta <= concealedDelta {
            out += field("plc_silent_ms", silentDelta / 48)
            out += field("plc_hear_ms", (concealedDelta - silentDelta) / 48)
        }
        out += field("plc_event", eventsDelta)
        return out == "audiosrtp hb=4" ? nil : out
    }

    /// `audiosrtp hb=3 eng=<1|2> vpio=<0|1> duck=<0|1> echo_act=<n> echo_idle=<n> echo_far=<n>
    /// [echo_active_db=<dBFS>] [echo_idle_db=<dBFS>] echo_suspect=<0|1>`: the echo state of the interval.
    /// `engine` 1 = WebRTC's own audio unit (native SRTP), 2 = the app's AVAudioEngine (legacy or fallback).
    /// `vpio` 1 = Voice-Processing I/O active (legacy engine: read from the pipeline) or CONFIGURED on (native: the
    /// factory is built with bypassVoiceProcessing=false and the unit is enabled; iOS offers no way to read whether the
    /// echo canceller inside it is working), 0 = not running voice processing. `duck` 1 = the bypass echo ducker is
    /// armed (legacy engine only), 0 = not applicable or off. `echo_suspect` is a PROXY, never an ERLE: see
    /// `NativeEchoProxy`. `echo` nil (legacy engine) leaves the echo fields out.
    public static func hb3(engine: Int, vpio: Bool, duck: Bool, echo: NativeEchoProxy.WindowReport?) -> String {
        var out: String = "audiosrtp hb=3"
        out += field("eng", engine)
        out += field("vpio", vpio ? 1 : 0)
        out += field("duck", duck ? 1 : 0)
        // The echo proxy only exists on the native path (nil on the legacy engine, which has its own buckets).
        guard let echo else { return out }
        out += field("echo_act", echo.activeFrames)
        out += field("echo_idle", echo.idleFrames)
        out += field("echo_far", echo.farCallbacks)
        if let db = NativeEchoProxy.dbfs(echo.activeRms) { out += " echo_active_db=" + String(db) }
        if let db = NativeEchoProxy.dbfs(echo.idleRms) { out += " echo_idle_db=" + String(db) }
        out += field("echo_suspect", echo.suspect ? 1 : 0)
        return out
    }
}

// MARK: - Per-interval extremes

/// The extremes of the 1 s samples between two heartbeats (the heartbeat itself is every 5 s and shows only
/// instantaneous values, so a 1-3 s spike between two heartbeats is invisible without this).
public struct IntervalExtremes: Equatable, Sendable {
    /// Number of 1 s samples folded in.
    public var samples: Int = 0
    public var rttMaxMs: Int?
    public var jitterMaxMs: Int?
    public var remoteRttMaxMs: Int?
    /// Largest number of packets newly counted lost within ONE 1 s sample. This is the best loss-burst figure the
    /// stats API allows: it exposes only the cumulative `packetsLost`, never the length of a consecutive run, so
    /// the true burst is at most this value and at least 1 whenever this is non-zero.
    public var lostMax: Int?
    /// Largest number of concealed samples within ONE 1 s sample.
    public var plcMax: Int64?

    public init() {}

    mutating func foldMax(_ other: IntervalExtremes) {
        samples += other.samples
        rttMaxMs = Self.maxOf(rttMaxMs, other.rttMaxMs)
        jitterMaxMs = Self.maxOf(jitterMaxMs, other.jitterMaxMs)
        remoteRttMaxMs = Self.maxOf(remoteRttMaxMs, other.remoteRttMaxMs)
        lostMax = Self.maxOf(lostMax, other.lostMax)
        if let o = other.plcMax { plcMax = Swift.max(plcMax ?? o, o) }
    }

    static func maxOf(_ a: Int?, _ b: Int?) -> Int? {
        guard let b else { return a }
        guard let a else { return b }
        return Swift.max(a, b)
    }
}

/// Folds one sample per second into the extremes of the current interval (`drain()` at each heartbeat) and of the
/// whole call (`callMax`). Cumulative counters are turned into per-sample deltas; a counter that goes DOWN (the
/// stats object was replaced by an ICE restart) re-baselines instead of producing a bogus negative or huge delta.
public struct IntervalExtremesTracker: Equatable, Sendable {
    /// Upper bound of a plausible ms value; anything above is a stats glitch and is dropped, not clamped.
    public static let maxMs: Double = 600_000

    private var prevLost: Int64?
    private var prevConcealed: Int64?
    private var window = IntervalExtremes()
    public private(set) var callMax = IntervalExtremes()

    public init() {}

    /// Every argument is optional: nil, negative or non-finite = "not measured this second".
    /// - Parameters:
    ///   - rttMs: ICE pair round-trip time, ms.
    ///   - jitterSec: RFC 3550 interarrival jitter of the inbound audio, seconds (the stats API unit).
    ///   - remoteRttSec: the peer's RTCP round-trip time for our outbound audio, seconds.
    ///   - lostCumulative: inbound audio `packetsLost`, cumulative.
    ///   - concealedCumulative: inbound audio `concealedSamples`, cumulative.
    public mutating func note(rttMs: Double?, jitterSec: Double?, remoteRttSec: Double?,
                              lostCumulative: Int64?, concealedCumulative: Int64?) {
        window.samples += 1
        if let v = Self.ms(rttMs) { window.rttMaxMs = IntervalExtremes.maxOf(window.rttMaxMs, v) }
        if let s = jitterSec, s.isFinite, s >= 0, let v = Self.ms(s * 1000) {
            window.jitterMaxMs = IntervalExtremes.maxOf(window.jitterMaxMs, v)
        }
        if let s = remoteRttSec, s.isFinite, s >= 0, let v = Self.ms(s * 1000) {
            window.remoteRttMaxMs = IntervalExtremes.maxOf(window.remoteRttMaxMs, v)
        }
        if let cur = lostCumulative, cur >= 0 {
            if let prev = prevLost, cur >= prev {
                let delta = Int(clamping: cur - prev)
                window.lostMax = IntervalExtremes.maxOf(window.lostMax, delta)
            }
            prevLost = cur
        } else {
            prevLost = nil
        }
        if let cur = concealedCumulative, cur >= 0 {
            if let prev = prevConcealed, cur >= prev {
                let delta = cur - prev
                window.plcMax = Swift.max(window.plcMax ?? delta, delta)
            }
            prevConcealed = cur
        } else {
            prevConcealed = nil
        }
    }

    /// Returns the extremes since the last drain and starts a new interval (the delta baselines stay). The whole-call
    /// maxima absorb what is returned.
    public mutating func drain() -> IntervalExtremes {
        let out = window
        callMax.foldMax(out)
        window = IntervalExtremes()
        return out
    }

    /// Whole-call maxima including the interval still open (the call ended between two heartbeats).
    public func callMaxIncludingOpenInterval() -> IntervalExtremes {
        var out = callMax
        out.foldMax(window)
        return out
    }

    /// Forgets everything (new call).
    public mutating func reset() {
        self = IntervalExtremesTracker()
    }

    private static func ms(_ v: Double?) -> Int? {
        guard let v, v.isFinite, v >= 0, v <= maxMs else { return nil }
        return Int(v.rounded())
    }
}

// MARK: - Audio route

/// What the route is, as numbers. `portType` strings are `AVAudioSession.Port.rawValue`.
public enum CallRouteDiagnostics {

    /// Route-change reason shipped for the sample taken at the first heartbeat of a call (not an Apple code).
    public static let reasonCallStart: Int = 99

    /// Output as a number: 1 earpiece, 2 loudspeaker, 3 Bluetooth, 4 wired, 5 car, 9 other, 0 none.
    /// Same numbering as `GroupDiagnostics.outputCode` (the group-call route lines), so one table serves both.
    public static func outputCode(_ portType: String?) -> Int {
        guard let port = portType else { return 0 }
        switch port {
        case "Receiver": return 1
        case "Speaker": return 2
        case "BluetoothHFP", "BluetoothA2DPOutput", "BluetoothLE": return 3
        case "Headphones", "LineOut", "USBAudio": return 4
        case "CarAudio": return 5
        default: return 9
        }
    }

    /// Input as a number: 1 built-in mic, 3 Bluetooth, 4 wired headset mic, 5 car, 9 other, 0 none.
    public static func inputCode(_ portType: String?) -> Int {
        guard let port = portType else { return 0 }
        switch port {
        case "MicrophoneBuiltIn": return 1
        case "BluetoothHFP", "BluetoothLE": return 3
        case "HeadsetMic", "USBAudio", "LineIn": return 4
        case "CarAudio": return 5
        default: return 9
        }
    }

    /// The Bluetooth profile of the route: 1 HFP (hands-free, a 8 or 16 kHz mono voice link), 2 A2DP (stereo music
    /// profile, output only, the mic stays the built-in one), 3 LE Audio, 0 not Bluetooth. HFP wins when either side
    /// is HFP, because the input being HFP is what forces the narrow-band voice link.
    public static func bluetoothProfile(outputPort: String?, inputPort: String?) -> Int {
        if outputPort == "BluetoothHFP" || inputPort == "BluetoothHFP" { return 1 }
        if outputPort == "BluetoothA2DPOutput" { return 2 }
        if outputPort == "BluetoothLE" || inputPort == "BluetoothLE" { return 3 }
        return 0
    }

    /// `audioroute why=<reason> old=<output code> out=<output code> in=<input code> profile=<0-3> sr=<Hz> out_ch=<n>
    /// in_ch=<n> vol=<0-100>`: one audio route change (or, with `why=99`, the route at the first heartbeat).
    /// `why` is the raw `AVAudioSession.RouteChangeReason` (1 new device, 2 old device gone, 3 category change,
    /// 4 override, 6 wake from sleep, 7 no suitable route, 8 configuration change). `sr` is the session's actual
    /// hardware sample rate: 16000 or 8000 on a Bluetooth hands-free route is a real band limit. Fields that cannot
    /// be read (negative or zero) are omitted; `old` is omitted when there is no previous route (the call-start sample).
    public static func routeLine(reason: Int, previousOutputPort: String?, outputPort: String?, inputPort: String?,
                                 sampleRateHz: Double, outputChannels: Int, inputChannels: Int,
                                 volume: Float) -> String {
        var out: String = "audioroute"
        out += CallMetricsLines.field("why", clamp(reason))
        if previousOutputPort != nil { out += CallMetricsLines.field("old", outputCode(previousOutputPort)) }
        out += CallMetricsLines.field("out", outputCode(outputPort))
        out += CallMetricsLines.field("in", inputCode(inputPort))
        out += CallMetricsLines.field("profile", bluetoothProfile(outputPort: outputPort, inputPort: inputPort))
        if let hz = sampleRateInt(sampleRateHz) { out += CallMetricsLines.field("sr", hz) }
        if outputChannels > 0 { out += CallMetricsLines.field("out_ch", clamp(outputChannels)) }
        if inputChannels > 0 { out += CallMetricsLines.field("in_ch", clamp(inputChannels)) }
        if volume.isFinite { out += CallMetricsLines.field("vol", Int((min(max(volume, 0), 1) * 100).rounded())) }
        return out
    }

    static func sampleRateInt(_ hz: Double) -> Int? {
        guard hz.isFinite, hz > 0, hz < 1_000_000 else { return nil }
        return Int(hz.rounded())
    }

    private static func clamp(_ v: Int) -> Int { min(max(v, 0), 99_999) }
}

/// What the audio route did during one call, for the end-of-call `call.audio.diag` and the `audioroute` line cap.
public struct CallRouteLedger: Equatable, Sendable {
    /// Cap on `audioroute` lines per call: an HFP negotiation can fire a dozen notifications in a second.
    public static let maxLines: Int = 40

    public private(set) var changes: Int = 0
    public private(set) var linesLogged: Int = 0
    public private(set) var speakerEver = false
    public private(set) var bluetoothEver = false
    public private(set) var hfpEver = false
    public private(set) var a2dpEver = false
    public private(set) var minSampleRateHz: Int?
    public private(set) var lastSampleRateHz: Int?
    public private(set) var lastOutputPort: String?
    public private(set) var lastInputPort: String?

    public init() {}

    /// Records the route as it is now. `isChange` true = a route-change notification (counted), false = a periodic
    /// sample. Returns true when the caller should log an `audioroute` line for it (a change, or `force`, within the cap).
    @discardableResult
    public mutating func note(outputPort: String?, inputPort: String?, sampleRateHz: Double,
                              isChange: Bool, force: Bool = false) -> Bool {
        if isChange { changes += 1 }
        if CallRouteDiagnostics.outputCode(outputPort) == 2 { speakerEver = true }
        switch CallRouteDiagnostics.bluetoothProfile(outputPort: outputPort, inputPort: inputPort) {
        case 1: hfpEver = true; bluetoothEver = true
        case 2: a2dpEver = true; bluetoothEver = true
        case 3: bluetoothEver = true
        default: break
        }
        if let hz = CallRouteDiagnostics.sampleRateInt(sampleRateHz) {
            lastSampleRateHz = hz
            if let current = minSampleRateHz { minSampleRateHz = Swift.min(current, hz) } else { minSampleRateHz = hz }
        }
        if let port = outputPort { lastOutputPort = port }
        if let port = inputPort { lastInputPort = port }
        guard isChange || force, linesLogged < Self.maxLines else { return false }
        linesLogged += 1
        return true
    }
}

// MARK: - Per-call state holder

/// The mutable per-call metrics state of `CallService`: extremes tracker, route ledger, heartbeat count. One lock,
/// because `CallService` is not main-actor isolated (the 1 s sampler runs on the main actor, the route observer on the
/// main queue, the teardown wherever the call ends).
public final class CallMetricsState: @unchecked Sendable {
    /// The 1:1 `call.audio.diag` is also emitted once this many heartbeats (5 s each) into the call, so a call that
    /// never reaches a clean teardown (crash, kill) still leaves one record.
    public static let midCallHeartbeat: Int = 3

    private let lock = NSLock()
    private var tracker = IntervalExtremesTracker()
    private var ledger = CallRouteLedger()
    private var heartbeats = 0
    private var midDiagTaken = false
    private var nativeSeen = false
    private var samplesSeen = 0

    public init() {}

    /// One 1 s sample. `native` true = the call is on native SRTP at this moment; it latches for the call, so the
    /// end-of-call diag still knows after the negotiation state has been torn down.
    /// Returns true for the first sample of the call (the caller resets the process-wide echo probe then, so a group
    /// call or an aborted call that fed it cannot leak into this one).
    @discardableResult
    public func noteSample(rttMs: Double?, jitterSec: Double?, remoteRttSec: Double?,
                           lostCumulative: Int64?, concealedCumulative: Int64?, native: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let first = samplesSeen == 0
        samplesSeen += 1
        if native { nativeSeen = true }
        tracker.note(rttMs: rttMs, jitterSec: jitterSec, remoteRttSec: remoteRttSec,
                     lostCumulative: lostCumulative, concealedCumulative: concealedCumulative)
        return first
    }

    /// Called once per heartbeat (every 5 s): returns the extremes of the interval just closed and the heartbeat number.
    public func closeInterval() -> (extremes: IntervalExtremes, heartbeat: Int) {
        lock.lock(); defer { lock.unlock() }
        heartbeats += 1
        return (tracker.drain(), heartbeats)
    }

    /// True exactly once, at the `midCallHeartbeat`-th heartbeat.
    public func takeMidCallDiagSlot() -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Not before the call is on native SRTP: a slot burned during a long ring would leave the call without its record.
        guard nativeSeen, !midDiagTaken, heartbeats >= Self.midCallHeartbeat else { return false }
        midDiagTaken = true
        return true
    }

    /// Records a route observation; true = log it.
    public func noteRoute(outputPort: String?, inputPort: String?, sampleRateHz: Double,
                          isChange: Bool, force: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ledger.note(outputPort: outputPort, inputPort: inputPort, sampleRateHz: sampleRateHz,
                           isChange: isChange, force: force)
    }

    /// Everything the end-of-call diag needs, taken under one lock.
    public func snapshot() -> (heartbeats: Int, callMax: IntervalExtremes, route: CallRouteLedger) {
        lock.lock(); defer { lock.unlock() }
        return (heartbeats, tracker.callMaxIncludingOpenInterval(), ledger)
    }

    /// True once a sample of this call was taken on native SRTP: the end-of-call native diag has something to report.
    /// A defensive teardown before a call starts (state already reset) reads false.
    public var sawNativeCall: Bool {
        lock.lock(); defer { lock.unlock() }
        return nativeSeen
    }

    /// True once a heartbeat has been counted.
    public var hasHeartbeats: Bool {
        lock.lock(); defer { lock.unlock() }
        return heartbeats > 0
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        tracker = IntervalExtremesTracker()
        ledger = CallRouteLedger()
        heartbeats = 0
        midDiagTaken = false
        nativeSeen = false
        samplesSeen = 0
    }
}

// MARK: - Native-path call.audio.diag

/// The `call.audio.diag` attribute set of a call that ran on native SRTP, where the app's own audio engine (the source of
/// the legacy diag) never starts. Names that exist in the legacy diag keep their name and unit, so the analysis tool's
/// echo and route reading works on both; new names carry their unit. A key is omitted when it was not measured.
public enum NativeCallAudioDiag {

    public static func attrs(final: Bool, heartbeats: Int, echo: NativeEchoProxy.CallReport,
                             callMax: IntervalExtremes, route: CallRouteLedger,
                             vpioConfigured: Bool) -> [String: Any] {
        var a: [String: Any] = [:]
        a["diag_final"] = final
        a["diag_native"] = true
        a["hb_n"] = heartbeats
        // The legacy echo buckets, fed from the native capture / render hooks. A frame here is one 10 ms callback.
        a["echo_active_frames"] = echo.activeFrames
        a["echo_idle_frames"] = echo.idleFrames
        a["echo_frame_ms"] = 10
        if let pct = echo.activeRms.map({ round1($0 * 100) }) { a["echo_active_rms_pct"] = pct }
        if let pct = echo.idleRms.map({ round1($0 * 100) }) { a["echo_idle_rms_pct"] = pct }
        a["echo_far_frames"] = echo.farCallbacks
        a["echo_suspect_win"] = echo.windowsSuspect
        a["echo_eval_win"] = echo.windowsEvaluated
        // Configured, not proven: see CallMetricsLines.hb3. The legacy names vpio_ever_active / vpio_bypassed_ever are
        // NOT set here on purpose (unknown on this path, and a false value would read as "bypassed").
        a["vpio_cfg"] = vpioConfigured
        if let v = callMax.rttMaxMs { a["rtt_max_ms"] = v }
        if let v = callMax.jitterMaxMs { a["jitter_max_ms"] = v }
        if let v = callMax.remoteRttMaxMs { a["remote_rtt_max_ms"] = v }
        if let v = callMax.lostMax { a["lost_max"] = v }
        if let v = callMax.plcMax { a["plc_max"] = v }
        a["route_changes"] = route.changes
        a["speaker_route_ever"] = route.speakerEver
        a["bt_route_ever"] = route.bluetoothEver
        a["bt_hfp_ever"] = route.hfpEver
        a["bt_a2dp_ever"] = route.a2dpEver
        if let hz = route.lastSampleRateHz { a["granted_sr"] = hz }
        if let hz = route.minSampleRateHz { a["min_sr"] = hz }
        if let p = route.lastOutputPort, let t = VpioObservability.portToken(p) { a["output_route"] = t }
        if let p = route.lastInputPort, let t = VpioObservability.portToken(p) { a["input_route"] = t }
        return a
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
