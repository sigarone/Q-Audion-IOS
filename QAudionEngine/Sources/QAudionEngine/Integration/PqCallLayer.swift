import Foundation

/// What the call integration needs from the app to sign and to check the second signature of a handshake. Without it the tag is
/// never advertised and nothing is signed or judged.
public struct PqSigRuntime: Sendable {
    /// This device already published its second key: the tag may be advertised and every bundle is signed. The server flag that
    /// stops new publications is not an input (see `PqSigAvailability`).
    public var isAvailable: @Sendable () -> Bool
    /// The signer of this device, built from the identity seed for one bundle; nil when the key cannot be derived.
    public var makeSigner: @Sendable () -> HybridBundleSigner?
    /// The second public key of that peer device whose certificate verified against `signerEdPub` (the Ed25519 key that verified
    /// the round's `sigV6`), the peer uuid and the sending device id, with that key id; nil if there is none.
    public var resolvePeerKey: @Sendable (_ peerUserId: String, _ deviceId: String?, _ signerEdPub: Data, _ keyId: Data) async -> Pqsig.MlDsaPublicKey?
    /// Fetch the peer's identity bundles ahead of the handshake. Never throws, never blocks a call.
    public var prefetch: (@Sendable (_ peerUserId: String) -> Void)?
    /// Test hook: make this side's signing fail. Production never sets it.
    public var forceSignFailure: (@Sendable () -> Bool)?

    public init(
        isAvailable: @escaping @Sendable () -> Bool,
        makeSigner: @escaping @Sendable () -> HybridBundleSigner?,
        resolvePeerKey: @escaping @Sendable (_ peerUserId: String, _ deviceId: String?, _ signerEdPub: Data, _ keyId: Data) async -> Pqsig.MlDsaPublicKey?,
        prefetch: (@Sendable (_ peerUserId: String) -> Void)? = nil,
        forceSignFailure: (@Sendable () -> Bool)? = nil
    ) {
        self.isAvailable = isAvailable
        self.makeSigner = makeSigner
        self.resolvePeerKey = resolvePeerKey
        self.prefetch = prefetch
        self.forceSignFailure = forceSignFailure
    }
}

/// The per-call state of the second handshake signature: what this side did with it in round 1 (a rekey bundle of the call does
/// the same), the anchor of the call (what round 1 proved about the peer) and the last rekey round this side refused. Bounded, and
/// cleared with the call. The pin records live in `CapsPinBook` and are never touched here.
final class PqCallLayer: @unchecked Sendable {

    enum LayerError: Error, Equatable {
        /// A rekey bundle that has to carry the signature could not be signed: it is not sent.
        case roundNotSent
    }

    struct OwnMode: Equatable {
        var plan: PqSigPlan
        var sent: Bool
    }

    /// What round 1 proved on this side: `H` when the peer's signature was valid under `keyId`.
    struct Anchor: Equatable {
        var auth: String
        var keyId: String?
        var result: String
    }

    struct Refusal: Equatable {
        var round: Int
        var reason: PqWarnReason
    }

    static let ownCapacity = 8
    static let anchorCapacity = 16
    static let refusalCapacity = 8

    private let lock = NSLock()
    private var own: [String: OwnMode] = [:]
    private var ownOrder: [String] = []
    private var anchors: [String: Anchor] = [:]
    private var anchorOrder: [String] = []
    private var refusals: [String: Refusal] = [:]
    private var refusalOrder: [String] = []

    // MARK: - State

    func ownMode(callId: String) -> OwnMode? {
        lock.lock()
        defer { lock.unlock() }
        return own[callId.lowercased()]
    }

    /// One slot per call; another call's bundle never overwrites the live call's sender rule.
    func setOwn(callId: String, plan: PqSigPlan, sent: Bool) {
        let key = callId.lowercased()
        lock.lock()
        if own[key] == nil { ownOrder.append(key) }
        own[key] = OwnMode(plan: plan, sent: sent)
        while ownOrder.count > Self.ownCapacity {
            own.removeValue(forKey: ownOrder.removeFirst())
        }
        lock.unlock()
    }

    func anchor(callId: String) -> Anchor? {
        lock.lock()
        defer { lock.unlock() }
        return anchors[callId.lowercased()]
    }

    func setAnchor(callId: String, _ anchor: Anchor) {
        let key = callId.lowercased()
        lock.lock()
        if anchors[key] == nil { anchorOrder.append(key) }
        anchors[key] = anchor
        while anchorOrder.count > Self.anchorCapacity {
            anchors.removeValue(forKey: anchorOrder.removeFirst())
        }
        lock.unlock()
    }

    func clearAnchor(callId: String) {
        let key = callId.lowercased()
        lock.lock()
        anchors.removeValue(forKey: key)
        anchorOrder.removeAll { $0 == key }
        lock.unlock()
    }

    func refusal(callId: String) -> Refusal? {
        lock.lock()
        defer { lock.unlock() }
        return refusals[callId.lowercased()]
    }

    func noteRefusal(callId: String, round: Int, reason: PqWarnReason) {
        let key = callId.lowercased()
        lock.lock()
        if refusals[key] == nil { refusalOrder.append(key) }
        refusals[key] = Refusal(round: round, reason: reason)
        while refusalOrder.count > Self.refusalCapacity {
            refusals.removeValue(forKey: refusalOrder.removeFirst())
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        own.removeAll()
        ownOrder.removeAll()
        anchors.removeAll()
        anchorOrder.removeAll()
        refusals.removeAll()
        refusalOrder.removeAll()
        lock.unlock()
    }

    // MARK: - Own bundles

    /// The bundle without any member of the second signature.
    static func stripped(_ bundle: AndroidHandshakeBundle) -> AndroidHandshakeBundle {
        bundle.withSecondSignature(capabilities: bundle.capabilities?.with(sigHybridV1: nil), mldsaKeyId: nil, sigHybrid: nil,
                                   capsWithdrawn: nil)
    }

    /// Finalizes the second-signature members of a bundle whose `sigV6` was just set, and signs it (design section 5.4).
    ///
    /// The tag (or, for a release that withdraws it, `capsWithdrawn`), `mldsaKeyId` and `sigHybrid` are set together; CAPSX and EXTX
    /// are computed from the bundle exactly as it will be sent. It never blocks a call: in round 1 a failure (no key, a failed
    /// signature, a bundle whose serialized frame would break the size rule) sends the bundle without any of them, and the peer
    /// judges it as an unsigned device. A rekey bundle of a call whose round 1 was signed MUST be signed too (the peer refuses it
    /// otherwise): there a failure throws `roundNotSent`, so the round is not sent (the next scheduled round retries; a rekey ACCEPT
    /// that cannot be signed is never sent, so the offerer abandons that round).
    func finalizeOwn(
        bundle: AndroidHandshakeBundle, kind: UInt8, round: Int, callId: String, transcript: Data, fpSelf: Data, fpPeer: Data?,
        runtime: PqSigRuntime?, capsBindEnabled: Bool, planOverride: PqSigPlan? = nil
    ) throws -> AndroidHandshakeBundle {
        let sticky: OwnMode? = round > 1 ? ownMode(callId: callId) : nil
        // `planOverride` is for tests only: no production code passes it (a test scans the sources for that).
        let plan: PqSigPlan = planOverride ?? sticky?.plan ?? PqSigAvailability.plan(
            capsBindEnabled: capsBindEnabled, available: runtime?.isAvailable() ?? false)
        let mustSign = sticky?.sent == true

        func fail(_ why: String) throws -> AndroidHandshakeBundle {
            CapsBindLog.line("pq sign=0 round=\(round) why=\(why) sent=\(mustSign ? 0 : 1)")
            if mustSign { throw LayerError.roundNotSent }
            setOwn(callId: callId, plan: .off, sent: false)
            return Self.stripped(bundle)
        }

        guard let runtime, plan != .off else {
            if sticky == nil { setOwn(callId: callId, plan: .off, sent: false) }
            let plain = Self.stripped(bundle)
            // the size rule is checked on every send, signed or not
            if !OpaqueFrameRule.fits(payload: AndroidHandshakeEnvelope.serialize(callId: callId, bundle: plain)) {
                CapsBindLog.line("pq size=over round=\(round) signed=0")
            }
            return plain
        }
        guard let signer = runtime.makeSigner() else { return try fail("no_key") }
        var caps = (bundle.capabilities ?? AndroidHandshakeBundle.Capabilities(ratchetV3: false)).with(sigHybridV1: nil)
        if plan == .advertise {
            // the tag requires `capsBindV1` in the same bundle
            guard caps.capsBindV1 == true else { return try fail("no_capsbind") }
            caps = caps.with(sigHybridV1: true)
        }
        let withdrawn: [String]? = plan == .withdraw ? [HybridSigPolicy.tag] : nil
        let keyIdB64 = signer.keyId.base64EncodedString()
        let unsignedWork = bundle.withSecondSignature(capabilities: caps, mldsaKeyId: keyIdB64, sigHybrid: nil, capsWithdrawn: withdrawn)
        if runtime.forceSignFailure?() == true { return try fail("hook") }
        let ownInfo = CapsBind.analyze(bundle: unsignedWork)
        guard let sig = signer.sign(kind: kind, transcript: transcript, dtlsFpSelf: fpSelf, dtlsFpPeer: fpPeer,
                                    capsx: ownInfo.capsx, extx: ownInfo.extx) else { return try fail("sign") }
        let signedWork = unsignedWork.withSecondSignature(capabilities: caps, mldsaKeyId: keyIdB64,
                                                          sigHybrid: sig.base64EncodedString(), capsWithdrawn: withdrawn)
        // the 24 KiB rule, on the frame this app writes
        guard OpaqueFrameRule.fits(payload: AndroidHandshakeEnvelope.serialize(callId: callId, bundle: signedWork)) else {
            return try fail("size")
        }
        setOwn(callId: callId, plan: plan, sent: true)
        return signedWork
    }

    // MARK: - Words of the protection line

    /// `auth=`, `pqstate=`, `pq_sig=`, `rekey=` and `round=` for a call (empty means no word).
    func lineWords(callId: String, pqState: String?) -> (auth: String, pqstate: String, pqSig: String, rekey: String, round: String) {
        let a = anchor(callId: callId)
        let r = refusal(callId: callId)
        return (a?.auth ?? "", pqState ?? "", a?.result ?? "", r != nil ? "refused" : "", r.map { String($0.round) } ?? "")
    }
}
