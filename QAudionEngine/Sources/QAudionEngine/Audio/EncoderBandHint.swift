import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// A ceiling on the audio band the call's native Opus encoder codes, for a call whose microphone is a
/// Bluetooth hands-free link. That link carries telephony audio: 8 kHz sampling (a 4 kHz band) or 16 kHz
/// (an 8 kHz band). The hint is a ceiling, never a forced bandwidth, and it leaves bitrate, packet size,
/// packet rate and CBR alone.
///
/// Off by default: the server flag `calls.bt_hfp_band_hint` (public flags file) switches it on for a field
/// comparison, and it does nothing on a WebRTC build that does not have the native setter.
///
/// Pure rules in `EncoderBandHint`, the per-process state in `EncoderBandHintController`. Foundation only
/// (the AVAudioSession read is isolated in the controller), so the rules are unit-tested off-device
/// (`EncoderBandHintTests`). Same rule as the Android client: a measured rate on a hands-free route gives a
/// limit, an unknown or higher rate gives none.
public enum EncoderBandHint {

    /// Server flag in the public flags file, default off.
    public static let flagKey: String = "calls.bt_hfp_band_hint"

    /// What the native setter reads as "no limit".
    public static let noLimit: Int = -1

    /// Playback rate that caps the encoder at narrowband (a 4 kHz band).
    public static let narrowbandHz: Int = 8000

    /// Playback rate that caps the encoder at wideband (an 8 kHz band).
    public static let widebandHz: Int = 16000

    /// `AVAudioSession.Port.bluetoothHFP.rawValue`.
    static let handsFreePort: String = "BluetoothHFP"

    /// The ceiling for a route, in Hz, or `noLimit`. Only a microphone that is the hands-free link counts
    /// (the input being hands-free is what forces the narrow telephony band; a hands-free output with the
    /// built-in microphone still has the full band), and only with a measured session rate of 16 kHz or less.
    public static func limitHz(inputPort: String?, sampleRateHz: Double) -> Int {
        guard inputPort == handsFreePort else { return noLimit }
        guard sampleRateHz.isFinite, sampleRateHz > 0 else { return noLimit }
        if sampleRateHz <= Double(narrowbandHz) { return narrowbandHz }
        if sampleRateHz <= Double(widebandHz) { return widebandHz }
        return noLimit
    }

    /// With the flag off nothing is ever capped, whatever the route says.
    public static func target(flagOn: Bool, limitHz: Int) -> Int {
        return flagOn ? limitHz : noLimit
    }

    /// 0 no limit, 1 narrowband, 2 wideband: the small code the log line carries instead of the rate.
    public static func code(forHz hz: Int) -> Int {
        if hz == narrowbandHz { return 1 }
        if hz == widebandHz { return 2 }
        return 0
    }

    /// `audioroute band=<0|1|2> old=<0|1|2> sr=<Hz>`: one line each time the hint that reached the encoder
    /// changes. Numbers only (plus the `audioroute` family word), so the log shipper's vocabulary gate and the
    /// in-app redactor keep it; `sr` is the session sample rate the decision rested on and is omitted when it
    /// cannot be read.
    public static func logLine(hz: Int, previousHz: Int, sampleRateHz: Double) -> String {
        var out: String = "audioroute"
        out += CallMetricsLines.field("band", code(forHz: hz))
        out += CallMetricsLines.field("old", code(forHz: previousHz))
        out += CallMetricsLines.field("sr", CallRouteDiagnostics.sampleRateInt(sampleRateHz))
        return out
    }

    /// `audioroute nosetter=1`: written once per process, the first time a ceiling was wanted (flag on, hands-free
    /// microphone) and the WebRTC build had no native setter to hand it to. Fixed text, one numeric field, so the
    /// log shipper's vocabulary gate keeps it (a longer key would be masked as a blob).
    public static let unsupportedLine: String = "audioroute nosetter=1"
}

/// Process-wide holder of the hint that is currently in force in the native encoder.
///
/// The native setter is process-wide, so one controller serves the process: `update` hands a new target to it
/// (only when it differs from what it already has) and `clear` takes the hint back. A setter that is not there
/// (`apply` answers false) leaves the state untouched, so nothing is remembered and the next update asks again;
/// the first time a ceiling was wanted and could not be handed over, one fixed line says so
/// (`EncoderBandHint.unsupportedLine`).
///
/// `startObserving` ties the controller to one call: it follows `AVAudioSession` route changes (and re-reads the
/// route a moment later, because a hands-free link settles on its rate after the notification) until the same call
/// stops it. The owner token keeps a replaced call's late `stopObserving` from switching off its successor, and a
/// route read taken for a call is handed to the encoder only while that call is still the one observing (checked
/// under the lock, right before the hand-over, so a stop that came in during the read wins).
public final class EncoderBandHintController: @unchecked Sendable {

    /// The controller of the process: the real native setter. Lines go through `print` until the app sets
    /// `lineSink` at launch (this module cannot reach the app's `RTLog`).
    public static let shared: EncoderBandHintController = EncoderBandHintController.makeShared()

    private let lock = NSLock()
    private let nativeSetter: @Sendable (Int) -> Bool
    private var logSink: @Sendable (String) -> Void
    private var unsupportedLogged: Bool = false
    private var appliedHz: Int = EncoderBandHint.noLimit
    private var flagProviderStorage: (@Sendable () -> Bool)?
    private var observer: NSObjectProtocol?
    private var ownerId: UInt64 = 0

    public init(apply: @escaping @Sendable (Int) -> Bool, log: @escaping @Sendable (String) -> Void) {
        self.nativeSetter = apply
        self.logSink = log
    }

    private static func makeShared() -> EncoderBandHintController {
        #if canImport(WebRTC)
        return EncoderBandHintController(
            apply: { hz in QaudionRuntimeTuning.setEncoderMaxPlaybackRate(hz) },
            log: { line in print(line) })
        #else
        return EncoderBandHintController(apply: { _ in false }, log: { line in print(line) })
        #endif
    }

    /// Reads `EncoderBandHint.flagKey` from the app's feature flags; set once at app start. Called on the main
    /// thread only (the flags are main-actor state). Unset reads as off.
    public var flagProvider: (@Sendable () -> Bool)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return flagProviderStorage
        }
        set {
            lock.lock()
            flagProviderStorage = newValue
            lock.unlock()
        }
    }

    /// Where the log lines go. The app sets it once at launch to `RTLog.info("call", line)`, the tag the other
    /// `audioroute` lines use; until then (and in tests) it is what `init` was given.
    public var lineSink: @Sendable (String) -> Void {
        get {
            lock.lock()
            defer { lock.unlock() }
            return logSink
        }
        set {
            lock.lock()
            logSink = newValue
            lock.unlock()
        }
    }

    /// The ceiling currently in force, `EncoderBandHint.noLimit` when none.
    public var currentHz: Int {
        lock.lock()
        defer { lock.unlock() }
        return appliedHz
    }

    /// Re-evaluates the route and hands the result to the encoder if it changed. Returns the ceiling in force.
    @discardableResult
    public func update(flagOn: Bool, inputPort: String?, sampleRateHz: Double) -> Int {
        return update(flagOn: flagOn, inputPort: inputPort, sampleRateHz: sampleRateHz, owner: nil)
    }

    /// The same, for a route read taken on behalf of one call (`owner` is the token `startObserving` returned):
    /// it is handed to the encoder only if that call is still the one observing at the moment of the hand-over.
    @discardableResult
    func update(flagOn: Bool, inputPort: String?, sampleRateHz: Double, owner: UInt64?) -> Int {
        let limit: Int = EncoderBandHint.limitHz(inputPort: inputPort, sampleRateHz: sampleRateHz)
        let target: Int = EncoderBandHint.target(flagOn: flagOn, limitHz: limit)
        return set(target: target, sampleRateHz: sampleRateHz, owner: owner)
    }

    /// Takes the hint back (end of the call, or a flag turned off).
    public func clear() {
        _ = set(target: EncoderBandHint.noLimit, sampleRateHz: 0)
    }

    private func set(target: Int, sampleRateHz: Double, owner: UInt64? = nil) -> Int {
        lock.lock()
        let previous: Int = appliedHz
        // A read taken for a call (`owner`) was made before this lock was taken. If that call stopped, or was
        // replaced, in the meantime, its answer is stale: applying it would put the ceiling back after the stop
        // took it away, and the setter is process-wide, so the next call would start with it. Checked here, in the
        // same lock hold as the hand-over, so a stop that already happened cannot be overtaken.
        if let owner = owner, observer == nil || ownerId != owner {
            lock.unlock()
            return previous
        }
        if target == previous {
            lock.unlock()
            return previous
        }
        // The native setter is a process-wide atomic store behind an Objective-C selector lookup (see
        // `QaudionRuntimeTuning`): it returns at once, so it runs under the lock. That keeps the "differs from
        // what is in force" check, the owner check above and the hand-over in one step.
        let accepted: Bool = nativeSetter(target)
        var reportUnsupported: Bool = false
        if accepted {
            appliedHz = target
        } else if target != EncoderBandHint.noLimit && !unsupportedLogged {
            // Flag on and a ceiling wanted, but this WebRTC build has no setter: say so once per process.
            unsupportedLogged = true
            reportUnsupported = true
        }
        let sink: @Sendable (String) -> Void = logSink
        lock.unlock()
        guard accepted else {
            if reportUnsupported { sink(EncoderBandHint.unsupportedLine) }
            return previous
        }
        sink(EncoderBandHint.logLine(hz: target, previousHz: previous, sampleRateHz: sampleRateHz))
        return target
    }

    /// Follows the route for the life of one call. Returns the token to hand back to `stopObserving`.
    @discardableResult
    public func startObserving() -> UInt64 {
        lock.lock()
        ownerId &+= 1
        let owner: UInt64 = ownerId
        lock.unlock()
        #if canImport(AVFoundation) && os(iOS)
        registerRouteObserverIfNeeded()
        // The first read waits for the main thread (the flag is main-actor state), then once more after the
        // link has had time to settle.
        DispatchQueue.main.async { [weak self] in self?.refreshFromAudioSession(owner: owner) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.refreshFromAudioSession(owner: owner)
        }
        #endif
        return owner
    }

    /// Ends the call's observation and takes the hint back. A token that is not the current owner's is ignored.
    public func stopObserving(owner: UInt64) {
        lock.lock()
        guard owner == ownerId else {
            lock.unlock()
            return
        }
        let token: NSObjectProtocol? = observer
        observer = nil
        lock.unlock()
        if let token = token {
            NotificationCenter.default.removeObserver(token)
        }
        clear()
    }

    #if canImport(AVFoundation) && os(iOS)
    private func registerRouteObserverIfNeeded() {
        lock.lock()
        let alreadyObserving: Bool = observer != nil
        lock.unlock()
        if alreadyObserving { return }
        let token: NSObjectProtocol = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.routeChanged()
        }
        lock.lock()
        if observer == nil {
            observer = token
            lock.unlock()
        } else {
            lock.unlock()
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func routeChanged() {
        lock.lock()
        let owner: UInt64 = ownerId
        lock.unlock()
        refreshFromAudioSession(owner: owner)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshFromAudioSession(owner: owner)
        }
    }

    /// Main thread only. Does nothing once the call `owner` stopped observing (or was replaced); the same check is
    /// made again under the lock inside `update`, because the session is read after this one.
    private func refreshFromAudioSession(owner: UInt64) {
        lock.lock()
        let observing: Bool = observer != nil && ownerId == owner
        let provider: (@Sendable () -> Bool)? = flagProviderStorage
        lock.unlock()
        guard observing else { return }
        let session = AVAudioSession.sharedInstance()
        let inputPort: String? = session.currentRoute.inputs.first?.portType.rawValue
        let sampleRate: Double = session.sampleRate
        let flagOn: Bool = provider?() ?? false
        update(flagOn: flagOn, inputPort: inputPort, sampleRateHz: sampleRate, owner: owner)
    }
    #endif
}
