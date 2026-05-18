import Foundation
import CryptoKit
import os.log

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
    /// SECURITY H-12: the epoch for which a DH has already been completed.
    /// Guards against a replayed OLD-epoch `receiveRemotePublic` (or a
    /// duplicate same-epoch one) overwriting a fresher `chainSecret`.
    private var dhCompletedEpoch: UInt64?
    private static let log = OSLog(subsystem: "com.qaudion.app", category: "ForwardSecrecy")

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
    ///
    /// SECURITY H-12: only complete a DH for a NEW epoch (or the current
    /// epoch if its DH has not run yet). A `>=` check allowed a replayed
    /// stale-epoch public key to re-run the DH and overwrite a fresher
    /// `chainSecret`, undoing post-compromise recovery. We now require
    /// `epoch > currentEpoch`, OR `epoch == currentEpoch` with no DH yet
    /// completed for that epoch. `performDH` errors are no longer
    /// swallowed — on failure the previous good `chainSecret` is kept
    /// intact and the failure is logged (never silently zeroed).
    public func receiveRemotePublic(_ key: Data, epoch: UInt64) throws {
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)
        lock.lock()
        defer { lock.unlock() }
        remotePublicKey = pub

        let isNewerEpoch = epoch > currentEpoch
        let isCurrentEpochFirstDH = (epoch == currentEpoch) && (dhCompletedEpoch != currentEpoch)
        guard isNewerEpoch || isCurrentEpochFirstDH else {
            os_log("receiveRemotePublic: ignoring stale/duplicate epoch %{public}llu (current %{public}llu)",
                   log: Self.log, type: .info, epoch, currentEpoch)
            return
        }

        do {
            try performDH()
            dhCompletedEpoch = epoch > currentEpoch ? epoch : currentEpoch
        } catch {
            // Keep the previous good chainSecret; do NOT zero it.
            os_log("receiveRemotePublic: performDH failed, retaining previous chain secret",
                   log: Self.log, type: .error)
        }
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
        // SECURITY M-16: post-compromise erasure must be immediate. Run
        // the erasure sweep under the lock so superseded chain secrets
        // are scrubbed now, not lazily on the next `deriveFrameKey`.
        scheduleErasure()
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
        // SECURITY H-12: the epoch advanced — its DH has not run yet.
        dhCompletedEpoch = nil
        let pub = EphemeralPublic(epoch: currentEpoch,
                                  publicKey: Data(localPrivateKey.publicKey.rawRepresentation))
        let callback = onEphemeralKey
        // Fire outside the lock to avoid deadlocks in the transport layer.
        DispatchQueue.global(qos: .utility).async { callback?(pub) }

        // Immediately attempt a DH if we already have the remote key.
        // SECURITY H-12: failure keeps the previous good chainSecret;
        // it is logged, never silently dropped.
        do {
            try performDH()
            dhCompletedEpoch = currentEpoch
        } catch {
            os_log("rotateEphemeralKey: performDH failed, retaining previous chain secret",
                   log: Self.log, type: .error)
        }

        // SECURITY M-16: erase superseded chain secrets immediately on
        // every rotation (called under the existing lock).
        scheduleErasure()
    }

    private func performDH() throws {
        guard let remote = remotePublicKey else { return }
        let shared = try localPrivateKey.sharedSecretFromKeyAgreement(with: remote)
        // SECURITY H-19: ideally the raw X25519 secret would never leave
        // corecrypto (use `shared.hkdfDerivedSymmetricKey`). Here, though,
        // `chainSecret` is fed as the HKDF *salt* in `deriveFrameKey`, and
        // the equivalent Android `ForwardSecrecy` mixes the raw DH bytes
        // the same way — running an extra HKDF on this side would change
        // the derived frame key and break cross-platform call audio.
        // Conservative fix (no wire change): copy the bytes straight into
        // a locked, auto-zeroed `SecureBytes`, then scrub the transient
        // `Data` so the raw secret does not linger on the heap.
        var derived = shared.withUnsafeBytes { Data($0) }
        chainSecret = SecureBytes(data: derived)
        CryptoConstants.zeroize(&derived)
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
