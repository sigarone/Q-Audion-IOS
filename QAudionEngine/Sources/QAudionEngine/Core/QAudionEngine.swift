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
    private static let adaptiveTarget = 120   // target padded plaintext size (bytes)
    private static let adaptiveHeader = 2    // 2-byte big-endian length prefix

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
        audioProcessor = QAudionAudioProcessor(
            codec: OpusCodec(config: .secure()),
            jitterBufferCapacity: AudioConstants.jitterBufferFramesWsRelay
        )
        // W479 — reset adaptive-padding state so each call starts clean.
        useAdaptivePadding = false
        sessionKey = nil
        txSeqAdaptive = 0
        state = .initialized
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
            // Build 2-byte-len-header + opus + random tail padded to targetLen bytes.
            // targetLen = max(120, opus+2) so oversized frames still encode correctly
            // (Android openAudio uses the 2-byte header to extract, any size decodes).
            let targetLen = max(Self.adaptiveTarget, opus.count + Self.adaptiveHeader)
            var rng = SystemRandomNumberGenerator()
            let hi = UInt8((opus.count >> 8) & 0xFF)
            let lo = UInt8(opus.count & 0xFF)
            let tailLen = targetLen - Self.adaptiveHeader - opus.count
            let tail: [UInt8] = tailLen > 0
                ? (0..<tailLen).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
                : []
            var padded = Data(capacity: targetLen)
            padded.append(hi); padded.append(lo)
            padded.append(contentsOf: opus)
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
            let opusBytes = padded.subdata(in: Self.adaptiveHeader..<(Self.adaptiveHeader + len))
            let pcm = audioProcessor?.processIncoming(opusFrame: opusBytes) ?? opusBytes
            stats.framesRx += 1
            return pcm
        }
        guard let rxSm = rxSessionManager, let cipher = aeadCipher else {
            throw QAudionEngineError.notInitialized
        }
        // W477 — RX uses the rxSessionManager only; TX has its own.
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
    /// bitrateKbps: target bitrate in kbps (e.g. 32 = 32 000 bps). Hard cap: 40.
    /// plp: expected packet-loss percentage hint for FEC budget (0–100).
    public func reconfigureAudioCodec(bitrateKbps: Int, plp: Int) {
        lock.lock()
        let proc = audioProcessor
        lock.unlock()
        guard let proc else { return }
        let clampedBr = min(max(bitrateKbps, 8), 40)
        proc.codec.reconfigure(OpusCodec.Config(
            bitrate: clampedBr * 1000, complexity: 10, enableHpf: true))
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
