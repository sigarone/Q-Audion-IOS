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
}

/// Process-wide holder of the hint that is currently in force in the native encoder.
///
/// The native setter is process-wide, so one controller serves the process: `update` hands a new target to it
/// (only when it differs from what it already has) and `clear` takes the hint back. A setter that is not there
/// (`apply` answers false) leaves the state untouched, so nothing is logged or remembered and the next update
/// asks again.
///
/// `startObserving` ties the controller to one call: it follows `AVAudioSession` route changes (and re-reads the
/// route a moment later, because a hands-free link settles on its rate after the notification) until the same call
/// stops it. The owner token keeps a replaced call's late `stopObserving` from switching off its successor.
public final class EncoderBandHintController: @unchecked Sendable {

    /// The controller of the process: the real native setter, lines through `print` (the stdout tee ships them).
    public static let shared: EncoderBandHintController = EncoderBandHintController.makeShared()

    private let lock = NSLock()
    private let nativeSetter: @Sendable (Int) -> Bool
    private let logSink: @Sendable (String) -> Void
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

    /// The ceiling currently in force, `EncoderBandHint.noLimit` when none.
    public var currentHz: Int {
        lock.lock()
        defer { lock.unlock() }
        return appliedHz
    }

    /// Re-evaluates the route and hands the result to the encoder if it changed. Returns the ceiling in force.
    @discardableResult
    public func update(flagOn: Bool, inputPort: String?, sampleRateHz: Double) -> Int {
        let limit: Int = EncoderBandHint.limitHz(inputPort: inputPort, sampleRateHz: sampleRateHz)
        let target: Int = EncoderBandHint.target(flagOn: flagOn, limitHz: limit)
        return set(target: target, sampleRateHz: sampleRateHz)
    }

    /// Takes the hint back (end of the call, or a flag turned off).
    public func clear() {
        _ = set(target: EncoderBandHint.noLimit, sampleRateHz: 0)
    }

    private func set(target: Int, sampleRateHz: Double) -> Int {
        lock.lock()
        let previous: Int = appliedHz
        if target == previous {
            lock.unlock()
            return previous
        }
        // The native setter is lock-free and returns at once, so it runs under the lock: two updates can never
        // interleave their "differs from what is in force" check and their hand-over.
        let accepted: Bool = nativeSetter(target)
        if accepted {
            appliedHz = target
        }
        lock.unlock()
        guard accepted else { return previous }
        logSink(EncoderBandHint.logLine(hz: target, previousHz: previous, sampleRateHz: sampleRateHz))
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
        DispatchQueue.main.async { [weak self] in self?.refreshFromAudioSession() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in self?.refreshFromAudioSession() }
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
        refreshFromAudioSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshFromAudioSession()
        }
    }

    /// Main thread only. Does nothing once the call stopped observing.
    private func refreshFromAudioSession() {
        lock.lock()
        let observing: Bool = observer != nil
        let provider: (@Sendable () -> Bool)? = flagProviderStorage
        lock.unlock()
        guard observing else { return }
        let session = AVAudioSession.sharedInstance()
        let inputPort: String? = session.currentRoute.inputs.first?.portType.rawValue
        let sampleRate: Double = session.sampleRate
        let flagOn: Bool = provider?() ?? false
        update(flagOn: flagOn, inputPort: inputPort, sampleRateHz: sampleRate)
    }
    #endif
}
