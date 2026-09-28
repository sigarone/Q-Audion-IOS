import Foundation
#if canImport(WebRTC)
import WebRTC

/// Lazy singleton that initializes Google's libwebrtc once per process.
/// Mirrors Android's `feature/feature-call/.../webrtc/PeerConnectionFactoryProvider.kt`:
/// one factory shared by every PeerConnection, default audio device with
/// hardware AEC + NS, default video encoder/decoder factories.
///
/// **Cross-platform contract:**
/// - Both peers MUST use the same SDP m-line ordering (audio first, video
///   second when present) so the m-line indices in ICE candidates match.
/// - Audio track id `audio0` and video track id `video0` are stable across
///   builds — use `setRemoteTrackIdsStable` if you ever need to bump.
public final class QAudionPeerConnectionFactory: @unchecked Sendable {

    public static let shared = QAudionPeerConnectionFactory()

    private let lock = NSLock()
    private var _factory: RTCPeerConnectionFactory?
    private var _audioProcessingModule: RTCDefaultAudioProcessingModule?
    private var callbackLogger: RTCCallbackLogger?

    /// W-AUNITTRACE (2026-09-10) — fires for the native AudioDeviceIOS
    /// lifecycle events this session's live tests need to actually SEE:
    /// "init"/"shutdown" (the create/destroy-per-call cycle itself,
    /// confirmed from WebRTC's own source to run once per call regardless
    /// of this factory's own persistence), "started" (the audio unit
    /// actually reached the started state), and "fail" (with the real
    /// OSStatus in `code`) when starting it failed outright. Wired by
    /// AppState to `RTLog.info("call", "aunit <kind>=1 [code=<n>]")` — kept
    /// out of this file the same way `muteNativeAudioSrtpSender` etc. are,
    /// since `QAudionApp`'s `RTLog` isn't reachable from this module.
    public var onNativeAudioLifecycleEvent: ((_ kind: String, _ code: Int32?) -> Void)?

    /// W-RXFALLBACKINJECT (2026-09-10) — process-lifetime, attached as
    /// `renderPreProcessingDelegate` in `buildFactory()` below. Unlike
    /// `NativeAudioCaptureTap` (a fresh per-call instance on the strictly
    /// per-call `QAudionPeerConnection`, since its `sink` closure captures
    /// per-call TX routing state), this needs no per-call state of its own —
    /// see `NativeAudioPlayoutInjector`'s own doc for the full rationale and
    /// the failure this closes. `CallService.injectNativePlayoutPCM` is
    /// wired straight to `playoutInjector.inject(_:)` by AppState at login.
    public let playoutInjector = NativeAudioPlayoutInjector()

    private init() {}

    /// Lazy accessor for the underlying RTCPeerConnectionFactory. Callers
    /// that need the TX capture tap (native-audio-srtp) must go through
    /// `sharedFactory` instead, to also get the `RTCDefaultAudioProcessingModule`
    /// handle to attach one to.
    public func factory() async -> RTCPeerConnectionFactory {
        await sharedFactory().factory
    }

    /// Builds the factory instance (called at most once per process by
    /// `sharedFactory()` below — see W-PERSISTENTFACTORY further down for
    /// why this is no longer per-call). `sealerProvider` on the public
    /// `sharedFactory()` entry point is retained for source-compatibility
    /// with existing call sites but is NO LONGER USED: 1:1 video E2EE moved
    /// from the codec-layer
    /// `SFrameVideoEncoder/DecoderFactoryDecorator` to the native RTP-layer
    /// `RTCFrameCryptor` (NativeVideoFrameCryptor). Wrapping the codec factories
    /// would DOUBLE-ENCRYPT (codec-layer seal + native FrameCryptor). So we
    /// return the plain HEVC-preferred factories — they still advertise/build
    /// H265 (RTCVideoEncoderH265/Decoder), which the native cryptor then encrypts
    /// after packetization (codec-agnostic). See NativeVideoFrameCryptor.swift.
    ///
    /// IOS-C4b TX-TAP FIX (2026-09-08) — also returns the
    /// `RTCDefaultAudioProcessingModule` backing this factory's audio
    /// pipeline, so a caller can attach an `RTCAudioCustomProcessingDelegate`
    /// (`NativeAudioCaptureTap`) to `capturePostProcessingDelegate` and
    /// actually observe the local mic's post-AEC PCM. `RTCAudioTrack.add(_:)`
    /// on the LOCAL (mic) track never delivers anything — libwebrtc's
    /// `LocalAudioSource::AddSink` (pc/local_audio_source.h) is an empty
    /// override in this pinned build (grep-verified, not assumed) — so the
    /// old `track.add(txTap)` wiring silently produced zero callbacks for the
    /// whole life of every call. `capturePostProcessingDelegate` is the real
    /// hook: it fires on the ACTUAL capture-side APM output, i.e. after
    /// hardware AEC/NS/AGC — the same signal that gets encoded and sent.
    ///
    /// Getting an `audioProcessingModule` handle at all requires switching
    /// off the argument-less `RTCPeerConnectionFactory(encoderFactory:
    /// decoderFactory:)` initializer this class used before, to
    /// `initWithAudioDeviceModuleType:bypassVoiceProcessing:...
    /// audioProcessingModule:` — the only public initializer that accepts a
    /// custom `audioProcessingModule` at all.
    ///
    /// W-ADMPARITY (adversarial review, 2026-09-08) — an EARLIER version of
    /// this fix picked `.audioEngine` for that call, on the reasoning that
    /// this app's own `LiveKit` dependency already runs it in production —
    /// for GROUP calls. That reasoning does not carry over: `LiveKit` builds
    /// and owns an entirely separate `RTCPeerConnectionFactory` internally
    /// (see `LiveKitGroupCallRoom.swift`), with its own CallKit/session
    /// integration this class's 1:1 path does not share, and this app
    /// already fences the two apart precisely BECAUSE they cannot safely
    /// share one hardware audio unit (`AudioCapture.start()`'s group-call
    /// guard: "refusing 1:1 engine to avoid setVoiceProcessingEnabled
    /// SIGABRT"; `NativeAudioSessionGate`'s own doc records three earlier,
    /// independent attempts to hand this app's 1:1 session/ADM ownership to
    /// something other than the plain default, each of which measurably
    /// regressed a real call). `.audioEngine` selects a DIFFERENT concrete
    /// audio-device implementation than the one this class's argument-less
    /// initializer has always used — this app's entire 1:1 CallKit-activation
    /// / route-handling / VP-IO contract has zero hours of production
    /// history against it.
    ///
    /// `.platformDefault` is the behavior-preserving choice instead:
    /// read directly against the pinned `webrtc-sdk/webrtc@m144_release`
    /// factory source (`gh api`, not assumed), the SAME top-level
    /// device-module constructor this class's argument-less initializer
    /// already calls is the one `.platformDefault` reaches too — `.audioEngine`
    /// is the only one of the two enum cases that diverges to a different
    /// implementation. Selecting `.platformDefault` therefore gets the
    /// `audioProcessingModule` handle this fix needs while keeping the exact
    /// same underlying audio device this class shipped with before it — a
    /// verified swap of the CONSTRUCTOR PATH, not of the audio backend
    /// itself. `bypassVoiceProcessing: false` preserves hardware Voice-
    /// Processing-I/O (AEC+NS+AGC) on that path exactly as this class's own
    /// top-of-file doc has always promised ("hardware AEC + NS"). See
    /// `project_ios_native_capture_tap_adm_choice_2026_09_08.md` (session
    /// memory) for the full source-level verification this comment
    /// summarizes.
    ///
    /// W-PERSISTENTFACTORY (2026-09-09) — this factory (and the native
    /// AudioDeviceModule/AudioUnit underneath it) is now built ONCE per
    /// process and reused for every 1:1 call; only the `RTCPeerConnection`
    /// itself is created and closed per call (`QAudionWebRtcCallController`'s
    /// three call sites). Tonight's own live evidence — two independent,
    /// individually-correct CallKit/RTCAudioSession-activation fixes both
    /// landed and both executed cleanly, yet a call placed 6-9s (and, later,
    /// 22-25s) after a previous one still reproduced a permanently dead
    /// sender — traced the fault one layer below AVAudioSession: destroying
    /// and rebuilding the native AudioUnit on every call repeats a
    /// maintainer-acknowledged libwebrtc stop/teardown race (bug webrtc:5993)
    /// once per call instead of once per app run. A prior settle-delay
    /// mitigation here (1.5s, since removed) was verified insufficient live
    /// — a fixed delay can't beat a race with no platform completion signal.
    ///
    /// Sequential `RTCPeerConnection`s sharing one long-lived factory is
    /// WebRTC's own documented normal usage (`PeerConnectionFactoryInterface`'s
    /// own doc comment describes its `Options` as applying "to subsequently
    /// created PeerConnections" — plural, sequential creation is the
    /// intended case, with no stated requirement to wait for a prior
    /// connection's threads to quiesce first). `RTCAudioSession` itself is
    /// already a process-wide singleton independent of factory lifetime, so
    /// none of tonight's already-verified-live CallKit activation/
    /// deactivation bookkeeping (`CallKitProvider`, `CallKitCallLedger`)
    /// changes behavior here — only how many times the ADM object underneath
    /// gets constructed changes, from once-per-call to once-per-process.
    ///
    /// Deliberately NOT changed: `useManualAudio` stays `false`. Idling the
    /// audio unit via `RTCAudioSession.isAudioEnabled` is a documented no-op
    /// whenever `useManualAudio` is `false` (verified against WebRTC's own
    /// `RTCAudioSession.mm` source), so flipping it would only add a second,
    /// historically dangerous state gate (see `NativeAudioSessionGate`'s own
    /// doc — three prior regressions from exactly that combination) for zero
    /// benefit: WebRTC's automatic mode already starts/stops the unit on its
    /// own, driven by track add/remove, which is untouched by this change.
    private func buildFactory()
        -> (factory: RTCPeerConnectionFactory, audioProcessingModule: RTCDefaultAudioProcessingModule) {
        // N2 (network-resilience-max, this task) — WebRTC-Network-UseNWPathMonitor,
        // MUST run before any other WebRTC call (`RTCInitFieldTrialDictionary`'s own
        // header doc: "Must be called before any other call into WebRTC"), hence
        // ahead of `RTCInitializeSSL()` below, not just ahead of the factory
        // constructor.
        //
        // Verified, not guessed, against the EXACT pinned source this app's own
        // `WebRTC` binaryTarget is built from (`Package.swift`'s own comment:
        // "same WebRTC source commit (webrtc-sdk/webrtc df1011beabae = m144_release
        // tip when the previous binary was built)"):
        //  - the trial name is REGISTERED at that exact commit —
        //    `experiments/field_trials.py` @ df1011beabae:
        //    `FieldTrial('WebRTC-Network-UseNWPathMonitor', 42221045, date(2024, 4, 1))`
        //    (fetched via `raw.githubusercontent.com/webrtc-sdk/webrtc/df1011beabae/
        //    experiments/field_trials.py` — this box has no local toolchain to unzip
        //    the xcframework itself, so the pinned SOURCE commit is the verification
        //    this task's own instructions call for).
        //  - the ObjC surface has a FIRST-CLASS constant for exactly this trial —
        //    `sdk/objc/api/peerconnection/RTCFieldTrials.h/.mm` @ the same commit:
        //    `RTCFieldTrialUseNWPathMonitor` = `@"WebRTC-Network-UseNWPathMonitor"`,
        //    `RTCFieldTrialEnabledValue` = `@"Enabled"` — this is not a speculative
        //    trial name, it is the one case the SDK itself names a constant for.
        //  - `RTCInitFieldTrialDictionary(NSDictionary<NSString*,NSString*>*)`
        //    (same file) builds the native init string as `"<key>/<value>/"` per
        //    entry, i.e. exactly `"WebRTC-Network-UseNWPathMonitor/Enabled/"` for a
        //    one-entry dictionary — matching this task's own spec string.
        //  - literal strings are used here rather than the bridged Swift constant
        //    names (`RTCFieldTrialUseNWPathMonitor`/`RTCFieldTrialEnabledValue`):
        //    this box cannot compile Swift to confirm the ObjC-to-Swift import
        //    renames those global `NSString *const` symbols to, and a wrong guess
        //    there would fail the build outright, whereas the literal string is
        //    exactly the byte value both constants hold, verified above.
        //
        // Residual, disclosed deviation: `RTCInitFieldTrialDictionary` itself is
        // marked `RTC_OBJC_DEPRECATED("Pass field trials when building
        // PeerConnectionFactory")` with a `TODO: bugs.webrtc.org/42220378 - Delete
        // after January 1, 2026` in that same pinned header — today is 2026-09-28,
        // past that TODO date, but the symbol is still declared (not removed) in
        // the exact binary this app links, so it still works; it will need
        // migrating to the newer "pass field trials at factory construction" form
        // whenever this app's WebRTC binary is next rebuilt past whatever revision
        // actually deletes it. See this task's report for the full citation trail.
        //
        // A dictionary (not a single hardcoded call) so a future SECOND field
        // trial merges into the SAME init string instead of a competing call
        // silently overwriting this one (`RTCInitFieldTrialDictionary` replaces
        // the entire global init string each call, per its own source above).
        //
        // Review note (verified against the same pinned sources): on THIS
        // app's factory path the trial is belt-and-braces, not the switch.
        // `RTCPeerConnectionFactory(audioDeviceModuleType:bypassVoiceProcessing:
        // encoderFactory:decoderFactory:audioProcessingModule:)` (below) ends in
        // `initWithNativeAudioEncoderFactory:...audioDeviceModuleType:...`,
        // which installs `webrtc::CreateNetworkMonitorFactory()` (the
        // NWPathMonitor-backed monitor) UNCONDITIONALLY; only the
        // `initWithNativeDependencies:` path consults this trial (through the
        // env's DeprecatedGlobalFieldTrials, i.e. this global string). So
        // libwebrtc already gets interface-change signals here; the trial keeps
        // that true if the factory is ever built through the other initializer.
        // Safe to repeat on a wedge-recovery rebuild: at this commit
        // `InitFieldTrialsFromString` copies the string into persistent,
        // mutex-guarded storage, so no live reader is left pointing at the
        // buffer the ObjC wrapper frees on a second call.
        RTCInitFieldTrialDictionary(["WebRTC-Network-UseNWPathMonitor": "Enabled"])

        // RTCInitializeSSL is idempotent — safe to call once on first use.
        RTCInitializeSSL()
        installNativeAudioUnitLogBridge()

        let encoderFactory = HevcPreferredVideoEncoderFactory()
        let decoderFactory = HevcPreferredVideoDecoderFactory()
        // nil config = APM defaults (unchanged AEC/NS/AGC/HPF toggle state
        // versus today — same as LiveKit's own `.init()`, whose designated
        // initializer's params are all nullable so this is equivalent).
        // BOTH delegate params are deliberately left `nil` here — see
        // W-RXFALLBACKINJECT-2 below for why passing either through this
        // initializer is silently a no-op on this pinned fork.
        let audioProcessingModule = RTCDefaultAudioProcessingModule(
            config: nil,
            capturePostProcessingDelegate: nil,
            renderPreProcessingDelegate: nil)

        // W-RXFALLBACKINJECT-2 (2026-09-10) — was passed directly into the
        // initializer above (`renderPreProcessingDelegate: playoutInjector`),
        // which is a confirmed bug in this pinned fork: `RTCAudioCustom
        // ProcessingAdapter.mm`'s own `initWithDelegate:` constructs the
        // native `webrtc::AudioCustomProcessingAdapter` but NEVER calls its
        // `SetDelegate` — the parameter is silently dropped. Only the
        // property SETTER (`-setAudioCustomProcessingDelegate:`, which this
        // property forwards to) calls `SetDelegate` on the native adapter.
        // A live test with per-call diagnostics (see
        // `NativeAudioPlayoutInjector.onEvent`'s "proc"/"mix" checkpoints)
        // confirmed `audioProcessingProcess` was never invoked ONCE across
        // 500+ real decoded frames queued via `inject(_:)` — this is why.
        // `NativeAudioCaptureTap`'s capture-side delegate already avoided
        // this bug by construction: `QAudionPeerConnection.swift` sets
        // `apm.capturePostProcessingDelegate = tap` via the setter, per-call,
        // never through this initializer. Assigning the setter here once,
        // right after construction, is the process-lifetime equivalent.
        audioProcessingModule.renderPreProcessingDelegate = playoutInjector

        let factory = RTCPeerConnectionFactory(
            audioDeviceModuleType: .platformDefault,
            bypassVoiceProcessing: false,
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory,
            audioProcessingModule: audioProcessingModule)
        return (factory, audioProcessingModule)
    }

    /// W-KEYLOGGATE (2026-09-24) — the minimum severity WebRTC's own DEBUG
    /// output (which on iOS is stderr) may reach. Deliberately `.warning`,
    /// never `.info` or lower: the native FrameCryptor prints derived key
    /// material at INFO (`api/crypto/frame_crypto_transformer.cc`, the
    /// `secret [..] ... slat << [..] ... derived_key [..]` and `raw_key [..]`
    /// prints; "slat" is upstream's typo of salt), and the app's stdout/stderr
    /// tee copies everything on stderr into the log ring that the live-log
    /// shipper uploads. `RTCSetMinDebugLogLevel` sets ONLY this stderr
    /// severity (`webrtc::LogMessage::LogToDebug`): a registered
    /// `RTCCallbackLogger` sink filters on its OWN severity, so the
    /// W-AUNITTRACE bridge below keeps receiving INFO lines while this is
    /// `.warning`. That callback still sees the key prints too, so
    /// `handleNativeLogLine` must never store or log `message` verbatim.
    /// Pinned by `QAudionPeerConnectionFactoryTests`; do not lower it.
    static let stderrDebugLogLevel: RTCLoggingSeverity = .warning

    /// W-NATIVESRTPDIAG (this task) — raises the WebRTC stderr DEBUG severity
    /// (``stderrDebugLogLevel``, normally `.warning`) to `.info` for the
    /// duration of a call that has native SRTP enabled locally
    /// (``CallCapabilities/isNativeSrtpEnabledLocally``), so the extra
    /// libwebrtc INFO lines W-KEYLOGGATE silenced (`channel.cc` state
    /// changes, `thread.cc` dispatch timing, `connection.cc` candidate
    /// updates, ...) are available again while this feature is being
    /// exercised/diagnosed — see ``restoreDefaultDebugLogLevel()`` for the
    /// counterpart and for why this is safe.
    ///
    /// Deliberately a GLOBAL severity change (`RTCSetMinDebugLogLevel` sets
    /// process-wide state, per its own header — there is no per-PeerConnection
    /// scope), same as `installNativeAudioUnitLogBridge()`'s own call to it.
    /// A 1:1 call is the only caller of the native SRTP audio path today, so
    /// there is no concurrent-call scenario where raise/restore from two
    /// different calls could race; if that ever changes, this needs a
    /// reference count instead of a bare set/restore pair.
    ///
    /// SAFE despite raising the callback logger's own already-`.info`
    /// severity's reach to stderr too: the two lines W-KEYLOGGATE exists for
    /// (`api/crypto/frame_crypto_transformer.cc`'s `RTC_LOG(LS_INFO)` key
    /// prints) are gone from the bundled `WebRTC.xcframework` at the SOURCE —
    /// `Package.swift`'s binaryTarget comment pins it to the
    /// `webrtc-ios-aes256-m144-native-pli-nokeylog` release, built from the
    /// commit that removed both prints, and `scripts/ci/assert-no-key-logging.sh`
    /// gates every build of that release on `RTC_LOG(LS_INFO)` no longer
    /// appearing in `frame_crypto_transformer.cc`. `KeyMaterialScrubber`
    /// (`Diagnostics/KeyMaterialScrubber.swift`) and `LogRedactor` still
    /// sanitize every ring/egress point as defence in depth regardless.
    public func raiseDebugLogLevelForNativeSrtpSession() {
        RTCSetMinDebugLogLevel(.info)
    }

    /// Counterpart to ``raiseDebugLogLevelForNativeSrtpSession()`` — restores
    /// the compiled default (``stderrDebugLogLevel``, `.warning`). Called
    /// whenever a call that raised the level ends, so a call that never
    /// touches native SRTP is never affected and the raised level never
    /// outlives the session it was raised for.
    public func restoreDefaultDebugLogLevel() {
        RTCSetMinDebugLogLevel(Self.stderrDebugLogLevel)
    }

    /// W-AUNITTRACE (2026-09-10) — the persistent-factory fix (this file's
    /// own W-PERSISTENTFACTORY, shipped and live-tested v1.0.1129) did NOT
    /// resolve the dead-TX-at-call-2 defect: the same symptom reproduced
    /// identically. Direct re-reading of WebRTC's own `audio_device_ios.mm`
    /// confirmed why — `ShutdownPlayOrRecord()`/`InitPlayOrRecord()` destroy
    /// and recreate the real native AudioUnit once per call, driven by the
    /// call-level Start/StopPlayout/Recording state machine, entirely
    /// independent of this factory/ADM Swift object's own lifetime. That
    /// cycle is invisible today: nothing in this app observes it. This
    /// bridges WebRTC's own internal diagnostic logging (public API,
    /// `RTCSetMinDebugLogLevel`/`RTCCallbackLogger` — this app's own direct
    /// dependency, not a foreign library's internals) so the NEXT live
    /// repro can show exactly when init/shutdown/start/failure happen,
    /// correlated with the app's own `audiosrtp hb=` heartbeat — evidence no
    /// Swift-level code change can substitute for, per that investigation's
    /// own conclusion. Pure instrumentation: emits short, numeric-tailed
    /// lines only for a small set of known messages (see
    /// `handleNativeLogLine`), changes no audio behavior.
    ///
    /// W-KEYLOGGATE (2026-09-24) — the DEBUG (stderr) severity is no longer
    /// `.info`: it is `stderrDebugLogLevel` (`.warning`). Only that stderr
    /// severity changed; the callback logger below keeps its own `.info`
    /// severity, so the bridge above still receives every INFO line.
    private func installNativeAudioUnitLogBridge() {
        RTCSetMinDebugLogLevel(Self.stderrDebugLogLevel)
        let logger = RTCCallbackLogger()
        logger.severity = .info
        logger.start { [weak self] message in
            self?.handleNativeLogLine(message)
        }
        callbackLogger = logger
    }

    /// Runs on whichever thread WebRTC logs from (the callback's own
    /// contract, per `RTCCallbackLogger`'s header) — kept to cheap substring
    /// checks and a closure call, no locking needed here since it only reads
    /// the `onNativeAudioLifecycleEvent` var (a simple optional-closure
    /// read/call, same pattern every other live-setter closure in this
    /// codebase already relies on being safe for).
    private func handleNativeLogLine(_ message: String) {
        // W-AUNITTRACE follow-up (2026-09-10) — the first live test with this
        // bridge found the callee's side of a dead-TX call 2 emits NONE of
        // the four original signals at all (no init/started/fail) despite
        // logging its own call-1 shutdown cleanly. `AudioDeviceIOS::
        // CreateAudioUnit()`'s own guard (`if (audio_unit_ ||
        // audio_is_initialized_) return false;`) fails COMPLETELY SILENTLY
        // — no log line anywhere on that path — which would exactly produce
        // this signature. These extra branches exist to tell that silent
        // guard apart from "this code path never ran at all": if
        // startplayout/startrecording fire but init/started/fail never
        // follow, the silent guard is the culprit; if even those never
        // fire, the defect is further upstream, before WebRTC's ADM is
        // touched at all. Ordering matters — check the sentence-form
        // failure messages BEFORE the bare substring checks they'd
        // otherwise also match.
        if let range = message.range(of: "failed to start audio unit, reason ") {
            let tail = message[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let code = Int32(tail.prefix(while: { $0 == "-" || $0.isNumber }))
            onNativeAudioLifecycleEvent?("fail", code)
        } else if message.contains("InitPlayOrRecord failed for Init") {
            onNativeAudioLifecycleEvent?("initfail", nil)
        } else if message.contains("Failed to begin WebRTC session") {
            onNativeAudioLifecycleEvent?("sessionfail", nil)
        } else if message.contains("InitPlayOrRecord") {
            onNativeAudioLifecycleEvent?("init", nil)
        } else if message.contains("ShutdownPlayOrRecord") {
            onNativeAudioLifecycleEvent?("shutdown", nil)
        } else if message.contains("Voice-Processing I/O audio unit is now started") {
            onNativeAudioLifecycleEvent?("started", nil)
        } else if message.contains("StartPlayout") {
            onNativeAudioLifecycleEvent?("spo", nil)
        } else if message.contains("StartRecording") {
            onNativeAudioLifecycleEvent?("sre", nil)
        }
    }

    /// Returns the process-lifetime factory + ADM, building them once on
    /// first use and reusing them for every subsequent call.
    /// `sealerProvider` is retained for source-compatibility with existing
    /// call sites but is NO LONGER USED — see the class-level kdoc above
    /// this method's predecessor for why (native RTP-layer FrameCryptor,
    /// not codec-layer sealing, owns 1:1 video E2EE now).
    public func sharedFactory(sealerProvider: @escaping () -> VideoFrameSealer? = { nil }) async
        -> (factory: RTCPeerConnectionFactory, audioProcessingModule: RTCDefaultAudioProcessingModule) {
        lock.lock()
        defer { lock.unlock() }
        if let f = _factory, let apm = _audioProcessingModule {
            return (f, apm)
        }
        let built = buildFactory()
        _factory = built.factory
        _audioProcessingModule = built.audioProcessingModule
        return built
    }

    /// Tear down — only call from app-shutdown hooks. Also calls
    /// `RTCCleanupSSL()`, which is correct on final shutdown but NOT
    /// something to invoke mid-process — see `resetForWedgeRecovery()` for
    /// the mid-call safety-net equivalent.
    public func teardown() {
        lock.lock()
        _factory = nil
        _audioProcessingModule = nil
        lock.unlock()
        RTCCleanupSSL()
    }

    /// W-ADMWEDGERESET (2026-09-09) — mid-process escape hatch for
    /// `CallService`'s consecutive-audio-srtp-wedge safety net. Forces the
    /// NEXT `sharedFactory()` call to rebuild factory+ADM from scratch,
    /// mirroring WebRTC's own upstream mitigation for a wedged native audio
    /// unit (field trial `WebRTC-Audio-iOS-Holding`: stop → uninitialize →
    /// reinitialize the VoiceProcessingAudioUnit in place, no process
    /// restart needed) — this app's coarser version of the same idea, one
    /// level up at the factory/ADM instead of the raw AudioUnit, since
    /// Swift has no reachable hook into the AudioUnit itself. Deliberately
    /// does NOT call `RTCCleanupSSL()` — that call is for final process
    /// shutdown only; calling it here and re-initializing moments later on
    /// the next call would cycle global SSL state for no benefit, since
    /// `RTCInitializeSSL()` in `buildFactory()` is already idempotent and
    /// safe to call again without a matching cleanup in between.
    public func resetForWedgeRecovery() {
        lock.lock()
        _factory = nil
        _audioProcessingModule = nil
        lock.unlock()
    }

    /// Build the default `RTCConfiguration` used by all 1:1 calls.
    /// Caller passes `iceServers` (typically built from
    /// `RelayCredentialsProvider.RelayBundle.servers`).
    ///
    /// - Parameter nativeSrtpEnabledLocally: W-NATIVESRTPDIAG (this task) —
    ///   ``CallCapabilities/isNativeSrtpEnabledLocally`` for the call this
    ///   configuration is being built for. Defaults to `false` so every
    ///   existing call site (and the `QAudionPeerConnectionFactoryTests`
    ///   call with no third argument) keeps building today's exact
    ///   `RTCConfiguration` — the extra fields below are added ONLY when
    ///   `true`, which is itself only possible on a call that already pre-
    ///   creates the native audio transceiver (see `QAudionPeerConnection
    ///   .init`'s own gate), so a normal call's ICE/SRTP negotiation is
    ///   untouched.
    ///
    ///   Best-practice parameters for the native-SRTP audio path, applied
    ///   only then (property names verified against the public
    ///   `webrtc-sdk/webrtc` Objective-C SDK headers — see this task's own
    ///   report for which ones could not be grep-verified against the
    ///   bundled `WebRTC.xcframework` on this box, which has no local
    ///   toolchain to unzip/inspect it):
    ///   - `cryptoOptions` — GCM cipher suites on (AES-GCM, matching the
    ///     native `RTCFrameCryptor`'s own `.aesGcm` algorithm one layer up),
    ///     the legacy 32-byte-tag AES_128_CM_HMAC_SHA1_32 cipher OFF (no
    ///     legacy peer to interop with on this brand-new path), encrypted
    ///     RTP header extensions ON (header extensions otherwise travel in
    ///     the clear even on an SRTP-GCM call), SFrame frame-encryption
    ///     requirement OFF (this app's own native `RTCFrameCryptor` is the
    ///     frame-encryption layer, not WebRTC's built-in SFrame transform —
    ///     requiring the latter would be a second, unused encryption gate).
    ///   - `tcpCandidatePolicy = .disabled` — TCP candidates add head-of-line
    ///     blocking on top of an already-encrypted, already-lossy-tolerant
    ///     RTP stream; UDP (host/srflx/relay) is sufficient and this app's
    ///     TURN servers all offer UDP relay.
    ///   - `audioJitterBufferMaxPackets = 17` — N1 (network-resilience-max,
    ///     this task; was 50). At this path's 60 ms packetization
    ///     (``AudioSdpPolicy/ptimeMs``), 17 packets is ~1.02 s of buffering
    ///     headroom, matching Riferimento A's own documented 1 s cap
    ///     (`resilience-assessment.md` §3, P1-1: "Riferimento A tiene al
    ///     massimo 1 s di buffer e un target di 500 ms",
    ///     `ref-a-lib/.../peer_connection_factory.rs:261-268`) instead of the
    ///     old 50-packet/3 s ceiling, which the same assessment measured as
    ///     letting NetEQ's target grow to ~2.2 s worst case (NetEQ targets
    ///     ~75% of the configured max) before `audioJitterBufferFastAccelerate
    ///     = false` (kept, see below) lets it recover. 17, not 16 or 18: 1000ms
    ///     / 60ms = 16.67, and this cap is a packet COUNT (must be an integer)
    ///     — 17 rounds up so a clean 1 s of jitter is never one packet short of
    ///     fitting, at the cost of ~20 ms of extra worst-case headroom over an
    ///     exact 1 s, negligible next to the ~1.4 s reduction this change makes.
    ///     Deliberately NOT lower: this is a receive-side-only cap (see the
    ///     "compatible" notes throughout this file — it never touches the fixed
    ///     60 ms ptime / 32 kbps CBR encode-side contract), so there is no
    ///     bitrate/ptime trade-off to weigh against going tighter here, only
    ///     the risk (assessment §3, P1-1 "Rischio") of more frequent buffer
    ///     under-runs on an EXTREME jitter burst that the old 3 s cushion would
    ///     have absorbed — accepted per the owner's explicit approval of this
    ///     whole assessment, condition/test-B language notwithstanding (no
    ///     live device available in this environment to run test B first).
    ///   - `audioJitterBufferFastAccelerate = false` — UNCHANGED by N1. The
    ///     assessment's own P1-1 leaves this "decide after test B: `false` as
    ///     Riferimento A, or `true` as done for W-JITTERCAP" — this pass keeps
    ///     `false` (matching Riferimento A, and this file's pre-existing
    ///     value) since no live-device test B ran in this environment to
    ///     justify diverging from Riferimento A's own shipped choice; the
    ///     smaller 17-packet ceiling already bounds the worst case
    ///     `fastAccelerate=false`'s slower catch-up can reach.
    ///   - `audioJitterBufferMinDelayMs` is deliberately NOT set.
    ///     W-NATIVESRTPBUILDFIX (2026-09-26): the CI simulator build proved
    ///     this pinned SDK's `RTCConfiguration` has no such member.
    ///   - `enableDscp = true` — N5 (network-resilience-max, this task).
    ///     Verified against this exact pinned commit's real header
    ///     (`RTCConfiguration.h` @ webrtc-sdk/webrtc df1011beabae): its own doc
    ///     comment on `enableDscp` reads "allows DSCP codes to be set on
    ///     outgoing packets, configured using **networkPriority field of
    ///     RTCRtpEncodingParameters**" — i.e. this flag is the master switch
    ///     `QAudionPeerConnection`'s own `encoding.networkPriority = .high`
    ///     (set on the native audio sender, see that file) requires to have
    ///     any effect at all; setting one without the other is a documented
    ///     no-op. Scoped to the native-SRTP branch only, same as every other
    ///     field here — the legacy sealed-DataChannel path has no
    ///     `RTCRtpEncodingParameters` of its own to prioritize.
    ///
    ///   N4 (network-resilience-max, this task) — turnPortPrunePolicy =
    ///   keep-first-ready: SKIPPED, not implemented. Verified against this
    ///   exact pinned commit's real sources (not guessed): the ObjC
    ///   `RTCConfiguration` surface (`RTCConfiguration.h` @ df1011beabae) has
    ///   no `turnPortPrunePolicy` property at all — only a plain
    ///   `BOOL shouldPruneTurnPorts`. Its native bridge
    ///   (`RTCConfiguration.mm`: `nativeConfig->prune_turn_ports =
    ///   _shouldPruneTurnPorts`) and the C++ policy resolver it feeds
    ///   (`api/peer_connection_interface.h` @ the same commit:
    ///   `GetTurnPortPrunePolicy() { return prune_turn_ports ?
    ///   PRUNE_BASED_ON_PRIORITY : turn_port_prune_policy; }`, the latter
    ///   defaulting to `NO_PRUNE`) together prove `shouldPruneTurnPorts = YES`
    ///   can only ever select `PRUNE_BASED_ON_PRIORITY` — never
    ///   `KEEP_FIRST_READY`, which the finer-grained
    ///   `turn_port_prune_policy` C++ field supports but which this pinned
    ///   ObjC SDK never exposes a way to set. Per this task's own instruction
    ///   ("if not available, skip and say so"): skipped. Turning on
    ///   `shouldPruneTurnPorts` anyway (accepting `PRUNE_BASED_ON_PRIORITY`
    ///   instead) was considered and rejected — it is a DIFFERENT policy than
    ///   the one the owner approved (priority-based pruning can retire a
    ///   still-viable lower-priority TURN port the moment a higher-priority
    ///   one connects, whereas keep-first-ready never prunes a port that is
    ///   already in a working candidate pair — swapping the policy silently
    ///   is a bigger behavior change than doing nothing).
    public static func defaultConfiguration(iceServers: [RTCIceServer],
                                            nativeSrtpEnabledLocally: Bool = false) -> RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        // Trickle ICE: candidates flow as they're discovered, no pre-gather wait.
        config.iceTransportPolicy = .all
        if nativeSrtpEnabledLocally {
            config.cryptoOptions = RTCCryptoOptions(
                srtpEnableGcmCryptoSuites: true,
                srtpEnableAes128Sha1_32CryptoCipher: false,
                srtpEnableEncryptedRtpHeaderExtensions: true,
                sframeRequireFrameEncryption: false)
            config.tcpCandidatePolicy = .disabled
            // N1 (network-resilience-max, this task): was 50 (~3s @ 60ms).
            config.audioJitterBufferMaxPackets = 17
            config.audioJitterBufferFastAccelerate = false
            // N5 (network-resilience-max, this task) — master switch for
            // `RTCRtpEncodingParameters.networkPriority` (see doc above).
            config.enableDscp = true
        }
        return config
    }

    /// Convenience converter from our [RelayServer] DTO to WebRTC's [RTCIceServer].
    public static func iceServers(from relays: [RelayServer]) -> [RTCIceServer] {
        return relays.map { rs in
            RTCIceServer(urlStrings: rs.urls,
                          username: rs.username ?? "",
                          credential: rs.credential ?? "")
        }
    }
}
#endif
