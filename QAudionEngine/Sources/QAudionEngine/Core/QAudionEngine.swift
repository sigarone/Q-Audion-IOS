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
        // W479 — reset adaptive-padding state so each call starts clean.
        useAdaptivePadding = false
        sessionKey = nil
        txSeqAdaptive = 0
        state = .initialized
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
    public func initSession(sharedSecret: Data, psk: Data? = nil,
                            adaptivePadding: Bool = false) throws {
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
        // W479 — store the raw session key and adaptive-padding flag.
        // Must be set atomically with state = .sessionActive so
        // processOutgoingAudio never reads a half-initialised flag.
        useAdaptivePadding = adaptivePadding
        sessionKey = adaptivePadding ? sharedSecret : nil
        txSeqAdaptive = 0
        state = .sessionActive
    }

    public func processOutgoingAudio(pcmFrame: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard state == .sessionActive || state == .processing else {
            throw QAudionEngineError.noActiveSession
        }
        // W479 — Android-compat path: static key, no AAD, adaptive padding.
        if useAdaptivePadding {
            guard let key = sessionKey, let cipher = aeadCipher else {
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
            // AES-256-GCM with static session key and NO AAD (nil = no authenticating: param).
            let encrypted = try cipher.encrypt(plaintext: padded, key: key, associatedData: nil)
            let seq = UInt32(truncatingIfNeeded: txSeqAdaptive)
            txSeqAdaptive &+= 1
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
        if useAdaptivePadding {
            guard let key = sessionKey, let cipher = aeadCipher else {
                throw QAudionEngineError.notInitialized
            }
            let cipherOutput = AeadCipher.CipherOutput(
                nonce: frame.nonce, ciphertext: frame.payload, tag: frame.tag
            )
            // AES-256-GCM with static session key and NO AAD — mirrors
            // Android AdaptivePaddingController.openAudio(frame, sessionKey).
            let padded = try cipher.decrypt(cipherOutput: cipherOutput, key: key,
                                            associatedData: nil)
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
                // The `??` is unreachable in `.sessionActive` (initialize()
                // always builds the processor); it returns one frame of silence
                // rather than an empty buffer for exactly the reason above.
                return audioProcessor?.codec.decodePLC()
                    ?? Data(count: AudioConstants.bytesPerFrame)
            }
            let opusBytes = padded.subdata(in: Self.adaptiveHeader..<(Self.adaptiveHeader + len))
            let pcm = audioProcessor?.processIncoming(opusFrame: opusBytes) ?? opusBytes
            stats.framesRx += 1
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
        // ratchet steps — their keys are simply discarded, which is safe:
        // this ratchet is one-way/forward-secure, those frames are gone.
        let expectedNext = rxSm.frameCounter + 1
        let seq64 = Int64(frame.sequenceNumber)
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
            for _ in 0..<gap { _ = try rxSm.ratchet() }
        } else if seq64 <= rxSm.frameCounter {
            // Stale, duplicate, or reordered-late frame: the ratchet
            // already advanced past this wire position. There is no way
            // back (forward-secure, one-way), so it is genuinely
            // undecryptable — drop it rather than stepping the chain
            // again, which would just reintroduce the same permanent-
            // desync bug in the opposite direction.
            throw QAudionEngineError.malformedFrame(
                "stale/duplicate frame seq=\(frame.sequenceNumber)")
        }
        let frameKey = try rxSm.ratchet()
        let cipherOutput = AeadCipher.CipherOutput(
            nonce: frame.nonce, ciphertext: frame.payload, tag: frame.tag
        )
        // W473 — reconstruct the AEAD AAD from the frame's sequence
        // number (see `frameAAD`). Must match what the sender bound.
        // Note: the W469 comment "no AAD" above is stale (pre-W473). AAD IS used.
        let opus = try cipher.decrypt(cipherOutput: cipherOutput, key: frameKey,
                                      associatedData: Self.frameAAD(frame.sequenceNumber))
        let pcm = audioProcessor?.processIncoming(opusFrame: opus) ?? opus
        stats.framesRx += 1
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

    /// XP-ratchet-loss — max forward gap the RX ratchet will fast-forward
    /// through in one frame (~20 s of 20 ms-frame audio). Real network
    /// blips lose a handful of frames; anything past this is treated as
    /// unrecoverable rather than looping the chain thousands of times.
    private static let maxRatchetCatchUpFrames: Int64 = 1000

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
        if state.canTransitionTo(.initialized) { state = .initialized }
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        txSessionManager?.destroySession()
        rxSessionManager?.destroySession()
        txSessionManager = nil; rxSessionManager = nil
        aeadCipher = nil; pqcKeyExchange = nil; audioProcessor = nil
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
        // Today the derived ceiling is the looser of the two (41 kbps at 120 B
        // / 20 ms), so nothing about the current operating point changes.
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
