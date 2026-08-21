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
    // DISPLAY-ONLY: human name, method label, and fingerprint of the
    // sovereign/KMS PSK that was mixed into the session key. Optional —
    // bound via the extended `bind(...)` overload; nil-safe so existing
    // behaviour is unchanged when they are not supplied.
    private var setPskName: ((String) -> Void)?
    private var setPskMethod: ((String) -> Void)?
    private var setPskFingerprint: ((String) -> Void)?
    /// Items 2 + 5 (2026-07-31 InCallScreen Android→iOS port) — fired at the
    /// end of `registerPqcSessionKey`, i.e. the single point every
    /// handshake-completion path (caller, responder, PSK-metadata variant)
    /// already converges on, mirroring Android's `CallController.onConnected`.
    /// AppState uses it to kick off auto voice-enrollment
    /// (`maybeAutoStartVoiceLearning`) and the VOICE_KEY announce loop
    /// (`startVoiceKeyAnnounceLoop`) — see `AppState.handleCallSessionEstablished`.
    private var onSessionEstablished: ((String) -> Void)?

    public init() {}

    /// Bind the broker to AppState via closures so the type system
    /// never sees AppState in a function-parameter position.
    /// Idempotent — re-binding replaces the previous closures.
    func bind(
        getCallContactId: @escaping () -> String?,
        setSessionKey: @escaping (Data) -> Void,
        setPskActive: @escaping (Bool) -> Void,
        setPskName: ((String) -> Void)? = nil,
        setPskMethod: ((String) -> Void)? = nil,
        setPskFingerprint: ((String) -> Void)? = nil,
        onSessionEstablished: ((String) -> Void)? = nil
    ) {
        self.getCallContactId = getCallContactId
        self.setSessionKey = setSessionKey
        self.setPskActive = setPskActive
        self.setPskName = setPskName
        self.setPskMethod = setPskMethod
        self.setPskFingerprint = setPskFingerprint
        self.onSessionEstablished = onSessionEstablished
    }

    /// DISPLAY-ONLY variant of ``registerPqcSessionKey(_:for:)`` that also
    /// records the negotiated sovereign/KMS PSK metadata for the in-call
    /// "CHIAVE IN USO" panel. Same security posture: pipes values, never
    /// derives. `pskFingerprint == nil` ⇒ no PSK was mixed ⇒ the PSK row
    /// stays hidden (we clear name/method/fp and leave `pskActive` driven
    /// by the session key just like the base method). Never throws, never
    /// gates the call.
    public func registerPqcSessionKeyWithPsk(
        _ sharedSecret: Data,
        for peerId: String,
        pskFingerprint: String?,
        pskName: String?,
        pskMethod: String?,
        retriesLeft: Int = CallSessionKeyBroker.sessionKeyRetryMaxAttempts
    ) {
        // Reuse the validated base path for the session-key swap + SAS notify
        // (it has its own internal retry for the same callContactId race).
        registerPqcSessionKey(sharedSecret, for: peerId)
        // The base method's retry is async, so `callContactId` may still be
        // unset here on the FIRST pass even when it will resolve moments
        // later — retry this guard too (display-only metadata, same bounded
        // window) rather than silently losing the PSK row for a call the
        // base method's retry goes on to accept.
        guard let currentPeer = getCallContactId?(), currentPeer == peerId else {
            guard retriesLeft > 0 else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.sessionKeyRetryIntervalNs)
                self?.registerPqcSessionKeyWithPsk(
                    sharedSecret, for: peerId,
                    pskFingerprint: pskFingerprint, pskName: pskName, pskMethod: pskMethod,
                    retriesLeft: retriesLeft - 1)
            }
            return
        }
        guard sharedSecret.count == 32 else { return }
        if let fp = pskFingerprint, !fp.isEmpty {
            setPskFingerprint?(fp)
            if let name = pskName, !name.isEmpty { setPskName?(name) } else { setPskName?("") }
            if let method = pskMethod, !method.isEmpty { setPskMethod?(method) } else { setPskMethod?("") }
        } else {
            // No PSK mixed — clear any leftover metadata from a prior call.
            setPskFingerprint?("")
            setPskName?("")
            setPskMethod?("")
        }
    }

    /// Bounded retry window for the "callContactId not set yet" race below
    /// — same TTL-bounded, fail-closed philosophy as `AppState`'s own
    /// `bufferOfferReplay`/`drainPendingOfferReplays` for the identical race
    /// class (a value legitimately arriving before `callContactId` is
    /// wired). 10 × 200ms = 2s, generous for a same-thread-hop UI-state
    /// race, short enough that a call that's genuinely wrong/stale just
    /// drops as before.
    // internal, not private — used as a default argument value on two
    // `public func`s below; Swift evaluates default-arg expressions at the
    // call site, so anything less than `internal` fails to compile for a
    // caller outside this file (confirmed by the real CI failure this fixes:
    // "static property 'sessionKeyRetryMaxAttempts' is private and cannot be
    // referenced from a default argument value").
    static let sessionKeyRetryMaxAttempts = 10
    private static let sessionKeyRetryIntervalNs: UInt64 = 200_000_000

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
    ///   - retriesLeft: internal — do not pass explicitly.
    public func registerPqcSessionKey(_ sharedSecret: Data, for peerId: String, retriesLeft: Int = CallSessionKeyBroker.sessionKeyRetryMaxAttempts) {
        guard let currentPeer = getCallContactId?() else {
            // I3-adjacent (2026-08-21) — confirmed live: a callee answering
            // from background (CallKit/PushKit wake) can complete the PQC
            // handshake and deliver the real session key here BEFORE
            // AppState finishes assigning `callContactId` for the new call
            // — this guard used to silently drop the key with no log, no
            // retry. Audio still started (a separate path,
            // onRelaySessionReady, doesn't depend on this), but
            // setSessionKey/sasReadyNotification/onSessionEstablished never
            // fired, so SAS words never appeared and reKeyScheduler.start()
            // (fired from onSessionEstablished) never ran — the call
            // eventually timed out. Bounded retry instead of an unbounded
            // wait or a silent drop: same fail-closed-after-a-window
            // discipline as bufferOfferReplay, just polling instead of
            // being replay-triggered (this class has no hook into every
            // `callContactId = ...` assignment site in AppState).
            guard retriesLeft > 0 else {
                print("[CallSessionKeyBroker] callContactId never became available for " + peerId + " after retry window — dropping PQC session key (SAS will not appear, call may stall)")
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.sessionKeyRetryIntervalNs)
                self?.registerPqcSessionKey(sharedSecret, for: peerId, retriesLeft: retriesLeft - 1)
            }
            return
        }
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
        // Items 2 + 5 — see `onSessionEstablished`'s doc. Fired AFTER the
        // guards above have already confirmed this is a genuine, current,
        // valid-length key for the call actually in progress.
        onSessionEstablished?(peerId)
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
