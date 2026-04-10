import Foundation
import CryptoKit

/// Enhanced forward secrecy layer that augments SessionManager's HKDF
/// ratchet with per-epoch X25519 Diffie-Hellman key agreements.
///
/// Key properties:
/// - **Post-compromise security**: if the current key is leaked, future
///   keys are safe once the next DH ratchet completes.
/// - **Key erasure**: old chain keys are automatically scrubbed after a
///   configurable delay, so past traffic cannot be decrypted even with
///   full device compromise.
///
/// Integration: `ForwardSecrecy` sits between `SessionManager` (which
/// manages the symmetric ratchet) and the transport layer, injecting a
/// fresh DH contribution every `ephemeralKeyRotationFrames` frames.
public final class ForwardSecrecy: @unchecked Sendable {

    /// Published to the remote peer so it can complete the DH exchange.
    public struct EphemeralPublic: Equatable {
        public let epoch: UInt64
        public let publicKey: Data   // 32 bytes, X25519
    }

    private let lock = NSLock()
    private var currentEpoch: UInt64 = 0
    private var frameInEpoch: Int = 0
    private var localPrivateKey: Curve25519.KeyAgreement.PrivateKey
    private var remotePublicKey: Curve25519.KeyAgreement.PublicKey?
    private var chainSecret: SecureBytes?
    private var pendingErasure: [(SecureBytes, Date)] = []

    /// Callback fired every time a new ephemeral public key is generated.
    /// The transport layer must send this to the remote peer.
    public var onEphemeralKey: ((EphemeralPublic) -> Void)?

    public init() {
        localPrivateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    // MARK: - Public API

    /// The current local ephemeral public key (send to remote peer).
    public var localPublic: EphemeralPublic {
        lock.lock(); defer { lock.unlock() }
        return EphemeralPublic(epoch: currentEpoch,
                               publicKey: Data(localPrivateKey.publicKey.rawRepresentation))
    }

    /// Feed the remote peer's ephemeral public key to complete the DH.
    public func receiveRemotePublic(_ key: Data, epoch: UInt64) throws {
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)
        lock.lock()
        remotePublicKey = pub
        if epoch >= currentEpoch {
            try? performDH()
        }
        lock.unlock()
    }

    /// Derive the frame key for the next frame, rotating the DH epoch
    /// when the rotation interval is reached.
    /// - Parameter baseChainKey: The chain key produced by SessionManager's ratchet.
    /// - Returns: A 32-byte frame key incorporating the DH secret.
    public func deriveFrameKey(baseChainKey: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }

        frameInEpoch += 1

        // Rotate the DH keypair at the configured interval.
        if frameInEpoch >= CryptoConstants.ephemeralKeyRotationFrames {
            rotateEphemeralKey()
        }

        // Mix the DH-derived chain secret (if available) into the frame key.
        let dhComponent: Data
        if let cs = chainSecret {
            dhComponent = cs.copyData()
        } else {
            dhComponent = Data(repeating: 0, count: 32)
        }

        let mixed = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: baseChainKey),
            salt: dhComponent,
            info: Data("q-audion-fs-frame".utf8),
            outputByteCount: CryptoConstants.keySizeBytes
        )

        // Schedule erasure of stale entries.
        scheduleErasure()

        return mixed.withUnsafeBytes { Data($0) }
    }

    /// Force an immediate key rotation (e.g., after a detected compromise).
    public func forceRotation() {
        lock.lock()
        rotateEphemeralKey()
        lock.unlock()
    }

    // MARK: - Internal

    private func rotateEphemeralKey() {
        // Schedule old key material for erasure.
        if let old = chainSecret {
            pendingErasure.append((old, Date()))
        }
        localPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        frameInEpoch = 0
        currentEpoch += 1
        let pub = EphemeralPublic(epoch: currentEpoch,
                                  publicKey: Data(localPrivateKey.publicKey.rawRepresentation))
        let callback = onEphemeralKey
        // Fire outside the lock to avoid deadlocks in the transport layer.
        DispatchQueue.global(qos: .utility).async { callback?(pub) }

        // Immediately attempt a DH if we already have the remote key.
        try? performDH()
    }

    private func performDH() throws {
        guard let remote = remotePublicKey else { return }
        let shared = try localPrivateKey.sharedSecretFromKeyAgreement(with: remote)
        let derived = shared.withUnsafeBytes { Data($0) }
        chainSecret = SecureBytes(data: derived)
    }

    /// Wipe chain secrets whose erasure delay has expired.
    private func scheduleErasure() {
        let cutoff = Date().addingTimeInterval(-CryptoConstants.keyErasureDelay)
        pendingErasure.removeAll { entry in
            if entry.1 < cutoff {
                entry.0.zeroize()
                return true
            }
            return false
        }
    }
}
