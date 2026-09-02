import Foundation
import CryptoKit

public final class QAudionEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var state: EngineState = .uninitialized
    private var config: EngineConfig
    // W477 — split TX/RX SessionManagers. The chain ratchet MUST
    // advance independently per direction: in a bidirectional call a
    // shared ratchet (the previous design) advanced the LOCAL counter
    // on every `processOutgoingAudio` AND every `processIncomingAudio`,
    // so the local RX counter immediately diverged from the peer's TX
    // counter (the peer advances ITS counter only on its own TX). Every
    // RX frame derived its key from a different chain step than the
    // peer had used to encrypt — telemetry showed `CryptoKitError`
    // (error 3 / authentication failure) on every frame the moment
    // bidirectional audio started. With this split:
    //   • `txSessionManager.ratchet()` advances ONLY when we encrypt,
    //   • `rxSessionManager.ratchet()` advances ONLY when we decrypt,
    // so our TX-key at index K matches the peer's RX-key at K, and our
    // RX-key at K matches the peer's TX-key at K. Both managers are
    // initialised from the SAME shared secret in `initSession`, so
    // they start with identical chainKeys.
    private var txSessionManager: SessionManager?
    private var rxSessionManager: SessionManager?
    private var aeadCipher: AeadCipher?
    private var pqcKeyExchange: PqcKeyExchange?
    private var audioProcessor: QAudionAudioProcessor?
    private var stats = EngineStats()
    private var sessionInfo: SessionInfo?
    private var sessionStartTime: Date?

    /// W-FECDECODE (2026-08-25) — forwards `audioProcessor.onFecRecoveredPcm`.
    /// A stored closure rather than a passthrough to `audioProcessor` itself:
    /// `initialize()`/`latchAudioProfile` REBUILD `audioProcessor`, and a
    /// caller may set this before either has run (audioProcessor still nil).
    /// Re-applied to the processor's own callback at every (re)construction
    /// site below, so it survives rebuilds and an out-of-order set/call.
    public var onFecRecoveredAudio: ((Data) -> Void)?

    /// W-PLPFEEDBACK (2026-08-25) — measures OUR inbound loss from the wire
    /// sequence numbers every successfully processed audio frame already
    /// carries. Fed in `processIncomingAudio`, read via `rxLossSnapshot()` by
    /// the periodic PLP: reporter (see `CallService`). Survives an
    /// `audioProcessor` rebuild — unlike the codec's own per-decoder
    /// counters, loss measurement is a property of the CALL, not of one
    /// profile's encoder/decoder pair.
    private let rxLossMeter = FrameLossMeter()

    // W479 — Android-compatible audio mode.
    // When `useAdaptivePadding` is true, processOutgoingAudio and
    // processIncomingAudio use the AdaptivePaddingController scheme
    // byte-identical to Android FrameRelayTransport:
    //   TX: static sessionKey + NO AAD + 2-byte len header + 120-byte padding
    //   RX: static sessionKey + NO AAD + strip 2-byte len header
    // This is set automatically by QAudionCallIntegration when the peer
    // handshakes via the Android JSON bundle path (onAndroidBundleReceived).
    // iOS↔iOS calls keep useAdaptivePadding = false (ratchet path, W477+W473).
    // Flag is reset in initialize() so each call starts clean.
    private var useAdaptivePadding: Bool = false
    private var sessionKey: Data?          // raw 32-byte key for adaptive path
    private var txSeqAdaptive: UInt64 = 0  // monotonic TX counter for adaptive path

    // ── MEDIA-3/MEDIA-4/MEDIA-5 (W-INNERAUDIOAAD, 2026-09-02) ──
    //
    // The adaptive-padding branch above is the "inner sealed-audio wire" the
    // audit flags: ONE static key seals both directions with NO AAD and no
    // replay window (Android's SealedAudioWire.kt / AdaptivePaddingController
    // equivalent). Fix, gated behind `innerAudioAadV1`
    // (`QAudionCallIntegration.innerAudioAadV1Enabled`, default false — see
    // that constant's doc): per-direction keys derived from the SAME shared
    // secret via distinct HKDF info labels, AAD binding callId/direction/
    // epoch/seq, and a 1024-slot replay window mirroring the outer M-15
    // sealer's (`PqcRtpFrameSealer`) shape exactly.
    //
    // `innerAudioAadActive` is false whenever the capability was not
    // negotiated (kill switch off, or peer didn't advertise it) — in that
    // case processOutgoingAudio/processIncomingAudio take the ORIGINAL
    // static-key/no-AAD branch below, byte-identical to today. This block of
    // state is simply unused, never read, in that case.
    private var innerAudioAadActive: Bool = false
    private var adaptiveSendKey: Data?     // k_a2b or k_b2a, whichever we send with
    private var adaptiveRecvKey: Data?     // the other one
    private var adaptiveCallIdBytes: Data = Data()
    private var adaptiveSelfIsRoleA: Bool = false
    private var adaptiveEpoch: UInt32 = 1  // the call's re-key round (CALL-3), reused as epoch

    /// 1024-slot sliding-window anti-replay state for the inner sealed-audio
    /// RX path, keyed on the wire sequence number. Same shape (word-sliced
    /// UInt64 bitmask, highest-accepted-counter tracking) as
    /// `PqcRtpFrameSealer`'s replay window — duplicated rather than shared
    /// because that class's window is `private` and counter-derived from its
    /// own nonce layout, whereas this one is keyed directly off the frame's
    /// wire `seq`. Reset whenever a fresh adaptive+AAD session is installed
    /// (see `initSession`), since `txSeqAdaptive`/the peer's mirror of it
    /// restart at 0 for every new epoch.
    private var innerAudioReplayInitialized = false
    private var innerAudioReplayHighest: UInt64 = 0
    private static let innerAudioReplayWindowSize: UInt64 = 1024
    private static let innerAudioReplayWordCount = Int(innerAudioReplayWindowSize / 64)
    private var innerAudioReplayWindow: [UInt64] =
        [UInt64](repeating: 0, count: QAudionEngine.innerAudioReplayWordCount)
    // W-BLOCKSIZE — the audio BLOCK: the total plaintext one frame occupies
    // before encryption (2-byte true-length header + Opus frame + CSPRNG
    // filler). Same numbers as before, now taken from the single fleet-wide
    // source so the block and the bitrate ceiling derived from it in
    // `AudioConstants` can never drift apart.
    private static let adaptiveTarget = AudioConstants.blockBytesStandard
    private static let adaptiveHeader = AudioConstants.lengthHeaderBytes

    // ── W-LONGAUDIO (2026-08-10) — the per-call audio profile ──
    //
    // The block size is now a property of the CALL, not of the build. It is
    // latched exactly once, before capture starts, and is terminal: there is no
    // setter that can move it afterwards, no re-evaluation and no mid-call
    // switch, in any direction, for any reason. That is not caution about
    // complexity — a block that can change mid-call makes the packet size a
    // function of something other than the profile, and the constant-size
    // property stops being provable.
    //
    // W-ALL60 (2026-08-14) — defaults to `AudioProfile.defaultProfile` (60 ms /
    // 256 bytes) and stays there unless `latchAudioProfile` is called with
    // something else, which now happens only for a sovereign-earbud call. A call
    // that never latches sends the same wire as every other call, which is the
    // whole point: the previous default made "never latched" audibly different
    // from "latched", on the same build, in the same call.
    // W-ALL60 (2026-08-14) — the default is the 60 ms profile, not 20 ms. A call
    // that never latches (handshake beat the capability list, an unparsed
    // envelope, a lost race) now runs 60 ms like every other call instead of
    // silently dropping to a different wire from its peer.
    private var audioProfile: AudioProfile = AudioProfile.defaultProfile
    private var audioProfileLatched = false

    /// The block this call seals into. 120 unless the long profile was latched.
    private var adaptiveTargetForCall: Int { audioProfile.blockBytes }

    public init(config: EngineConfig = .production()) { self.config = config }

    public func initialize() throws {
        lock.lock(); defer { lock.unlock() }
        guard state.canTransitionTo(.initialized) else {
            throw QAudionEngineError.invalidStateTransition(from: state, to: .initialized)
        }
        txSessionManager = SessionManager()
        rxSessionManager = SessionManager()
        aeadCipher = AeadCipher()
        pqcKeyExchange = PqcKeyExchange()
        // W-LONGAUDIO — reset the profile BEFORE the processor is built, so a
        // new call can never inherit the previous one's block. `initialize()` is
        // the start of a call's life; the latch happens later, after the
        // handshake, and only if the peer agreed.
        audioProfile = AudioProfile.defaultProfile
        audioProfileLatched = false
        // W-ALL60 — build the codec FOR the profile rather than from `.secure()`'s
        // bare defaults. `.secure()` alone yields a 20 ms / 120-byte encoder, so
        // an un-latched call used to encode 20 ms frames while `audioProfile`
        // claimed otherwise; `Config(profile:)` keeps the two in agreement by
        // construction and clamps the bitrate to what the block can carry.
        audioProcessor = QAudionAudioProcessor(
            codec: OpusCodec(config: OpusCodec.Config(profile: audioProfile)),
            jitterBufferMs: AudioConstants.jitterBufferMsWsRelay
        )
        // W-FECDECODE — re-apply on every (re)construction; see the property's doc.
        audioProcessor?.onFecRecoveredPcm = { [weak self] pcm in self?.onFecRecoveredAudio?(pcm) }
        // W479 — reset adaptive-padding state so each call starts clean.
        useAdaptivePadding = false
        sessionKey = nil
        txSeqAdaptive = 0
        // W-INNERAUDIOAAD — reset the directional-key/AAD/replay state too;
        // a new call must never inherit the previous one's keys or window.
        resetInnerAudioAadState()
        // W-RXREORDER — a retained frame key belongs to exactly one session's
        // chain; carrying one into a new call would be both useless and a key
        // held past its purpose.
        clearSkippedKeys()
        state = .initialized
    }

    /// W-INNERAUDIOAAD — zeroize/reset all directional-key + replay-window
    /// state for the inner sealed-audio wire. Called from `initialize()`
    /// (new call), `initSession()` (every install, including a re-key round —
    /// the replay window and sequence space both restart at that point), and
    /// `destroySession()`.
    private func resetInnerAudioAadState() {
        if var k = adaptiveSendKey { CryptoConstants.zeroize(&k) }
        if var k = adaptiveRecvKey { CryptoConstants.zeroize(&k) }
        innerAudioAadActive = false
        adaptiveSendKey = nil
        adaptiveRecvKey = nil
        adaptiveCallIdBytes = Data()
        adaptiveSelfIsRoleA = false
        adaptiveEpoch = 1
        innerAudioReplayInitialized = false
        innerAudioReplayHighest = 0
        for i in innerAudioReplayWindow.indices { innerAudioReplayWindow[i] = 0 }
    }

    /// W-LONGAUDIO (2026-08-10) — latch the audio profile for this call.
    ///
    /// Call ONCE, after the capability negotiation result is in hand and before
    /// audio capture starts. Rebuilds the Opus codec for the profile's frame
    /// duration and block, and re-sizes the jitter buffer in milliseconds.
    ///
    /// Idempotent and TERMINAL by construction: the second call is refused, not
    /// applied. If the negotiation result is not available when this runs, the
    /// caller passes `.standard` (or does not call at all) and the call runs
    /// standard for its whole life — which is the correct outcome, not a
    /// condition to retry out of. A retry loop here would reintroduce exactly the
    /// mid-call switch the constant-rate property forbids.
    ///
    /// - Returns: `true` if this call latched the profile; `false` if it was
    ///   already latched, or the engine is past the point where it is safe.
    @discardableResult
    public func latchAudioProfile(_ profile: AudioProfile) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !audioProfileLatched else { return false }
        guard state == .initialized || state == .sessionActive else { return false }
        audioProfileLatched = true
        guard profile != audioProfile else { return true }
        audioProfile = profile
        // Rebuild the codec around the new operating point. `Config(profile:)`
        // clamps the bitrate to what the block can carry before libopus sees it,
        // which for the long profile is 32 kbps with zero headroom.
        audioProcessor = QAudionAudioProcessor(
            codec: OpusCodec(config: OpusCodec.Config(profile: profile)),
            jitterBufferMs: AudioConstants.jitterBufferMsWsRelay
        )
        // W-FECDECODE — re-apply on every (re)construction; see the property's doc.
        audioProcessor?.onFecRecoveredPcm = { [weak self] pcm in self?.onFecRecoveredAudio?(pcm) }
        return true
    }

    /// The profile this call is sealing into. `.standard` until latched.
    public var activeAudioProfile: AudioProfile {
        lock.lock(); defer { lock.unlock() }
        return audioProfile
    }

    /// W479 — `adaptivePadding: true` switches audio to the
    /// AdaptivePaddingController-compatible scheme (static session key,
    /// no AAD, 2-byte len header + 120-byte fixed-size padding).
    /// Set this when the peer handshaked via the Android JSON bundle path.
    ///
    /// W-INNERAUDIOAAD (MEDIA-3/4/5) — `innerAudioAadV1: true` (only
    /// meaningful together with `adaptivePadding: true`) additionally
    /// switches that scheme from one static shared key/no-AAD to
    /// per-direction keys + AAD + a 1024-slot replay window. The caller
    /// (`QAudionCallIntegration`) only ever passes `true` here when BOTH
    /// `Self.innerAudioAadV1Enabled` (default false) is on AND the peer
    /// negotiated the same capability — see that constant's doc. `callId`/
    /// `selfIsRoleA`/`epoch` are only read when `innerAudioAadV1` is true.
    public func initSession(sharedSecret: Data, psk: Data? = nil,
                            adaptivePadding: Bool = false,
                            innerAudioAadV1: Bool = false,
                            callId: String = "",
                            selfIsRoleA: Bool = false,
                            epoch: UInt32 = 1) throws {
        lock.lock(); defer { lock.unlock() }
        guard state == .initialized || state == .sessionActive else {
            throw QAudionEngineError.invalidStateTransition(from: state, to: .sessionActive)
        }
        guard let txSm = txSessionManager, let rxSm = rxSessionManager else {
            throw QAudionEngineError.notInitialized
        }
        // W477 — initialise BOTH managers from the SAME shared secret,
        // so they produce identical initial chainKeys. From there each
        // chain advances independently per direction.
        let sessionState = try txSm.initSession(sharedSecret: sharedSecret, psk: psk)
        _ = try rxSm.initSession(sharedSecret: sharedSecret, psk: psk)
        sessionInfo = SessionInfo(sessionId: sessionState.sessionId, isActive: true)
        sessionStartTime = Date()
        stats = EngineStats()
        // W-PLPFEEDBACK — deliberately NOT reset here. A re-key restarts the
        // sender's wire sequence at 0 (see `txSeqAdaptive` below and
        // W-RXREORDER), and `rxLossMeter` already treats a large backward
        // jump as exactly that — a counter restart — folding the closed span
        // into its cumulative totals and re-anchoring rather than losing
        // history (see `FrameLossMeter`'s own doc). An external reset here
        // would instead make `expected`/`lost` jump BACKWARD out from under
        // the periodic reporter's windowed delta (`CallService`'s
        // `plpPrevExpected`/`plpPrevLost`), which has no way to know a reset
        // happened and would read the drop as a burst of negative loss.
        // W479 — store the raw session key and adaptive-padding flag.
        // Must be set atomically with state = .sessionActive so
        // processOutgoingAudio never reads a half-initialised flag.
        useAdaptivePadding = adaptivePadding
        txSeqAdaptive = 0
        // W-INNERAUDIOAAD (MEDIA-3/4/5) — every (re-)install of the adaptive
        // path restarts the sequence space (txSeqAdaptive above), so the
        // directional keys and replay window must restart with it, whether
        // or not this round uses them. Old keys are zeroized first.
        resetInnerAudioAadState()
        if adaptivePadding && innerAudioAadV1 {
            innerAudioAadActive = true
            adaptiveCallIdBytes = Data(callId.utf8)
            adaptiveSelfIsRoleA = selfIsRoleA
            adaptiveEpoch = epoch
            sessionKey = nil
            let ikm = SymmetricKey(data: sharedSecret)
            // MEDIA-3 — per-direction keys from the SAME shared secret via
            // distinct HKDF info labels. Byte-identical formula required on
            // every platform that turns this capability on:
            //   k_a2b = HKDF-SHA256(ikm=sessionKey, salt="", info="q-audion-inner-audio-a2b-v1", L=32)
            //   k_b2a = HKDF-SHA256(ikm=sessionKey, salt="", info="q-audion-inner-audio-b2a-v1", L=32)
            let infoA2B = Data("q-audion-inner-audio-a2b-v1".utf8)
            let infoB2A = Data("q-audion-inner-audio-b2a-v1".utf8)
            let keyA2B = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: ikm, salt: Data(), info: infoA2B, outputByteCount: 32)
            let keyB2A = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: ikm, salt: Data(), info: infoB2A, outputByteCount: 32)
            let dataA2B = Self.dataFromSymmetricKey(keyA2B)
            let dataB2A = Self.dataFromSymmetricKey(keyB2A)
            // Role "A" sends with k_a2b/receives with k_b2a; role "B" is the
            // mirror image — same convention as the outer M-15 sealer's
            // `PqcRtpFrameSealer.createDirectional` (A.send == B.recv).
            adaptiveSendKey = selfIsRoleA ? dataA2B : dataB2A
            adaptiveRecvKey = selfIsRoleA ? dataB2A : dataA2B
        } else {
            sessionKey = adaptivePadding ? sharedSecret : nil
        }
        // W-RXREORDER — the RX chain restarts here, so any key retained against
        // the previous chain's positions is now meaningless. Re-keying mid-call
        // (the handshake fires from several sites) must not leave a window open.
        clearSkippedKeys()
        state = .sessionActive
    }

    /// W-INNERAUDIOAAD — extract a derived `HKDF` `SymmetricKey`'s raw bytes.
    /// CryptoKit gives no public initializer from `SymmetricKey` to `Data`
    /// other than iterating its contiguous bytes.
    private static func dataFromSymmetricKey(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    public func processOutgoingAudio(pcmFrame: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard state == .sessionActive || state == .processing else {
            throw QAudionEngineError.noActiveSession
        }
        // W479 — Android-compat path: static key, no AAD, adaptive padding.
        // W-INNERAUDIOAAD (MEDIA-3/4/5) — when negotiated, `key` below is this
        // call's TX-direction key instead of the one shared static key, and
        // the AEAD call further down binds an AAD instead of passing none.
        if useAdaptivePadding {
            guard let cipher = aeadCipher else {
                throw QAudionEngineError.notInitialized
            }
            guard let key = innerAudioAadActive ? adaptiveSendKey : sessionKey else {
                throw QAudionEngineError.notInitialized
            }
            let opus = audioProcessor?.processOutgoing(pcmFrame: pcmFrame) ?? pcmFrame
            // W-PADOVERFLOW (2026-08-10) — an oversized frame must NOT change
            // the size of the packet.
            //
            // This used to build `targetLen = max(120, opus + 2)`, i.e. it grew
            // the block to fit whatever the encoder produced. Android's
            // equivalent threw instead, and the throw was swallowed upstream so
            // the frame never reached the wire. Both are the same class of
            // defect seen from opposite sides: the observable property of the
            // packet — its size here, its existence there — became a function
            // of the audio.
            //
            // That is the worst possible failure for this design. The whole
            // point of a fixed-size, fixed-rate train is that an observer
            // learns nothing from sizes or timing; a packet that grows whenever
            // the encoder overshoots is exactly the size channel the block
            // exists to close, and it is silent — no log, no counter, nothing
            // audible.
            //
            // The margin is not theoretical: under CBR the encoder emits
            // `AudioConstants.opusCbrBytes` bytes deterministically, so an
            // operating point chosen at the arithmetic ceiling leaves zero
            // slack and any increase lands here.
            //
            // Failure now degrades to ONE frame of silence: the packet still
            // goes out, at the same size, at the same instant, with a
            // true-length header of ZERO and the normal CSPRNG filler. The
            // receiver treats a zero-length body as a lost frame and conceals
            // it (see processIncomingAudio), and the constant-rate, constant-
            // size property holds. The counter still fires so the
            // misconfiguration is visible in `EngineStats`.
            // W-LONGAUDIO (2026-08-10) — the block is THIS CALL's, latched once.
            // 120 unless `latchAudioProfile` was given the long profile, which
            // requires a peer that advertised both tags and a build with the
            // send kill switch on. Everything below is unchanged arithmetic
            // around a different constant, so a standard call is byte-identical.
            let target = adaptiveTargetForCall
            let budget = target - Self.adaptiveHeader
            let overflow = opus.count > budget
            if overflow { stats.padOverflowFrames &+= 1 }
            let bodyLen = overflow ? 0 : opus.count
            // Build 2-byte-len-header + opus + CSPRNG filler, always exactly
            // `target` bytes of plaintext.
            var rng = SystemRandomNumberGenerator()
            let hi = UInt8((bodyLen >> 8) & 0xFF)
            let lo = UInt8(bodyLen & 0xFF)
            let tailLen = target - Self.adaptiveHeader - bodyLen
            let tail: [UInt8] = tailLen > 0
                ? (0..<tailLen).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
                : []
            var padded = Data(capacity: target)
            padded.append(hi); padded.append(lo)
            if bodyLen > 0 { padded.append(contentsOf: opus) }
            padded.append(contentsOf: tail)
            // Legacy: AES-256-GCM with static session key and NO AAD (nil = no
            // authenticating: param). MEDIA-4: when negotiated, bind
            // callId||direction||epoch||seq as AAD instead — same cipher call,
            // same ciphertext framing, only the key and the `associatedData`
            // argument differ.
            let seq64 = txSeqAdaptive
            let seq = UInt32(truncatingIfNeeded: seq64)
            txSeqAdaptive &+= 1
            let aad: Data? = innerAudioAadActive
                ? Self.innerAudioAad(
                    callIdBytes: adaptiveCallIdBytes,
                    // Role A sends with k_a2b (direction 0x01); role B sends
                    // with k_b2a (direction 0x02) — mirrors adaptiveSendKey's
                    // own selection above.
                    direction: adaptiveSelfIsRoleA ? 0x01 : 0x02,
                    epoch: adaptiveEpoch,
                    seq: seq64)
                : nil
            let encrypted = try cipher.encrypt(plaintext: padded, key: key, associatedData: aad)
            let frame = EncryptedFrame(
                sequenceNumber: seq,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                nonce: encrypted.nonce,
                payload: encrypted.ciphertext,
                tag: encrypted.tag
            )
            stats.framesTx += 1
            return FrameEncoder.serialize(frame)
        }
        guard let txSm = txSessionManager, let cipher = aeadCipher else {
            throw QAudionEngineError.notInitialized
        }
        // W477 — TX uses the txSessionManager only; RX has its own.
        let frameKey = try txSm.ratchet()
        let opus = audioProcessor?.processOutgoing(pcmFrame: pcmFrame) ?? pcmFrame
        // W473 — bind the frame sequence number into the AEAD as AAD,
        // byte-identical to Android `SecureAudioPipeline.buildAad`.
        // Before this, iOS used NO AAD while Android bound seq||timestamp,
        // so every cross-platform decrypt failed with a GCM tag mismatch.
        let seq = UInt32(truncatingIfNeeded: txSm.frameCounter)
        let encrypted = try cipher.encrypt(plaintext: opus, key: frameKey,
                                           associatedData: Self.frameAAD(seq))
        let frame = EncryptedFrame(
            sequenceNumber: seq,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            nonce: encrypted.nonce,
            payload: encrypted.ciphertext,
            tag: encrypted.tag
        )
        stats.framesTx += 1
        return FrameEncoder.serialize(frame)
    }

    public func processIncomingAudio(serializedFrame: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard state == .sessionActive || state == .processing else {
            throw QAudionEngineError.noActiveSession
        }
        // W469 — cross-platform wire format detection (common to both paths).
        let frame: EncryptedFrame
        if FrameEncoder.isValid(serializedFrame) {
            frame = try FrameEncoder.deserialize(serializedFrame)
        } else {
            frame = try WireRelayFrameCodec.decode(serializedFrame).frame
        }
        // W479 — Android-compat path: static session key, no AAD, strip 2-byte padding header.
        // W-INNERAUDIOAAD (MEDIA-3/4/5) — when negotiated, `key` is this call's
        // RX-direction key, a replay window rejects a repeated/too-old `seq`
        // BEFORE the AEAD open is attempted, and the AEAD open binds the same
        // AAD the sender used instead of none.
        if useAdaptivePadding {
            guard let cipher = aeadCipher else {
                throw QAudionEngineError.notInitialized
            }
            guard let key = innerAudioAadActive ? adaptiveRecvKey : sessionKey else {
                throw QAudionEngineError.notInitialized
            }
            // MEDIA-5 — reject replays/too-old frames before spending any
            // crypto on them. Keyed on the wire sequence number, same
            // 1024-slot shape as the outer M-15 sealer's replay window.
            if innerAudioAadActive {
                guard innerAudioCheckAndUpdateReplay(seq: UInt64(frame.sequenceNumber)) else {
                    throw QAudionEngineError.malformedFrame(
                        "inner-audio replay/stale seq=\(frame.sequenceNumber)")
                }
            }
            let cipherOutput = AeadCipher.CipherOutput(
                nonce: frame.nonce, ciphertext: frame.payload, tag: frame.tag
            )
            // Legacy: AES-256-GCM with static session key and NO AAD — mirrors
            // Android AdaptivePaddingController.openAudio(frame, sessionKey).
            // MEDIA-4: when negotiated, reconstruct the SAME AAD the sender
            // bound — the RECEIVE direction is the opposite of adaptiveSendKey's
            // (we open with k_b2a iff we send with k_a2b, and vice versa).
            let aad: Data? = innerAudioAadActive
                ? Self.innerAudioAad(
                    callIdBytes: adaptiveCallIdBytes,
                    direction: adaptiveSelfIsRoleA ? 0x02 : 0x01,
                    epoch: adaptiveEpoch,
                    seq: UInt64(frame.sequenceNumber))
                : nil
            let padded = try cipher.decrypt(cipherOutput: cipherOutput, key: key,
                                            associatedData: aad)
            guard padded.count >= Self.adaptiveHeader else {
                throw QAudionEngineError.malformedFrame("adaptive padding too short: \(padded.count)")
            }
            let len = (Int(padded[0]) << 8) | Int(padded[1])
            guard len >= 0, Self.adaptiveHeader + len <= padded.count else {
                throw QAudionEngineError.malformedFrame("adaptive length header invalid: len=\(len) padded=\(padded.count)")
            }
            // W-PADOVERFLOW (2026-08-10) — a true-length header of ZERO means
            // the peer's encoder overshot its block and it sent this packet
            // with no audio in it rather than sending a differently-sized one
            // (see processOutgoingAudio). The packet arrived on time and at the
            // right size, which is what preserves the constant-rate property;
            // the audio for this one frame is simply absent.
            //
            // Treat it as a lost frame and let concealment fill it. It must NOT
            // go through `processIncoming`: that pushes the empty body into the
            // jitter buffer, where it later decodes to nil (OpusCodec.decode
            // rejects an empty frame), and the `??` fallback below would then
            // hand an EMPTY Data back to the caller as if it were PCM —
            // straight into `AudioCapture.playFrame` and the playout buffer.
            guard len > 0 else {
                stats.framesRx += 1
                // W-PLPFEEDBACK — this packet DID arrive on the wire (it is
                // the fleet's explicit "no audio this frame" marker, not a
                // transit loss), so it counts toward the loss meter exactly
                // like any other received frame.
                rxLossMeter.onFrame(seq: Int64(frame.sequenceNumber))
                // The `??` is unreachable in `.sessionActive` (initialize()
                // always builds the processor); it returns one frame of silence
                // rather than an empty buffer for exactly the reason above.
                return audioProcessor?.codec.decodePLC()
                    ?? Data(count: AudioConstants.bytesPerFrame)
            }
            let opusBytes = padded.subdata(in: Self.adaptiveHeader..<(Self.adaptiveHeader + len))
            let pcm = audioProcessor?.processIncoming(opusFrame: opusBytes,
                                                       sequenceNumber: frame.sequenceNumber) ?? opusBytes
            stats.framesRx += 1
            rxLossMeter.onFrame(seq: Int64(frame.sequenceNumber))
            return pcm
        }
        guard let rxSm = rxSessionManager, let cipher = aeadCipher else {
            throw QAudionEngineError.notInitialized
        }
        // W477 — RX uses the rxSessionManager only; TX has its own.
        // XP-ratchet-loss — rxSm.ratchet() previously advanced exactly
        // once per successfully-received frame with no reference to the
        // wire sequence number. Audio runs over a lossy, non-retransmitted
        // path (WS relay / DataChannel), so ANY single dropped frame left
        // the RX chain permanently one step behind the peer's TX chain —
        // every following frame then failed GCM auth for the rest of the
        // call (matches telemetry: iOS↔iOS calls decrypting zero audio
        // partway through). Use frame.sequenceNumber (already trusted for
        // the AAD below) to detect the gap and fast-forward the missing
        // ratchet steps. (Those steps' keys used to be discarded here on the
        // grounds that "those frames are gone" — see W-RXREORDER immediately
        // below for why that premise was wrong, and what happens now instead.)
        //
        // W-RXREORDER (2026-08-13) — the catch-up above is only half the
        // problem, and the other half is the one that reaches the user on an
        // iOS↔iOS call.
        //
        // This ratchet path carries audio over a transport that is explicitly
        // UNORDERED: the sealed-audio DataChannel is created with
        // `isOrdered = false, maxRetransmits = 0`
        // (`QAudionPeerConnection.createAudioDataChannel`, matching Android's
        // DC), and the sender additionally alternates between that DataChannel
        // and the WS relay per frame (`CallService.processAndSendEncryptedFrame`
        // falls back the instant the DC is not open). Two transports with very
        // different latencies feeding one chain means a later frame routinely
        // arrives BEFORE an earlier one — guaranteed at the moment the call
        // switches from the relay to the freshly-opened P2P channel, and again
        // on every DC flap.
        //
        // Before this change the two branches below turned that into permanent
        // loss: an early frame fast-forwarded the chain, and then EVERY frame
        // still in flight behind it hit the `seq64 <= frameCounter` branch and
        // was thrown away as "stale". One reordering event destroyed the whole
        // burst behind it, not one frame.
        //
        // Why only iOS↔iOS: the adaptive-padding branch above (the path taken
        // for an Android peer) has a STATIC session key and no sequence
        // dependency at all, so reordering there is free. This branch is the
        // only one where wire order is load-bearing, and it is the branch a
        // call between two iOS devices always takes (see `useAdaptivePadding`).
        //
        // The fix is the standard one for a symmetric chain: RETAIN the keys
        // the catch-up skips, in a bounded window, so a late frame can still be
        // opened with the key belonging to ITS wire position. A key is removed
        // the moment it is used, so a replayed frame still fails — the replay
        // property the old branch provided is kept, the collateral loss is not.
        let expectedNext = rxSm.frameCounter + 1
        let seq64 = Int64(frame.sequenceNumber)
        let frameKey: Data
        if seq64 > expectedNext {
            let gap = seq64 - expectedNext
            guard gap <= Self.maxRatchetCatchUpFrames else {
                // Bigger than any real packet-loss burst (~20 s of audio at
                // 20 ms/frame) — likely a corrupt/forged seq or a genuinely
                // new session; don't churn the chain thousands of times,
                // just drop this frame like before (DoS guard).
                throw QAudionEngineError.malformedFrame(
                    "ratchet catch-up gap too large: \(gap)")
            }
            // Retain, don't discard: each skipped step is the key for exactly
            // one wire position, and that frame may simply be late rather than
            // lost. `rememberSkippedKey` bounds the window.
            for i in 0..<gap {
                let skippedKey = try rxSm.ratchet()
                rememberSkippedKey(skippedKey, forSeq: expectedNext + i)
            }
            frameKey = try rxSm.ratchet()
        } else if seq64 <= rxSm.frameCounter {
            // Reordered-late, or a duplicate/replay. The chain itself cannot go
            // backwards (forward-secure, one-way), but if we retained this
            // position's key when we skipped past it, the frame is perfectly
            // decryptable and its audio is still wanted — at 60 ms a dropped
            // frame is 60 ms of hole, three times what it costs at 20 ms.
            guard let retained = takeSkippedKey(forSeq: seq64) else {
                // No retained key: either a genuine duplicate (the key was
                // consumed by the first copy), or the frame is older than the
                // retention window. Both are undecryptable here.
                throw QAudionEngineError.malformedFrame(
                    "stale/duplicate frame seq=\(frame.sequenceNumber)")
            }
            stats.framesRxReordered &+= 1
            frameKey = retained
        } else {
            frameKey = try rxSm.ratchet()
        }
        let cipherOutput = AeadCipher.CipherOutput(
            nonce: frame.nonce, ciphertext: frame.payload, tag: frame.tag
        )
        // W473 — reconstruct the AEAD AAD from the frame's sequence
        // number (see `frameAAD`). Must match what the sender bound.
        // Note: the W469 comment "no AAD" above is stale (pre-W473). AAD IS used.
        let opus = try cipher.decrypt(cipherOutput: cipherOutput, key: frameKey,
                                      associatedData: Self.frameAAD(frame.sequenceNumber))
        let pcm = audioProcessor?.processIncoming(opusFrame: opus,
                                                   sequenceNumber: frame.sequenceNumber) ?? opus
        stats.framesRx += 1
        rxLossMeter.onFrame(seq: Int64(frame.sequenceNumber))
        return pcm
    }

    /// W473 — per-frame AEAD additional-authenticated-data: the 32-bit
    /// frame sequence number, big-endian, exactly 4 bytes. Byte-identical
    /// to Android `SecureAudioPipeline.buildAad` (post-W473). Android
    /// previously appended an 8-byte timestamp, but the
    /// `WireRelayFrameCodec` relay envelope used for iOS<->Android calls
    /// carries no timestamp field, so a seq||timestamp AAD could never be
    /// reconstructed by the relay receiver and every cross-platform
    /// decrypt failed with a GCM tag mismatch. Sequence-based replay
    /// detection already provides frame freshness.
    private static func frameAAD(_ seq: UInt32) -> Data {
        var be = seq.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    /// MEDIA-4 (W-INNERAUDIOAAD) — the inner sealed-audio wire's AEAD AAD
    /// when `innerAudioAadV1` is negotiated:
    ///   aad = UTF8(callId) || direction_byte || epoch_u32_be || seq_u64_be
    /// `direction` is `0x01` for a2b, `0x02` for b2a — the direction the KEY
    /// used for this frame belongs to (not "am I sending or receiving").
    /// Exact byte layout required on every platform that turns this on.
    private static func innerAudioAad(
        callIdBytes: Data, direction: UInt8, epoch: UInt32, seq: UInt64
    ) -> Data {
        var aad = Data(capacity: callIdBytes.count + 1 + 4 + 8)
        aad.append(callIdBytes)
        aad.append(direction)
        var epochBE = epoch.bigEndian
        aad.append(withUnsafeBytes(of: &epochBE) { Data($0) })
        var seqBE = seq.bigEndian
        aad.append(withUnsafeBytes(of: &seqBE) { Data($0) })
        return aad
    }

    /// MEDIA-5 (W-INNERAUDIOAAD) — sliding-window anti-replay check for the
    /// inner sealed-audio RX path, keyed directly on the wire `seq` (unlike
    /// `PqcRtpFrameSealer`'s, which extracts a counter from its own nonce
    /// layout). Algorithm and window size (1024 slots) are otherwise
    /// identical: returns true and accepts if `seq` is fresh; returns false
    /// (caller must reject, before spending any AEAD work) if it is a replay
    /// or falls outside the window. Already lock-protected by the caller
    /// holding `lock` for the whole of `processIncomingAudio`.
    private func innerAudioCheckAndUpdateReplay(seq: UInt64) -> Bool {
        if !innerAudioReplayInitialized {
            innerAudioReplayInitialized = true
            innerAudioReplayHighest = seq
            for i in innerAudioReplayWindow.indices { innerAudioReplayWindow[i] = 0 }
            innerAudioReplayWindow[0] = 1   // bit 0 = highest = seen
            return true
        }
        if seq > innerAudioReplayHighest {
            let shift = seq - innerAudioReplayHighest
            if shift >= Self.innerAudioReplayWindowSize {
                for i in innerAudioReplayWindow.indices { innerAudioReplayWindow[i] = 0 }
            } else {
                innerAudioShiftWindowRight(by: Int(shift))
            }
            innerAudioSetWindowBit(0)
            innerAudioReplayHighest = seq
            return true
        }
        let gap = innerAudioReplayHighest - seq
        guard gap < Self.innerAudioReplayWindowSize else { return false }   // too old
        if innerAudioTestWindowBit(Int(gap)) { return false }   // already seen
        innerAudioSetWindowBit(Int(gap))
        return true
    }

    private func innerAudioSetWindowBit(_ index: Int) {
        innerAudioReplayWindow[index / 64] |= (1 << UInt64(index % 64))
    }

    private func innerAudioTestWindowBit(_ index: Int) -> Bool {
        (innerAudioReplayWindow[index / 64] & (1 << UInt64(index % 64))) != 0
    }

    /// Right-shifts the whole multi-word bitmask by `n` bits — identical
    /// layout/direction to `PqcRtpFrameSealer.shiftWindowRight`: word[0]
    /// holds the least-significant (most recent) bits.
    private func innerAudioShiftWindowRight(by n: Int) {
        guard n > 0 else { return }
        let wordShift = n / 64
        let bitShift = n % 64
        let count = innerAudioReplayWindow.count
        if bitShift == 0 {
            for i in 0..<count {
                innerAudioReplayWindow[i] =
                    (i + wordShift < count) ? innerAudioReplayWindow[i + wordShift] : 0
            }
            return
        }
        for i in 0..<count {
            let lo = (i + wordShift < count)
                ? (innerAudioReplayWindow[i + wordShift] >> UInt64(bitShift)) : 0
            let hiIdx = i + wordShift + 1
            let hi = (hiIdx < count)
                ? (innerAudioReplayWindow[hiIdx] << UInt64(64 - bitShift)) : 0
            innerAudioReplayWindow[i] = lo | hi
        }
    }

    /// XP-ratchet-loss — max forward gap the RX ratchet will fast-forward
    /// through in one frame (~20 s of 20 ms-frame audio). Real network
    /// blips lose a handful of frames; anything past this is treated as
    /// unrecoverable rather than looping the chain thousands of times.
    private static let maxRatchetCatchUpFrames: Int64 = 1000

    // ── W-RXREORDER (2026-08-13) — retained keys for out-of-order frames ──
    //
    // Keyed by the WIRE sequence number the key belongs to. Populated only by
    // the catch-up loop in `processIncomingAudio`, drained by a late frame that
    // names one of those positions, and emptied with the session.
    //
    // Bounded at `maxRetainedSkippedKeys`. The bound is a real security knob,
    // not housekeeping: a retained frame key is one the chain has already
    // stepped past, so holding it postpones forward secrecy for exactly that
    // frame. 128 is ~2.5 s of audio at 20 ms and ~7.7 s at 60 ms — far longer
    // than any reordering a live call produces, and short enough that the
    // forward-secrecy window stays measured in seconds.
    private var rxSkippedFrameKeys: [Int64: Data] = [:]

    /// Max retained out-of-order frame keys. See `rxSkippedFrameKeys`.
    private static let maxRetainedSkippedKeys = 128

    /// Retain one skipped frame key, evicting the OLDEST wire position when the
    /// window is full — the oldest is the one least likely to still be in
    /// flight, and evicting it is what keeps the forward-secrecy window bounded.
    ///
    /// Caller must hold `lock` (both call sites are inside `processIncomingAudio`).
    private func rememberSkippedKey(_ key: Data, forSeq seq: Int64) {
        rxSkippedFrameKeys[seq] = key
        while rxSkippedFrameKeys.count > Self.maxRetainedSkippedKeys {
            guard let oldest = rxSkippedFrameKeys.keys.min() else { break }
            if var stale = rxSkippedFrameKeys.removeValue(forKey: oldest) {
                // SECURITY C-8 parity — scrub the evicted key rather than
                // letting ARC drop the buffer unzeroed.
                CryptoConstants.zeroize(&stale)
            }
        }
    }

    /// Consume the retained key for `seq`, if one is held. Removing on read is
    /// what preserves replay protection: a second copy of the same frame finds
    /// nothing and is rejected exactly as before.
    ///
    /// Caller must hold `lock`.
    private func takeSkippedKey(forSeq seq: Int64) -> Data? {
        rxSkippedFrameKeys.removeValue(forKey: seq)
    }

    /// Drop every retained key. Called wherever the session ends or restarts —
    /// a key from a previous session must never be reachable from a new one.
    ///
    /// Caller must hold `lock`.
    private func clearSkippedKeys() {
        // Snapshot the keys first: removing from the dictionary while iterating
        // its own `keys` view mutates the collection being walked.
        let positions = Array(rxSkippedFrameKeys.keys)
        for k in positions {
            if var stale = rxSkippedFrameKeys.removeValue(forKey: k) {
                CryptoConstants.zeroize(&stale)
            }
        }
        rxSkippedFrameKeys.removeAll()
    }

    public func destroySession() {
        lock.lock(); defer { lock.unlock() }
        txSessionManager?.destroySession()
        rxSessionManager?.destroySession()
        sessionInfo?.isActive = false
        if let start = sessionStartTime {
            stats.sessionDurationMs = Int64(Date().timeIntervalSince(start) * 1000)
        }
        // W479 — zeroize the raw session key when the session ends.
        sessionKey = nil
        useAdaptivePadding = false
        txSeqAdaptive = 0
        // W-INNERAUDIOAAD — zeroize the directional keys too and drop the
        // replay window; no reason to hold either past the session's end.
        resetInnerAudioAadState()
        // W-RXREORDER — the retention window is the one place frame keys outlive
        // their own ratchet step, so ending the session must close it.
        clearSkippedKeys()
        if state.canTransitionTo(.initialized) { state = .initialized }
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        txSessionManager?.destroySession()
        rxSessionManager?.destroySession()
        txSessionManager = nil; rxSessionManager = nil
        aeadCipher = nil; pqcKeyExchange = nil; audioProcessor = nil
        clearSkippedKeys()  // W-RXREORDER
        state = .destroyed
    }

    public func getState() -> EngineState { lock.lock(); defer { lock.unlock() }; return state }
    public func getStats() -> EngineStats { lock.lock(); defer { lock.unlock() }; return stats }
    public func getConfig() -> EngineConfig { lock.lock(); defer { lock.unlock() }; return config }
    public func getSessionInfo() -> SessionInfo? { lock.lock(); defer { lock.unlock() }; return sessionInfo }

    /// Reconfigure the Opus encoder with tuner-derived values.
    /// Thread-safe; no-op when called before initialize() (audioProcessor nil).
    /// bitrateKbps: target bitrate in kbps (e.g. 32 = 32 000 bps). Hard cap: 40,
    /// under the block-derived ceiling (see below).
    /// plp: expected packet-loss percentage hint for FEC budget (0–100).
    public func reconfigureAudioCodec(bitrateKbps: Int, plp: Int) {
        lock.lock()
        let proc = audioProcessor
        let profile = audioProfile
        lock.unlock()
        guard let proc else { return }
        // W-BLOCKSIZE — this is the mid-call bitrate change, and mid-call is
        // the real hazard: the frame size is deterministic, but the bitrate is
        // not constant for the life of a call. 40 kbps stays as the product cap
        // (the Opus wideband speech plateau, see `AudioCodecPrefs`);
        // `clampToBlock` is the wire gate underneath it, so raising that cap
        // later can never silently push a frame past what the block holds.
        //
        // W-OPUSHEADROOM (2026-08-27) — the base preferred bitrate
        // (`AudioConstants.opusBitrate`, hence `AudioCodecPrefs.bitrateKbps`)
        // moved from 32 to 40 kbps, i.e. exactly up to the product cap. The
        // standard-profile ceiling (41 kbps at 120 B / 20 ms) is still the
        // looser of the two, so a standard-profile call's operating point DOES
        // change now (32 → 40 kbps) and still fits with headroom to spare.
        // The long-profile ceiling (32 kbps, zero headroom) is the tighter one
        // and clamps this same 40 kbps input straight back down to 32 — see
        // `profile.clamp` below, which is the reason raising the base constant
        // needed no change here at all.
        //
        // W-LONGAUDIO (2026-08-10) — clamp with the ACTIVE profile's block and
        // frame duration, and rebuild the config from the profile.
        //
        // Both halves of that are load-bearing, and both were wrong for a long
        // profile call:
        //
        //   • the clamp took `clampToBlock`'s STANDARD defaults, so a stored
        //     preference of 40 kbps sailed through the 41 kbps standard ceiling
        //     and then encoded 300 bytes into a 240-byte budget — overflow on
        //     EVERY frame, which the pad logic turns into constant-rate silence.
        //     The long profile's ceiling is 32 kbps and has exactly zero
        //     headroom: 32 kbps at 60 ms is 240 bytes against 240 available.
        //     The 14 spare bytes are `blockSafetyBytes`, not budget.
        //
        //   • the rebuilt `Config` took the DEFAULT 20 ms / 120 B, so a mid-call
        //     retune would have silently reset a latched 60 ms encoder back to
        //     20 ms — a mid-call profile switch, arriving through the auto-tuner
        //     rather than through anything that looks like a profile decision.
        //
        // The 40 kbps product cap stays; `profile.clamp` is the wire gate
        // underneath it.
        let clampedBr = profile.clamp(kbps: min(max(bitrateKbps, 8), 40))
        proc.codec.reconfigure(OpusCodec.Config(
            profile: profile, bitrate: clampedBr * 1000, complexity: 10, enableHpf: true))
        proc.codec.setPacketLossPct(max(0, min(plp, 100)))
    }

    /// W-FECDECODE — cumulative FEC recovery counters for the active
    /// decoder, for the rate-limited diagnostic log
    /// (`CallService`'s `fec_rec=<n> fec_fail=<n>`). Zero/zero before
    /// `initialize()` has built a processor.
    public func rxFecStats() -> (recovered: Int64, failed: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let proc = audioProcessor else { return (0, 0) }
        return (proc.codec.fecRecoveredFrames, proc.codec.fecFailedFrames)
    }

    /// W-PLPFEEDBACK — cumulative inbound-loss snapshot for the periodic
    /// PLP: reporter. See `rxLossMeter`'s doc for why this is never reset
    /// mid-call: the caller computes a WINDOWED delta between two snapshots,
    /// and a monotonically non-decreasing pair is what makes that safe.
    public func rxLossSnapshot() -> (expected: Int64, lost: Int64) {
        lock.lock(); defer { lock.unlock() }
        return (rxLossMeter.expected, rxLossMeter.lost)
    }
}

public enum QAudionEngineError: Error, CustomStringConvertible {
    case invalidStateTransition(from: EngineState, to: EngineState)
    case notInitialized
    case noActiveSession
    /// W479 — adaptive-padding frame failed structural validation (bad length header etc.).
    case malformedFrame(String)

    public var description: String {
        switch self {
        case .invalidStateTransition(let from, let to): return "Cannot transition from \(from) to \(to)"
        case .notInitialized: return "Engine not initialized"
        case .noActiveSession: return "No active session"
        case .malformedFrame(let reason): return "Malformed frame: \(reason)"
        }
    }
}
