import Foundation
import CryptoKit

public final class QAudionEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var state: EngineState = .uninitialized
    private var config: EngineConfig
    private var sessionManager: SessionManager?
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
        sessionManager = SessionManager()
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
        guard let sm = sessionManager else { throw QAudionEngineError.notInitialized }
        let sessionState = try sm.initSession(sharedSecret: sharedSecret, psk: psk)
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
        guard let sm = sessionManager, let cipher = aeadCipher else {
            throw QAudionEngineError.notInitialized
        }
        let frameKey = try sm.ratchet()
        let opus = audioProcessor?.processOutgoing(pcmFrame: pcmFrame) ?? pcmFrame
        let encrypted = try cipher.encrypt(plaintext: opus, key: frameKey)
        let frame = EncryptedFrame(
            sequenceNumber: UInt32(truncatingIfNeeded: sm.frameCounter),
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
        guard let sm = sessionManager, let cipher = aeadCipher else {
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
        let frameKey = try sm.ratchet()
        let cipherOutput = AeadCipher.CipherOutput(
            nonce: frame.nonce, ciphertext: frame.payload, tag: frame.tag
        )
        let opus = try cipher.decrypt(cipherOutput: cipherOutput, key: frameKey)
        let pcm = audioProcessor?.processIncoming(opusFrame: opus) ?? opus
        stats.framesRx += 1
        return pcm
    }

    public func destroySession() {
        lock.lock(); defer { lock.unlock() }
        sessionManager?.destroySession()
        sessionInfo?.isActive = false
        if let start = sessionStartTime {
            stats.sessionDurationMs = Int64(Date().timeIntervalSince(start) * 1000)
        }
        if state.canTransitionTo(.initialized) { state = .initialized }
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        sessionManager?.destroySession()
        sessionManager = nil; aeadCipher = nil; pqcKeyExchange = nil; audioProcessor = nil
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
