import Foundation

/// W-VPIOOBS (2026-09-25) -- pure helpers behind the VP-IO observability package of
/// `AudioCapture` (telemetry only: nothing here decides anything about the audio path).
///
/// THE QUESTION THIS ANSWERS. On the test iPhone Apple's Voice-Processing
/// I/O never delivered a single tap buffer from the built-in mic within the W-AEC-FIX watchdog
/// window (71 of 71 built-in-mic calls since 13/7 ended in bypass, ~1% on the other devices), and
/// every call log could say was that the watchdog fired: not how long the tap takes when it does
/// deliver, not whether the timer that fired belonged to the engine it judged, not what the
/// hardware / OS / mic mode / port list / tap format looked like. This file holds the arithmetic,
/// the numeric log lines and the `call.audio.diag` attribute set for those measurements, so each
/// of them is pinned by `VpioObservabilityTests` without a live audio session.
///
/// LOG LINES are numeric and compact on purpose: the log shipper's redactor drops any body with
/// free multi-word text (that is why `W-AEC-FIX ... starved` never reached Loki), but keeps
/// `key=number` tokens and `ev=<word>` under the enum-like key `ev`. Same family as the
/// `audioVp vpio=1 want=1 byp=0 ...` line CallService already prints. No id, no key, no UUID.
public enum VpioObservability {

    // MARK: - Clock arithmetic

    /// Upper bound of every ms value shipped. Keeps a `key=digits` token within the 7-digit numeric
    /// grammar the log shipper keeps readable.
    public static let maxMs: Int = 999_999

    /// Whole ms between two monotonic stamps. -1 when either stamp is unset (0 = "never
    /// recorded"), 0 when `endMs` is not after `startMs` (a tap buffer that landed before
    /// `start()` returned), clamped to `maxMs`. Never negative except for the "unknown" -1.
    public static func elapsedMs(from startMs: Int64, to endMs: Int64) -> Int {
        guard startMs > 0, endMs > 0 else { return -1 }
        let delta: Int64 = endMs - startMs
        if delta <= 0 { return 0 }
        if delta > Int64(maxMs) { return maxMs }
        return Int(delta)
    }

    // MARK: - Numeric log lines (RTLog "call", via AudioCapture.onDiagLine)

    /// The watchdog was armed: VP-IO is active for engine generation `gen`. `engMs` = ms the
    /// start took from the `engine.start()` call to the end of `start()`.
    public static func armLine(gen: Int, engMs: Int) -> String {
        return "audioVp ev=arm gen=\(gen) since_start_ms=0 eng_ms=\(engMs)"
    }

    /// The tap delivered its first buffer. `ms` counts from the end of `start()` (the same origin
    /// the watchdog window uses), `engMs` from the `engine.start()` call.
    public static func firstFrameLine(gen: Int, ms: Int, engMs: Int) -> String {
        return "audioVp ev=ff gen=\(gen) ms=\(ms) eng_ms=\(engMs)"
    }

    /// The watchdog judged a start starved and restarted without VP-IO. `sinceStartMs` is the age
    /// of the LATEST start at that instant; `stale` = the timer belonged to an older generation
    /// than the engine it looked at; `engineRunning` = `AVAudioEngine.isRunning` (an engine stopped
    /// by a configuration change reads 0).
    public static func fireLine(gen: Int, sinceStartMs: Int, stale: Bool, engineRunning: Bool) -> String {
        let staleFlag: Int = stale ? 1 : 0
        let runFlag: Int = engineRunning ? 1 : 0
        return "audioVp ev=fire gen=\(gen) since_start_ms=\(sinceStartMs) stale=\(staleFlag) er=\(runFlag)"
    }

    /// An `AVAudioEngineConfigurationChange` reached the live engine. `sinceEngineMs` counts from
    /// the `engine.start()` call.
    public static func configChangeLine(gen: Int, sinceEngineMs: Int) -> String {
        return "audioVp ev=cfg gen=\(gen) eng_ms=\(sinceEngineMs)"
    }

    // MARK: - Per-call ledger

    /// What the VP-IO watchdog saw during one call. Owned by `AudioCapture` (main queue); the
    /// tap thread never touches it. One `AudioCapture` instance is one call.
    public struct Ledger: Equatable {
        /// Starts that armed the watchdog (VP-IO active).
        public private(set) var armedStarts: Int = 0
        /// First tap buffer of the FIRST armed start of the call: ms from the end of `start()` /
        /// from the `engine.start()` call. -1 = that start never delivered inside the window.
        public private(set) var firstStartFrameMs: Int = -1
        public private(set) var firstStartFrameEngMs: Int = -1
        /// Same, for the most recent armed start. -1 = it never delivered inside the window.
        public private(set) var lastStartFrameMs: Int = -1
        /// Watchdog expiries that restarted the engine without VP-IO.
        public private(set) var starveFired: Int = 0
        /// Watchdog expiries whose generation was no longer the current one (a timer armed for an
        /// engine that had already been replaced). W-VPIOWD ignores them; the first build of the
        /// observability package still acted on them, and counted them here as well as in `starveFired`.
        public private(set) var starveStale: Int = 0
        /// Generation of the last expiry that restarted the engine, and the age of the latest start then.
        public private(set) var lastStarveGen: Int = 0
        public private(set) var lastStarveMs: Int = -1
        /// `AVAudioEngineConfigurationChange` notifications within `configWindowMs` of an `engine.start()`.
        public private(set) var cfgChanges2s: Int = 0

        public init() {}

        public mutating func noteArmed() {
            armedStarts += 1
            lastStartFrameMs = -1
        }

        public mutating func noteFirstFrame(ms: Int, engMs: Int) {
            lastStartFrameMs = ms
            if armedStarts == 1 {
                firstStartFrameMs = ms
                firstStartFrameEngMs = engMs
            }
        }

        public mutating func noteStarve(gen: Int, sinceStartMs: Int, stale: Bool) {
            starveFired += 1
            if stale { starveStale += 1 }
            lastStarveGen = gen
            lastStarveMs = sinceStartMs
        }

        public mutating func noteStaleExpiry() {
            starveStale += 1
        }

        public mutating func noteConfigChange(sinceEngineMs: Int) {
            if sinceEngineMs >= 0 && sinceEngineMs <= VpioObservability.configWindowMs {
                cfgChanges2s += 1
            }
        }
    }

    /// The first 2 s after an `engine.start()`: where a configuration change silences a tap.
    public static let configWindowMs: Int = 2_000

    // MARK: - Once-per-call environment

    /// What the phone looked like when the call's first engine was built. Every field optional:
    /// what could not be read is left out of the telemetry, never faked.
    public struct Environment: Equatable {
        public var hwMachine: String?        // sysctl hw.machine, e.g. "iPhone15,2"
        public var osBuild: String?          // sysctl kern.osversion, e.g. "23G80"
        public var micMode: Int?             // AVCaptureDevice.activeMicrophoneMode.rawValue (0 standard, 1 wide, 2 voice isolation)
        public var inputPorts: String?       // availableInputs port types, comma-joined
        public var preferredInput: String?   // preferredInput port type, "none" when unset
        public var tapFmtBefore: String?     // "<Hz>/<channels>" of the input node BEFORE enableVoiceProcessing
        public var tapFmtAfter: String?      // same, AFTER

        public init() {}
    }

    /// Keep a value that ships as a telemetry string readable and small: ASCII letters, digits and
    /// `, . - _ /` only, at most `maxLen` characters, nil when nothing is left.
    public static func sanitizedToken(_ raw: String, maxLen: Int = 40) -> String? {
        var out: String = ""
        for scalar in raw.unicodeScalars {
            let v: UInt32 = scalar.value
            let isDigit: Bool = v >= 48 && v <= 57
            let isUpper: Bool = v >= 65 && v <= 90
            let isLower: Bool = v >= 97 && v <= 122
            let isPunct: Bool = allowedPunctuation.contains(v)
            if isDigit || isUpper || isLower || isPunct {
                out.unicodeScalars.append(scalar)
                if out.unicodeScalars.count >= maxLen { break }
            }
        }
        return out.isEmpty ? nil : out
    }

    /// `,` `.` `-` `_` `/` as scalar values.
    private static let allowedPunctuation: Set<UInt32> = [44, 46, 45, 95, 47]

    /// "<Hz>/<channels>", e.g. "48000/1"; "0/0" for the not-yet-negotiated format.
    public static func tapFormatString(sampleRate: Double, channels: Int) -> String {
        var hz: Int = 0
        if sampleRate.isFinite && sampleRate > 0 && sampleRate < 1_000_000 {
            hz = Int(sampleRate.rounded())
        }
        var ch: Int = 0
        if channels > 0 && channels < 1_000 { ch = channels }
        return "\(hz)/\(ch)"
    }

    /// Longest single port-type token that ships whole: `LogRedactor.redactStructured` (applied on the
    /// device to every telemetry string) masks a run of 20 or more `[A-Za-z0-9+/=_-]` characters, and a
    /// comma ends a run. `ContinuityMicrophone` (iOS 17+) is exactly 20.
    public static let maxPortTokenLen: Int = 19

    /// One `AVAudioSession` port type as it ships in `input_ports` / `preferred_input`: the known type
    /// that would be masked whole is shortened to `ContinuityMic`, anything else is bounded to
    /// `maxPortTokenLen`. nil when nothing is left.
    public static func portToken(_ raw: String) -> String? {
        let name: String = (raw == "ContinuityMicrophone") ? "ContinuityMic" : raw
        return sanitizedToken(name, maxLen: maxPortTokenLen)
    }

    /// Comma-joined port types, in the order given, at most `maxPorts` of them; nil when empty.
    public static func portsList(_ portTypes: [String], maxPorts: Int = 8) -> String? {
        var cleaned: [String] = []
        for raw in portTypes {
            if let token = portToken(raw) {
                cleaned.append(token)
                if cleaned.count >= maxPorts { break }
            }
        }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: ",")
    }

    /// `sysctlbyname` string value (`hw.machine`, `kern.osversion`), nil when the name is unknown.
    public static func sysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        var bytes: [UInt8] = []
        for c in buffer {
            if c == 0 { break }
            bytes.append(UInt8(bitPattern: c))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - call.audio.diag attributes

    /// The attribute set `CallService` merges into `call.audio.diag` at call end. Naming follows the
    /// server's attribute contract: units in the name, and a key is OMITTED when it was not measured
    /// (a placeholder would read as a real zero).
    ///
    /// * `vpio_watchdog_gen` -- engine generations this call went through (+1 per start and per stop).
    /// * `vpio_starts` -- starts that armed the watchdog.
    /// * `vpio_first_frame_ms` / `vpio_first_frame_eng_ms` -- first VP-IO start: first tap buffer, ms
    ///   from the end of `start()` / from `engine.start()`. Absent = it never delivered in the window.
    /// * `vpio_last_frame_ms` -- the same for the most recent armed start.
    /// * `vpio_starve_fired` / `vpio_starve_stale` -- watchdog expiries that restarted the engine /
    ///   whose generation was no longer current. `vpio_starve_gen` / `vpio_starve_ms` -- generation
    ///   and start age at the last restart.
    /// * `engine_cfg_changes_2s` -- configuration changes within 2 s of an `engine.start()`.
    /// * `hw_machine`, `os_build`, `mic_mode`, `input_ports`, `preferred_input`, `tap_fmt_before`,
    ///   `tap_fmt_after` -- the once-per-call environment.
    public static func diagAttrs(ledger: Ledger, gen: Int, env: Environment?) -> [String: Any] {
        var attrs: [String: Any] = [:]
        attrs["vpio_watchdog_gen"] = gen
        attrs["vpio_starts"] = ledger.armedStarts
        attrs["vpio_starve_fired"] = ledger.starveFired
        attrs["vpio_starve_stale"] = ledger.starveStale
        attrs["engine_cfg_changes_2s"] = ledger.cfgChanges2s
        if ledger.firstStartFrameMs >= 0 { attrs["vpio_first_frame_ms"] = ledger.firstStartFrameMs }
        if ledger.firstStartFrameEngMs >= 0 { attrs["vpio_first_frame_eng_ms"] = ledger.firstStartFrameEngMs }
        if ledger.lastStartFrameMs >= 0 { attrs["vpio_last_frame_ms"] = ledger.lastStartFrameMs }
        if ledger.starveFired > 0 {
            attrs["vpio_starve_gen"] = ledger.lastStarveGen
            if ledger.lastStarveMs >= 0 { attrs["vpio_starve_ms"] = ledger.lastStarveMs }
        }
        if let env = env {
            if let v = env.hwMachine { attrs["hw_machine"] = v }
            if let v = env.osBuild { attrs["os_build"] = v }
            if let v = env.micMode { attrs["mic_mode"] = v }
            if let v = env.inputPorts { attrs["input_ports"] = v }
            if let v = env.preferredInput { attrs["preferred_input"] = v }
            if let v = env.tapFmtBefore { attrs["tap_fmt_before"] = v }
            if let v = env.tapFmtAfter { attrs["tap_fmt_after"] = v }
        }
        return attrs
    }
}
