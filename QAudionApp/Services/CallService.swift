import Foundation
import AVFoundation  // AVAudioSession for speaker override
import CryptoKit     // W574l — one-way key fingerprint for seal-key diagnostics
import QAudionEngine

/// W-LONGAUDIO (2026-08-10) — the peer's advertised capability list AND the
/// wire `call_id` it arrived for, as ONE value that can only be read or written
/// as a pair.
///
/// Two separate stored properties would not do. The list is written by a
/// signalling handler on the main queue and read by `latchAudioProfileForCall`
/// on the PQC handshake thread, and two independent non-atomic stores have two
/// interleavings: a reader that sees the NEW list with the OLD id fails the
/// comparison and gets `nil` (harmless — that is STANDARD), but a reader that
/// sees the NEW id with the OLD list gets the PREVIOUS peer's tags stamped with
/// this call's id, which is the exact defect the id was added to close, smuggled
/// back in through store ordering. Nothing in the language forbids that
/// interleaving: these are plain properties with no barrier between them.
///
/// So both live behind one `NSLock`, held only long enough to copy the pair in
/// or out — the same contract `CallService.relaySlotLock` documents for the
/// relay sealer slots, and for the same reason.
///
/// This type is a value CARRIER, not the rule: the rule itself is
/// `CallCapabilities.peerCapabilities(forCallId:capturedForCallId:capturedList:)`
/// in the engine, where it is unit-testable without an AppState.
final class PeerCapabilityBinding: @unchecked Sendable {
    private let lock = NSLock()
    /// Deliberately NOT named `callId`/`capabilities`: the accessor below has
    /// base name `capabilities`, and a stored property sharing it would make
    /// every unqualified reference inside this type an overload-resolution
    /// question rather than a lookup.
    private var capturedCallId: String?
    private var capturedCapabilities: [String]?

    /// Record `capabilities` as belonging to `callId`. An empty or missing id
    /// stores `nil`, which can never match anything — "captured, but we cannot
    /// say for which call" is treated exactly like "not captured".
    func store(callId: String?, capabilities: [String]?) {
        lock.lock(); defer { lock.unlock() }
        let id = callId ?? ""
        capturedCallId = id.isEmpty ? nil : id
        capturedCapabilities = capabilities
    }

    /// Forget the binding. Called when a call ends so the between-calls state is
    /// "no proof of ownership" by default rather than by two UUIDs differing.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        capturedCallId = nil
        capturedCapabilities = nil
    }

    /// The peer's list, but only if it was captured for `wantedCallId`.
    func capabilities(forCallId wantedCallId: String?) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return CallCapabilities.peerCapabilities(
            forCallId: wantedCallId,
            capturedForCallId: capturedCallId,
            capturedList: capturedCapabilities
        )
    }
}

// Swift 6 — CallService coordinates its OWN concurrency (it is not @MainActor):
// the TX audio pipeline is serialised on the private `txAudioQueue`, decoded-RX
// diagnostic counters are touched on the capture/decode threads, and every
// UI-facing callback hops to the main actor via `Task { @MainActor in … }`.
// That manual, queue-based serialisation is exactly the contract `@unchecked
// Sendable` documents, and it lets the TX @Sendable dispatch closures capture
// `self` without the compiler flagging a false data race. No behaviour change.
final class CallService: @unchecked Sendable {
    var callIntegration: QAudionCallIntegration?
    var onDeepfakeAlert: ((Bool) -> Void)?
    var onDeepfakeScore: ((ConfidenceIndex.Level, Float) -> Void)?
    var onTxWaveformUpdate: (([Float]) -> Void)?
    var onRxWaveformUpdate: (([Float]) -> Void)?
    var onCipherWaveformUpdate: (([Float]) -> Void)?
    /// Unified call UI — Guardian ribbon voice biometrics (pitch/stress/
    /// health/speech-rate/confidence). Wired 1:1 alongside onDeepfakeAlert/
    /// onDeepfakeScore below, on BOTH integration binding sites (`startCall`
    /// outgoing + `activateIncomingCallAudio` responder — the old
    /// outgoing-only asymmetry left gauges dead on every incoming call, fixed
    /// 2026-07-04). Gated on `EngineConfig.production().enableVoiceAnalysis`
    /// at the wiring call site (not here) — mirrors how `VoiceAnalysisEngine`
    /// itself gates processing via its own internal `enabled` flag.
    var onVoiceAnalysis: ((VoiceAnalysisResult) -> Void)?
    /// Unified call UI — REAL remote-voice spectrum: 40 log-spaced bands
    /// (0..1), ≤15 Hz (66 ms throttle at the source — see
    /// `QAudionCallIntegration.onVoiceSpectrum`). Wired alongside
    /// `onVoiceAnalysis` on BOTH the outgoing and incoming integration
    /// binding sites; AppState publishes it for the Guardian MiniSpectrum.
    var onVoiceSpectrum: (([Float]) -> Void)?
    /// Feature B ("voce verificata") — bridges
    /// `QAudionCallIntegration.onVoiceLearningStateChanged` to AppState.
    /// Wired 1:1 alongside `onVoiceAnalysis`/`onVoiceSpectrum` on BOTH
    /// integration binding sites (`startCall` outgoing +
    /// `activateIncomingCallAudio` responder) so a manually-started
    /// learning session works on either call direction.
    var onVoiceLearningStateChanged: ((VoiceLearningSession.State) -> Void)?
    /// Tier 1 ("voce come chiave") — bridges
    /// `QAudionCallIntegration.onOwnerContinuityStateChanged` to AppState.
    /// Wired 1:1 alongside `onVoiceLearningStateChanged` on BOTH
    /// integration binding sites. Fires on `OwnerContinuityMonitor`'s own
    /// private queue — AppState must hop to `@MainActor` itself before
    /// publishing, same as every other cross-thread call-engine callback.
    var onOwnerContinuityStateChanged: ((OwnerContinuityMonitor.State) -> Void)?
    /// Tier 2 ("voce remota") — bridges
    /// `QAudionCallIntegration.onContactVoiceLevelChanged` to AppState.
    /// Same wiring/threading contract as `onOwnerContinuityStateChanged`
    /// above.
    var onContactVoiceLevelChanged: ((ContactVoiceContinuityGate.Level) -> Void)?

    /// W65+W66: Full audio capture + processing pipeline.
    ///
    /// W65 ha attivato `AVAudioSession.voiceChat` mode (HW AEC/NS/AGC
    /// system-wide). W66 chiude il loop client-side: AudioCapture
    /// instanziato con la pipeline così l'AVAudioEngine.inputNode è
    /// **attivamente** engaged con `setVoiceProcessingEnabled(true)`
    /// — il VP IO unit gira su DSP separato e processa ogni PCM frame
    /// PRIMA che arrivi al nostro tap.
    ///
    /// Flow per-frame:
    ///   1. mic → VP IO unit (HW AEC + NS + AGC) → tap callback
    ///   2. supplemental software spectral subtraction (pipeline)
    ///   3. processOutgoingAudio → integration encrypt → EncryptedFrame
    ///   4. (network send: scope ENGINE WT — `wsClient.sendAudioFrame`)
    ///
    /// AudioPlayback è anch'esso instanziato e pronto a receive PCM
    /// dall'incoming WS handler. Il binding network → playback è
    /// engine WT (richiede WS dispatch → processIncomingAudio →
    /// playback.playFrame).
    ///
    /// Conflitti potenziali con C-engine audio capture: il C-engine non
    /// risulta avere capture attivo iOS-side (CLAUDE.md "voice call
    /// quality cross-platform iOS↔Android, never tested"), quindi il
    /// path Swift è l'unico mic consumer attivo. Se future PR engine-side
    /// dovesse aggiungere C-level capture concorrente, va coordinato
    /// con un toggle qui per disable Swift capture.
    private var audioPipeline: AudioProcessingPipeline?
    private var audioCapture: AudioCapture?
    private var audioPlayback: AudioPlayback?

    // XP-crackle — `AudioCapture`'s input tap runs on a dedicated real-time
    // Core Audio thread; Apple's guidance (and every other platform's own
    // fix for the identical symptom — Android's CallAudioBridge txChannel,
    // Desktop's off-thread encode) is that ANY allocation, lock, or I/O on
    // that thread risks missed render deadlines, which is exactly what
    // audible crackling sounds like. `processAndSendEncryptedFrame` used to
    // run synchronously right there: Opus encode, TWO AEAD seals (engine +
    // relay), JSONSerialization, an NSLock, and a URLSessionWebSocketTask
    // hand-off — all on the tap thread. Hand off to this dedicated SERIAL
    // queue instead. Serial (not concurrent) matters: the ratchet chain
    // position is assigned in ENCRYPT-call order, so frames must still be
    // processed strictly one-at-a-time in the order they were captured —
    // GCD serial queues execute `.async` blocks in FIFO submission order,
    // and Core Audio only ever calls the tap callback from one thread at a
    // time, so submission order already equals capture order.
    private let txAudioQueue = DispatchQueue(
        label: "com.bcrypto.qaudion.call.tx-audio-encode", qos: .userInitiated)

    /// W66: contatori di frame per diagnosi (esposti via Settings →
    /// Diagnostica). framesEncrypted incrementa ogni volta che un PCM
    /// dal mic completa il roundtrip processOutgoingAudio. framesPlayed
    /// incrementa quando un PCM decrypted entra in AudioPlayback.
    public private(set) var framesEncryptedTx: Int64 = 0
    public private(set) var framesDecryptedRx: Int64 = 0

    /// W-VIDTRANS (2026-07-24) — live read of the same three counters that
    /// `call.audio.counts` ships at teardown, so `call.video.transition` can
    /// carry audio liveness AT the moment of a lane flip. Teardown-only
    /// counters answer "was audio alive during this call"; these answer "was
    /// audio alive at this instant", which is what distinguishes a transition
    /// that killed audio from one that merely preceded an unrelated failure.
    public var liveAudioCounters: (txEnc: Int64, rxRecv: Int64, rxDec: Int64) {
        (framesEncryptedTx, framesReceivedRx, framesDecryptedRx)
    }

    // MARK: - W-DCMUX (2026-08-11) — which transport actually carried the audio
    //
    // Four counters, one per (direction × transport). They exist because the
    // question "did this call run on the DataChannel or on the WS relay?" was
    // not answerable from iOS logs at all: the live Loki pull of call
    // `0289b8d4` returned 14 iOS lines for a 69-second call, none of them about
    // the DataChannel, so "the channel never opened", "it opened and we never
    // wrote to it" and "it opened and we wrote to it and the peer ignored it"
    // were indistinguishable — and those are the three Phase 0 outcomes the
    // rollout decision hangs on.
    //
    // They count FRAMES, not bytes, and they are diagnostics only: nothing
    // reads them to make a routing decision. The routing decision stays exactly
    // where it was, per frame, in the `sendAudioOverDataChannel` fork below.
    //
    // Threading: the two TX counters are touched only on `txAudioQueue` (the
    // single serial encode queue) and the two RX counters only on main, the
    // same lock-free discipline as `framesEncryptedTx` / `framesDecryptedRx`
    // above. Reads from elsewhere are diagnostics and tolerate being one frame
    // stale.
    public private(set) var txFramesDc: Int64 = 0
    public private(set) var txFramesWs: Int64 = 0
    public private(set) var rxFramesDc: Int64 = 0
    public private(set) var rxFramesWs: Int64 = 0

    /// W-DCMUX — which transport an inbound sealed frame arrived on.
    ///
    /// The two receive paths converge on `handleIncomingEncryptedFrame` by
    /// design (identical bytes, identical decrypt, identical playout) and that
    /// must not change. This tags the ENTRY POINT only, so the split survives
    /// the convergence.
    /// `Sendable` and payload-free: the value is captured by the `@Sendable`
    /// `DispatchQueue.main.async` closure that every inbound frame already hops
    /// through, alongside the `callId` that is captured there today.
    public enum AudioRxTransport: Sendable {
        case dataChannel
        case wsRelay
    }

    /// W-DCMUX — first-frame markers, so the "it started working" instant is in
    /// the log exactly once per call instead of 50 times a second.
    private var loggedFirstTxOnDc = false
    private var loggedFirstRxOnDc = false
    /// Rate limiter for the TX-fallback line: first occurrence, then every
    /// 250th. At 50 fps an unrate-limited line would be 50 lines/second of the
    /// same fact, which is how a useful log becomes an unreadable one.
    private var txFallbackCount: Int64 = 0

    // MARK: - W-NETVIS (Android→iOS parity, 2026-08-10) — audio wire bytes
    //
    // The FLUSSO column needs bytes, and it must count them at the SAME LAYER
    // Android does or the two platforms disagree while looking comparable.
    //
    // Android's relay counter is `BcryptoWsFrameRelayTransport.txBytes
    // .addAndGet(wirePayload.size)` (BcryptoWsFrameRelayTransport.kt:275) where
    // `wirePayload = pqcSend?.seal(payload) ?: payload` (:243). That is the
    // SEALED FRAME and nothing below it: the file says so itself at :242
    // ("Everything below the `wirePayload` line is transport"). It therefore
    // excludes the base64 expansion, the JSON `audio_frame` envelope, the
    // 18-byte binary header, the WebSocket frame header and the TLS record —
    // on the text wire form the real packet is roughly 2.5-3× this number.
    // These counters deliberately reproduce that under-count rather than
    // measure the true wire cost, because a column that means one thing on
    // Android and another on iOS is worse than one that is uniformly
    // approximate: the point of the band is the cross-platform comparison
    // during a single call.
    //
    // So: TX counts `sealedFrame.count` at the send site (post-seal,
    // pre-envelope) and RX counts the POST-UNSEAL length, mirroring Android's
    // `rxBytes.addAndGet(bytes.size)` after `openInbound(...)`
    // (BcryptoWsFrameRelayTransport.kt:195-197 text, :223-225 binary — both
    // count what `openInbound` returned, and `unsealRelayFrame` here is the
    // exact same operation, pass-through until the sealer is installed).
    //
    // ONE DIVERGENCE, and it is real: Android increments TX only when the send
    // returned `ok` (:273). `BCryptoWebSocketClient.sendAudioFrame` returns
    // Void (BCryptoWebSocketClient.swift:1058) and exposes no per-send result,
    // so on the WS-relay path this counts frames HANDED to a bound socket, not
    // frames the socket accepted. The DataChannel path has no such gap —
    // `sendAudioFrameData` returns Bool and is counted only when true. The
    // difference is visible only while the socket is dead, where Android would
    // read 0 and this reads the offered rate. Closing it needs a return value
    // from the WS client, which is not this change's file.
    //
    // Threading: `wireTxBytes` is touched only on `txAudioQueue` (the single
    // serial encode queue), `wireRxBytes` only on main. Same lock-free
    // discipline as `framesEncryptedTx` / `framesDecryptedRx` directly above,
    // which are already public and read from views on every TimelineView tick.
    private var wireTxBytes: Int64 = 0
    private var wireRxBytes: Int64 = 0

    /// Previous throughput sample: monotonic timestamp + the two byte totals
    /// read at that instant. `nil` until the first sample of the call, which
    /// is why the band shows "—" for the first tick after connect — exactly
    /// like Android, where a rate needs two samples
    /// (`CallViewModel.publishNetworkStats`, CallViewModel.kt:1963-1976).
    private var lastThroughputSample: (atSec: Double, tx: Int64, rx: Int64)?

    /// Live wire throughput in kbps, last computed by [sampleWireThroughput].
    /// `nil` ⇒ "—". Written on the main actor by the sampler only.
    public private(set) var wireTxKbps: Double?
    public private(set) var wireRxKbps: Double?

    /// Measured RTT on the leg that is ACTUALLY carrying the audio, in ms, or
    /// `nil` when no such measurement exists (WS-relay path, or ICE not
    /// converged). Written on the main actor by the sampler only.
    public private(set) var mediaRttMs: Double?

    /// Compute the tx/rx kbps for this tick and store the RTT the caller
    /// resolved for the active media leg.
    ///
    /// The rate formula is Android's, verbatim
    /// (`CallViewModel.publishNetworkStats`, CallViewModel.kt:1966-1977):
    /// a delta between the last two polls divided by the ACTUALLY elapsed
    /// time, guarded by `dtSec > 0.2` and by both deltas being non-negative
    /// (a negative delta means the counter was reset, not negative traffic).
    /// Not a fixed window, so the caller's cadence does not change the value —
    /// this runs at Android's drawer-open cadence (1 Hz) rather than its
    /// piggyback cadence (2 s) and reports the same number either way.
    ///
    /// ONE DELIBERATE DEPARTURE from Android: a skipped sample yields nil
    /// here, where Android keeps the previous value
    /// (`txKbps = txKbps ?: it.txKbps`, CallViewModel.kt:1984-1985). That
    /// stickiness is why an Android readout FREEZES on a stale rate instead of
    /// admitting it stopped measuring. A dash is the truthful state.
    ///
    /// - Parameter rttMs: RTT for the active media leg, or nil when the audio
    ///   is not on a leg WebRTC can measure. Never substituted with the
    ///   signalling ping (`AppState.latencyMs`): that is a real measurement of
    ///   a different quantity (this device → signalling server, every 30 s) and
    ///   under this label it would be undetectably wrong.
    @MainActor
    public func sampleWireThroughput(mediaRttMs rttMs: Double?) {
        self.mediaRttMs = rttMs
        // Monotonic: a wall-clock step (NTP, timezone) must not manufacture a
        // spike or a negative dt.
        let nowSec = ProcessInfo.processInfo.systemUptime
        let tx = wireTxBytes
        let rx = wireRxBytes
        if let prev = lastThroughputSample {
            let dtSec = nowSec - prev.atSec
            if dtSec > 0.2, tx >= prev.tx, rx >= prev.rx {
                wireTxKbps = Double(tx - prev.tx) * 8.0 / 1000.0 / dtSec
                wireRxKbps = Double(rx - prev.rx) * 8.0 / 1000.0 / dtSec
            } else {
                wireTxKbps = nil
                wireRxKbps = nil
            }
        }
        lastThroughputSample = (nowSec, tx, rx)
    }

    // MARK: - W466 — audio-pipeline diagnostics
    //
    // The user reported "call connects but no voice/video" and asked for
    // instrumentation to tell whether the break is in CAPTURE, ENCRYPT,
    // NETWORK, DECRYPT or PLAYBACK. The frame loop runs ~50x/sec, so the
    // logging is rate-limited: a one-shot marker for the FIRST occurrence
    // of each milestone, plus a periodic heartbeat every 250 frames
    // (~5 s). The previously-silent encrypt catch is now surfaced too —
    // it used to hide every Opus/AEAD failure.
    private var framesReceivedRx: Int64 = 0   // audio_frame envelopes off the WS, pre-decrypt
    private var txEncryptErrorCount: Int64 = 0
    private var rxDecryptErrorCount: Int64 = 0
    // W-TXGATE (2026-07-12) — the mic starts capturing the instant the call UI
    // appears, but the PQC session key isn't derived until the handshake
    // completes (~0.8 s later). Every mic frame in that window used to hit
    // `processOutgoingAudio` and throw QAudionEngineError.error3 (no session),
    // inflating tx_enc_err with EXPECTED pre-handshake drops that are
    // indistinguishable from a real post-handshake crypto failure (the
    // tune-report card flagged 40 such "errors" on a healthy call). Gate the
    // encrypt on session-ready: pre-handshake frames are dropped cleanly into a
    // SEPARATE counter, so tx_enc_err counts ONLY real failures.
    private var txSessionReady = false
    private var txPreHandshakeDropped: Int64 = 0
    // AUDIO-DIAG (2026-07-12) — decoded RX audio level accumulators, mirror of
    // Android MediaPathDiag.recordRxLevel (rx_peak_pct/rx_rms_pct). Touched only
    // on the RX decode branch (same lock-free discipline as framesDecryptedRx),
    // read+reset in teardownAudioStack. peak = max |sample|, rms = sqrt(Σs²/n),
    // both reported as % of 16-bit full scale in the call.audio.diag summary.
    private var rxLevelPeak: Float = 0        // running max |sample|, normalized [0,1]
    private var rxLevelSumSq: Double = 0      // Σ(sample²) over the whole call
    private var rxLevelSampleCount: Int64 = 0 // n, for the RMS denominator
    // W-VOICEZERO (2026-07-21) — voice-analysis observability. There was NO
    // telemetry of any kind for the Guardian-ribbon analyzer, which is exactly
    // why "STRESS/RESPIRO/TONO are always zero" survived unnoticed from the
    // feature's first commit: the RX pipeline reported healthy audio while
    // `PitchExtractor` declared every single frame unvoiced (un-normalised
    // autocorrelation vs a normalised threshold — see VoicedDecisionPolicy).
    // These two counters make the failure visible in call.audio.diag as
    // va_results / va_voiced_pct: a call with va_results > 0 and
    // va_voiced_pct == 0 IS the bug, unambiguously.
    // Touched only from the two `getVoiceAnalysis().onResult` closures, which
    // run on the same main-queue RX branch as the counters above.
    //
    // PRIVACY — deliberately counters ONLY, no measured voice values. Sums of
    // f0 and stress were dropped along with the telemetry keys that carried
    // them (see the emit site): call.audio.diag is stored unsealed on the
    // server, and mean F0 is a voice biometric while stress is an affective
    // inference about the user.
    private var vaResultCount: Int64 = 0
    private var vaVoicedCount: Int64 = 0
    // Bug B diagnostics — did the playback/capture AVAudioEngines actually
    // start (true only after startAudioIOIfReady ran with an active session),
    // and did the didActivate-fallback have to fire (CallKit skipped its own
    // didActivate). Emitted in the call.audio.counts summary on teardown.
    private var audioEnginesStarted = false
    private var didActivateFallbackFired = false
    /// W-PADOVERFLOW — the engine that owns this call's audio, kept so the
    /// teardown summary can read its counters. Weak because the engine's
    /// lifetime belongs to AppState, not to this service: a strong reference
    /// here would outlive the call and keep the whole audio stack alive.
    ///
    /// It exists because `padOverflowFrames` was being incremented and read by
    /// nothing, which is the same as not counting it at all — the failure it
    /// records is a frame replaced by silence, and silence is what nobody
    /// notices. On iOS there is no adb, so telemetry is the only channel.
    private weak var audioEngineRef: QAudionEngine?
    // Frames dropped because their call_id didn't match the active session.
    // Batched relay delivery from a previous/overlapping session causes x250+
    // AEAD failures (CryptoKitError 3) without this filter.
    private var rxStaleDropCount: Int64 = 0
    private var loggedFirstTxCapture = false
    private var loggedFirstTxEncrypt = false
    private var loggedTxNoTransport = false
    private var loggedFirstRxReceive = false
    private var loggedRxNoIntegration = false
    private var loggedFirstRxDecrypt = false
    private var loggedRxNoPlayback = false
    private var loggedFirstStaleDrop = false

    // W481 — pre-bind RX frame buffer.
    // The PQC handshake and callIntegration binding are async; audio frames
    // from the peer can arrive in the 200-600 ms window before binding
    // completes. Silently dropping them advances the peer's TX ratchet
    // WITHOUT advancing our RX ratchet, causing a permanent off-by-one
    // that makes every subsequent decrypt fail (CryptoKitError error 3).
    // We buffer up to kRxPreBufferCap frames and drain them immediately
    // after callIntegration is set. Cap = 20 ≈ 400 ms at 20 ms/frame.
    private var rxPreBuffer: [Data] = []
    private static let rxPreBufferCap = 20

    // MARK: - W469 — cross-platform audio wire format
    //
    // The engine's `processOutgoingAudio` always serialises the
    // iOS-native `FrameEncoder` container. Android peers on the
    // BcryptoWsRelay can only decode the compact `WireRelayFrameCodec`
    // audio envelope — telemetry of an iPad↔A50 call showed the iPad
    // rejecting 2250+ Android frames at header parsing. The toggle
    // mirrors the video path's UserDefault (default ON → cross-platform).
    private var loggedFirstTxWire = false
    private lazy var androidAudioWireCompat: Bool =
        (UserDefaults.standard.object(
            forKey: "qaudion.video.android_wire_compat") as? Bool) ?? true

    /// W67: WebSocket transport binding. Quando setato via
    /// `wireTransport(wsClient:peerUserId:)`, il loop chiude:
    ///   TX: capture.onFrame → encrypt → wsClient.sendAudioFrame
    ///   RX: wsClient handler "audio_frame" → handleIncomingEncryptedFrame
    /// Quando nil, le encrypted bytes restano locali (counter only).
    private var wsClient: BCryptoWebSocketClient?
    private var peerUserId: String?
    /// W476 — lazy fallback providers. Wired ONCE by AppState at login.
    /// `wireTransport(wsClient:peerUserId:)` is supposed to bind the two
    /// fields above at call setup, but both call sites in AppState gate
    /// the binding on `if let ws = liveProvider?.getWebSocketClient()` —
    /// when `liveProvider` is nil at that exact moment (or for a callee
    /// whose answer path never ran `startIncomingCallAudioOnAnswer`) the
    /// binding is silently SKIPPED, and every encrypted TX frame after
    /// that is dropped on the floor: capture+encrypt run normally
    /// (waveforms visibly move) but the server logs zero
    /// `audio relay from=<us>` and the peer hears nothing. These
    /// closures let `processAndSendEncryptedFrame` recover at TX time by
    /// fetching the live WS + current peer id directly. They follow the
    /// CLAUDE.md §16 pattern (no AppState param — closures capture only
    /// what they need, weakly).
    // Best-effort getters: read non-isolated because the TX path runs on
    // txAudioQueue (a dedicated background queue — XP-crackle moved it off
    // the AVFAudio tap thread, but it's still not main). AppState only sets
    // `liveProvider` and `callContactId` from main, but a stale read across
    // threads is acceptable for this fallback (worst case: drops the very
    // first frame and binds on the second). They MUST stay nullary `() -> ...`.
    public typealias WsClientProvider = () -> BCryptoWebSocketClient?
    public typealias PeerIdProvider = () -> String?
    /// Returns true iff the call is in an active/encrypted state — used
    /// by the W469 fallback timer to skip self-activation during outgoing
    /// ring (before the peer has answered). Wired by AppState at login.
    public typealias CallActiveProvider = () -> Bool
    /// W525 — Returns the wire-format call_id of the currently active
    /// call (lowercase UUID for outgoing, server-supplied callIdStr
    /// for incoming). Required on every `audio_frame` envelope so
    /// Android + Desktop peers accept the frame instead of dropping
    /// it for missing/mismatched call_id. Wired by AppState at login.
    public typealias CallIdProvider = () -> String?
    /// W-LONGAUDIO (2026-08-10) — the PEER's raw advertised capability list
    /// **for the call whose wire id is passed in**, exactly as it arrived on
    /// `call_incoming` (responder) or `call_answer` (caller).
    ///
    /// The parameter is not a convenience: it is the enforcement of §1.6 clause
    /// 2, "a negotiation result exists for THIS call". The provider returns the
    /// list only when it was captured for that exact call id, and `nil`
    /// otherwise — no id, no stored id, or two ids that differ. A nullary
    /// version of this getter can only answer "the last list I saw from
    /// anybody", which lets a PREVIOUS call's peer decide THIS call's wire
    /// format; that is the one outcome the whole design exists to prevent.
    ///
    /// Read once, at the latch, and never again. `nil` is a perfectly good
    /// answer: it means the call runs the standard profile for its whole life,
    /// which is the correct outcome rather than something to wait or retry for.
    /// Wired by AppState to its ``PeerCapabilityBinding``, which holds the list
    /// and the id it was captured for behind one lock.
    public typealias PeerCapabilitiesProvider = (String?) -> [String]?
    public var getWsClient: WsClientProvider?
    public var getPeerId: PeerIdProvider?
    public var isCallActive: CallActiveProvider?
    public var getCallId: CallIdProvider?
    public var getPeerCapabilities: PeerCapabilitiesProvider?
    /// W-GRPVPIO-CRASH-3 (2026-07-17) — returns true while a GROUP call owns
    /// the shared VoiceProcessingIO hardware unit (LiveKit's SFU room drives
    /// it directly). Injected by AppState (`{ groupCallKitId != nil }`).
    /// Every 1:1 audio-engine START path guards on this so NO caller — any
    /// WS message handler, CallKit callback, or stale redelivered signaling —
    /// can call `setVoiceProcessingEnabled(true)` on a SECOND engine while
    /// LiveKit already holds the unit: that throws an uncatchable ObjC
    /// NSException inside AVAudioEngineGraph::_Connect (EXC_CRASH/SIGABRT,
    /// crashPointId B4lMk7amGdH7pnGoa5qsYT — repro'd 5+ times today via the
    /// App Store Connect crash portal, always "crash after answering" a
    /// group call). The earlier fix gated ONLY the `call_answer` WS handler;
    /// the crash log's Last Exception Backtrace (still
    /// NSURLSessionWebSocketTask.receive → app → setVoiceProcessingEnabled)
    /// proved another WS message path reaches it. Guarding at the engine
    /// entry points here is defense-in-depth: it closes every path at once
    /// rather than playing whack-a-mole with individual message handlers.
    public var isGroupCallActive: (() -> Bool)?
    /// W-DCAUDIO — send a sealed audio frame over the WebRTC DataChannel if it is
    /// open; returns true if queued there, false to fall back to the WS relay.
    /// Wired by AppState to `QAudionWebRtcCallController.sendAudioFrameData`. The
    /// payload is the raw WireRelayFrameCodec envelope (same bytes as the WS path).
    public var sendAudioOverDataChannel: ((Data) -> Bool)?
    /// W-DCMUX (2026-08-11) — why the closure above returned `false`, as a
    /// single Int. Wired by AppState; read ONLY when a fallback line is about to
    /// be printed (first occurrence, then every 250th), never per frame.
    ///
    ///   `-3` audio is pinned to the WS relay for this call shape
    ///        (`AppState.audioPinnedToWsRelay`, set on the video-upgrade
    ///        responder path so the proven relay audio leg is left alone);
    ///   `-2` there is no `QAudionWebRtcCallController` for this call at all;
    ///   `-4` a controller exists but its `PeerConnection` is gone;
    ///   `-1` a PeerConnection exists but no DataChannel was ever created;
    ///   `0…3` the raw `RTCDataChannelState` (0 connecting, 1 open, 2 closing,
    ///        3 closed) of a channel that exists but is not open.
    ///
    /// `sendAudioFrameData` collapses every one of these into the same `false`,
    /// and they are different bugs: the capability tag is irrelevant for
    /// `-3`/`-2`/`-4`, ICE is the suspect for `-1`/`0`, and `2`/`3` mean a
    /// channel that was alive and died — the case the Android WS-receive
    /// companion change exists for. `1` (OPEN) must be unreachable here and
    /// prints as `openbug` if it ever is.
    public var audioDataChannelDiag: (() -> Int)?
    /// W-KCMAC (multi-PSK-mixing SYNTHESIS.md ship step 5) — live-getter for the
    /// active call's key-confirmation telemetry snapshot, same pattern as
    /// `getCallId` above. Wired by AppState to read its own per-call
    /// `keyConfirmationTelemetryByCall` dict. `nil` when the current call never
    /// fired `onKcMacReady` (no active call, or the PQC handshake never
    /// completed) — `teardownAudioStack()` simply omits the four fields in
    /// that case rather than emitting placeholders. Read (not consumed) at
    /// `call.audio.diag` teardown — no new telemetry channel, per the design.
    public var getKeyConfirmationTelemetry:
        (() -> (pskMixN: Int, kcMacResult: String, assuranceState: String, expectedButMissing: Bool)?)?
    /// Token usato per de-registrare il handler "audio_frame" su endCall
    /// — assumiamo che `registerHandler` sostituisca il precedente per
    /// type, quindi de-register è no-op (ma resettiamo wsClient così
    /// future incoming frames non triggherano playback senza session).

    /// W464 — true once CallKit has activated the shared AVAudioSession.
    /// `AVAudioEngine.start()` (inside AudioCapture/AudioPlayback) REQUIRES
    /// an active session; starting it before CallKit's `didActivate`
    /// throws "Session activation failed" and the call ends up with NO
    /// audio in either direction even though WebRTC + the PQC handshake
    /// succeed. We therefore create the capture/playback objects in
    /// `startCall` / `activateIncomingCallAudio` but DEFER their
    /// `.start()` until `handleAudioSessionActivated()` fires.
    private var audioSessionActive = false

    /// W574b — true once the remote peer has formally answered
    /// (`call_answer` received, for outgoing calls) or once WE answered
    /// (incoming calls — set in `activateIncomingCallAudio`). Gates the
    /// mic start INDEPENDENTLY of `AppState.callState`: the outgoing flow
    /// sets `.active` right after the OFFER is sent (long before the peer
    /// answers), so the v1.0.618 `isCallActive?()` check never blocked
    /// anything — verified in the 655de1d9 device log (mic at +1.6s,
    /// call_answer at +5.9s).
    private var peerAnswered = false

    // MARK: - W574e — M-15 BcryptoWsRelay frame sealing (Android interop)

    /// PQC RTP frame sealers for the WS-relay audio path. Android's
    /// `BcryptoWsFrameRelayTransport` wraps EVERY relay audio frame in an
    /// AES-GCM seal (nonce12||ct||tag16, HKDF key from the PQC session key
    /// + callId, per-frame counter nonce, 64-frame anti-replay) ON TOP of
    /// the AdaptivePadding+WireRelayFrameCodec frame — UNCONDITIONALLY. iOS
    /// shipped the byte-identical `PqcRtpFrameSealer` (KAT-matched) but
    /// never wired it into this path (only into WebRTC SRTP), so every
    /// Android→iOS relay frame failed AEAD decode (100% rx_dec_err, calls
    /// 8bfdbad1/427e5027). These two sealers (independent counters via
    /// makeSibling — M-13) restore the layer. nil until the session key is
    /// known → pre-handshake frames pass through, matching Android's
    /// `pqcSend?.seal(payload) ?: payload`.
    private var relaySealerSend: PqcRtpFrameSealer?
    private var relaySealerRecv: PqcRtpFrameSealer?

    /// W574h — the (lowercased) callId the current relay sealers are bound to.
    /// The M-15 seal key is `HKDF(pqcSessionKey, info="…:<callId>")`, so the
    /// sealer is only valid for ONE call. Tracking the bound callId lets the
    /// installer re-key when the active call changes (call glare / retry leave
    /// more than one callId in flight) instead of staying locked to a dead
    /// call's key — the v1.0.624→632 "connected but silent both ways" bug.
    private var relaySealerCallId: String?

    /// W574l — fingerprint (8 hex of SHA-256) of the session key the current
    /// sealers were built from. The call handshake fires `onRelaySessionReady`
    /// from MULTIPLE sites with DIFFERENT key material (QUAD raw ML-KEM
    /// `sharedSecret` vs JSON dual-hybrid `combined`); the old per-callId
    /// idempotency locked the sealer to whichever fired FIRST, so if a
    /// contact-key-exchange `sharedSecret` install beat the real audio
    /// `combined` key, the seal was keyed wrong while the audio engine used
    /// `combined` → 100% M-15 unseal failure even on a clean same-callId call.
    /// Tracking the key fingerprint lets the installer re-key when the KEY
    /// changes for the same call (last-write-wins on key); logging it lets the
    /// two peers' seal keys be compared across devices.
    private var relaySealerKeyFp: String?

    /// W-SLOTLOCK (2026-07-12) — serialises the mutable reference-typed relay
    /// slots that are touched from MULTIPLE threads: the TX audio tap
    /// (txAudioQueue) reads `wsClient`/`peerUserId`/`relaySealerSend` per frame;
    /// the RX decode path reads `relaySealerRecv`; `installRelaySealers` (fires
    /// from several handshake sites), `wireTransport`, `answer()` and
    /// `teardownAudioStack()` write them from the call-lifecycle thread. Without
    /// a barrier the release-old/retain-new ARC write of a reference slot races
    /// a concurrent read → torn refcount → use-after-free that detonates later
    /// (EXC_CRASH/SIGTRAP) at an innocent site. CallService is @unchecked
    /// Sendable precisely so it can own this synchronisation. Contract: hold the
    /// lock ONLY to copy the reference in/out — never across seal/open/network or
    /// any call that might re-enter (NSLock is non-recursive).
    private let relaySlotLock = NSLock()

    /// W-LONGAUDIO (2026-08-10) — resolve and latch this call's audio profile.
    ///
    /// Called exactly once, from the `.active` handshake transition. Everything
    /// it consults is already in hand: the peer's raw advertised list (injected
    /// by AppState) and the local list from the gated accessor. It performs the
    /// intersection itself rather than reading the WebRTC controller's cached
    /// result, because on a WS-relay audio call — which is how iOS carries voice
    /// — there may be no live PeerConnection at all, and reaching for one would
    /// make the profile depend on whether video happened to be negotiated.
    ///
    /// Every failure is the same failure: STANDARD. No peer list, an unparsed
    /// one, an earbud in the call, the kill switch off, or a peer that only
    /// advertised half the pair — all land on today's wire, silently and
    /// completely.
    private func latchAudioProfileForCall() {
        // ── The peer list must belong to THIS call, and be provably so ──
        //
        // §1.6 clause 2 is "a negotiation result exists for THIS call". Ask for
        // the active call's wire id first and hand it to the provider, which
        // returns the peer's advertised list ONLY if that is the call the list
        // was captured for.
        //
        // Everything that can go wrong here lands on the same answer. No active
        // call id yet (the handshake beat the id binding), no stored list, a
        // list captured for a DIFFERENT call, or a fresh list whose main-actor
        // write has not landed yet — all of them are `nil`, which negotiates to
        // an empty intersection and resolves to STANDARD. There is deliberately
        // no wait and no retry: the contract's answer to "the negotiation result
        // has not arrived" is that the call runs standard for its whole life.
        let activeCallId = getCallId?()
        let peerCaps = getPeerCapabilities?(activeCallId)
        let negotiated = CallCapabilities.negotiate(
            local: CallsGate.filterAdvertisedCapabilities(CallCapabilities.localCaps()),
            peer: peerCaps
        )
        // On iOS the sovereign earbud is always the PEER's: there is no iOS
        // earbud transport, so we detect the tag rather than advertise it. That
        // peer relays sealed frames to firmware with a 960-sample decode buffer.
        //
        // Reads the SAME call-bound `peerCaps` as the negotiation above, so an
        // unbindable list cannot make this true either. That direction is safe
        // by construction: `peerCaps == nil` makes this `false`, and `false` can
        // only ever move the resolver toward LONG — but the resolver has already
        // failed clause 3 on the empty intersection, so the answer is STANDARD
        // regardless. The two checks are independent and both must hold.
        let earbudInCall = CallCapabilities.peerAdvertisedEarbudRelay(peerCaps)
        let profile = CallCapabilities.resolveAudioProfile(
            negotiated: negotiated,
            earbudInCall: earbudInCall
        )
        // ── Ordering: CAPTURE bounds the ENGINE, never the reverse ──
        //
        // This method runs from THREE sites — the PQC `.active` transition, the
        // incoming-answer audio setup, and immediately before `capture.start()`
        // — because none of them is guaranteed to come first. On an outgoing
        // call CallKit's `didActivate` can precede the handshake entirely.
        //
        // Capture is the side with the hard constraint: its geometry cannot
        // change once the AVAudioEngine is running. The engine's latch, by
        // contrast, is terminal but can be taken late. So capture is asked
        // FIRST, and a refusal downgrades the whole call to standard — the "any
        // doubt, fall back silently and completely" rule, applied to an ordering
        // race instead of to a parse failure.
        //
        // Getting this backwards is not a subtle bug: an engine encoding at
        // 60 ms behind a re-chunker still emitting 1920-byte frames rejects
        // every single `encode`, and the call connects, holds a perfectly
        // constant packet rate, and transmits nothing at all.
        let capture = audioCapture
        var agreed = profile
        if profile != .standard, capture?.setCaptureProfile(profile) != true {
            agreed = .standard
        }
        callIntegration?.latchAudioProfile(agreed)
        // Read back what the engine actually holds: an earlier visit may have
        // latched it, and the latch is terminal.
        let effective = callIntegration?.activeAudioProfile ?? .standard
        if effective != agreed, capture?.setCaptureProfile(effective) != true,
           capture?.captureProfile != effective {
            // Unreachable under the ordering above (the engine only ever holds a
            // long profile that capture already accepted). Logged rather than
            // assumed away, because the symptom would be a silent call.
            print("[CallService] W-LONGAUDIO: profile mismatch — engine \(effective.frameDurationMs) ms vs capture \(capture?.captureProfile.frameDurationMs ?? -1) ms")
        }
        if effective != .standard || profile != effective {
            print("[CallService] W-LONGAUDIO: audio profile \(effective.frameDurationMs) ms / \(effective.blockBytes) B (resolved \(profile.frameDurationMs) ms)")
        }
    }

    /// One-way 8-hex fingerprint of a key — safe to log (does NOT reveal key
    /// bytes). Used only to compare seal keys across the two peers' logs.
    private static func sealKeyFingerprint(_ key: Data) -> String {
        let digest = SHA256.hash(data: key)
        var hex = ""
        for b in digest.prefix(4) {
            let s = String(b, radix: 16)
            hex += (s.count == 1 ? "0" + s : s)
        }
        return hex
    }

    /// Build the WS-relay sealers from the established PQC session key and
    /// the wire call_id. MUST use the lowercase wire call_id (same string
    /// Android feeds `PqcRtpFrameSealer.create`) or the HKDF info diverges
    /// and interop fails.
    ///
    /// W574h — the sealer MUST track the ACTIVE call. The M-15 seal key is
    /// `HKDF(pqcSessionKey, info="q-audion-srtp-master-v1:<callId>")`, so a
    /// sealer built for callId A can NEVER open/seal frames for callId B.
    /// Under call glare or retry there can be more than one callId in flight
    /// (e.g. a superseded outgoing call whose handshake completed first, then
    /// the call actually answered) — the old `guard relaySealerSend == nil`
    /// locked onto whichever fired first and silently skipped the live call,
    /// so the peer's frames failed 100% AEAD (M-15 unseal failed) in BOTH
    /// directions with NO fallback (W574d disabled SRTP audio). This installer
    /// now:
    ///   • IGNORES installs for a callId that isn't the active call
    ///     (`getActiveCallId()` is set by bindIncomingCallId /
    ///     sendCallOfferWithId BEFORE the handshake completes, so it is
    ///     authoritative here) — a dead call's late handshake can't clobber
    ///     the live sealer, and can't leave us keyed to a stale call;
    ///   • is IDEMPOTENT for the SAME call — re-firing must NOT rebuild,
    ///     because that would reset the AES-GCM send counter to 0 and risk
    ///     (key, nonce) reuse (catastrophic for confidentiality);
    ///   • RE-KEYS when the active call's id genuinely changes.
    /// Pure iOS-side logic — no wire-format / HKDF change, so Android, the
    /// firmware earbud counterparty, Desktop and the server are unaffected.
    public func installRelaySealers(sessionKey: Data, callId: String,
                                    srtpDirKeyV1: Bool = false, selfIsRoleA: Bool = false) {
        let cid = callId.lowercased()
        // Stale-call guard: only (re)key for the call media actually flows on.
        if let active = getCallId?()?.lowercased(), !active.isEmpty, active != cid {
            let a: String = String(cid.prefix(8))
            let b: String = String(active.prefix(8))
            let line: String = "[CallService] W574h: relay sealer install IGNORED for non-active callId=" + a + "… (active=" + b + "…)"
            print(line)
            return
        }
        // W574l — idempotent ONLY when the callId AND the key are both
        // unchanged (rebuilding with the same key would reset the AES-GCM
        // counter → (key,nonce) reuse). Re-key when the call's session key
        // changes: the handshake fires onRelaySessionReady from several sites
        // with different key material, and the seal MUST end up on the audio
        // session key the engine actually uses — last write wins. A new key
        // means a brand-new sealer with counter 0, which is safe (the key,
        // and therefore the whole nonce space, is new).
        let kfp: String = Self.sealKeyFingerprint(sessionKey)
        // W-SLOTLOCK — read the dedup slots under the lock (they are written from
        // the audio threads' lazy paths). Copy out; the crypto below runs unlocked.
        let (dedupSend, dedupCallId, dedupKeyFp): (PqcRtpFrameSealer?, String?, String?) =
            relaySlotLock.withLock { (relaySealerSend, relaySealerCallId, relaySealerKeyFp) }
        if dedupSend != nil, dedupCallId == cid, dedupKeyFp == kfp { return }
        let hadSealer: Bool = (dedupSend != nil)
        // P0-4 (2026-08-05, coordinated fix plan cluster 3) — the legacy
        // non-directional fallback that used to run here (single shared master
        // key via `PqcRtpFrameSealer(pqcSessionKey:callId:)` + `makeSibling()`,
        // each sealer counting its own AES-GCM nonce from 0) let caller-frame-N
        // and callee-frame-N reuse the exact same (key, nonce) pair —
        // catastrophic AEAD failure. This M-15 seal is a WS-relay-specific
        // OUTER wrap on top of `integration.processOutgoingAudio`'s own
        // per-frame encryption (the real E2EE layer, unconditional and
        // unaffected by this flag — see `unsealRelayFrame`'s doc: frames pass
        // through UNCHANGED whenever no sealer is installed, which is exactly
        // the pre-handshake posture this now also uses when directional keys
        // were never negotiated). So the correct fix is to SKIP installing
        // this specific outer wrap, not to fabricate an unsafe shared key.
        guard srtpDirKeyV1 else {
            let p: String = String(cid.prefix(8))
            let line: String = "[CallService] W574x-iOS: srtpDirKeyV1 not negotiated callId=" + p + "… — P0-4 fail-closed: skipping non-directional M-15 outer seal"
            print(line)
            return
        }
        do {
            // W574x — directional per-direction keys when both peers negotiated
            // srtpDirKeyV1 (fixes bidirectional AES-GCM nonce reuse). Role A =
            // the lexicographically-smaller userId (computed by the caller, same
            // rule as Android/Desktop).
            let pair = try PqcRtpFrameSealer.createDirectional(
                pqcSessionKey: sessionKey, callId: cid, selfIsRoleA: selfIsRoleA)
            let send = pair.send
            let recv = pair.recv
            relaySlotLock.withLock {
                relaySealerSend = send
                relaySealerRecv = recv
                relaySealerCallId = cid
                relaySealerKeyFp = kfp
            }
            let verb: String = hadSealer ? "re-keyed" : "installed"
            let p: String = String(cid.prefix(8))
            // W574x diag — mirror Android's "PQC_DIAG W574x ... dirKeys=.. roleA=.."
            // so an iOS↔Android call can be compared side-by-side: if iOS dirKeys
            // disagrees with the peer (one directional, one single) OR the role is
            // not opposite, the recv key can't open the peer's frames (M-15 unseal
            // failed/replay). keyfp is the MASTER sessionKey fp (pre-directional) —
            // if it differs across peers the handshake/callId diverged, not the role.
            let dirStr: String = srtpDirKeyV1 ? "true" : "false"
            let roleStr: String = selfIsRoleA ? "A" : "B"
            let line: String = "[CallService] PQC_DIAG W574x-iOS sealers " + verb + " callId=" + p + "… keyfp=" + kfp + " dirKeys=" + dirStr + " role=" + roleStr
            print(line)
        } catch {
            print("[CallService] W574e: relay sealer install failed: \(error) — relay runs unsealed (Android interop will fail)")
        }
    }

    // MARK: - Mute / Hold

    /// When true, processOutgoingAudio returns silent (zero-padded) ciphertext.
    /// Drives the user-facing mute toggle. CallKit's CXSetMutedCallAction
    /// flips this via AppState bridge.
    public private(set) var isMuted: Bool = false

    /// Set/cleared by the CallKit mute bridge. Must be called on the main thread.
    public func setMuted(_ muted: Bool) {
        self.isMuted = muted
    }

    /// Feature B ("voce verificata") — start learning `contactId`'s voice
    /// from the CURRENT call's decoded RX audio. No-op if there is no
    /// active `callIntegration` (e.g. called outside a call).
    func startVoiceLearning(contactId: String) {
        callIntegration?.startVoiceLearning(contactId: contactId)
    }

    /// Tier 2 ("voce remota") — activate continuous per-contact RX
    /// verification for `contactId`. No-op if there is no active
    /// `callIntegration`. Wired from both call directions: outgoing calls
    /// call this from the `.active` handler below (contactId already in
    /// scope from `startCall`'s own parameter); incoming calls call it from
    /// `activateIncomingCallAudio` once `contactId` is passed in.
    func activateContactVoiceVerification(contactId: String) {
        callIntegration?.activateContactVoiceVerification(contactId: contactId)
    }

    /// Tier 2 counterpart — deactivate continuous per-contact RX
    /// verification. `endCall`/`teardownAudioStack` already tear down the
    /// whole `callIntegration` (whose own `onCallEnded` calls the
    /// equivalent cleanup internally), so this is only needed for an
    /// explicit mid-call contact switch, if one is ever added.
    func deactivateContactVoiceVerification() {
        callIntegration?.deactivateContactVoiceVerification()
    }

    /// See `QAudionCallIntegration.ownerContinuityShouldAlert` — `false`
    /// (never alert) if there is no active `callIntegration`.
    func ownerContinuityShouldAlert() -> Bool {
        callIntegration?.ownerContinuityShouldAlert() ?? false
    }

    /// Cancel an in-flight voice-learning session for the current call.
    func cancelVoiceLearning() {
        callIntegration?.cancelVoiceLearning()
    }

    /// When true, audio is paused. For now, hold == mute both directions plus
    /// pausing the duration timer (QAudionCallIntegration hold API is USER WT).
    public private(set) var isOnHold: Bool = false

    public func setOnHold(_ onHold: Bool) {
        self.isOnHold = onHold
        if onHold { stopDurationTimer() } else { startDurationTimer() }
    }

    // MARK: - Call duration tracking

    /// Wall-clock seconds since `startCall(...)` succeeded.
    public private(set) var callDurationSeconds: TimeInterval = 0
    public var onDurationTick: ((TimeInterval) -> Void)?

    private var durationTimer: Timer?
    private var callStartedAt: Date?

    private func startDurationTimer() {
        callStartedAt = callStartedAt ?? Date()
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let started = self.callStartedAt else { return }
            let dur = Date().timeIntervalSince(started)
            self.callDurationSeconds = dur
            self.onDurationTick?(dur)
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    func startCall(engine: QAudionEngine, contactId: String) throws {
        // W65: defensive cleanup se startCall è chiamato 2x senza endCall.
        teardownAudioStack()
        // W-PADOVERFLOW — after the defensive teardown, so that teardown
        // reports the PREVIOUS call rather than this one's empty counters.
        audioEngineRef = engine

        // W65: PRIMA cosa — configura AVAudioSession in `.voiceChat` mode
        // per attivare lo stack HW DSP di Apple (Voice Processing I/O).
        // Best-effort: se fallisce la chiamata continua comunque.
        // W406: read CallsGate so the user's AEC/NS/AGC choice
        // actually controls Apple's VP I/O unit. iOS bundles the three
        // effects into a single switch — when ALL three are off,
        // we explicitly disable VP I/O. Otherwise the previous
        // hardcoded `setVoiceProcessingEnabled(true)` behavior holds.
        let pipeline = AudioProcessingPipeline()
        pipeline.voiceProcessingOverride = CallsGate.anyVoiceProcessingEnabled
        do {
            try pipeline.configureForVoIP()
            self.audioPipeline = pipeline
        } catch {
            print("[CallService] AVAudioSession.voiceChat config failed: \(error.localizedDescription) — fallback a session default")
            // Even without successful session config, continue: pipeline can
            // still attempt VP enable on the engine inputNode below.
            self.audioPipeline = pipeline
        }

        // W66: instantiate audio capture + playback PRIMA dell'integration
        // così il VP IO unit è attivo sul mic capture loop.
        // Best-effort: errori catturati e loggati — la chiamata continua
        // anche se il capture / playback falliscono (es. simulator).
        let capture = AudioCapture(audioPipeline: pipeline)
        // W-GRPVPIO-CRASH-4 — gate THIS 1:1 engine's own restart paths
        // (route change / interruption / starve watchdog) on the same
        // group-call-ownership signal the entry chokepoints use, so a stray
        // observer-driven restart during a group call can't SIGABRT in
        // setVoiceProcessingEnabled. See AudioCapture.isGroupCallActive kdoc.
        capture.isGroupCallActive = { [weak self] in self?.isGroupCallActive?() == true }
        let playback = AudioPlayback()

        // Encrypt-on-mic-frame callback: ogni PCM dal mic passa attraverso
        // VP IO HW DSP, poi spectral subtraction, poi processOutgoingAudio
        // (Opus encode + AEAD encrypt). L'output `encrypted` è un
        // `EncryptedFrame` serializzato pronto per il transport WS — ma il
        // network sender (`BCryptoWebSocketClient.sendAudioFrame`) NON è
        // wirable da CallService senza injection del wsClient — è
        // ENGINE WT. Per ora i frame encryptati sono solo conteggiati
        // così l'utente vede via Diagnostica che il loop crypto sta girando.
        capture.onFrame = { [weak self] pcmFrame in
            guard let self = self,
                  let integration = self.callIntegration else { return }
            // W69: dev network simulator hook. In Off (default) il call
            // è branch-predicted off-path. In altri profili può
            // droppare o ritardare il frame.
            if !NetworkConditionSimulator.shared.isPassthrough() {
                if NetworkConditionSimulator.shared.shouldDropOutbound() {
                    return  // frame droppato — simula packet loss outbound
                }
                // Delay è async; isolated in a Task così non blocca il
                // tap callback. Per simulare HighLatency / Satellite il
                // peer riceve il frame con il delay configurato.
                Task { [weak self] in
                    await NetworkConditionSimulator.shared.delayOutbound()
                    self?.txAudioQueue.async {
                        self?.processAndSendEncryptedFrame(pcmFrame: pcmFrame, integration: integration)
                    }
                }
                return
            }
            // XP-crackle — off the real-time tap thread; see txAudioQueue kdoc.
            self.txAudioQueue.async { [weak self] in
                self?.processAndSendEncryptedFrame(pcmFrame: pcmFrame, integration: integration)
            }
        }

        // W464 — store the capture/playback refs UNCONDITIONALLY (before
        // any .start()) so the start can be (re)driven later.
        self.audioPlayback = playback
        self.audioCapture = capture
        // W464 — OUTGOING calls are now driven by CallKit's CXProvider
        // (AppState.startCall(contactId:) calls `callKit.startOutgoingCall`),
        // which triggers `provider(_:didActivate:)`. We defer starting the
        // audio engines until `handleAudioSessionActivated()` is fired by CallKit.

        let integration = QAudionCallIntegration()

        integration.onStateChanged = { [weak self] state in
            guard let self else { return }
            switch state {
            case .active:
                print("[CallService] PQC handshake complete — session active")
                // W-TXGATE — session key is live; open the TX encrypt gate. From
                // here processOutgoingAudio can succeed, so any failure past this
                // point is a REAL crypto error (counted in tx_enc_err).
                self.txSessionReady = true
                // W-LONGAUDIO (2026-08-10) — THE LATCH. Once per call, here.
                //
                // This is the one point that satisfies both halves of the
                // requirement: it runs strictly AFTER the PQC handshake outcome
                // is known (that is what `.active` means) and strictly BEFORE
                // capture starts, since the audio engines are started later by
                // CallKit's `didActivate`. It must precede
                // `reconfigureAudioCodec` below, because that call clamps the
                // bitrate against whatever profile is latched — clamping first
                // and latching second would apply the standard ceiling to a long
                // profile and overflow every frame.
                //
                // No setter, no re-evaluation, no retry: `latchAudioProfile`
                // refuses a second call. If the peer's capabilities have not
                // arrived yet the resolver returns `.standard` and the call runs
                // standard for its whole life.
                self.latchAudioProfileForCall()
                // Engine is now initialized — apply tuner-persisted codec params.
                self.callIntegration?.reconfigureAudioCodec(
                    bitrateKbps: AudioCodecPrefs.bitrateKbps,
                    plp:         AudioCodecPrefs.plp
                )
                // Tier 2 ("voce remota") — outgoing side: `contactId` is
                // this closure's own capture from `startCall`'s parameter,
                // so it's always the CURRENT call's peer. Routed through
                // `self.callIntegration?` (not the captured `integration`
                // local) to match this handler's own existing
                // `reconfigureAudioCodec` call just above — same
                // stale-closure guard.
                self.callIntegration?.activateContactVoiceVerification(contactId: contactId)
            case .error:
                self.endCall()
            case .fallback:
                // W461: PQC handshake slow/timed out. Do NOT tear down the
                // call here — the 30s fallback is purely a "handshake slow"
                // signal. Ending the call here caused the exact 30s drop bug
                // (iPad→A50 calls always dropped at :30). The call ends
                // normally when either side hangs up.
                //
                // CORRECTION (audit wf_b1d38abe): there is NO "audio continues
                // via WebRTC DTLS" invariant on iOS. The WebRTC SRTP audio
                // track is added DISABLED (QAudionPeerConnection.addLocalAudioTrack,
                // W574d) and the remote SRTP audio track is force-disabled on
                // arrival — voice rides ONLY the sealed WS relay (PqcRtpFrameSealer
                // M-15 seal over the engine's Opus+AEAD frames). While the relay
                // sealer is not yet installed (G2 unmet) NO mic frame is sent at
                // all (fail-closed, see startAudioIOIfReady / processAndSendEncryptedFrame).
                // So this state means "still negotiating the PQC seal", never
                // "falling back to plaintext/DTLS audio".
                print("[CallService] PQC handshake fallback — keeping call alive; voice stays on the sealed relay (no DTLS-audio fallback exists). Diagnose: check Android ACCEPT routing and callId case match.")
            default:
                break
            }
        }

        integration.onDeepfakeAlert = { [weak self] level, score in
            guard let self else { return }
            let isAlert: Bool
            switch level {
            case .red:
                isAlert = true
            case .yellow, .green:
                isAlert = false
            }
            self.onDeepfakeAlert?(isAlert)
            self.onDeepfakeScore?(level, score)
        }

        // Unified call UI — Guardian ribbon voice biometrics. Battery/perf
        // gate: only assign `onResult` (i.e. only ever receive callbacks)
        // when the engine config has voice analysis enabled. EngineConfig
        // .production() has enableVoiceAnalysis=true; .batteryOptimized()
        // (not currently selected anywhere) has it false — this check keeps
        // the wiring inert automatically if/when the app switches profiles,
        // without adding a second gate that could drift from the engine's
        // own config. VoiceAnalysisEngine.processFrame() ALSO internally
        // downsamples via analysisRate (default every 5th frame), so this
        // wiring does not run the full analysis pipeline unconditionally.
        if EngineConfig.production().enableVoiceAnalysis {
            integration.getVoiceAnalysis().onResult = { [weak self] result in
                self?.recordVoiceAnalysisSample(result)
                self?.onVoiceAnalysis?(result)
            }
            // Unified call UI — REAL RX spectrum for the Guardian ribbon's
            // MiniSpectrum. Same battery gate as the gauges above; the
            // integration additionally skips the FFT while this stays nil.
            integration.onVoiceSpectrum = { [weak self] bands in
                self?.onVoiceSpectrum?(bands)
            }
        }

        // Feature B ("voce verificata") — bridge the per-contact learning
        // session's state, unconditionally (not gated on enableVoiceAnalysis:
        // this is a manually-triggered, one-shot action, not a per-frame
        // battery-cost pipeline like the gauges above).
        integration.onVoiceLearningStateChanged = { [weak self] state in
            self?.onVoiceLearningStateChanged?(state)
        }
        // Tier 1/Tier 2 — unconditional, same reasoning as
        // `onVoiceLearningStateChanged` above: these are not a per-frame
        // battery-cost pipeline gated on `enableVoiceAnalysis`.
        integration.onOwnerContinuityStateChanged = { [weak self] state in
            self?.onOwnerContinuityStateChanged?(state)
        }
        integration.onContactVoiceLevelChanged = { [weak self] level in
            self?.onContactVoiceLevelChanged?(level)
        }

        // NOTE: do NOT call `integration.onCallSetupStarted` here.
        // That legacy entry point flipped the engine state machine into
        // .capabilitySent with an empty send-closure (bytes → /dev/null),
        // which then made `beginAndroidOutgoing` →
        // `onAndroidCallSetupStarted` fail with
        // `invalidState(.capabilitySent)` so no PQC OFFER ever reached
        // the peer and the call attached no media (silent audio).
        // The universal outgoing path is `beginAndroidOutgoing` for
        // ALL peer types (iOS / Android / Desktop) — it owns the
        // idle → capabilitySent transition itself and ships the real
        // JSON+QUAD OFFER pair.

        self.callIntegration = integration
        drainRxPreBuffer()  // W481 — replay any frames that arrived before binding
        startDurationTimer()

        // W469 — CallKit `didActivate` fallback for OUTGOING calls.
        // The W467 path defers the audio-engine start to
        // `provider(_:didActivate:)`. Telemetry of an iPad→A50 call
        // showed the iPad relaying ZERO TX frames: the mic never
        // started because CallKit's `didActivate` was not observed and
        // `audioSessionActive` stayed false forever, making
        // `startAudioIOIfReady()` a permanent no-op. If the session is
        // still not active after a short grace period, self-activate so
        // the call has working audio. `configureForVoIP()` already ran
        // above (best-effort `setActive(true)`); this only flips the
        // flag and starts the (idempotent) capture/playback engines. If
        // CallKit DOES fire `didActivate` first, this closure sees
        // `audioSessionActive == true` and does nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            guard !self.audioSessionActive, self.callIntegration != nil else { return }
            // Only self-activate when the peer has actually answered.
            // During outgoing ring this must not open the mic — the peer
            // hasn't answered yet and early audio activation leaks the
            // session and causes the waveform to animate before answer.
            // W574b: use peerAnswered (not isCallActive — AppState sets
            // .active right after the OFFER, before the answer).
            guard self.peerAnswered else {
                print("[CallService] W469 — skipped; peer has not answered yet")
                return
            }
            print("[CallService] W469 — CallKit didActivate not seen after 1.5s; self-activating audio session (fallback)")
            self.handleAudioSessionActivated()
        }
    }

    /// W450: incoming-call counterpart of `startCall(engine:contactId:)`.
    ///
    /// For incoming calls `startCall(engine:contactId:)` is never invoked
    /// because `AppState.isInCall` is already true (set by the
    /// `call_incoming` WS handler). This method fills that gap: it sets up
    /// the same AudioCapture + AudioPlayback stack and wires them to an
    /// EXISTING integration created by `AppState.ensureResponderIntegration`.
    ///
    /// Unlike `startCall`, it does NOT create a new QAudionCallIntegration —
    /// the PQC handshake has already started on the provided integration and
    /// we must not discard that state.
    ///
    /// - Parameters:
    ///   - engine: The shared QAudionEngine instance (unused directly here;
    ///     kept symmetric with `startCall` for future use).
    ///   - integration: The responder integration built during ringing.
    ///   - contactId: The caller's contactId, if already known (AppState's
    ///     `callContactId` is set by the `call_incoming` WS handler before
    ///     this method ever runs — see this method's own doc above). `nil`
    ///     is tolerated (Tier 2 activation is simply skipped) rather than
    ///     required, so a caller that genuinely doesn't have it yet never
    ///     has to fail the whole answer path over a Tier-2-only gap.
    func activateIncomingCallAudio(engine: QAudionEngine,
                                   integration: QAudionCallIntegration,
                                   contactId: String? = nil) throws {
        // W-GRPVPIO-CRASH-3 — refuse to build a 1:1 audio engine while a
        // group call owns the VP-IO unit (see `isGroupCallActive` kdoc). A
        // stray/redelivered 1:1 accept-path message during a group call
        // otherwise reaches setVoiceProcessingEnabled here and aborts the
        // whole process.
        if isGroupCallActive?() == true {
            print("[CallService] activateIncomingCallAudio SKIPPED — group call active (VP-IO owned by LiveKit)")
            return
        }
        // W-PADOVERFLOW — incoming-call counterpart of the assignment in
        // startCall(engine:contactId:). Set after the group-call bail-out so a
        // refused activation does not repoint the reference.
        audioEngineRef = engine
        // W574i — preserve the M-15 relay sealers across the defensive
        // teardown. On the CALLEE the PQC handshake completes DURING ringing,
        // so onRelaySessionReady -> installRelaySealers has ALREADY run by the
        // time the user answers and this method fires. teardownAudioStack()
        // nils relaySealer{Send,Recv,CallId} — and the handshake will NOT fire
        // again (it's done), so without this the callee runs with NIL sealers:
        // it sends UNSEALED relay frames (159 B) and cannot unseal the caller's
        // SEALED frames (187 B) -> 100% RX failure, no audio in either
        // direction (the v1.0.624->633 callee-side "connected but silent" bug).
        // The CALLER never hit this because it installs its sealers AFTER its
        // own startCall() teardown. Save the sealers, run the teardown, then
        // restore them iff they still belong to the call being answered.
        // W-SLOTLOCK — snapshot the sealers atomically before teardown nils them.
        let (_savedSealerSend, _savedSealerRecv, _savedSealerCallId, _savedSealerKeyFp):
            (PqcRtpFrameSealer?, PqcRtpFrameSealer?, String?, String?) =
            relaySlotLock.withLock {
                (relaySealerSend, relaySealerRecv, relaySealerCallId, relaySealerKeyFp)
            }
        // Defensive cleanup: stop any leftover capture from a previous call.
        teardownAudioStack()
        if let cid = _savedSealerCallId, _savedSealerSend != nil {
            let active: String = getCallId?()?.lowercased() ?? ""
            // Restore when the sealer matches the active call, or when the
            // active id is unknown (the sealer was installed by W574h only for
            // the active call, so it cannot belong to a superseded one here).
            if active.isEmpty || active == cid {
                relaySlotLock.withLock {
                    relaySealerSend = _savedSealerSend
                    relaySealerRecv = _savedSealerRecv
                    relaySealerCallId = cid
                    relaySealerKeyFp = _savedSealerKeyFp
                }
                let p: String = String(cid.prefix(8))
                let line: String = "[CallService] W574i: preserved M-15 relay sealers across answer teardown (callId=" + p + "…)"
                print(line)
            }
        }

        let pipeline = AudioProcessingPipeline()
        pipeline.voiceProcessingOverride = CallsGate.anyVoiceProcessingEnabled
        do {
            try pipeline.configureForVoIP()
        } catch {
            print("[CallService] activateIncomingCallAudio: AVAudioSession config failed: \(error.localizedDescription)")
        }
        self.audioPipeline = pipeline

        let capture = AudioCapture(audioPipeline: pipeline)
        // W-GRPVPIO-CRASH-4 — same restart-path gate as the outgoing side
        // (see startCall). Closes the observer-driven restart that bypasses
        // the activateIncomingCallAudio entry guard during a group call.
        capture.isGroupCallActive = { [weak self] in self?.isGroupCallActive?() == true }
        let playback = AudioPlayback()

        // TX path: mic → VP DSP → encrypt → WS send (same as outgoing).
        capture.onFrame = { [weak self] pcmFrame in
            guard let self else { return }
            if !NetworkConditionSimulator.shared.isPassthrough() {
                if NetworkConditionSimulator.shared.shouldDropOutbound() { return }
                Task { [weak self] in
                    await NetworkConditionSimulator.shared.delayOutbound()
                    self?.txAudioQueue.async {
                        self?.processAndSendEncryptedFrame(
                            pcmFrame: pcmFrame, integration: integration)
                    }
                }
                return
            }
            // XP-crackle — off the real-time tap thread; see txAudioQueue kdoc.
            self.txAudioQueue.async { [weak self] in
                self?.processAndSendEncryptedFrame(pcmFrame: pcmFrame, integration: integration)
            }
        }

        // W464 — INCOMING calls ARE driven by CallKit's CXProvider
        // (reportIncomingCall + CXAnswerCallAction). CallKit OWNS the
        // AVAudioSession and activates it itself, then calls
        // `provider(_:didActivate:)`. `activateIncomingCallAudio` runs
        // from the answer handler BEFORE that callback, so the session is
        // NOT yet active here: store the refs and DEFER the engine start.
        // `audioSessionActive` stays false (teardownAudioStack reset it)
        // and `handleAudioSessionActivated()` — wired to
        // `CallKitProvider.onAudioSessionActivated` — performs the real
        // start once CallKit hands the session over. Calling
        // `startAudioIOIfReady()` now is a deliberate no-op that also
        // covers the race where `didActivate` somehow already fired.
        self.audioPlayback = playback
        self.audioCapture = capture
        // Bind the integration BEFORE the latch below: `latchAudioProfileForCall`
        // reads `callIntegration` to reach the engine, and this method is a
        // second, independent entry to the latch (the first is the `.active`
        // handshake transition in `startCall`, which the incoming path does not
        // run). Moved up from below for that reason; nothing else depends on the
        // ordering, since `drainRxPreBuffer` runs later either way.
        self.callIntegration = integration
        // W-LONGAUDIO (2026-08-10) — latch before the engines start. Idempotent:
        // if the handshake path already latched, the engine refuses this one and
        // the capture profile is taken from what the engine actually holds. On a
        // build with the send kill switch off this resolves to `.standard` on
        // every path, which is byte-identical to what shipped before it existed.
        latchAudioProfileForCall()
        // W574b — WE are the answering side: this method only runs from the
        // answer handler, so the call is answered by definition. Unblock the
        // pre-answer mic gate before the (possibly deferred) engine start.
        peerAnswered = true
        startAudioIOIfReady()
        // Unified call UI — responder-side Guardian wiring (2026-07-04 gap
        // fix): the incoming path never wired `getVoiceAnalysis().onResult`,
        // so the ribbon gauges + spectrum stayed dead on EVERY incoming call
        // (the old asymmetry noted on `AppState.voiceAnalysis`). Mirror
        // startCall's block 1:1 so both call directions feed the same sinks.
        // Placed BEFORE drainRxPreBuffer so even replayed pre-bind frames
        // already reach the spectrum tap.
        if EngineConfig.production().enableVoiceAnalysis {
            integration.getVoiceAnalysis().onResult = { [weak self] result in
                self?.recordVoiceAnalysisSample(result)
                self?.onVoiceAnalysis?(result)
            }
            integration.onVoiceSpectrum = { [weak self] bands in
                self?.onVoiceSpectrum?(bands)
            }
        }
        // Feature B — mirror the outgoing-side wiring 1:1 (same reasoning as
        // the voiceAnalysis mirror immediately above this block).
        integration.onVoiceLearningStateChanged = { [weak self] state in
            self?.onVoiceLearningStateChanged?(state)
        }
        // Tier 1/Tier 2 — mirror the outgoing-side wiring 1:1, same
        // reasoning as `onVoiceLearningStateChanged` immediately above.
        integration.onOwnerContinuityStateChanged = { [weak self] state in
            self?.onOwnerContinuityStateChanged?(state)
        }
        integration.onContactVoiceLevelChanged = { [weak self] level in
            self?.onContactVoiceLevelChanged?(level)
        }
        // For incoming calls the PQC handshake started before answer, so
        // engine.initialize() has already run — apply tuner prefs now.
        integration.reconfigureAudioCodec(
            bitrateKbps: AudioCodecPrefs.bitrateKbps,
            plp:         AudioCodecPrefs.plp
        )
        // Tier 2 ("voce remota") — incoming side, same reasoning as
        // `reconfigureAudioCodec` immediately above: the handshake (and
        // therefore the session) is already up by the time this runs, so
        // activation can happen unconditionally here rather than needing
        // its own `.active`-state hook like the outgoing side does.
        if let contactId {
            integration.activateContactVoiceVerification(contactId: contactId)
        }
        drainRxPreBuffer()  // W481 — replay any frames that arrived before binding
        startDurationTimer()

        // Bug B — `didActivate` fallback. CallKit emits
        // provider(_:didActivate:) ONLY on an inactive→active AVAudioSession
        // transition. `configureForVoIP()` above best-effort `setActive(true)`,
        // and a PRIOR call can leave the session active, so on the SECOND
        // incoming call CallKit frequently SKIPS didActivate →
        // handleAudioSessionActivated() never runs → `audioSessionActive`
        // stays false → startAudioIOIfReady() no-ops → handshake completes but
        // there is TOTAL SILENCE (the exact "second call: data exchange OK but
        // no audio" symptom). If didActivate hasn't fired shortly after we set
        // up the stack, drive the start ourselves. The session is already
        // active (that's WHY CallKit skipped didActivate), so flipping the
        // flag + startAudioIOIfReady() starts capture+playback under it.
        // Idempotent: guarded on !audioSessionActive, and the engines guard on
        // their own isRunning flag, so a real didActivate that fires first wins.
        // Fallback: ensure audio engines start even if CallKit's didActivate
        // never fires (W520 suppressed call, or CallKit skipping didActivate
        // because the session was already active). The guard on
        // !audioSessionActive was WRONG — in rapid call sequences the flag
        // could be stale from a previous call, silently skipping the fallback
        // and leaving tx_enc=0 (the "iPhone non codificava" bug).
        // startAudioIOIfReady() is already idempotent (guards on isRunning),
        // so calling it unconditionally is safe — worst case it's a no-op.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self = self,
                  (self.audioCapture != nil || self.audioPlayback != nil) else { return }
            if !self.audioSessionActive {
                print("[CallService] Bug B fallback — CallKit didActivate never fired; forcing session active + starting audio")
                self.didActivateFallbackFired = true
                self.audioPipeline?.activateSession()
                self.handleAudioSessionActivated()
            } else {
                // Session is already active but engines may not have started
                // (e.g. rapid call sequence where the flag was stale). Poke
                // startAudioIOIfReady to ensure they're running.
                self.startAudioIOIfReady()
            }
        }
    }

    /// Originator-side wire driver for the iOS-as-caller PQC handshake.
    /// Closes the WIRE_SPEC §5 P0 gap that had `onCallSetupStarted` get
    /// passed an empty closure (no OFFER bytes ever reached the wire).
    ///
    /// Sequence (per OpenRouter glm-5.1 review 2026-05-06):
    ///   1. Snapshot integration to a strong local — guards against
    ///      mid-method teardown from another concurrency domain.
    ///   2. Send `call_offer` with the supplied callId — wakes the
    ///      Android peer's WsCallSignaller which buffers the
    ///      CallIncoming event per-callId for the user-accept path.
    ///   3. Drive `integration.onAndroidCallSetupStarted` with the
    ///      same callId. The engine generates dual-hybrid keypair,
    ///      stashes the privs INSIDE the method body BEFORE invoking
    ///      either send closure, then ships the JSON OFFER (literal
    ///      string, no base64 wrap) followed by the legacy QUAD
    ///      binary OFFER for backwards compat.
    ///   4. On any failure mid-stream: fire `sendCallHangupForId` so
    ///      the peer's UI doesn't sit on a phantom incoming call.
    ///
    /// CallId is supplied by the caller (AppState) so the WS-level
    /// callId, the engine stash key, the PQC bundle's `callId` field,
    /// and the eventual ACCEPT routing all converge on the same UUID.
    func beginAndroidOutgoing(
        callId: String,
        recipientId: String,
        callingApi: CallingApi,
        callerDisplay: String? = nil,
        hasVideo: Bool = false
    ) async throws {
        // Snapshot to local strong ref — prevents use-after-free if
        // another Task tears down callIntegration mid-await.
        guard let integration = self.callIntegration else {
            throw CallServiceError.noIntegration
        }

        // 1) call_offer (vestigial empty SDP — WIRE_SPEC §3 SDP-less
        //    PQC path uses opaque_message OFFER for the actual crypto).
        //    `callerDisplay` and `hasVideo` must match the parallel
        //    WebRTC offer so Android's WsCallSignaller sets up the right
        //    media pipeline regardless of which offer it processes first.
        let vestigialSdp = ""
        try await callingApi.sendCallOfferWithId(
            callId: callId,
            recipientId: recipientId,
            sdp: vestigialSdp,
            // R-4 (vkey-v1): strip `vkey-v1` when sovereign-only is on so
            // we never advertise phone-level video E2EE to the peer.
            // W-LONGAUDIO (2026-08-10): via the gated accessor, so the audio
            // profile tags are subject to the earbud filter as well.
            capabilities: CallsGate.filterAdvertisedCapabilities(CallCapabilities.localCaps()),
            callerDisplay: callerDisplay,
            hasVideo: hasVideo
        )

        // 2) PQC handshake OFFER pair (JSON + QUAD). Best-effort
        //    cleanup on failure: tell the peer to dismiss the
        //    phantom incoming call.
        do {
            try await integration.onAndroidCallSetupStarted(
                callId: callId,
                sendOpaqueRaw: { wireString in
                    try await callingApi.sendOpaqueMessageString(
                        recipientId: recipientId, payload: wireString)
                },
                sendOpaqueBinary: { data in
                    try await callingApi.sendOpaqueMessage(
                        recipientId: recipientId, data: data)
                }
            )
        } catch is CancellationError {
            // User cancelled the call after call_offer landed but
            // before the OFFER bundles went out. Best-effort hangup
            // and re-raise so AppState can transition the UI to .idle.
            try? await callingApi.sendCallHangupForId(
                callId: callId, recipientId: recipientId)
            throw CancellationError()
        } catch {
            print("[CallService] Android originator OFFER pipeline failed for callId=\(callId.prefix(8))…: \(error)")
            try? await callingApi.sendCallHangupForId(
                callId: callId, recipientId: recipientId)
            throw error
        }
    }

    enum CallServiceError: Error {
        case noIntegration
    }

    /// W574e — strip the M-15 relay seal from an inbound frame, mirroring
    /// Android `BcryptoWsFrameRelayTransport.parseRawFrame`.
    ///
    /// Returns the inner `0x01|…` WireRelayFrameCodec frame, or nil if the
    /// frame must be DROPPED. Once the recv sealer is installed (key
    /// established) ALL frames are expected sealed — an open failure is a
    /// replay/forgery/garbage frame and is dropped (matching Android, which
    /// drops on SecurityException). Before install (sealer nil) the frame
    /// passes through unchanged — the pre-handshake window where neither
    /// side seals yet.
    private func unsealRelayFrame(_ data: Data) -> Data? {
        // W-SLOTLOCK — copy the recv sealer under the lock (installRelaySealers /
        // teardown write it from other threads); open() runs unlocked.
        guard let sealer = relaySlotLock.withLock({ relaySealerRecv }) else { return data }
        do {
            return try sealer.open(data)
        } catch {
            return nil
        }
    }

    func endCall() {
        onDeepfakeAlert?(false)
        stopDurationTimer()
        callStartedAt = nil
        callDurationSeconds = 0
        isMuted = false
        isOnHold = false

        // W65+W66: stop capture/playback + rilascia AVAudioSession.
        // teardownAudioStack also handles callIntegration cleanup.
        teardownAudioStack()
    }

    /// W-VOICEZERO — accumulate the per-call Guardian-analyzer health counters
    /// summarised in `call.audio.diag`. Two adds, called at most ~10 Hz
    /// (`VoiceAnalysisEngine` analyses every 5th 20 ms frame), on the same
    /// main-queue RX branch as the rx level accumulators.
    ///
    /// PRIVACY — counts ONLY. The measured values (f0, stress) are deliberately
    /// NOT accumulated: they would end up in plaintext server telemetry, and a
    /// mean fundamental frequency is a voice biometric while stress is an
    /// affective inference. "Was the analyzer fed, and did it hear voicing"
    /// is the whole diagnostic question, and two counters answer it.
    private func recordVoiceAnalysisSample(_ result: VoiceAnalysisResult) {
        vaResultCount &+= 1
        guard result.pitch.voiced else { return }
        vaVoicedCount &+= 1
    }

    /// W481 — drain frames buffered before callIntegration was bound.
    /// Call immediately after `self.callIntegration = integration` on the
    /// main thread. Processes each frame through processIncomingAudio so
    /// the RX ratchet advances in step with the peer's TX ratchet.
    private func drainRxPreBuffer() {
        guard !rxPreBuffer.isEmpty, let integration = callIntegration else { return }
        let frames = rxPreBuffer
        rxPreBuffer.removeAll()
        let n: String = frames.count.description
        print("[CallService] RX W481: draining " + n + " pre-buffered frame(s)")
        for frame in frames {
            // W574e — these buffered frames arrived pre-bind (pre-handshake),
            // so they are normally unsealed pass-through; unsealRelayFrame
            // returns them unchanged when the sealer isn't installed yet, or
            // strips the seal / drops if it is.
            guard let inner = unsealRelayFrame(frame) else {
                rxDecryptErrorCount &+= 1
                continue
            }
            // W-NETVIS — same layer as the live RX path above. These bytes did
            // arrive on the wire; they were merely held until `callIntegration`
            // bound, so they belong in the rx total. Bounded by
            // `rxPreBufferCap`, so the drain can inflate at most one sample at
            // the very start of the call.
            wireRxBytes &+= Int64(inner.count)
            do {
                let pcm = try integration.processIncomingAudio(serializedFrame: inner)
                framesDecryptedRx &+= 1
                audioCapture?.playFrame(pcm)  // single-engine: playback lives on the capture engine
            } catch {
                rxDecryptErrorCount &+= 1
            }
        }
    }

    /// W66+W67: ingresso per il RX path. Chiamato dal handler "audio_frame"
    /// del `BCryptoWebSocketClient` quando il server inoltra un frame
    /// del peer. Esegue decrypt + playback + UI updates.
    ///
    /// Thread safety: il WS handler è invocato su una background queue
    /// di URLSession. AVAudioPCMBuffer scheduleBuffer è thread-safe per
    /// Apple docs, ma per safety con i `@Published` AppState e i counter
    /// non-atomic, dispatchiamo l'intera elaborazione su main.
    /// `callId` is the `call_id` field from the `audio_frame` WS envelope.
    /// When present and mismatched against the active call, the frame is
    /// dropped immediately — this prevents x250+ CryptoKitError 3 storms
    /// caused by stale relay delivery from a previous/overlapping session.
    /// W-DCAUDIO — inbound sealed audio frame received over the WebRTC
    /// DataChannel. The bytes are the raw WireRelayFrameCodec envelope (identical
    /// to what the WS "audio_frame" handler delivers after base64 decode), so we
    /// route them through the same decrypt + playback path. The DataChannel is
    /// per-call (one PC per call), so the active call_id applies. Wired by AppState
    /// to `QAudionWebRtcCallController.onAudioDataChannelFrame`.
    public func handleIncomingDataChannelAudio(_ data: Data) {
        handleIncomingEncryptedFrame(data, callId: getCallId?(), rxTransport: .dataChannel)
    }

    /// W-DCMUX (2026-08-11) — call-id prefix for a log line, or `"none"`.
    ///
    /// Eight characters, lowercased: byte-identical to the `qa.call.short8`
    /// join key that `ship-ios-logs.py` extracts (`call_short8`, which requires
    /// >= 8 characters and yields nothing shorter) and that `correlate-call.py`
    /// matches on. A shorter prefix would produce a line the correlator cannot
    /// join, which is worse than no line at all because it looks like evidence.
    ///
    /// The shipper redacts the printed value itself to `[REDACTED:callid]` —
    /// that is expected and correct. The join happens on the extracted
    /// attribute, not on the visible text; the id has to be IN the line for the
    /// attribute to exist at all.
    static func short8(_ callId: String?) -> String {
        guard let raw = callId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              raw.count >= 8
        else { return "none" }
        return String(raw.prefix(8))
    }

    /// W-DCMUX (2026-08-11) — the sealed-audio DataChannel changed state.
    ///
    /// Called by AppState from `QAudionWebRtcCallController
    /// .onAudioDataChannelStateChange`, which fires on the WebRTC signalling
    /// thread at creation (caller), receipt (callee) and every subsequent
    /// transition. Logging lives here, not in AppState, because this is where
    /// the call id and the two frame counters already are.
    ///
    /// - Parameters:
    ///   - raw: the `RTCDataChannelState` raw value (0 connecting, 1 open,
    ///     2 closing, 3 closed).
    ///   - role: `caller` or `callee` — the shipper lifts it into the `qa.role`
    ///     attribute, and on the caller side the first event is the CREATION of
    ///     the channel while on the callee side it is its RECEIPT.
    func noteAudioDataChannelState(raw: Int, role: String) {
        let line: String = "dcmux st=" + raw.description
              + " role=" + role
              + " callId=" + Self.short8(getCallId?())
              + " tx=" + txFramesDc.description
              + " rx=" + rxFramesDc.description
        print("[CallService] " + line)
        // This whole diagnostic family used to be print()-only. print() never
        // leaves the device — RTLog is the only bridge — so a "audio non
        // buono" report on an Android<->iOS call had no way to show whether
        // this side ever opened the DataChannel, whether it fell back to the
        // WS relay and why, or whether either leg carried zero frames.
        // Verified redactor-safe: short8 caller ids, single-word `why=`
        // tokens, decimal counters — no run of 12+ base64-alphabet
        // characters for RE_RESIDUAL_B64 to catch.
        RTLog.info("call", line)
    }

    public func handleIncomingEncryptedFrame(_ serializedFrame: Data,
                                             callId: String? = nil,
                                             rxTransport: AudioRxTransport = .wsRelay) {
        // W69: dev network simulator hook RX. Stessa semantica del TX —
        // simula packet loss inbound. Branch-predicted off-path in Off.
        if !NetworkConditionSimulator.shared.isPassthrough() {
            if NetworkConditionSimulator.shared.shouldDropInbound() {
                return  // frame inbound droppato
            }
        }
        // Dispatch to main per coerenza con TX path (Task { @MainActor })
        // e per evitare race su framesDecryptedRx counter.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Stale-session filter: drop frames whose call_id doesn't match
            // the active call. Without this, the relay delivers all buffered
            // frames from a previous session to the new session's decrypt
            // path, causing x250+ AEAD authentication failures (CryptoKitError 3).
            // Only filter when both sides are known — if either is nil (old
            // client with no call_id, or call not yet fully set up), allow through.
            if let incomingId = callId,
               let activeId = self.getCallId?(),
               incomingId.caseInsensitiveCompare(activeId) != .orderedSame {
                self.rxStaleDropCount &+= 1
                if !self.loggedFirstStaleDrop {
                    self.loggedFirstStaleDrop = true
                    let inc: String = String(incomingId.prefix(8))
                    let act: String = String(activeId.prefix(8))
                    let line: String = "[CallService] RX stale drop: frame callId=" + inc + "… != active=" + act + "… (suppressing further per-frame logs)"
                    print(line)
                }
                return
            }
            // W466 — count EVERY audio_frame off the WS, before decrypt,
            // so the telemetry distinguishes "peer never sent" from
            // "received but decrypt failed".
            self.framesReceivedRx &+= 1
            // W-DCMUX — split the SAME count by arrival transport. Counted here,
            // after the stale-call filter and before decrypt, so it means
            // exactly what `framesReceivedRx` means and the two can be compared
            // directly. Both branches then fall through to one decrypt path —
            // that convergence is the design and stays untouched.
            switch rxTransport {
            case .dataChannel:
                self.rxFramesDc &+= 1
                if !self.loggedFirstRxOnDc {
                    self.loggedFirstRxOnDc = true
                    let line: String = "dcmux first=rxdc callId="
                          + Self.short8(self.getCallId?())
                          + " n=" + self.rxFramesDc.description
                    print("[CallService] " + line)
                    RTLog.info("call", line)
                }
            case .wsRelay:
                self.rxFramesWs &+= 1
            }
            if !self.loggedFirstRxReceive {
                self.loggedFirstRxReceive = true
                let bytes: String = serializedFrame.count.description
                let line: String = "[CallService] RX: first audio_frame received from peer (" + bytes + " bytes)"
                print(line)
            }
            guard let integration = self.callIntegration else {
                // W481 — buffer instead of drop. Dropping silently advances
                // the peer's TX ratchet without advancing our RX ratchet,
                // causing a permanent off-by-one (CryptoKitError on EVERY
                // subsequent frame). Buffer up to rxPreBufferCap frames;
                // drainRxPreBuffer() replays them once callIntegration binds.
                if self.rxPreBuffer.count < Self.rxPreBufferCap {
                    self.rxPreBuffer.append(serializedFrame)
                }
                if !self.loggedRxNoIntegration {
                    self.loggedRxNoIntegration = true
                    print("[CallService] RX W481: callIntegration nil — buffering frame (will drain on bind)")
                }
                return
            }
            // W574e — strip the M-15 relay seal before the AdaptivePadding
            // decode. Android wraps every relay frame in this seal; once our
            // recv sealer is installed an open failure means replay/forgery →
            // drop (counts as a decrypt error). Pre-install → pass through.
            guard let inner = self.unsealRelayFrame(serializedFrame) else {
                self.rxDecryptErrorCount &+= 1
                if self.rxDecryptErrorCount == 1 || self.rxDecryptErrorCount % 250 == 0 {
                    print("[CallService] RX: M-15 unseal failed/replay (x\(self.rxDecryptErrorCount)) — dropped")
                }
                return
            }
            // W-NETVIS — the FLUSSO rx counter, at Android's exact layer: the
            // POST-UNSEAL length, counted the moment the open succeeds and
            // before the Opus decode, mirroring `rxBytes.addAndGet(bytes.size)`
            // after `openInbound(...)` on both of Android's wire forms
            // (BcryptoWsFrameRelayTransport.kt:195-197 and :223-225).
            // `unsealRelayFrame` is the same operation as `openInbound`,
            // pass-through until the recv sealer is installed.
            self.wireRxBytes &+= Int64(inner.count)
            do {
                let pcm = try integration.processIncomingAudio(serializedFrame: inner)
                self.framesDecryptedRx &+= 1
                if !self.loggedFirstRxDecrypt {
                    self.loggedFirstRxDecrypt = true
                    print("[CallService] RX: first frame DECRYPTED ok — AEAD+Opus decode live")
                }
                if let cap = self.audioCapture {
                    // single-engine: playback runs on the capture engine's player node
                    cap.playFrame(pcm)
                } else if !self.loggedRxNoPlayback {
                    self.loggedRxNoPlayback = true
                    print("[CallService] RX: decrypted frame but audioCapture is nil — not audible")
                }
                if self.framesDecryptedRx % 250 == 0 {
                    // W-IOSAUDIOSTARVE (2026-08-02): was
                    // "<n> frames decrypted+played" — prose, which
                    // ship-ios-logs.py's positive-allow-list redactor drops
                    // WHOLESALE (verified against its own redact_body: the old
                    // wording returns ship=False, empty body). That is why the
                    // shipped corpus contained TX heartbeats and not a single
                    // RX one, and nobody noticed.
                    //
                    // ⚠ THE 12-CHARACTER RULE — read before adding any field
                    // here or anywhere else that must reach Loki. The shipper's
                    // RE_BASE64_BLOB is /[A-Za-z0-9+/=_\-]{12,}/ and it runs on
                    // the WHOLE line: ANY unbroken run of 12+ alphanumeric-ish
                    // characters is replaced by [REDACTED:blob]. A `key=value`
                    // token is one such run, so the token — key plus '=' plus
                    // digits — must stay UNDER 12 characters or it silently
                    // vanishes in transit while looking perfectly fine on the
                    // device. `frames=180000` is 13 and dies; `rx=180000` is 9
                    // and survives. That is the entire reason for the terse key
                    // names below, and it is why every line here was verified
                    // against the real redact_body with realistic values before
                    // being committed.
                    let n: String = self.framesDecryptedRx.description
                    let line: String = "[CallService] RX heartbeat: rx=" + n
                    print(line)
                    // W-IOSAUDIOSTARVE (2026-08-02) — playout health, every 250
                    // frames (~5 s), alongside the frame count above.
                    //
                    // These counters were incremented and read by NOTHING, so
                    // the iOS receiver was the one leg of a call whose audio
                    // quality could not be measured: a "seghettato" report was
                    // impossible to confirm or contradict from telemetry, and
                    // the fix for it therefore impossible to verify.
                    //
                    // Deliberately emitted as flat key=value pairs of integers:
                    // ship-ios-logs.py's redactor is a POSITIVE allow-list on
                    // structured shape (see its HARD PRIVACY INVARIANT header),
                    // so prose would be dropped to [REDACTED:blob] and the
                    // numbers would never reach Loki — which is exactly how
                    // this blind spot survived.
                    //
                    // Reading the result: underruns+concealed high with depth
                    // normal = the render side could not keep up (starved
                    // consumer). hardDrops+overruns high with depth near
                    // capacity = frames arrived clumped (bursty wire). pushed
                    // is the denominator; without it none of the rest is a rate.
                    //
                    // Keys are two characters BECAUSE OF THE 12-CHARACTER RULE
                    // above, not for brevity: `underruns=489` is 13 characters
                    // and ships as [REDACTED:blob], `un=489` is 6 and arrives.
                    // At two characters the token survives up to a six-digit
                    // value, i.e. ~1 hour of continuous call at 50 fps — well
                    // past any real session. Verified against the shipper's own
                    // redact_body at 1250, 180000 and pathological values.
                    //   pu = pushed      un = underruns   ov = overruns
                    //   hd = hardDrops   cc = concealed   dp = depth
                    // `silenceDrops` is deliberately not emitted: tiers 1/2
                    // discard frames that were inaudible anyway, so it is the
                    // least diagnostic of the seven. It stays on `PlayoutStats`
                    // for in-process callers. A seventh field needs its own
                    // line — appending here would push the line past the
                    // structured-shape budget.
                    if let cap = self.audioCapture {
                        let s = cap.playoutStats
                        let stats: String = "[CallService] RX playout:"
                            + " pu=" + s.pushed.description
                            + " un=" + s.underruns.description
                            + " ov=" + s.overruns.description
                            + " hd=" + s.hardDrops.description
                            + " cc=" + s.concealed.description
                            + " dp=" + s.depth.description
                        print(stats)
                    }
                }
                let rxSamples = self.updateWaveformSamples(from: pcm)
                self.onRxWaveformUpdate?(rxSamples)
                // AUDIO-DIAG (2026-07-12) — accumulate decoded RX level from the
                // samples already in hand (no extra decode). rxSamples are the
                // Int16 PCM normalized to [-1,1]; peak/rms roll up into
                // call.audio.diag as rx_peak_pct/rx_rms_pct (mirror of Android).
                for s in rxSamples {
                    let a = abs(s)
                    if a > self.rxLevelPeak { self.rxLevelPeak = a }
                    self.rxLevelSumSq += Double(s) * Double(s)
                }
                self.rxLevelSampleCount &+= Int64(rxSamples.count)
            } catch {
                self.rxDecryptErrorCount &+= 1
                if self.rxDecryptErrorCount == 1 || self.rxDecryptErrorCount % 250 == 0 {
                    let desc: String = error.localizedDescription
                    let cnt: String = self.rxDecryptErrorCount.description
                    let line: String = "[CallService] RX decrypt FAILED (x" + cnt + "): " + desc
                    print(line)
                }
            }
        }
    }

    /// W66: stop ordinato di capture + playback + session deactivation.
    /// Chiamato sia in `endCall()` che come defensive cleanup all'inizio
    /// di `startCall()` (re-entry guard).
    /// Also owns callIntegration lifecycle: fires onCallEnded and nils it
    /// so stale frames arriving after teardown can't be decrypted with
    /// an old session key (they hit the W481 pre-buffer instead).
    private func teardownAudioStack() {
        // Diagnostic: emit the REAL audio frame counters BEFORE they reset.
        // call.media.summary's `suspect_silent` is a timer-only heuristic and
        // says nothing about audio — these counters are the ground truth that
        // distinguishes the failure modes the user reported ("connected but no
        // audio / no SAS"):
        //   rx_recv>0 & rx_dec≈rx_recv & engines_started → audio DECRYPTS; a
        //       silent call then means PLAYBACK/route (Bug B / speaker).
        //   rx_recv>0 & rx_dec≈0 & rx_dec_err high       → KEY MISMATCH (the
        //       two sides derived different session keys → SAS won't match).
        //   rx_recv≈0                                     → audio never arrived
        //       (peer not capturing / transport / wrong call_id).
        //   engines_started=false                         → engines never ran.
        // Only emit when the call actually had an audio stack (skip the
        // defensive pre-call cleanups that would log all-zeros).
        if audioEnginesStarted || framesReceivedRx > 0 || framesEncryptedTx > 0 {
            let _callId = getCallId?()
            let _attrs: [String: Any] = [
                "tx_enc":          framesEncryptedTx,
                "rx_recv":         framesReceivedRx,
                "rx_dec":          framesDecryptedRx,
                "rx_dec_err":      rxDecryptErrorCount,
                "tx_enc_err":      txEncryptErrorCount,
                // W-TXGATE — expected mic frames dropped before the session key
                // existed (~0.8 s handshake window); NOT a fault. Kept separate
                // so tx_enc_err stays a clean real-failure signal.
                "tx_pre_hs":       txPreHandshakeDropped,
                // W-PADOVERFLOW — TX frames whose Opus output did not fit the
                // audio block and were therefore sent as a silent frame of the
                // same size. MUST be 0: anything else means the operating
                // point (bitrate x frame duration) was chosen above what the
                // block holds, and the call lost audio without any other
                // symptom. Numeric so the server-side redactor keeps it
                // readable rather than blobbing it.
                "pad_overflow":    audioEngineRef?.getStats().padOverflowFrames ?? -1,
                "engines_started": audioEnginesStarted,
                "fallback_fired":  didActivateFallbackFired,
                "session_active":  audioSessionActive
            ]
            Task { @MainActor in
                TelemetryService.shared.emit(kind: "call.audio.counts", callId: _callId, attrs: _attrs)
            }
            // Post-call Opus tuning — must run BEFORE counters reset below.
            // W574c: callId attached so the tune decision (or skip reason)
            // shows up on the server's per-call telemetry timeline.
            AudioAutoTuner.shared.tunePostCall(
                framesReceived:  framesReceivedRx,
                framesDecrypted: framesDecryptedRx,
                rxDecryptErrors: rxDecryptErrorCount,
                callId:          getCallId?()
            )
            // AUDIO-DIAG (2026-07-10) — real per-call evidence for two open
            // reports, replacing guesswork:
            //   * "scoppiettii" on EARPIECE: defaults leave VP-IO fully OFF
            //     (aec/ns/agc all false), so the raw mic hits Opus with no
            //     AEC/NS/AGC and no limiter — unlike Android, which ships HW
            //     AEC+NS on. `clip_samples > 0` with `peak_pct ~100` and
            //     `vpio_ever_active=false` confirms hard clipping.
            //   * AirPods "voce storpiata": `bt_route_ever=true` plus a
            //     `granted_sr` far below `preferred_sr` (48k) confirms the
            //     A2DP→HFP narrow-band drop rather than a double-AEC theory.
            // MUST read before audioCapture/audioPipeline are nil'd + stopped
            // below. peak_pct is peak/32767 rounded to 1dp.
            if let capture = audioCapture, let pipeline = audioPipeline {
                let level = capture.consumeLevelStats()
                let diag = pipeline.consumeAudioDiagStats()
                let peakPct = Double(level.peak) / Double(Int16.max) * 100
                // TX mic RMS (% of full scale) alongside the existing TX peak.
                let txRmsPct = Double(level.rms) / Double(Int16.max) * 100
                // Decoded RX level (% of full scale) — peak/rms mirror of Android.
                let rxPeakPct = Double(rxLevelPeak) * 100
                let rxRmsPct = rxLevelSampleCount > 0
                    ? (rxLevelSumSq / Double(rxLevelSampleCount)).squareRoot() * 100
                    : 0
                var diagAttrs: [String: Any] = [
                    "peak_pct":           (peakPct * 10).rounded() / 10,
                    "rms_pct":            (txRmsPct * 10).rounded() / 10,
                    // W-MICAGC — max software make-up gain the mic AGC reached this
                    // call (1.0 = never engaged; higher = raw mic was quiet and got
                    // lifted). Hitting the ceiling ⇒ RMS target unreachable.
                    "agc_gain":           (Double(level.agcGain) * 100).rounded() / 100,
                    // W-AGCCEIL — soft-knee limiter duty cycle (% of tx samples the
                    // limiter actually shaped). Expected ~0: the make-up AGC is now
                    // hard-capped at 90% FS, below the 95% knee, so the limiter should
                    // only catch the ~1 ms attack residual and transients VP-IO already
                    // delivered at full scale. A persistently non-trivial value means
                    // the AGC is overdriving into the limiter again — the W-AGCCEIL
                    // regression, which produced the "metallic" far-end timbre and
                    // which peak_pct/clip_samples alone could not distinguish.
                    "limiter_pct":        (level.limiterPct * 1000).rounded() / 1000,
                    "rx_peak_pct":        (rxPeakPct * 10).rounded() / 10,
                    "rx_rms_pct":         (rxRmsPct * 10).rounded() / 10,
                    "clip_samples":       level.clipSamples,
                    "vpio_ever_active":   diag.vpioEverActive,
                    "agc_ever_active":    diag.agcEverActive,
                    "speaker_route_ever": diag.speakerRouteEver,
                    "bt_route_ever":      diag.bluetoothRouteEver,
                    "input_route":        diag.inputRoute,
                    "output_route":       diag.outputRoute,
                    "granted_sr":         diag.grantedSampleRate,
                    "preferred_sr":       diag.preferredSampleRate,
                    // W-CANONICAL — proof instruments for the VP-IO migration:
                    // tap_sr/tap_ch = real post-enable tap format (≠48000 was
                    // the W556 warp class, now converted); engine_restarts =
                    // mid-call route bounces; vpio_bypassed_ever = the starve
                    // watchdog forced the raw-mic fallback this call.
                    "tap_sr":             diag.tapSampleRate,
                    "tap_ch":             diag.tapChannels,
                    "engine_restarts":    diag.engineRestarts,
                    "vpio_bypassed_ever": diag.vpioBypassedEver,
                    // W-VPIORETRY (2026-07-21) — vpio_bypassed_ever is a BOOL and
                    // therefore could not distinguish "one transient starve during a
                    // car-kit route change, recovered" from "the entire call ran with
                    // no AEC / no NS / no Apple AGC". On call 1de9935f it was the
                    // latter, because forceDisableVoiceProcessing used to be a one-way
                    // latch cleared only at call end. These two counters make the
                    // difference readable: bypass_count > retry_count + 1 means we
                    // never got VP-IO back.
                    "vpio_bypass_count":  diag.vpioBypassCount,
                    "vpio_retry_count":   diag.vpioRetryCount,
                    // W-AUDIODEATH (2026-07-24, call db4e5b20) — the three fields that
                    // would have named the "iOS went silent" fault instead of leaving
                    // it to inference. On that call rx_recv/rx_dec were a perfect
                    // 3594/3594 (everything arrived AND decrypted) with nothing
                    // audible, i.e. the loss was strictly downstream of decryption —
                    // exactly what these measure. engine_restart_fail > 0 means a
                    // torn-down engine never came back (audio dead from that moment);
                    // playout_dropped > 0 with healthy rx_dec is the direct signature
                    // of decoded frames being binned at the playout guard;
                    // engine_running_at_end = false confirms it lasted to hangup.
                    "engine_restart_fail":  diag.engineRestartFailures,
                    "playout_dropped":      diag.playoutDropped,
                    "engine_running_at_end": diag.engineRunningAtEnd,
                    // W-IOSPLAYOUT (2026-07-25) — the player node's OWN queue, which no
                    // counter observed. `playout_dropped` above covers frames that never
                    // reached the player; these cover what happened to the ones that did.
                    // A depth that grows is standing latency heard as delay, a depth that
                    // empties is the gap heard as a dropout, and until now the two were
                    // indistinguishable from each other and from a network problem.
                    //
                    // `playout_sched_fail` is the third distinct way a decoded frame dies:
                    // the engine was alive and willing, and our own scheduling code threw
                    // the frame away (allocation failure, or an output bus format we do not
                    // fill). Both of those paths returned in silence before this.
                    //
                    // `playout_ledger_anomalies` is the measurement declaring its own
                    // reliability: a route flip can fire pending completion handlers in a
                    // burst, and rather than clamp that away, a non-zero count here means
                    // read `playout_inflight_max` as a lower bound.
                    "playout_writes":         diag.playoutWrites,
                    "playout_inflight_max":   diag.playoutInFlightMax,
                    "playout_sched_fail":     diag.playoutSchedFail,
                    "playout_ledger_anomalies": diag.playoutLedgerAnomalies,
                    // W-AGCNOISE (2026-07-21) — the make-up loop's actual behaviour,
                    // which agc_gain alone cannot show. agc_gain is a call-MAX and has
                    // the same blind spot as peak_pct: 5.89 reads the same whether the
                    // loop touched the ceiling once or lived on it. agc_gain_mean is
                    // the time-average APPLIED gain; agc_hold_pct is the share of
                    // buffers the SNR gate classified as background (high = the loop
                    // correctly refused to chase noise); agc_noise_floor_pct is the
                    // tracked background level that now sets the ceiling — if the
                    // noise-floor model is wrong, that field is what says so.
                    //
                    // PRIVACY — levels and counters only, same class as the peak/rms
                    // fields already here. Nothing spectral, no fundamental frequency,
                    // no affective inference: call.audio.diag is stored UNSEALED on
                    // the server (see the va_* note below).
                    "agc_gain_mean":      (level.agcGainMean * 100).rounded() / 100,
                    "agc_noise_floor_pct": (level.agcNoiseFloorPct * 100).rounded() / 100,
                    "agc_hold_pct":       (level.agcHoldPct * 10).rounded() / 10,
                    // W-TXBURST (2026-07-21) — most 20 ms frames emitted from a SINGLE
                    // tap callback. 1–2 is a steady 50 fps stream. A large value means
                    // iOS is handing the peer bursts rather than a stream, which is the
                    // open question behind the Android leg discarding 3512 of 5559
                    // received frames on call 1de9935f (jitter-buffer overrun / emergency
                    // drain — both are over-full paths). Counter only.
                    "tx_burst_max":       level.txBurstMax,
                    // W-VOICEZERO (2026-07-21) — Guardian-analyzer health, the
                    // instrument this subsystem never had. va_results counts
                    // analyzer callbacks this call (0 ⇒ nothing is feeding the
                    // analyzer at all); va_voiced_pct is the share that detected
                    // voicing. va_results > 0 with va_voiced_pct == 0 IS the
                    // "gauges read zero" bug — that was the state of every call
                    // from the feature's first commit until this fix.
                    //
                    // PRIVACY — deliberately ONLY these two counters. A first cut
                    // of this fix also emitted `va_f0_avg` (mean fundamental
                    // frequency) and `va_stress_avg` (mean affective score).
                    // Both were removed before shipping: `call.audio.diag` is
                    // stored UNSEALED in plaintext on the VPS (verified by
                    // reading /opt/bcrypto/data/telemetry/*.jsonl directly), mean
                    // F0 is a speaker/gender-correlated voice biometric and
                    // stress is an inference about the user's emotional state.
                    // Shipping either to the server contradicts this project's
                    // stated posture — it does not even persist a phone number in
                    // clear — and neither adds diagnostic power the two counters
                    // above lack: "is the analyzer being fed, and does it detect
                    // voicing" fully answers the zero-gauges question. If a future
                    // need for the values themselves appears, they must ride the
                    // E2EE-sealed report channel, not plaintext telemetry.
                    "va_results":         vaResultCount,
                    "va_voiced_pct":      vaResultCount > 0
                        ? (Double(vaVoicedCount) / Double(vaResultCount) * 1000).rounded() / 10
                        : 0,
                    // W-IOSECHO (2026-07-22) — iOS port of Android's
                    // W-SPKAEC/W-SPKECHO echo-cancellation-EFFECTIVENESS
                    // fields (commits fb6b9b7/caf6fcd/45d3618). Until now
                    // iOS could only say VP-IO was ever nominally on/bypassed
                    // (`vpio_ever_active`/`vpio_bypassed_ever` above) — never
                    // whether it actually cancelled anything. These measure
                    // near-end mic RMS while the far end was recently
                    // audible vs while it was not; see `AudioCapture.
                    // EchoBucketTotals` for the full method and its honest
                    // limitations (a level-based proxy for "AEC under load",
                    // not a hardware ERLE readout — no current iOS SDK
                    // exposes one).
                    //
                    // Field-by-field mapping vs Android's `CallAudioBridge`:
                    //  * echo_active_frames/rms_pct, echo_idle_frames/rms_pct,
                    //    route_changes, speaker_ms — SAME name, genuinely
                    //    equivalent measurement, so tune-report.py's existing
                    //    "aec on/ref-bound" / "route chg/speaker" / "echo
                    //    far/near rms" card rows (which already key off these
                    //    exact strings under `call.audio.diag`, platform-
                    //    agnostic) now populate for iOS legs too.
                    //  * aec_ever_active — reused (not duplicated logic):
                    //    Android's field exists BECAUSE its AudioEffect API
                    //    lets a canceler be requested-but-fail-to-attach
                    //    (hence a separate `cap.isAecActive()` check beyond
                    //    "we asked for VOICE_COMMUNICATION source"). Apple's
                    //    `setVoiceProcessingEnabled` has no such split — it
                    //    is a synchronous pass/fail, and success bundles
                    //    AEC+NS+AGC atomically. `vpio_ever_active` (above)
                    //    THEREFORE ALREADY IS "the canceler really attached",
                    //    not merely "requested" — so it is reported again
                    //    here under Android's name rather than duplicated
                    //    computation, purely so the shared tune-report.py
                    //    card renders instead of reading "X" on every iOS leg.
                    //  * aec_session_bound — DELIBERATELY OMITTED. Android's
                    //    field exists because binding the output AudioTrack
                    //    to the mic's echo-reference session is a SEPARATE,
                    //    independently-fallible async step. On iOS the
                    //    reference is structural: the SINGLE-ENGINE FIX
                    //    (see AudioCapture.start()) attaches the player node
                    //    to the SAME AVAudioEngine as the capture tap BEFORE
                    //    VP-IO is even enabled, so there is no separate bind
                    //    step that can fail independently of capture itself
                    //    starting. Emitting an always-true tautology under
                    //    Android's name would read as a real measurement
                    //    when it is not one — omitted rather than faked.
                    //  * echo_gain_min — DELIBERATELY OMITTED. This is
                    //    Android's OWN software residual-echo-suppressor gain
                    //    floor (`SpeakerEchoSuppressor`); iOS runs no
                    //    equivalent software suppression stage (Apple's VP-IO
                    //    is the only canceler in the chain, opaque past
                    //    `setVoiceProcessingEnabled`), so there is nothing
                    //    honest to report under this name.
                    "echo_active_frames":  level.echoActiveFrames,
                    "echo_active_rms_pct": (level.echoActiveRmsPct * 10).rounded() / 10,
                    "echo_idle_frames":    level.echoIdleFrames,
                    "echo_idle_rms_pct":   (level.echoIdleRmsPct * 10).rounded() / 10,
                    "route_changes":       diag.routeChanges,
                    "speaker_ms":          diag.speakerMs,
                    "aec_ever_active":     diag.vpioEverActive
                ]
                // W-KCMAC/W-ASSURANCE (ship step 5, telemetry-only) — riding the
                // EXISTING call.audio.diag emission rather than a new channel
                // (per the design). `nil` when this call never fired
                // `onKcMacReady` at all (e.g. torn down before the handshake
                // completed) — the four fields are simply omitted, exactly like
                // the "skipped" AudioAutoTuner case above omits its fields.
                if let kc = getKeyConfirmationTelemetry?() {
                    diagAttrs["psk_mix_n"] = kc.pskMixN
                    diagAttrs["kc_mac_result"] = kc.kcMacResult
                    diagAttrs["assurance_state"] = kc.assuranceState
                    diagAttrs["expected_but_missing"] = kc.expectedButMissing
                }
                Task { @MainActor in
                    TelemetryService.shared.emit(kind: "call.audio.diag", callId: _callId, attrs: diagAttrs)
                }
            }
        }
        audioEnginesStarted = false
        didActivateFallbackFired = false
        callIntegration?.onCallEnded()
        callIntegration = nil
        audioCapture?.stop()
        audioCapture = nil
        audioPlayback?.stop()
        audioPlayback = nil
        audioPipeline?.deactivateSession()
        audioPipeline = nil
        framesEncryptedTx = 0
        framesDecryptedRx = 0
        // W-NETVIS — reset the wire-byte counters AND the derived readouts, so
        // a second call never opens showing the previous call's rate. Android
        // has exactly that bug: nothing clears `txKbps`/`rxKbps` on Ended
        // (CallViewModel.kt), so a surviving ViewModel instance carries the old
        // number into the next call until a fresh delta lands.
        wireTxBytes = 0
        wireRxBytes = 0
        lastThroughputSample = nil
        wireTxKbps = nil
        wireRxKbps = nil
        mediaRttMs = nil
        // W466 — reset the per-call diagnostic counters/markers so the
        // next call's telemetry starts from a clean slate.
        framesReceivedRx = 0
        txEncryptErrorCount = 0
        rxDecryptErrorCount = 0
        txSessionReady = false            // W-TXGATE — re-arm for the next call
        txPreHandshakeDropped = 0
        rxLevelPeak = 0        // AUDIO-DIAG (2026-07-12) — reset RX level accumulators
        rxLevelSumSq = 0
        rxLevelSampleCount = 0
        vaResultCount = 0      // W-VOICEZERO — reset analyzer health counters
        vaVoicedCount = 0
        loggedFirstTxCapture = false
        loggedFirstTxEncrypt = false
        loggedTxNoTransport = false
        loggedFirstRxReceive = false
        loggedRxNoIntegration = false
        loggedFirstRxDecrypt = false
        loggedRxNoPlayback = false
        loggedFirstStaleDrop = false
        rxStaleDropCount = 0
        // W-DCMUX — per-call, like every counter above. A second call must not
        // open showing the previous call's transport split: "rx dc=812" carried
        // over from a call that DID use the DataChannel would be read as proof
        // about a call that never touched it.
        txFramesDc = 0
        txFramesWs = 0
        rxFramesDc = 0
        rxFramesWs = 0
        txFallbackCount = 0
        loggedFirstTxOnDc = false
        loggedFirstRxOnDc = false
        rxPreBuffer.removeAll()  // W481
        // W464 — drop the session-active flag so the NEXT call starts
        // from a clean slate and waits for its own CallKit `didActivate`.
        audioSessionActive = false
        peerAnswered = false  // W574b — re-arm the pre-answer mic gate for the next call
        // W-SLOTLOCK — nil the cross-thread reference slots under the lock so an
        // in-flight tap (TX) or decode (RX) frame can't race the release-old ARC
        // write of these reference-typed slots (torn refcount → use-after-free).
        relaySlotLock.withLock {
            relaySealerSend = nil  // W574e — fresh M-15 sealers per call (new key)
            relaySealerRecv = nil
            relaySealerCallId = nil  // W574h — unbind so the next call re-keys cleanly
            relaySealerKeyFp = nil   // W574l
            // W67: reset transport binding. Nota: NON disconnect-iamo il
            // wsClient (può restare connesso per signaling / chat / contacts).
            // Solo facciamo nil-out i riferimenti così future audio frames
            // non triggherano send/playback.
            wsClient = nil
            peerUserId = nil
        }
    }

    // MARK: - W464 — CallKit audio-session lifecycle

    /// W464 — start the capture + playback `AVAudioEngine`s, but ONLY once
    /// CallKit has activated the shared `AVAudioSession`.
    ///
    /// `AudioCapture.start()` / `AudioPlayback.start()` both guard on an
    /// internal `isRunning` flag, so this is idempotent: it is safe to
    /// call from `startCall` / `activateIncomingCallAudio` (where the
    /// session is usually NOT yet active → no-op) AND from
    /// `handleAudioSessionActivated()` (where it actually starts the
    /// engines). Whichever runs last with `audioSessionActive == true`
    /// performs the real start.
    private func startAudioIOIfReady() {
        // W-GRPVPIO-CRASH-3 — the single chokepoint every 1:1 audio start
        // funnels through (activateIncomingCallAudio, handleAudioSessionActivated,
        // handleCallAnswered, and CallKit didActivate all reach here). Refusing
        // it while a group call owns VP-IO closes EVERY path to the crashing
        // setVoiceProcessingEnabled at once (see `isGroupCallActive` kdoc).
        // W-AUDIOGATEDIAG (2026-08-03): the three guards below were
        // print()-only — invisible in every remote log pull. Found while
        // chasing a live "call connects, video track received, zero audio
        // TX/RX heartbeat ever" report with no way to tell WHICH gate was
        // blocking. `ship-ios-logs.py`'s redactor is stricter than the
        // documented "numeric survives" rule suggests — every one of these
        // exact strings was verified to survive `redact_body` before
        // shipping (several plausible variants, incl. any extra
        // `word=word` field or a compound word like "capturefail", did
        // NOT and were silently dropped). `gate` is a numeric code, not a
        // string: 1=group_active 2=no_session 3=no_answer. "call" is
        // already allow-listed in TAG_SCOPE_PREFIXES.
        if isGroupCallActive?() == true {
            RTLog.warn("call", "audioIO skip=1 gate=1")
            return
        }
        guard audioSessionActive else {
            RTLog.info("call", "audioIO defer=1 gate=2")
            return
        }
        // W574b pre-answer gate: for outgoing calls CallKit fires didActivate
        // as soon as the call UI appears — BEFORE the peer answers. Block the
        // mic until call_answer arrives (handleCallAnswered flips the flag).
        // Incoming calls set the flag in activateIncomingCallAudio (we ARE
        // the answerer), so this is a no-op on the answering side.
        // Do NOT use AppState.callState here — the outgoing flow sets
        // `.active` immediately after the OFFER is sent, which defeated
        // the v1.0.618 isCallActive?() version of this gate.
        guard peerAnswered else {
            RTLog.info("call", "audioIO defer=1 gate=3")
            return
        }
        // SINGLE-ENGINE FIX — start ONE AVAudioEngine only. AudioCapture now
        // owns both the mic tap AND the playback player node, so there is no
        // separate AudioPlayback engine to start (a second engine on the same
        // AVAudioSession muted the output route → total silence). audioPlayback
        // is left intentionally unused/nil.
        if let capture = audioCapture {
            // W-LONGAUDIO (2026-08-10) — last chance to align capture with the
            // engine, and the one that closes the ordering hole.
            //
            // The other two latch sites run from the handshake and from the
            // incoming-answer setup, and neither is guaranteed to precede this
            // one: on an OUTGOING call CallKit fires `didActivate` — and hence
            // this method — as soon as the call UI appears, which can be before
            // the PQC handshake reaches `.active`. `setCaptureProfile` refuses
            // once the engine is running, so a latch that lands after `start()`
            // would leave the encoder expecting 5760-byte frames while the
            // re-chunker still emits 1920: every `encode` rejected, every frame
            // sent as constant-size silence. Running it here, immediately before
            // `start()`, means whichever site fires first, capture agrees with
            // the engine by the time a single sample is captured.
            //
            // Idempotent on the engine (the latch is terminal), and a no-op on
            // any build with the send kill switch off.
            latchAudioProfileForCall()
            do {
                try capture.start()
                // W-AUDIOGATEDIAG (2026-08-03): confirms all three gates
                // above actually cleared and AVAudioEngine.start() itself
                // succeeded — the one line that, if present, rules out
                // startAudioIOIfReady as the cause of a "no audio"
                // report and points at TX encode/send or RX decode/
                // playback instead. Was previously unlogged entirely
                // (silence on success gave no positive confirmation).
                RTLog.info("call", "audioIO started=1")
                // W-VPIODIAG (2026-08-12): whether Apple's Voice Processing I/O
                // — AEC, NS and AGC behind one hardware switch — is actually
                // engaged for this call.
                //
                // Added because the question "was echo cancellation off on that
                // call?" could not be answered from telemetry at all. Android
                // ships it per call ("Audio capture started: ... ns=true,
                // aec=true"); iOS emitted the equivalent only through
                // AudioProcessingPipeline.emitSessionDiagnostics, which is a
                // plain print() carrying `vpio=true` — a non-numeric run, which
                // is exactly what the redactor drops. Zero such lines exist in
                // Loki, so the state was invisible remotely no matter how many
                // calls were made.
                //
                // Every field is therefore numeric, per the same rule the
                // capfail branch below documents. `vpio` is what the engine
                // ended up with, `want` is what the user's toggles asked for,
                // and they differ exactly when a fallback fired: the W-AEC-FIX
                // starve watchdog or the setVoiceProcessingEnabled NSException
                // degrade, both of which trade echo for a working mic and
                // count in `byp`.
                let vpActive = audioPipeline?.voiceProcessingIsActive == true
                // W574c only force-enables AEC on the built-in loudspeaker route —
                // "was echo cancellation off" is unanswerable without knowing
                // whether that route was even the one active, so it rides along
                // on the same numeric-only line for the same redactor reason.
                let onSpeaker = AudioProcessingPipeline.currentRouteHasBuiltInSpeaker()
                RTLog.info(
                    "call",
                    "audioVp vpio=\(vpActive ? 1 : 0)"
                        + " want=\(CallsGate.anyVoiceProcessingEnabled ? 1 : 0)"
                        + " byp=\(audioPipeline?.voiceProcessingBypassCount ?? -1)"
                        + " aec=\(CallsGate.aecEnabled ? 1 : 0)"
                        + " ns=\(CallsGate.nsEnabled ? 1 : 0)"
                        + " agc=\(CallsGate.agcEnabled ? 1 : 0)"
                        + " spk=\(onSpeaker ? 1 : 0)"
                )
            } catch {
                // Was print()-only — invisible in every remote log pull.
                // The error description is deliberately NOT included: it's
                // free-form English text, and a multi-word free-form run
                // makes the redactor drop the WHOLE line (verified against
                // the real redact_body), not just scrub the offending part
                // — better a bare positive/negative signal that reliably
                // ships than a detailed one that silently doesn't.
                RTLog.warn("call", "audioIO capfail=1")
            }
        }
        // Diagnostics: mark audio I/O live once the single engine has started.
        if audioCapture != nil {
            audioEnginesStarted = true
        }
    }

    /// W464 — CallKit activated the shared `AVAudioSession`. This is the
    /// only safe moment to spin up the mic-capture / speaker-playback
    /// `AVAudioEngine`s. Wired from `AppState` to
    /// `CallKitProvider.onAudioSessionActivated`. Runs on the main thread.
    public func handleAudioSessionActivated() {
        audioSessionActive = true
        startAudioIOIfReady()
        // EARPIECE is the default route for an encrypted phone call (user
        // requirement: "gestire il volume della capsula telefonica; lo speaker
        // esterno va bene solo se lo imposto dall'interfaccia per fare vivavoce").
        // Do NOT force .speaker here — the .voiceChat session already routes to
        // the receiver. The user switches to speaker via the in-call button
        // (overrideOutputAudioPort(.speaker)). The .none reset in endCall keeps
        // the next call starting on the earpiece.
    }

    /// W464 — CallKit released the audio session (call ending or
    /// interrupted). Future audio-engine starts must wait for the next
    /// `didActivate`. Wired from `CallKitProvider.onAudioSessionDeactivated`.
    public func handleAudioSessionDeactivated() {
        audioSessionActive = false
    }

    /// W574 — called by AppState when `call_answer` is received (callee has
    /// formally accepted). Kicks off audio I/O if CallKit already fired
    /// `didActivate` (audioSessionActive == true). If `didActivate` has not
    /// yet arrived, the deferred call to `startAudioIOIfReady()` from
    /// `handleAudioSessionActivated()` will complete the start once it fires.
    public func handleCallAnswered() {
        peerAnswered = true
        startAudioIOIfReady()
        // W574b — post-answer W469 fallback. The 1.5s timer in startCall
        // now (correctly) skips while the peer hasn't answered, so it no
        // longer covers the "CallKit didActivate never fires" case for
        // outgoing calls. Re-arm here: if the session is still inactive
        // shortly after the answer, self-activate so the call gets audio.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            guard !self.audioSessionActive,
                  self.callIntegration != nil,
                  self.peerAnswered else { return }
            // Was print()-only. If this fires it means CallKit never
            // called didActivate within 1s of answer — a real signal
            // worth seeing remotely, not just a harmless fallback.
            // Verified against the real redact_body (see the gate-comment
            // on startAudioIOIfReady) — several plausible spellings of
            // this exact field were silently dropped before "selfact".
            RTLog.warn("call", "audioIO selfact=1")
            self.handleAudioSessionActivated()
        }
    }

    /// W469 — convert the engine's `FrameEncoder` output to the wire
    /// format the peer can decode. With the Android-wire toggle ON
    /// (default) this re-wraps the frame as a `WireRelayFrameCodec`
    /// audio envelope, which Android relay peers decode and iOS peers
    /// auto-detect. The audio AEAD carries no AAD, so re-containerising
    /// changes only header bytes — never the ciphertext/tag. On a parse
    /// failure it returns the original bytes unchanged (fail-safe).
    private func encodeAudioForWire(_ frameEncoderBytes: Data) -> Data {
        guard androidAudioWireCompat else { return frameEncoderBytes }
        guard let fe = try? FrameEncoder.deserialize(frameEncoderBytes) else {
            return frameEncoderBytes
        }
        return WireRelayFrameCodec.encodeAudio(fe)
    }

    /// W69 helper: encrypt + waveform-update + network-send routine
    /// extracted from `capture.onFrame` per essere call-able sia dal
    /// fast path (NetworkSim Off) che dal task-isolated delay path
    /// (NetworkSim HighLatency/Satellite).
    ///
    /// W-STALEPIPE (2026-07-13) — same class of bug fixed for video
    /// (onOutboundFragment identity guard): `capture.onFrame` snapshots
    /// `integration` once and hands it to `txAudioQueue.async` (or, on the
    /// NetworkSim delay path, to a Task that can sleep arbitrarily long
    /// first). CallService itself is a process-wide singleton
    /// (`AppState.callService = CallService()`), so a queued/delayed frame
    /// that outlives `endCall()` (which sets `self.callIntegration = nil`
    /// and stops audioCapture) still finds `self` alive and — for the
    /// incoming-call capture.onFrame — has NO freshness check at all before
    /// this call, encrypting and sending audio for a call that already
    /// ended. Mirrors the fleet-wide "video relay rejected: not an
    /// established call party" finding (~6662/week) at smaller volume
    /// (~705/week server-side "audio relay rejected"). Fixed at this single
    /// shared chokepoint (both capture.onFrame sites funnel through here)
    /// rather than duplicating the guard at each closure.
    private func processAndSendEncryptedFrame(pcmFrame: Data,
                                               integration: QAudionCallIntegration) {
        guard callIntegration === integration else {
            RTLog.error("call", "W-STALEPIPE processAndSendEncryptedFrame called with an integration that is no longer self.callIntegration — dropping frame (would have been rejected server-side anyway)")
            return
        }
        // W517 — honour mute / hold flags.
        // Hold: suppress TX entirely so the peer hears silence without
        // the ratchet advancing out-of-step.
        guard !isOnHold else { return }
        // Mute: replace mic PCM with silence so the crypto state advances
        // in step with the peer (ratchet stays aligned) but the peer
        // hears nothing. Mirrors the gate in the legacy processOutgoingAudio().
        let frameToProcess = isMuted ? Data(repeating: 0, count: pcmFrame.count) : pcmFrame

        // W466 — TX-path instrumentation: prove whether the mic produces
        // frames, whether encryption succeeds, and whether frames hit the
        // wire. Rate-limited (first occurrence + 250-frame heartbeat).
        if !loggedFirstTxCapture {
            loggedFirstTxCapture = true
            let bytes: String = frameToProcess.count.description
            let line: String = "[CallService] TX: first mic frame reached encrypt stage (" + bytes + " bytes PCM)"
            print(line)
        }
        do {
            let encrypted = try integration.processOutgoingAudio(pcmFrame: frameToProcess)
            framesEncryptedTx &+= 1
            if !loggedFirstTxEncrypt {
                loggedFirstTxEncrypt = true
                let bytes: String = encrypted.count.description
                let line: String = "[CallService] TX: first frame ENCRYPTED ok (" + bytes + " bytes) — Opus+AEAD pipeline live"
                print(line)
            }
            let txSamples = updateWaveformSamples(from: frameToProcess)
            let cipherSamples = updateCipherSamples(from: encrypted)
            Task { @MainActor [weak self] in
                self?.onTxWaveformUpdate?(txSamples)
                self?.onCipherWaveformUpdate?(cipherSamples)
            }
            // W476 — fall back to the lazy providers (set once by AppState
            // at login) when `wireTransport` never bound these eagerly.
            // Without this every encrypted TX frame was silently dropped
            // for any call where `liveProvider` was nil at startCall
            // /answer time — the local waveforms moved but the server
            // logged zero `audio relay from=<us>` and the peer heard
            // silence.
            //
            // W574c — priority INVERTED: prefer the LIVE provider's client
            // over the cached `wsClient`. The cache binds whatever instance
            // was current at call setup; when that instance is superseded
            // mid-call (multi-provider reconnect, see fix/ws-reconnect-storm)
            // its webSocketTask goes nil and `send(audio_frame)` drops every
            // frame with no recovery — call 382c46bb: client tx_enc=2245,
            // server relayed=1, while RX kept flowing on the NEW instance.
            // `getWsClient` always resolves the current live instance; the
            // cache remains as fallback for transient liveProvider==nil.
            // W-SLOTLOCK — snapshot the cached transport refs under the lock; the
            // getWsClient/getPeerId provider closures run OUTSIDE the lock.
            let (cachedWs, cachedPeer): (BCryptoWebSocketClient?, String?) =
                relaySlotLock.withLock { (wsClient, peerUserId) }
            let effectiveWs = getWsClient?() ?? cachedWs
            let effectivePeer = cachedPeer ?? getPeerId?()
            if let ws = effectiveWs, let peer = effectivePeer {
                // W522 — when the W476 lazy fallback rescues TX (wireTransport
                // was never called because liveProvider was nil at startCall),
                // we ALSO need to register the audio_frame RX handler. Without
                // this branch the iPad encrypts+sends correctly but never sees
                // any inbound audio_frame from the peer: the symptom is the
                // remote side hears us but we hear silence (confirmed in
                // session bbe9a2ff, 1.0.520 — TX heartbeat reaches 3000 frames
                // while RX heartbeat is never emitted).
                let needsRxRegistration: Bool = (cachedWs == nil)
                if cachedWs == nil {
                    // W-SLOTLOCK — lazy-populate the transport cache under the lock.
                    relaySlotLock.withLock {
                        if wsClient == nil { wsClient = ws }
                        if peerUserId == nil { peerUserId = peer }
                    }
                }
                if needsRxRegistration {
                    ws.registerHandler(type: "audio_frame") { [weak self] _, data in
                        guard let self,
                              let b64 = data["frame"] as? String,
                              let frameData = Data(base64Encoded: b64) else { return }
                        let incomingCallId = data["call_id"] as? String
                        self.handleIncomingEncryptedFrame(frameData, callId: incomingCallId)
                    }
                    print("[CallService] W522: lazy audio_frame RX handler registered (fallback path)")
                }
                // W469 — emit the cross-platform wire format. The engine's
                // `processOutgoingAudio` always serialises the iOS-native
                // `FrameEncoder` container; Android peers on the relay can
                // only decode the compact `WireRelayFrameCodec` audio
                // envelope. `encodeAudioForWire` re-containerises it (the
                // receiving iOS side auto-detects either format, so this is
                // also correct for iOS↔iOS).
                let wireFrame = encodeAudioForWire(encrypted)
                // W574e — apply the M-15 seal so the on-wire bytes match
                // Android's BcryptoWsFrameRelayTransport.sendRaw exactly:
                // seal( 0x01|nonce|seq|ctLen|ct ). Pass-through until the
                // sealer is installed (key-established), mirroring Android's
                // `pqcSend?.seal(payload) ?: payload`. iOS↔iOS (both new)
                // seal↔open; iOS↔Android now interops.
                let sealedFrame: Data
                // W-SLOTLOCK — copy the send sealer under the lock; seal() runs unlocked.
                if let sealer = relaySlotLock.withLock({ relaySealerSend }) {
                    sealedFrame = (try? sealer.seal(wireFrame)) ?? wireFrame
                } else {
                    sealedFrame = wireFrame
                }
                // W525: include the call_id so Android/Desktop accept
                // the frame. Their filter drops envelopes whose
                // call_id doesn't match the active call.
                let cid = getCallId?()
                // W-DCAUDIO — prefer the P2P sealed-audio DataChannel when it is
                // open; fall back to the WS relay otherwise. Identical bytes on
                // either path (the raw WireRelayFrameCodec envelope), so the peer
                // decodes both the same way. The DataChannel is lower-latency and
                // keeps media off the server; the WS relay guarantees delivery when
                // ICE/DTLS cannot form a P2P link.
                let sentOnDc: Bool = sendAudioOverDataChannel?(sealedFrame) ?? false
                if !sentOnDc {
                    ws.sendAudioFrame(recipientId: peer, frame: sealedFrame, callId: cid)
                }
                // W-DCMUX — record WHICH transport carried this frame, and log
                // the two moments that matter: the first frame on the
                // DataChannel, and the reason we could not use it. The routing
                // decision itself is untouched above; nothing below can change
                // where a frame went.
                // `short8` is computed INSIDE the log branches, never per frame:
                // this runs 50 times a second on the audio encode queue and a
                // trim+lowercase+prefix on every frame is pure allocation
                // churn on a real-time path for a string almost nobody reads.
                if sentOnDc {
                    txFramesDc &+= 1
                    if !loggedFirstTxOnDc {
                        loggedFirstTxOnDc = true
                        let line: String = "dcmux first=txdc callId=" + Self.short8(cid)
                              + " n=" + txFramesDc.description
                        print("[CallService] " + line)
                        RTLog.info("call", line)
                    }
                } else {
                    txFramesWs &+= 1
                    txFallbackCount &+= 1
                    // First, then every 250th (~5 s at 50 fps). Reading the diag
                    // closure is deliberately inside this gate: it hops into the
                    // WebRTC object graph and must not run per frame.
                    if txFallbackCount == 1 || txFallbackCount % 250 == 0 {
                        let raw: Int = audioDataChannelDiag?() ?? -2
                        let why: String
                        switch raw {
                        case -4: why = "nopc"
                        case -3: why = "pinned"
                        case -2: why = "noctl"
                        case -1: why = "nochan"
                        case 0:  why = "conn"
                        case 2:  why = "closing"
                        case 3:  why = "closed"
                        // `1` is OPEN and must be unreachable here: an open
                        // channel returns true from sendAudioFrameData, including
                        // for a backpressure drop. If this ever prints, the
                        // send-side predicate and the diagnostic disagree and
                        // THAT is the bug, so it gets its own word rather than
                        // being folded into a plausible-looking one.
                        case 1:  why = "openbug"
                        default: why = "unknown"
                        }
                        // Every token here is deliberately short: the log
                        // shipper replaces the whole body with an attribute-only
                        // summary if ANY run of 12+ [A-Za-z0-9+/=_-] characters
                        // survives its scrub (ship-ios-logs.py, RE_RESIDUAL_B64
                        // -> _attribute_summary). `why=connecting` would be 14
                        // and would silently delete this line's content. Verified
                        // against that module's own redact_body.
                        let line: String = "dcmux txfall why=" + why
                              + " st=" + raw.description
                              + " callId=" + Self.short8(cid)
                              + " n=" + txFallbackCount.description
                        print("[CallService] " + line)
                        RTLog.warn("call", line)
                    }
                }
                // W-NETVIS — the FLUSSO byte counter, at Android's exact layer:
                // the SEALED frame, before base64 / JSON envelope / binary
                // header / WS frame / TLS record, mirroring `txBytes.addAndGet(
                // wirePayload.size)` (BcryptoWsFrameRelayTransport.kt:275).
                // Counted on BOTH transports because both carry these identical
                // bytes. On the DataChannel `sentOnDc` is a real send result, so
                // this matches Android's "only when ok"; on the WS relay
                // `sendAudioFrame` returns Void and no such result exists —
                // see the counter's declaration for that divergence.
                wireTxBytes &+= Int64(sealedFrame.count)
                if !loggedFirstTxWire {
                    loggedFirstTxWire = true
                    let fmt: String = androidAudioWireCompat ? "WireRelayFrameCodec" : "FrameEncoder"
                    let a: String = encrypted.count.description
                    let b: String = wireFrame.count.description
                    let line: String = "[CallService] TX: wire format = " + fmt + " (" + a + "->" + b + " bytes)"
                    print(line)
                    // W526 diagnostic: confirm whether the call_id is
                    // actually flowing through. If `cid == nil` here the
                    // peer (Android/Desktop) silently drops every frame.
                    let cidStr: String = cid ?? "<NIL>"
                    let cidShortPrefix: String = String(cidStr.prefix(8))
                    let cidShort: String = cidStr.count > 8 ? (cidShortPrefix + "…") : cidStr
                    let peerShort: String = String(peer.prefix(8))
                    let cidLine: String = "[CallService] TX call_id=" + cidShort + " (peer=" + peerShort + "…)"
                    print(cidLine)
                }
                if framesEncryptedTx % 250 == 0 {
                    let n: String = framesEncryptedTx.description
                    let line: String = "[CallService] TX heartbeat: " + n + " frames encrypted+sent"
                    print(line)
                    // W-DCMUX — the transport split, on the SAME 250-frame beat
                    // (~5 s at 50 fps). This is the line §8 acceptance reads:
                    // on a DataChannel-borne call `dc` climbs on both rows while
                    // `ws` stays flat, and vice versa. Deliberately beside the
                    // existing heartbeat rather than on its own timer, so the
                    // two can never disagree about which frame count they mean.
                    let dcmuxLine: String = "dcmux tx dc=" + txFramesDc.description
                          + " ws=" + txFramesWs.description
                          + " rx dc=" + rxFramesDc.description
                          + " ws=" + rxFramesWs.description
                          + " callId=" + Self.short8(cid)
                          + " n=" + n
                    print("[CallService] " + dcmuxLine)
                    // The one line that actually answers "what carried this
                    // call's audio, on iOS's own side" — every ~5s for the
                    // call's duration. `rx dc=0 rx ws=0` with a live call
                    // means this device received nothing at all; `tx`/`rx`
                    // disagreeing on which leg is climbing means the two
                    // ends are on different transports and, per the W-DCMUX
                    // design note this mirrors, headed for one-way silence.
                    // None of that was visible off-device before this line
                    // reached RTLog — only the Xcode console saw it.
                    RTLog.info("call", dcmuxLine)
                }
            } else if !loggedTxNoTransport {
                loggedTxNoTransport = true
                print("[CallService] TX: encrypted frames NOT sent — WS transport not bound (wsClient/peerUserId nil)")
            }
        } catch {
            // W-TXGATE — separate the EXPECTED pre-handshake window from a REAL
            // crypto failure. Before the session key exists (txSessionReady
            // still false), processOutgoingAudio necessarily throws
            // QAudionEngineError.error3 on every mic frame — ~40 frames over the
            // ~0.8 s handshake. Counting those in tx_enc_err made a healthy call
            // look like it had 40 crypto errors (surfaced by tune-report). Route
            // them to txPreHandshakeDropped instead; tx_enc_err now counts ONLY
            // failures AFTER the session went active — a genuine bug signal.
            if !txSessionReady {
                txPreHandshakeDropped &+= 1
                return
            }
            // W466 — a real post-handshake encrypt failure. Log the first one and
            // every 250th so the telemetry shows whether they persist.
            txEncryptErrorCount &+= 1
            if txEncryptErrorCount == 1 || txEncryptErrorCount % 250 == 0 {
                let desc: String = error.localizedDescription
                let cnt: String = txEncryptErrorCount.description
                let line: String = "[CallService] TX encrypt FAILED (x" + cnt + "): " + desc
                print(line)
            }
        }
    }

    /// W530 — register ONLY the inbound `audio_frame` handler on the
    /// given WS, without touching the eager outbound fields
    /// (`wsClient` / `peerUserId`). AppState calls this once at login
    /// AND on every WS reconnect, so the dispatcher's
    /// `messageHandlers["audio_frame"]` slot is always populated
    /// before any frame can arrive — eliminating the ~5 s RX gap that
    /// was caused by `wireTransport(wsClient:peerUserId:)` only
    /// running at startCall/answer time when `liveProvider` happened
    /// to be non-nil.
    ///
    /// Idempotent: BCryptoWebSocketClient.registerHandler replaces any
    /// previous handler for the same type, so calling this on every
    /// reconnect simply re-attaches the closure on the (possibly
    /// fresh) WS instance.
    ///
    /// The handler dispatches to `handleIncomingEncryptedFrame` which
    /// no-ops via the rxPreBuffer when no call integration is bound
    /// yet (W481) — so registering early is harmless.
    public func attachIncomingAudioHandler(wsClient: BCryptoWebSocketClient) {
        wsClient.registerHandler(type: "audio_frame") { [weak self] _, data in
            guard let self,
                  let b64 = data["frame"] as? String,
                  let frameData = Data(base64Encoded: b64) else { return }
            let incomingCallId = data["call_id"] as? String
            self.handleIncomingEncryptedFrame(frameData, callId: incomingCallId)
        }
    }

    /// W67: wire del WebSocket transport per chiudere il loop audio.
    /// Chiamato da `AppState.startCall()` PRIMA di `startCall(engine:contactId:)`
    /// così la prima frame catturata può immediatamente essere instradata.
    ///
    /// Registra il handler "audio_frame" che il `BCryptoWebSocketClient`
    /// emette quando il server inoltra un audio frame del peer:
    ///   1. extract `frame` field (base64) dal payload JSON
    ///   2. decode base64 → serialized EncryptedFrame
    ///   3. handleIncomingEncryptedFrame → decrypt → AudioPlayback
    public func wireTransport(wsClient: BCryptoWebSocketClient,
                              peerUserId: String) {
        // W-SLOTLOCK — write the transport refs under the lock (the TX tap on
        // txAudioQueue reads them per frame).
        relaySlotLock.withLock {
            self.wsClient = wsClient
            self.peerUserId = peerUserId
        }

        // Register handler. BCryptoWebSocketClient.registerHandler
        // sostituisce qualsiasi precedente handler per lo stesso type,
        // quindi non serve unregister esplicito su endCall.
        wsClient.registerHandler(type: "audio_frame") { [weak self] _, data in
            guard let self,
                  let b64 = data["frame"] as? String,
                  let frameData = Data(base64Encoded: b64) else { return }
            let incomingCallId = data["call_id"] as? String
            self.handleIncomingEncryptedFrame(frameData, callId: incomingCallId)
        }
    }

    func processOutgoingAudio(pcmFrame: Data) throws -> Data {
        guard let integration = callIntegration else {
            throw CallServiceError.noIntegration
        }
        // When muted, replace PCM plaintext with silence before encryption.
        // The AEAD ciphertext still flows to the remote peer; the plaintext is zeroed.
        let frameToEncrypt = isMuted ? Data(repeating: 0, count: pcmFrame.count) : pcmFrame
        let encrypted = try integration.processOutgoingAudio(pcmFrame: frameToEncrypt)

        // Update TX waveform from raw PCM
        let txSamples = updateWaveformSamples(from: pcmFrame)
        onTxWaveformUpdate?(txSamples)

        // Update cipher waveform from encrypted output
        let cipherSamples = updateCipherSamples(from: encrypted)
        onCipherWaveformUpdate?(cipherSamples)

        return encrypted
    }

    func processIncomingAudio(frame: Data) throws -> Data {
        guard let integration = callIntegration else {
            throw CallServiceError.noIntegration
        }
        let pcm = try integration.processIncomingAudio(serializedFrame: frame)

        // Update RX waveform from decoded PCM
        let rxSamples = updateWaveformSamples(from: pcm)
        onRxWaveformUpdate?(rxSamples)

        return pcm
    }

    // MARK: - Waveform Helpers

    /// Converts PCM Int16 data to a normalized Float array suitable for waveform display.
    /// Each sample is divided by 32768.0 to produce values in the range [-1.0, 1.0].
    func updateWaveformSamples(from pcmData: Data) -> [Float] {
        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }
        var samples = [Float](repeating: 0, count: sampleCount)
        pcmData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                samples[i] = Float(int16Buffer[i]) / 32768.0
            }
        }
        return samples
    }

    /// Takes encrypted frame bytes and normalizes them as Float values for the cipher waveform.
    /// Each byte is mapped from [0, 255] to [-1.0, 1.0] to visualize the encrypted stream.
    func updateCipherSamples(from encryptedData: Data) -> [Float] {
        guard !encryptedData.isEmpty else { return [] }
        var samples = [Float](repeating: 0, count: encryptedData.count)
        encryptedData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for i in 0..<encryptedData.count {
                samples[i] = (Float(bytes[i]) / 127.5) - 1.0
            }
        }
        return samples
    }
}
