import Foundation
#if canImport(WebRTC)
import WebRTC
#endif

/// Per-call DTLS state of a 1:1 call (WIRE_SPEC §3.8): the call's own explicit ECDSA P-256
/// certificate, its fingerprint, and the fingerprint of the PEER's certificate once the signed
/// handshake bundle has been verified and the fingerprint pinned.
///
/// **Why a context object.** The signed handshake (`QAudionCallIntegration`) needs the own
/// fingerprint BEFORE it signs anything, which is before any PeerConnection exists (the caller
/// signs its OFFER first; the callee signs its ACCEPT possibly while only a ring-time PC exists).
/// The PeerConnection must then present exactly that certificate. So the certificate is generated
/// once per call, here, and shared by id: the handshake reads the fingerprint, the PeerConnection
/// takes the certificate (`RTCConfiguration.certificate`) and the pinned peer fingerprint (checks
/// (a) SDP and (b) stats).
///
/// The certificate is never reused across calls, which keeps calls unlinkable (F3).
///
/// **Peer fingerprint pin.** `pinPeer` is called by the handshake once per call; a later bundle
/// (a re-key round) that carries a DIFFERENT fingerprint is a `conflict` and ends the call (F9).
/// Work that must not run before the pin — applying a remote SDP — registers with
/// `whenPeerPinned` and is run (once, in order) when the pin arrives, or immediately if it already
/// has.
public final class CallDtlsContext: @unchecked Sendable {

    public enum PinResult: Equatable {
        /// First pin of this call.
        case pinned
        /// Same fingerprint as already pinned (a retransmit, or a re-key round).
        case unchanged
        /// A different fingerprint than the pinned one: the call must end.
        case conflict
    }

    /// The call id exactly as the first user of the context wrote it (the signed handshake's call
    /// id string; not case-normalised).
    public let callId: String
    /// This side's own fingerprint: `u8(alg=1) || SHA-256(DER certificate)` (33 bytes).
    public let fingerprint: Data

    #if canImport(WebRTC)
    /// The certificate to put in `RTCConfiguration.certificate`. `nil` only for a fingerprint-only
    /// test context, which a PeerConnection refuses.
    public let certificate: RTCCertificate?
    #endif

    private let lock = NSLock()
    private var peer: Data?
    private var waiters: [(Data) -> Void] = []

    #if canImport(WebRTC)
    init(callId: String, certificate: RTCCertificate?, fingerprint: Data) {
        self.callId = callId
        self.certificate = certificate
        self.fingerprint = fingerprint
    }
    #else
    init(callId: String, fingerprint: Data) {
        self.callId = callId
        self.fingerprint = fingerprint
    }
    #endif

    /// The pinned peer fingerprint, once the handshake pinned it.
    public var peerFingerprint: Data? {
        lock.lock(); defer { lock.unlock() }
        return peer
    }

    /// Pin the peer's fingerprint (33 bytes, `DtlsFingerprint.isWellFormedBinary`). Runs the
    /// registered waiters when this is the first pin.
    @discardableResult
    public func pinPeer(_ fp: Data) -> PinResult {
        guard DtlsFingerprint.isWellFormedBinary(fp) else { return .conflict }
        lock.lock()
        if let existing = peer {
            lock.unlock()
            return existing == fp ? .unchanged : .conflict
        }
        peer = fp
        let ready = waiters
        waiters = []
        lock.unlock()
        for waiter in ready { waiter(fp) }
        return .pinned
    }

    /// Run `body` with the peer fingerprint: immediately when it is already pinned, otherwise
    /// when `pinPeer` first succeeds. Waiters run in registration order.
    public func whenPeerPinned(_ body: @escaping (Data) -> Void) {
        lock.lock()
        if let fp = peer {
            lock.unlock()
            body(fp)
            return
        }
        waiters.append(body)
        lock.unlock()
    }
}

/// Process-wide registry of the per-call `CallDtlsContext`s, keyed by the lowercased call id.
///
/// **Lifetime (R-CERT).** A call's certificate is pinned for the whole call. A context becomes
/// *live* when a PeerConnection is bound to it (`hold`) and *signed* when its fingerprint was read
/// for a handshake bundle (`fingerprint(forCallId:)`); live contexts are never evicted, whatever
/// number of other calls' OFFERs arrive meanwhile, until `release` (the call ended). Only the last
/// few NOT-live contexts (an OFFER that is merely ringing) are retained, evicted by insertion
/// order. A call id whose context was signed is never given a second certificate: once it is
/// released (or dropped by the safety cap) the id is retired and `context(forCallId:)` answers
/// `nil` for it, so a late re-key can never sign a different fingerprint than the one the peer
/// pinned (which would end the call with `dtls_fp_mismatch`).
public final class CallDtlsContextStore: @unchecked Sendable {
    public static let shared = CallDtlsContextStore()

    private let lock = NSLock()
    private var byCall: [String: CallDtlsContext] = [:]
    /// Registry keys in insertion order.
    private var order: [String] = []
    /// Keys protected from eviction (a call in progress), in the order they were held.
    private var live: [String] = []
    /// Keys whose fingerprint was read for a bundle (they have signed, or are about to).
    private var signed: Set<String> = []
    /// Signed call ids that no longer have a context: never regenerated.
    private var retired: Set<String> = []
    private var retiredOrder: [String] = []

    /// Not-live contexts kept (ringing OFFERs).
    static let retained = 4
    /// Safety cap on live contexts, in case a call end is never reported.
    static let liveCap = 8
    /// Retired call ids remembered.
    static let retiredCap = 256

    private let generator: (String) -> CallDtlsContext?

    public init() {
        self.generator = { CallDtlsContextStore.generate(callId: $0) }
    }

    /// Tests: a generator that does not need the WebRTC binary.
    init(generator: @escaping (String) -> CallDtlsContext?) {
        self.generator = generator
    }

    /// The context of `callId`, generating the call's certificate on first use. `nil` when the
    /// certificate cannot be generated (or on a host without WebRTC), or when the call id already
    /// signed with a certificate that is gone — the caller must then fail the call: a 1:1 call
    /// without its pinned certificate is never set up.
    public func context(forCallId callId: String) -> CallDtlsContext? {
        let key = callId.lowercased()
        guard !key.isEmpty else { return nil }
        lock.lock()
        if let existing = byCall[key] {
            lock.unlock()
            return existing
        }
        if retired.contains(key) {
            lock.unlock()
            return nil
        }
        lock.unlock()
        // The context keeps the call id EXACTLY as the caller of `context(forCallId:)` spelled it
        // (the frame keys of WIRE_SPEC 3.7.2 are derived from the exact transcript string); only
        // the registry key is lower-cased.
        guard let created = generator(callId) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let raced = byCall[key] { return raced }
        if retired.contains(key) { return nil }
        byCall[key] = created
        order.append(key)
        evictIfNeeded()
        return created
    }

    /// The call's own fingerprint (33 bytes), generating the certificate on first use. Reading it
    /// is what the signed handshake does, so it marks the call id as signed AND live: from here on
    /// the context is never evicted and never regenerated.
    public func fingerprint(forCallId callId: String) -> Data? {
        guard let ctx = context(forCallId: callId) else { return nil }
        let key = callId.lowercased()
        lock.lock()
        signed.insert(key)
        holdLocked(key)
        lock.unlock()
        return ctx.fingerprint
    }

    /// Keep the context of `callId` (a PeerConnection of the call is bound to it) until `release`.
    public func hold(callId: String) {
        let key = callId.lowercased()
        guard !key.isEmpty else { return }
        lock.lock()
        holdLocked(key)
        lock.unlock()
    }

    /// The call ended: drop its context. A call id that had signed is retired (never regenerated).
    public func release(callId: String) {
        let key = callId.lowercased()
        guard !key.isEmpty else { return }
        lock.lock()
        dropLocked(key)
        lock.unlock()
    }

    /// The context of `callId` if one exists; never generates.
    public func existing(forCallId callId: String) -> CallDtlsContext? {
        lock.lock(); defer { lock.unlock() }
        return byCall[callId.lowercased()]
    }

    /// Forget every context (tests).
    func removeAll() {
        lock.lock()
        byCall.removeAll()
        order.removeAll()
        live.removeAll()
        signed.removeAll()
        retired.removeAll()
        retiredOrder.removeAll()
        lock.unlock()
    }

    // MARK: - Locked helpers (the lock is held)

    private func holdLocked(_ key: String) {
        guard byCall[key] != nil, !live.contains(key) else { return }
        live.append(key)
        while live.count > Self.liveCap {
            // The oldest hold that never signed goes first; a signed call is only ever dropped
            // when every live context has signed (a pathological number of simultaneous calls).
            let victim = live.first(where: { !signed.contains($0) }) ?? live[0]
            dropLocked(victim)
        }
    }

    private func dropLocked(_ key: String) {
        byCall.removeValue(forKey: key)
        order.removeAll { $0 == key }
        live.removeAll { $0 == key }
        if signed.remove(key) != nil {
            retired.insert(key)
            retiredOrder.append(key)
            while retiredOrder.count > Self.retiredCap {
                retired.remove(retiredOrder.removeFirst())
            }
        }
    }

    private func evictIfNeeded() {
        // Only contexts that are not live count against the retention window.
        var notLive = order.filter { !live.contains($0) }
        while notLive.count > Self.retained {
            let victim = notLive.removeFirst()
            dropLocked(victim)
        }
    }

    private static func generate(callId: String) -> CallDtlsContext? {
        #if canImport(WebRTC)
        // ECDSA P-256 (the libwebrtc default key type), explicit per call. `expires` is chosen to
        // be valid whether the binding reads it in seconds or milliseconds.
        let params: [String: Any] = ["name": "ECDSA", "expires": NSNumber(value: 30_000_000)]
        guard let cert = RTCCertificate.generate(withParams: params),
              let fp = DtlsFingerprint.fromPem(cert.certificate) else {
            return nil
        }
        return CallDtlsContext(callId: callId, certificate: cert, fingerprint: fp)
        #else
        return nil
        #endif
    }
}
