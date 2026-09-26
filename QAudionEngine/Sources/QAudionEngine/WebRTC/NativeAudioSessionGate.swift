import AVFoundation
import Foundation
import WebRTC

/// W-ADMNOMANUAL (2026-08-31) — manual audio mode is GONE. This type is kept
/// as an inert seam plus the record of why, because the idea ("CallKit apps
/// should use `RTCAudioSession.useManualAudio`") is superficially right and
/// will otherwise be reintroduced.
///
/// What was tried, and what each attempt measured on a live call:
///
///   1.0.1053  `useManualAudio = true` + `isAudioEnabled` at the gate=4
///             chokepoint. The app's own session configuration stopped being
///             the one in force: `buf=0.02` (the SDK's default) where the app
///             asks for 0.005.
///   1.0.1056  plus the documented `audioSessionDidActivate` relay. Capture
///             died outright — `audioIO capfail=1` appears here for the first
///             time and in every build after, and the in-call session reported
///             `in=` EMPTY, `out=Speaker`.
///   1.0.1066  relay removed, manual mode kept. The route probe caught the
///             moment of death, two `gate=4` lines one second apart:
///                 inp=1 outp=1 rec=1 buf=5     <- correct session
///                 inp=0 outp=1 rec=1 buf=20    <- after isAudioEnabled=true
///             `rec=1` throughout: the microphone is available, it is simply
///             no longer in the route. Enabling the unit is what makes the SDK
///             reconfigure the session out from under the app.
///
/// Both directions of the same mistake: this app configures and activates
/// `AVAudioSession` directly (AudioProcessingPipeline.configureForVoIP,
/// CallKitProvider), which is outside `RTCAudioSession`'s bookkeeping. With
/// the relay the SDK reconfigures; without it the SDK believes the session is
/// inactive and tears it down. Manual mode only has a coherent meaning if the
/// app ALSO routes every session mutation and activation through
/// `RTCAudioSession` under its lock — a much larger change than the one this
/// file attempted, and not one to make blind.
///
/// So: automatic mode, the arrangement that shipped for months and that the
/// telemetry shows with a healthy session (`buf=0.005 vpio=true`, no
/// `capfail`) up to and including 1.0.1052. WebRTC starts its own audio unit
/// when a track is ready, as it always did. The genuine defect 1053 was built
/// to fix — the callee announcing no outbound audio — was a JSEP transceiver
/// problem and is fixed independently by W-PREATTACHMIC.
///
/// Both entry points are deliberately kept and deliberately do nothing, so
/// the call sites keep documenting where the audio unit's lifecycle would be
/// controlled if this is ever revisited WITH the full contract in hand.
///
/// W-CKAUDIOFORWARD (2026-09-09) — a narrower, separate change landed in
/// `CallKitProvider` (both `didActivate`/`didDeactivate` and the
/// self-activation fallback): forwarding CallKit's own activation/
/// deactivation into `RTCAudioSession` so it isn't purely inferring session
/// state from its own passive observation. This is NOT the same attempt as
/// 1053/1056/1066 above — `useManualAudio` stays `false` (this file's two
/// entry points are untouched, still no-ops) and `isAudioEnabled` is never
/// set. Those three attempts all coupled the relay to manual mode, which is
/// what the analysis above pins the actual regression on (the app's own
/// direct session ownership fighting the SDK's manual-mode reconfiguration);
/// this change only informs automatic mode of an event it has no other way
/// to observe. Still needs its own live call-to-call verification before
/// being trusted — a different variable than 1056 is not a proof, only a
/// reason to expect a different result.
///
/// W-ADMMANUAL (2026-09-26) — manual audio mode is BACK, but only for a call
/// whose native-SRTP snapshot is on (`CallCapabilities.nativeSrtpCallSnapshot`),
/// and this time with the contract the note above said was missing:
///
/// * Armed in `QAudionPeerConnection.init`, BEFORE the mic track is added and
///   before any SDP: in automatic mode WebRTC's audio device module activated
///   the session itself (`configureWebRTCSession` → `setActive(YES)`) and
///   started its VoiceProcessingIO unit the moment the first audio stream
///   started — at RING time on both roles, before CallKit's `didActivate`.
///   With `useManualAudio = true` and `isAudioEnabled = false` the module only
///   creates its unit object and waits.
/// * `isAudioEnabled = true` is set from ONE place, `CallService.startAudioIOIfReady`'s
///   native branch, only when `NativeAudioUnitGateDecisions.verdict` says so
///   (session active from CallKit, call answered, native negotiated, relay
///   fallback not engaged, custom `AudioCapture` stopped). `false` on
///   CallKit `didDeactivate`, call teardown, relay-fallback engage, and
///   (backstop) `QAudionPeerConnection.close()` before `pc.close()`.
/// * WebRTC's own session configuration (`RTCAudioSessionConfiguration`
///   `webRTC`) is aligned with the app's (playAndRecord / voiceChat /
///   allowBluetoothHFP / 48 kHz / 5 ms) before arming, so enabling the unit
///   no longer re-applies WebRTC's defaults (the `buf=20` of 1.0.1066) over
///   the app's session.
/// * The custom path is untouched on every other call: nothing here runs
///   unless a native-SRTP call armed it (`isArmed`).
/// * Never reverted to `useManualAudio = false` inside the process: calls
///   with native SRTP off have no m=audio line, so WebRTC's audio module never
///   starts for them and the value is irrelevant, while flipping it back to
///   `false` with a unit object still alive (PeerConnection teardown has no
///   completion signal) would restart that unit on the spot. Conservative
///   choice where the fork's behaviour is not determinable from here.
/// * Note on the 1053/1056/1066 history above: until W-SRTPFBRESET
///   (2026-09-08) the relay-fallback latch was never reset between calls, so
///   those trials very likely ran the custom `AudioCapture` VoiceProcessingIO
///   next to WebRTC's on every call after the first — the `inp=0` they
///   measured is also what two concurrent VoiceProcessingIO units produce.
///
/// Every decision emits one numeric `admgate ...` line through ``log``.
public enum NativeAudioSessionGate {

    /// RTLog bridge — this engine module cannot reach `RTLog`. Wired once at
    /// login by AppState. Lines are numeric (redactor-safe) and carry no key
    /// material.
    public static var log: ((String) -> Void)?

    /// WebRTC's session configuration while armed: identical to
    /// `AudioProcessingPipeline.configureForVoIP()` (5 ms, 48 kHz) and
    /// `CallKitProvider`'s category/mode/options.
    static let webRtcIoBufferDuration: TimeInterval = 0.005
    static let webRtcSampleRate: Double = 48_000

    private static let lock = NSLock()
    /// Non-zero while a native-SRTP call owns manual mode. A token, not a
    /// Bool, so a replaced PeerConnection of the same call (glare, duplicate
    /// OFFER) closing late cannot disarm the one that replaced it.
    private static var armedToken: Int = 0
    private static var lastToken: Int = 0
    /// Set when a native call arms; consumed by `CallKitProvider.reportCallEnded`
    /// to pick the balanced single deactivation (W-ADMBALANCE).
    private static var nativeCallAwaitingBalance = false

    /// `true` while a native-SRTP call armed manual mode.
    public static var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return armedToken != 0
    }

    /// Item 1 — arm manual mode for a native-SRTP call. Must run before the
    /// PeerConnection's audio track is added and before any SDP is applied.
    /// Returns the token `disarm(token:)` needs.
    @discardableResult
    public static func armManualMode() -> Int {
        let cfgFields = applyWebRtcSessionConfiguration()
        let session = RTCAudioSession.sharedInstance()
        let prevManual = session.useManualAudio
        let prevEnabled = session.isAudioEnabled
        // Disable first, then manual on: `canPlayOrRecord` (= !manual || enabled)
        // flips to false at most once, and never to true on the way.
        session.isAudioEnabled = false
        session.useManualAudio = true
        lock.lock()
        lastToken &+= 1
        if lastToken <= 0 { lastToken = 1 }
        armedToken = lastToken
        nativeCallAwaitingBalance = true
        let token = armedToken
        lock.unlock()
        let prevManualFlag = prevManual ? 1 : 0
        let prevEnabledFlag = prevEnabled ? 1 : 0
        emit("admgate arm=1 prevman=\(prevManualFlag) preven=\(prevEnabledFlag) cfg=\(cfgFields) tok=\(token)")
        return token
    }

    /// Items 3-6/9 — start (`true`) or stop (`false`) WebRTC's audio unit.
    /// No-op unless a native-SRTP call armed manual mode, so no other call
    /// can reach `isAudioEnabled`. `reason` is a
    /// `NativeAudioUnitGateDecisions.ChangeReason` raw value (log only).
    /// Returns `true` when the state actually changed.
    @discardableResult
    public static func setNativeAudioActive(_ active: Bool, reason: Int) -> Bool {
        guard isArmed else { return false }
        let session = RTCAudioSession.sharedInstance()
        let activeFlag = active ? 1 : 0
        guard session.useManualAudio else {
            emit("admgate en=\(activeFlag) why=\(reason) skip=1")
            return false
        }
        guard session.isAudioEnabled != active else { return false }
        session.isAudioEnabled = active
        let count = session.activationCount
        let sessionActive = session.isActive ? 1 : 0
        emit("admgate en=\(activeFlag) why=\(reason) cnt=\(count) act=\(sessionActive)")
        return true
    }

    /// Whether `token` is the arm currently in force (a replaced
    /// PeerConnection of the same call holds a stale one).
    public static func isCurrent(token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token != 0 && armedToken == token
    }

    /// Whether WebRTC's unit is currently allowed to run (armed AND enabled).
    public static var isNativeAudioEnabled: Bool {
        guard isArmed else { return false }
        return RTCAudioSession.sharedInstance().isAudioEnabled
    }

    /// Release manual-mode ownership after the PeerConnection that armed it
    /// closed. Ignored for a stale token (a replaced PeerConnection).
    public static func disarm(token: Int) {
        lock.lock()
        guard token != 0, armedToken == token else {
            let current = armedToken
            lock.unlock()
            emit("admgate disarm=0 tok=\(token) cur=\(current)")
            return
        }
        armedToken = 0
        lock.unlock()
        let session = RTCAudioSession.sharedInstance()
        if session.isAudioEnabled { session.isAudioEnabled = false }
        let manualFlag = session.useManualAudio ? 1 : 0
        emit("admgate disarm=1 tok=\(token) man=\(manualFlag)")
    }

    /// Item 10 (every call) — at PeerConnection construction, before a
    /// native call arms: a unit left enabled by a previous call must not be
    /// inherited. Minimal: touches `isAudioEnabled` only when manual mode is
    /// on AND it is still enabled (a leak); on a call with native SRTP off it
    /// also drops a stale arm/balance latch, so that call's lifecycle
    /// (including reportCallEnded's drain) is exactly the legacy one.
    public static func auditAtCallStart(nativeCall: Bool) {
        if !nativeCall {
            lock.lock()
            let wasArmed = armedToken != 0
            armedToken = 0
            nativeCallAwaitingBalance = false
            lock.unlock()
            if wasArmed { emit("admgate audit=1 stalearm=1") }
        }
        let session = RTCAudioSession.sharedInstance()
        guard session.useManualAudio, session.isAudioEnabled else { return }
        session.isAudioEnabled = false
        let nativeFlag = nativeCall ? 1 : 0
        emit("admgate audit=1 forced=1 native=\(nativeFlag)")
    }

    /// W-ADMBALANCE — `true` once per native call end (read and cleared).
    public static func consumeNativeCallBalanceFlag() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = nativeCallAwaitingBalance
        nativeCallAwaitingBalance = false
        return value
    }

    // MARK: - Item 2: WebRTC's session configuration

    /// Aligns `RTCAudioSessionConfiguration`'s global WebRTC configuration —
    /// the one WebRTC applies when its unit is enabled — with the app's own
    /// session. Returns how many fields were applied (5 expected), 0 if the
    /// global setter is missing.
    ///
    /// COMPILE SAFETY: this SDK's headers are not available locally and none
    /// of `category`/`mode`/`categoryOptions`/`sampleRate`/`ioBufferDuration`
    /// or `+setWebRTCConfiguration:` is used anywhere else in this repo, so
    /// they are reached through KVC and the Objective-C runtime, each guarded
    /// by `responds(to:)` / `class_getClassMethod`: a missing member is a
    /// logged no-op, never a build failure or a KVC exception. Only
    /// `webRTC()` is called directly (the reference implementations call it
    /// from Swift against the same upstream header).
    ///
    /// Only reached from `armManualMode()`, i.e. only on a native-SRTP call;
    /// the global it writes is read only by WebRTC's own audio module, which
    /// never runs on a call with native SRTP off (no m=audio), and the custom
    /// path configures `AVAudioSession` directly without ever reading it.
    private static func applyWebRtcSessionConfiguration() -> Int {
        let cfg = RTCAudioSessionConfiguration.webRTC()
        #if targetEnvironment(simulator)
        let options: AVAudioSession.CategoryOptions = []
        #else
        let options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        #endif
        var fields = 0
        fields += kvcSet(cfg, key: "category", setter: "setCategory:",
                         value: AVAudioSession.Category.playAndRecord.rawValue as NSString)
        fields += kvcSet(cfg, key: "mode", setter: "setMode:",
                         value: AVAudioSession.Mode.voiceChat.rawValue as NSString)
        fields += kvcSet(cfg, key: "categoryOptions", setter: "setCategoryOptions:",
                         value: NSNumber(value: options.rawValue))
        fields += kvcSet(cfg, key: "sampleRate", setter: "setSampleRate:",
                         value: NSNumber(value: webRtcSampleRate))
        fields += kvcSet(cfg, key: "ioBufferDuration", setter: "setIoBufferDuration:",
                         value: NSNumber(value: webRtcIoBufferDuration))
        let setter = NSSelectorFromString("setWebRTCConfiguration:")
        guard let method = class_getClassMethod(RTCAudioSessionConfiguration.self, setter) else {
            emit("admgate cfg=0 fields=\(fields)")
            return 0
        }
        typealias SetConfigurationFn = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let fn = unsafeBitCast(method_getImplementation(method), to: SetConfigurationFn.self)
        fn(RTCAudioSessionConfiguration.self as AnyObject, setter, cfg)
        return fields
    }

    private static func kvcSet(_ object: NSObject, key: String, setter: String, value: AnyObject) -> Int {
        guard object.responds(to: NSSelectorFromString(setter)) else { return 0 }
        object.setValue(value, forKey: key)
        return 1
    }

    private static func emit(_ line: String) {
        let out: String = "[NativeAudioSessionGate] " + line
        print(out)
        log?(line)
    }
}
