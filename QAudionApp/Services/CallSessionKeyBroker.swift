import Foundation
import CryptoKit
import QAudionEngine

/// W375 — surface the real PQC session key into AppState for SAS.
///
/// The W369 transitional path seeds `AppState.callPqcSessionKey` from
/// the per-pair PSK at call setup. That works for cross-platform SAS
/// derivation (both peers hold the same PSK) but it's NOT the actual
/// ML-KEM-1024 session key produced by the call's PQC handshake.
///
/// This broker lets the call setup path register a callback that
/// fires once the ML-KEM handshake completes with the freshly-derived
/// 32-byte shared secret. The broker:
///   1. Re-seeds `AppState.callPqcSessionKey` with the real key.
///   2. Posts `Notification.Name("qaudion.call.sasReady")` so any UI
///      observer (LiveInCallScreen via TimelineView re-render, etc.)
///      picks up the new SAS words.
///   3. If a SAS verification is already stored for this peer under
///      the previous fingerprint, it gets auto-invalidated because
///      the new SAS words produce a different fingerprint
///      (W368 SasVerificationStore).
///
/// **Security note:** the broker doesn't compute keys — it just
/// pipes them. The actual derivation lives in
/// `QAudionCallIntegration.deriveHybridSessionKey` (ML-KEM-1024 +
/// X25519, schema :2) which is the security-critical path. The
/// broker is a "bind result to UI" adapter.
@MainActor
public final class CallSessionKeyBroker {

    public static let sasReadyNotification = Notification.Name("qaudion.call.sasReady")
    public static let shared = CallSessionKeyBroker()

    private var getCallContactId: (() -> String?)?
    private var setSessionKey: ((Data) -> Void)?
    private var setPskActive: ((Bool) -> Void)?

    public init() {}

    /// Bind the broker to AppState via closures so the type system
    /// never sees AppState in a function-parameter position.
    /// Idempotent — re-binding replaces the previous closures.
    func bind(
        getCallContactId: @escaping () -> String?,
        setSessionKey: @escaping (Data) -> Void,
        setPskActive: @escaping (Bool) -> Void
    ) {
        self.getCallContactId = getCallContactId
        self.setSessionKey = setSessionKey
        self.setPskActive = setPskActive
    }

    /// Call this from the PQC handshake completion path with the
    /// freshly-derived session key (output of
    /// `QAudionCallIntegration.deriveHybridSessionKey`).
    ///
    /// - Parameters:
    ///   - sharedSecret: 32-byte ML-KEM-derived session key.
    ///   - peerId: the peer this key is bound to. Used to keep
    ///             `AppState.callContactId` consistent — if the peer
    ///             changed mid-flight (unlikely but possible during a
    ///             call leg renegotiation), we ignore the late
    ///             arrival.
    public func registerPqcSessionKey(_ sharedSecret: Data, for peerId: String) {
        guard let currentPeer = getCallContactId?() else { return }
        guard currentPeer == peerId else {
            print("[CallSessionKeyBroker] late PQC key for " + peerId + " - current peer is " + currentPeer + "; ignoring")
            return
        }
        guard sharedSecret.count == 32 else {
            let len = String(describing: sharedSecret.count)
            print("[CallSessionKeyBroker] PQC session key wrong length: " + len)
            return
        }
        setSessionKey?(sharedSecret)
        setPskActive?(true)
        NotificationCenter.default.post(
            name: Self.sasReadyNotification,
            object: nil,
            userInfo: ["peerId": peerId])
    }

    /// Helper: derive a 32-byte session key from raw HKDF inputs.
    /// Mirrors Android's `HybridPqcKeyExchange.deriveSessionKey` —
    /// HKDF-SHA256 over a concatenation of the ML-KEM secret, X25519
    /// shared, and (optional) Secure Enclave shared.
    public static func deriveSessionKey(
        mlKemShared: Data,
        x25519Shared: Data,
        enclaveShared: Data = Data()
    ) -> Data {
        var ikm = Data()
        ikm.append(mlKemShared)
        ikm.append(x25519Shared)
        ikm.append(enclaveShared)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data("qaudion-call-session-v1".utf8),
            info: Data("q-audion-session-key".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
    }
}
