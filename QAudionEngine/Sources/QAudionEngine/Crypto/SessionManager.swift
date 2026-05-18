import Foundation
import CryptoKit

public final class SessionManager: @unchecked Sendable {
    public struct SessionState: Equatable {
        public let sessionId: Data
        public let rootKey: Data
        public let chainKey: Data
        public let frameCounter: Int64
    }

    public static let ratchetMinFrames: Int64 = 10
    public static let ratchetMaxFrames: Int64 = 200
    public static let ratchetDefaultFrames: Int64 = Int64(CryptoConstants.ratchetIntervalFrames)

    private let lock = NSLock()
    private var currentSession: SessionState?
    private var lastRatchetTime: Int64 = 0
    public private(set) var adaptiveRatchetInterval: Int64

    public init() { self.adaptiveRatchetInterval = Self.ratchetDefaultFrames }

    public func initSession(sharedSecret: Data, psk: Data? = nil) throws -> SessionState {
        guard sharedSecret.count == CryptoConstants.keySizeBytes else {
            throw SessionManagerError.invalidSecretSize(sharedSecret.count)
        }
        if let psk = psk {
            guard psk.count == CryptoConstants.keySizeBytes else {
                throw SessionManagerError.invalidPskSize(psk.count)
            }
        }
        let effectiveSecret: SymmetricKey
        if let psk = psk {
            effectiveSecret = hkdfDerive(ikm: psk, salt: sharedSecret, info: CryptoConstants.hkdfInfoPskMix)
        } else {
            effectiveSecret = SymmetricKey(data: sharedSecret)
        }
        let effectiveData = effectiveSecret.withUnsafeBytes { Data($0) }
        let rootKey = hkdfDerive(ikm: effectiveData, salt: nil, info: CryptoConstants.hkdfInfoRoot)
        let rootKeyData = rootKey.withUnsafeBytes { Data($0) }
        let chainKey = hkdfDerive(ikm: effectiveData, salt: nil, info: CryptoConstants.hkdfInfoChain)
        let chainKeyData = chainKey.withUnsafeBytes { Data($0) }

        var sessionId = Data(count: 32)
        sessionId.withUnsafeMutableBytes { buffer in
            #if canImport(Security)
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
            #else
            let fd = open("/dev/urandom", O_RDONLY)
            if fd >= 0 { _ = read(fd, buffer.baseAddress!, 32); close(fd) }
            #endif
        }
        let state = SessionState(sessionId: sessionId, rootKey: rootKeyData, chainKey: chainKeyData, frameCounter: 0)
        lock.lock()
        currentSession = state
        lastRatchetTime = Int64(Date().timeIntervalSince1970 * 1000)
        lock.unlock()
        return state
    }

    public func ratchet() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let session = currentSession else { throw SessionManagerError.noActiveSession }
        let interval = max(Self.ratchetMinFrames, min(Self.ratchetMaxFrames, adaptiveRatchetInterval))
        let shouldRootRatchet = session.frameCounter > 0 && session.frameCounter % interval == 0
        var newRootKey = session.rootKey
        var newChainKey = session.chainKey
        if shouldRootRatchet {
            newRootKey = hkdfDerive(ikm: session.rootKey, salt: nil, info: CryptoConstants.hkdfInfoRoot).withUnsafeBytes { Data($0) }
            newChainKey = hkdfDerive(ikm: session.rootKey, salt: nil, info: CryptoConstants.hkdfInfoChain).withUnsafeBytes { Data($0) }
        }
        let frameKeyData = hkdfDerive(ikm: newChainKey, salt: nil, info: CryptoConstants.hkdfInfoChain).withUnsafeBytes { Data($0) }
        let nextChainData = hkdfDerive(ikm: newChainKey, salt: nil, info: CryptoConstants.hkdfInfoNextChain).withUnsafeBytes { Data($0) }
        currentSession = SessionState(sessionId: session.sessionId, rootKey: newRootKey, chainKey: nextChainData, frameCounter: session.frameCounter + 1)
        // SECURITY C-8: ARC does not zero-fill released buffers. When a
        // root ratchet stepped the keys, the prior root/chain keys are
        // now superseded — scrub their buffers via the hardened,
        // optimiser-proof CryptoConstants.zeroize (memset_s on Darwin).
        // `SessionState` is a value type with `let` Data fields, so this
        // scrubs mutable copies; effective erasure of the canonical
        // backing store holds only while no other live `SessionState`
        // copy aliases it (copy-on-write). This is the conservative,
        // wire-neutral choice — no field type/format change that could
        // drift from Android — and is best-effort defence-in-depth on top
        // of the keys never being persisted in this manager.
        if shouldRootRatchet {
            var staleRoot = session.rootKey
            var staleChain = session.chainKey
            CryptoConstants.zeroize(&staleRoot)
            CryptoConstants.zeroize(&staleChain)
        }
        return frameKeyData
    }

    public var frameCounter: Int64 { lock.lock(); defer { lock.unlock() }; return currentSession?.frameCounter ?? 0 }
    public var sessionState: SessionState? { lock.lock(); defer { lock.unlock() }; return currentSession }

    public func updateConfidence(_ confidence: Float) {
        let c = max(0, min(1, confidence))
        adaptiveRatchetInterval = Self.ratchetMinFrames + Int64(Float(Self.ratchetMaxFrames - Self.ratchetMinFrames) * c)
    }

    public func destroySession() { lock.lock(); currentSession = nil; lastRatchetTime = 0; lock.unlock() }

    // SECURITY M-33: callers pass `salt: nil`, which becomes an empty
    // salt. This is INTENTIONAL and cross-platform load-bearing — the
    // Android session ratchet and the KAT cross-platform vectors
    // (QAudionEngineTests/CrossPlatform/CrossPlatformTestVectors) derive
    // these session/root/chain keys with the same zero-length salt.
    // RFC 5869 §2.2 explicitly defines HKDF-Extract with a zero-filled
    // salt of HashLen when none is supplied, so this is well-defined (not
    // a "missing salt" bug) and the per-call distinct `info` strings
    // provide domain separation. Introducing a named salt here would
    // change every derived key and break audio interop with Android —
    // comment-only by design.
    private func hkdfDerive(ikm: Data, salt: Data?, info: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt ?? Data(), info: info, outputByteCount: CryptoConstants.keySizeBytes)
    }
}
public enum SessionManagerError: Error { case invalidSecretSize(Int); case invalidPskSize(Int); case noActiveSession }
