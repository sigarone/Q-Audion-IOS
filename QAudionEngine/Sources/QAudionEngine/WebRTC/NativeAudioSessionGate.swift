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

    /// Asks the app layer (CallService's gate, on the main thread) to
    /// re-decide whether the unit may run — the engine cannot see the call
    /// state the verdict needs. Wired once at login by AppState.
    ///
    /// W-GATEOWNER (2026-09-27) — carries the arm `token` this request was
    /// found current for, ALONGSIDE `reason`, not instead of the ownership
    /// check below: the app layer schedules its own reapply asynchronously
    /// (`Task { @MainActor in ... }`), so the token checked here can go stale
    /// before that closure actually runs (a hand-over to a new arm in
    /// between). The receiver must revalidate with ``isCurrent(token:)``
    /// right before calling `reapplyNativeAudioUnitGate`, the same way
    /// `setNativeAudioInactive(ifCurrent:reason:)` is owner-checked at the
    /// switch itself.
    public static var onGateReapplyRequested: ((Int, Int) -> Void)?

    /// See ``onGateReapplyRequested``. No-op unless armed. `token` is the arm
    /// in force at the time of THIS call, so the receiver has something to
    /// revalidate against by the time its own (possibly deferred) reapply
    /// actually runs — see ``onGateReapplyRequested``'s kdoc.
    public static func requestGateReapply(reason: Int) {
        lock.lock()
        let current = armedToken
        lock.unlock()
        guard current != 0 else { return }
        onGateReapplyRequested?(current, reason)
    }

    /// W-NUDGEOWN (2026-09-27) — ``requestGateReapply(reason:)`` on behalf of
    /// the arm `token` only: a no-op (logged, `admgate W-GATEOWNER reapply=0`)
    /// when `token` is no longer the arm in force — a closed or replaced
    /// PeerConnection has nothing left to restart. Not itself a switch: the
    /// app layer re-decides on the main thread from the CURRENT call's state
    /// and enables the arm in force through its own enable, so even a request
    /// that passes this check just before a hand-over can only re-run the
    /// successor's own verdict, PROVIDED the app layer revalidates `token`
    /// again once its (possibly deferred) reapply actually runs — see
    /// ``onGateReapplyRequested``. Returns whether the request was forwarded.
    @discardableResult
    public static func requestGateReapply(ifCurrent token: Int, reason: Int) -> Bool {
        lock.lock()
        let current = armedToken
        lock.unlock()
        guard token != 0, current == token else {
            emit("admgate W-GATEOWNER reapply=0 why=\(reason) tok=\(token) cur=\(current)")
            return false
        }
        onGateReapplyRequested?(token, reason)
        return true
    }

    /// WebRTC's session configuration while armed: identical to
    /// `AudioProcessingPipeline.configureForVoIP()` (5 ms, 48 kHz) and
    /// `CallKitProvider`'s category/mode/options.
    static let webRtcIoBufferDuration: TimeInterval = 0.005
    static let webRtcSampleRate: Double = 48_000

    /// Guards the statics below (arm token, speaker preference).
    ///
    /// LOCK ORDER (W-ADMATOMIC, 2026-09-26): `RTCAudioSession`'s configuration
    /// lock (`lockForConfiguration()`) FIRST, then this one — never the other
    /// way round. This lock is only held for a read or write of these statics:
    /// never across an `RTCAudioSession`/`AVAudioSession` call, a log emit or
    /// a callback. Every change this type makes to `isAudioEnabled` /
    /// `useManualAudio` runs inside the configuration lock TOGETHER with the
    /// ownership check it depends on (the token, or "armed"), so no arm,
    /// enable or disarm can interleave between the check and the mutation: a
    /// stale owner can never switch a successor's unit off. The configuration
    /// lock is thread-affine, so these critical sections never await; they
    /// never call back into app code either — the two setters only notify
    /// WebRTC's own audio device module, which applies the change
    /// asynchronously on its own thread. `CallKitProvider` takes the same
    /// configuration lock and never calls into this type while holding it.
    ///
    /// OWNERS (W-GATEOWNER, 2026-09-27) — who may switch a running unit, and
    /// where that authority is checked:
    /// * an ARM TOKEN (``armManualMode()``): the PeerConnection that armed
    ///   and whatever acts for it (its `close()`, its controller's
    ///   capture-live nudge, W-NUDGEOWN), and CallService for the arm its own
    ///   enable switched on (``enableNativeAudio(reason:)`` returns it).
    ///   Checked inside the critical section above, together with the switch.
    /// * the CALL GENERATION (CallService's W-STALESEALER counter): which call
    ///   an identity-less CallKit event belongs to. Checked on the main thread,
    ///   which is where every generation bump (`CallService.endCall`) and every
    ///   enable run; the switch that follows is then owner-checked by token.
    /// * the CALLKIT UUID: the self-activation debt `CallKitProvider` balances
    ///   (`CallKitCallLedger`, under the ledger's own lock).
    /// A stale owner's request is a logged no-op, never a switch of a
    /// successor's unit. The ledger lock, CallService's `relaySlotLock`, the
    /// PeerConnection's arm-token lock and the controller's capture-live lock
    /// are leaf locks: each is released before this type is called, so the
    /// only nesting anywhere is configuration lock → this lock.
    private static let lock = NSLock()
    /// Non-zero while a native-SRTP call owns manual mode. A token, not a
    /// Bool, so a replaced PeerConnection of the same call (glare, duplicate
    /// OFFER) closing late cannot disarm the one that replaced it.
    private static var armedToken: Int = 0
    private static var lastToken: Int = 0
    // W-ADMBALANCE-UUID (2026-09-26) — the process-wide "native call awaiting
    // balance" flag that lived here is gone: `CallKitProvider` now records the
    // native call by its CallKit uuid (`CallKitCallLedger.recordNativeBalance`)
    // and `reportCallEnded` consumes that uuid's record only.
    /// W-NATIVESPKR — whether WebRTC's own session configuration must carry
    /// `.defaultToSpeaker` (the user's loudspeaker preference on a native
    /// call). WebRTC re-applies its configuration's category options every
    /// time it (re)configures the session for its unit (enable, interruption
    /// end), which silently dropped the option the loudspeaker rides on.
    private static var webRtcDefaultToSpeaker = false

    /// `true` while a native-SRTP call armed manual mode.
    public static var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return armedToken != 0
    }

    /// Item 1 — arm manual mode for a native-SRTP call. Must run before the
    /// PeerConnection's audio track is added and before any SDP is applied.
    /// Returns the token `disarm(token:)` needs.
    ///
    /// PROCESS-LIFETIME NOTE: once set here, `RTCAudioSession.useManualAudio`
    /// intentionally stays `true` until the process exits — `disarm` only
    /// switches `isAudioEnabled` off. This is inert for every call with native
    /// SRTP off: such a call has no m=audio line (the mic track is only
    /// pre-attached on a native call), so no audio stream ever starts on it
    /// and WebRTC's audio device module never initializes, whatever the
    /// manual flag says; the custom path configures `AVAudioSession` itself
    /// and never reads it; group calls (v2) use the same arm on the shared
    /// audio session. Switching it back to `false` is what would NOT be
    /// inert: with a unit object still alive (PeerConnection teardown has no
    /// completion signal) `canPlayOrRecord` would flip to `true` and restart
    /// that unit on the spot.
    @discardableResult
    public static func armManualMode() -> Int {
        lock.lock(); webRtcDefaultToSpeaker = false; lock.unlock()
        let cfgFields = applyWebRtcSessionConfiguration()
        let session = RTCAudioSession.sharedInstance()
        // W-ADMATOMIC — the session switch and the token take-over are one
        // critical section (lock order: see `lock`).
        session.lockForConfiguration()
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
        let token = armedToken
        lock.unlock()
        session.unlockForConfiguration()
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
        // Fast path, unchanged: never armed (every call with native SRTP off)
        // → the session is not touched and no lock is taken.
        guard isArmed else { return false }
        return switchUnit(active, reason: reason, requiredToken: nil).changed
    }

    /// W-DEACTOWN (2026-09-27) — `setNativeAudioActive(true, reason:)` that
    /// also returns the OWNER of the enable: the arm token in force, read in
    /// the SAME configuration-lock critical section as the switch. The caller
    /// keeps it and later stops exactly that arm with
    /// ``setNativeAudioInactive(ifCurrent:reason:)``, never a successor's.
    /// 0 when nothing is armed (no-op, same fast path as before).
    @discardableResult
    public static func enableNativeAudio(reason: Int) -> Int {
        guard isArmed else { return 0 }
        return switchUnit(true, reason: reason, requiredToken: nil).owner
    }

    /// W-ADMATOMIC (2026-09-26) — `QAudionPeerConnection.close()`'s backstop:
    /// switch the unit off only if `token` is STILL the arm in force, with the
    /// check and the switch in one critical section. It used to be
    /// `isCurrent(token:)` followed by `setNativeAudioActive(false)`: a
    /// replacement PeerConnection could arm and have its unit enabled in
    /// between, and the stale close then switched the successor's unit off.
    /// Returns `true` when the state actually changed.
    @discardableResult
    public static func setNativeAudioInactive(ifCurrent token: Int, reason: Int) -> Bool {
        guard token != 0 else { return false }
        return switchUnit(false, reason: reason, requiredToken: token).changed
    }

    /// What one `switchUnit` did: whether `isAudioEnabled` changed, and the
    /// arm token the caller was found to own (0 = not owned).
    private struct SwitchOutcome {
        let changed: Bool
        let owner: Int
    }

    /// The one place this type flips `isAudioEnabled` for a running call.
    /// Ownership (`requiredToken` is the arm in force, or — `nil` — any arm)
    /// is checked and the unit switched inside ONE configuration-lock
    /// critical section (see `lock`); the log line is emitted after it.
    ///
    /// W-GATEOWNER (2026-09-27) — an owner-checked request (`requiredToken`
    /// given) whose token is no longer the arm in force is a stale owner (a
    /// replaced PeerConnection, an ended call's event): it stays a no-op and
    /// now leaves one numeric line, `admgate W-GATEOWNER en= why= tok= cur=`.
    private static func switchUnit(_ active: Bool, reason: Int, requiredToken: Int?) -> SwitchOutcome {
        let session = RTCAudioSession.sharedInstance()
        let activeFlag = active ? 1 : 0
        session.lockForConfiguration()
        lock.lock()
        let current = armedToken
        let owned: Bool
        if let required = requiredToken {
            owned = required != 0 && current == required
        } else {
            owned = current != 0
        }
        lock.unlock()
        guard owned else {
            session.unlockForConfiguration()
            if let required = requiredToken {
                emit("admgate W-GATEOWNER en=\(activeFlag) why=\(reason) tok=\(required) cur=\(current)")
            }
            return SwitchOutcome(changed: false, owner: 0)
        }
        guard session.useManualAudio else {
            session.unlockForConfiguration()
            emit("admgate en=\(activeFlag) why=\(reason) skip=1")
            return SwitchOutcome(changed: false, owner: current)
        }
        guard session.isAudioEnabled != active else {
            session.unlockForConfiguration()
            return SwitchOutcome(changed: false, owner: current)
        }
        session.isAudioEnabled = active
        let count = session.activationCount
        let sessionActive = session.isActive ? 1 : 0
        session.unlockForConfiguration()
        emit("admgate en=\(activeFlag) why=\(reason) cnt=\(count) act=\(sessionActive)")
        return SwitchOutcome(changed: true, owner: current)
    }

    /// Whether `token` is the arm currently in force (a replaced
    /// PeerConnection of the same call holds a stale one). A snapshot only:
    /// to act on the answer, use a call that checks it under the
    /// configuration lock (`setNativeAudioInactive(ifCurrent:reason:)`,
    /// `disarm(token:)`).
    public static func isCurrent(token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token != 0 && armedToken == token
    }

    /// W-ADMCONFIRM (2026-09-26) — `RTCAudioSession`'s own view of whether the
    /// shared session is active (its `isActive`, kept by its locked
    /// `setActive` and by `audioSessionDidActivate`/`audioSessionDidDeactivate`).
    /// Read-only; see `NativeAudioUnitGateDecisions.sessionActiveForUnit`.
    public static var isSessionActive: Bool {
        RTCAudioSession.sharedInstance().isActive
    }

    /// Whether WebRTC's unit is currently allowed to run (armed AND enabled).
    public static var isNativeAudioEnabled: Bool {
        guard isArmed else { return false }
        return RTCAudioSession.sharedInstance().isAudioEnabled
    }

    /// Release manual-mode ownership after the PeerConnection that armed it
    /// closed. Ignored for a stale token (a replaced PeerConnection).
    ///
    /// W-ADMATOMIC (2026-09-26) — the token check, the release and the unit
    /// switch-off are ONE configuration-lock critical section. The check used
    /// to be released before `isAudioEnabled = false`: a replacement could arm
    /// and enable its unit in that window, and this (by then stale) disarm
    /// muted the successor's call.
    public static func disarm(token: Int) {
        guard token != 0 else {
            lock.lock(); let current = armedToken; lock.unlock()
            emit("admgate disarm=0 tok=\(token) cur=\(current)")
            return
        }
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        lock.lock()
        let current = armedToken
        let owned = current == token
        if owned { armedToken = 0 }
        lock.unlock()
        guard owned else {
            session.unlockForConfiguration()
            emit("admgate disarm=0 tok=\(token) cur=\(current)")
            return
        }
        if session.isAudioEnabled { session.isAudioEnabled = false }
        let manualFlag = session.useManualAudio ? 1 : 0
        session.unlockForConfiguration()
        emit("admgate disarm=1 tok=\(token) man=\(manualFlag)")
    }

    /// Item 10 (every call) — at PeerConnection construction, before a
    /// native call arms: a unit left enabled by a previous call must not be
    /// inherited. Minimal: touches `isAudioEnabled` only when manual mode is
    /// on AND it is still enabled (a leak); on a call with native SRTP off it
    /// also drops a stale arm, so that call's lifecycle is exactly the legacy
    /// one (its reportCallEnded drain never depended on this type: such a
    /// call's uuid is never recorded as native, see W-ADMBALANCE-UUID).
    public static func auditAtCallStart(nativeCall: Bool) {
        if !nativeCall {
            lock.lock()
            let wasArmed = armedToken != 0
            armedToken = 0
            lock.unlock()
            if wasArmed { emit("admgate audit=1 stalearm=1") }
        }
        let session = RTCAudioSession.sharedInstance()
        // Lock-free pre-check, unchanged: in a process where manual mode was
        // never armed (every session with the toggle off) this returns here,
        // without taking the configuration lock.
        guard session.useManualAudio, session.isAudioEnabled else { return }
        // W-ADMATOMIC — re-checked and switched off in one configuration-lock
        // critical section (see `lock`).
        session.lockForConfiguration()
        guard session.useManualAudio, session.isAudioEnabled else {
            session.unlockForConfiguration()
            return
        }
        session.isAudioEnabled = false
        session.unlockForConfiguration()
        let nativeFlag = nativeCall ? 1 : 0
        emit("admgate audit=1 forced=1 native=\(nativeFlag)")
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
    /// logged no-op, never a build failure or a KVC exception.
    ///
    /// A FRESH configuration object (NSObject `init`, which the upstream header
    /// documents as "initializes configuration to defaults" — the same way
    /// WebRTC builds its own global one) is filled and then swapped in by the
    /// setter, rather than mutating the shared global in place: WebRTC reads
    /// that object on its own audio thread whenever it (re)configures the
    /// session, and the swap is done under its own `@synchronized`.
    ///
    /// Only reached from `armManualMode()`, i.e. only on a native-SRTP call;
    /// the global it writes is read only by WebRTC's own audio module, which
    /// never runs on a call with native SRTP off (no m=audio), and the custom
    /// path configures `AVAudioSession` directly without ever reading it.
    private static func applyWebRtcSessionConfiguration() -> Int {
        let cfg = RTCAudioSessionConfiguration()
        var options = baseCategoryOptions
        lock.lock(); let speakerOn = webRtcDefaultToSpeaker; lock.unlock()
        if speakerOn { options.insert(.defaultToSpeaker) }
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

    /// The category options every session mutation of a native call uses
    /// (same as `CallKitProvider` / `configureForVoIP`).
    static var baseCategoryOptions: AVAudioSession.CategoryOptions {
        #if targetEnvironment(simulator)
        return []
        #else
        return [.allowBluetoothHFP]
        #endif
    }

    // MARK: - W-NATIVESPKR (2026-09-26): speaker route on a native call

    /// The in-call speaker toggle on a native-SRTP call: category + output
    /// override under `RTCAudioSession`'s configuration lock (the raw
    /// `AVAudioSession` path mutated the session outside WebRTC's lock while
    /// its unit runs), WITHOUT `.interruptSpokenAudioAndMixWithOthers` (the
    /// W-NOMIXOPTION audit removed it everywhere else; a mixable session is
    /// at odds with an echo-cancelling unit), and with WebRTC's own
    /// configuration updated so its next reconfiguration keeps the choice.
    /// `hardOverride`: iPad (no receiver route) pins `.speaker`; iPhone keeps
    /// the soft W-SOFTSPKR model (`.defaultToSpeaker` + override `.none`).
    /// The override goes through `AVAudioSession` (already used for it
    /// app-wide) inside the lock: `RTCAudioSession`'s own override wrapper
    /// is not used anywhere in this repo and no header is available here.
    @discardableResult
    public static func applySpeakerRoute(speakerOn: Bool, hardOverride: Bool) -> Bool {
        lock.lock(); webRtcDefaultToSpeaker = speakerOn; lock.unlock()
        _ = applyWebRtcSessionConfiguration()
        var options = baseCategoryOptions
        if speakerOn { options.insert(.defaultToSpeaker) }
        let port: AVAudioSession.PortOverride = (hardOverride && speakerOn) ? .speaker : .none
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        var ok = 1
        do {
            try rtcSession.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(port)
        } catch {
            ok = 0
        }
        rtcSession.unlockForConfiguration()
        let speakerFlag = speakerOn ? 1 : 0
        let hardFlag = hardOverride ? 1 : 0
        emit("admgate spk=\(speakerFlag) hard=\(hardFlag) ok=\(ok)")
        return ok == 1
    }

    /// Reference-implementation parity: at call configuration (CallKit start
    /// / answer action) a native call starts from output override `.none`,
    /// so a loudspeaker override leaked from a previous call cannot pin the
    /// new one. Under `RTCAudioSession`'s lock, through `AVAudioSession`.
    /// Only for a call whose native-SRTP snapshot is on.
    public static func resetOutputOverrideForNativeCall(site: Int) {
        guard CallCapabilities.nativeSrtpCallSnapshot == true else { return }
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        var ok = 1
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        } catch {
            ok = 0
        }
        rtcSession.unlockForConfiguration()
        emit("admgate route=0 site=\(site) ok=\(ok)")
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
