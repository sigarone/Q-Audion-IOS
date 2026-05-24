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
        state = .initialized
    }

    public func initSession(sharedSecret: Data, psk: Data? = nil) throws {
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
        state = .sessionActive
    }

    public func processOutgoingAudio(pcmFrame: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard state == .sessionActive || state == .processing else {
            throw QAudionEngineError.noActiveSession
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
        guard let rxSm = rxSessionManager, let cipher = aeadCipher else {
            throw QAudionEngineError.notInitialized
        }
        // W469 — cross-platform RX. iOS peers send the native
        // `FrameEncoder` container (29-byte header: version|flags|seq|
        // ts|nonceLen|nonce|payloadLen). Android peers, over the
        // BcryptoWsRelay, send the compact `WireRelayFrameCodec` audio
        // envelope (mux|nonce|seq|ctLen). Before this fix iOS always ran
        // `FrameEncoder.deserialize`, which rejected every Android frame
        // at the flags/nonceLen byte (`invalidFlags`/`invalidNonceLength`)
        // — telemetry showed 2250+ consecutive RX failures on an
        // iPad↔A50 call. `FrameEncoder.isValid` is a strong check
        // (version byte + nonceLen byte @14 == 12); a WireRelay frame's
        // byte 14 is a seq byte (≈0 for any real call), so the two
        // formats are unambiguously distinguishable. The audio AEAD uses
        // NO additional-authenticated-data, so the container format does
        // not affect decryption — only nonce/ciphertext/tag matter.
        let frame: EncryptedFrame
        if FrameEncoder.isValid(serializedFrame) {
            frame = try FrameEncoder.deserialize(serializedFrame)
        } else {
            frame = try WireRelayFrameCodec.decode(serializedFrame).frame
        }
        // W477 — RX uses the rxSessionManager only; TX has its own.
        let frameKey = try rxSm.ratchet()
        let cipherOutput = AeadCipher.CipherOutput(
            nonce: frame.nonce, ciphertext: frame.payload, tag: frame.tag
        )
        // W473 — reconstruct the AEAD AAD from the frame's sequence
        // number (see `frameAAD`). Must match what the sender bound.
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
}

public enum QAudionEngineError: Error, CustomStringConvertible {
    case invalidStateTransition(from: EngineState, to: EngineState)
    case notInitialized
    case noActiveSession

    public var description: String {
        switch self {
        case .invalidStateTransition(let from, let to): return "Cannot transition from \(from) to \(to)"
        case .notInitialized: return "Engine not initialized"
        case .noActiveSession: return "No active session"
        }
    }
}
