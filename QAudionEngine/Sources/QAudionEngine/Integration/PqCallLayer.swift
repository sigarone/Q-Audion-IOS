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
/// the same), the anchor of the call (what round 1 proved about the peer) and the last rekey round this side refused. Bounded without evicting, and
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

    /// The most calls each table keeps. A call's entry is never evicted to make room for another call's: a flood of bundles of
    /// other call ids (each can set state) must not be able to remove what the live call needs, so at the bound a NEW entry is
    /// dropped instead (`overflowed` then says so) and a missing anchor is read as a refusal. Everything is cleared with the call.
    static let stateCapacity = 1024

    private struct Table<V> {
        var items: [String: V] = [:]
        var overflowed = false

        mutating func set(_ key: String, _ value: V) {
            if items[key] == nil && items.count >= PqCallLayer.stateCapacity {
                overflowed = true
                return
            }
            items[key] = value
        }
    }

    private let lock = NSLock()
    private var own = Table<OwnMode>()
    private var anchors = Table<Anchor>()
    private var roundKeys = Table<Pqsig.MlDsaPublicKey>()
    private var refusals = Table<Refusal>()

    // MARK: - State

    func ownMode(callId: String) -> OwnMode? {
        lock.lock()
        defer { lock.unlock() }
        return own.items[callId.lowercased()]
    }

    /// One slot per call; another call's bundle never overwrites or evicts the live call's sender rule.
    func setOwn(callId: String, plan: PqSigPlan, sent: Bool) {
        lock.lock()
        own.set(callId.lowercased(), OwnMode(plan: plan, sent: sent))
        lock.unlock()
    }

    func anchor(callId: String) -> Anchor? {
        lock.lock()
        defer { lock.unlock() }
        return anchors.items[callId.lowercased()]
    }

    /// True once an anchor had to be dropped for lack of room: a call whose anchor is missing then cannot be told from one that lost it.
    var anchorsOverflowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return anchors.overflowed
    }

    func setAnchor(callId: String, _ anchor: Anchor) {
        lock.lock()
        anchors.set(callId.lowercased(), anchor)
        lock.unlock()
    }

    func clearAnchor(callId: String) {
        lock.lock()
        anchors.items.removeValue(forKey: callId.lowercased())
        lock.unlock()
    }

    /// The second public key round 1 of the call verified under: rekey rounds are checked against it, not against the evictable
    /// store of peer keys.
    func round1Key(callId: String) -> Pqsig.MlDsaPublicKey? {
        lock.lock()
        defer { lock.unlock() }
        return roundKeys.items[callId.lowercased()]
    }

    func setRound1Key(callId: String, _ key: Pqsig.MlDsaPublicKey) {
        lock.lock()
        roundKeys.set(callId.lowercased(), key)
        lock.unlock()
    }

    func refusal(callId: String) -> Refusal? {
        lock.lock()
        defer { lock.unlock() }
        return refusals.items[callId.lowercased()]
    }

    func noteRefusal(callId: String, round: Int, reason: PqWarnReason) {
        lock.lock()
        refusals.set(callId.lowercased(), Refusal(round: round, reason: reason))
        lock.unlock()
    }

    func reset() {
        lock.lock()
        own = Table<OwnMode>()
        anchors = Table<Anchor>()
        roundKeys = Table<Pqsig.MlDsaPublicKey>()
        refusals = Table<Refusal>()
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

        // The 24 KiB rule, on the frame this app writes.
        func fits(_ candidate: AndroidHandshakeBundle) -> Bool {
            OpaqueFrameRule.fits(payload: AndroidHandshakeEnvelope.serialize(callId: callId, bundle: candidate))
        }
        // What is given up first when a bundle that carries the key-exchange member of the outer relay layer does not fit: that member,
        // and in round 1 also the two tags (the bundle then reads as one of a build without the layer, and the call uses the older
        // outer layer); in a rekey the member only (its tags must equal those of round 1). The second signature is never given up
        // for it. Every way out of this function goes through the same rule.
        func givingUpRelay(_ candidate: AndroidHandshakeBundle) -> AndroidHandshakeBundle {
            round == 1 ? candidate.withoutRelay() : candidate.with(relayKem: nil)
        }
        func fitted(_ candidate: AndroidHandshakeBundle) -> AndroidHandshakeBundle {
            if candidate.relayKem != nil, !fits(candidate) { return givingUpRelay(candidate) }
            return candidate
        }

        func fail(_ why: String) throws -> AndroidHandshakeBundle {
            CapsBindLog.line("pq sign=0 round=\(round) why=\(why) sent=\(mustSign ? 0 : 1)")
            if mustSign { throw LayerError.roundNotSent }
            setOwn(callId: callId, plan: .off, sent: false)
            return fitted(Self.stripped(bundle))
        }

        guard let runtime, plan != .off else {
            if sticky == nil { setOwn(callId: callId, plan: .off, sent: false) }
            let plain = fitted(Self.stripped(bundle))
            // the size rule is checked on every send, signed or not
            if !OpaqueFrameRule.fits(payload: AndroidHandshakeEnvelope.serialize(callId: callId, bundle: plain)) {
                CapsBindLog.line("pq size=over round=\(round) signed=0")
            }
            return plain
        }
        guard let signer = runtime.makeSigner() else { return try fail("no_key") }
        let withdrawn: [String]? = plan == .withdraw ? [HybridSigPolicy.tag] : nil
        let keyIdB64 = signer.keyId.base64EncodedString()
        // CAPSX and EXTX are computed from the bundle exactly as it will be sent, so a bundle that gives up the member is signed
        // again from its reduced form.
        func signWork(_ base: AndroidHandshakeBundle) -> (work: AndroidHandshakeBundle, failure: String?) {
            var caps = (base.capabilities ?? AndroidHandshakeBundle.Capabilities(ratchetV3: false)).with(sigHybridV1: nil)
            if plan == .advertise {
                // the tag requires `capsBindV1` in the same bundle
                guard caps.capsBindV1 == true else { return (base, "no_capsbind") }
                caps = caps.with(sigHybridV1: true)
            }
            let unsignedWork = base.withSecondSignature(capabilities: caps, mldsaKeyId: keyIdB64, sigHybrid: nil, capsWithdrawn: withdrawn)
            if runtime.forceSignFailure?() == true { return (base, "hook") }
            let ownInfo = CapsBind.analyze(bundle: unsignedWork)
            guard let sig = signer.sign(kind: kind, transcript: transcript, dtlsFpSelf: fpSelf, dtlsFpPeer: fpPeer,
                                        capsx: ownInfo.capsx, extx: ownInfo.extx) else { return (base, "sign") }
            let signedWork = unsignedWork.withSecondSignature(capabilities: caps, mldsaKeyId: keyIdB64,
                                                              sigHybrid: sig.base64EncodedString(), capsWithdrawn: withdrawn)
            return (signedWork, nil)
        }
        var attempt = signWork(bundle)
        if let why = attempt.failure { return try fail(why) }
        if bundle.relayKem != nil, !fits(attempt.work) {
            attempt = signWork(givingUpRelay(bundle))
            if let why = attempt.failure { return try fail(why) }
        }
        guard fits(attempt.work) else { return try fail("size") }
        setOwn(callId: callId, plan: plan, sent: true)
        return attempt.work
    }

    // MARK: - Words of the protection line

    /// `auth=`, `pqstate=`, `pq_sig=`, `rekey=` and `round=` for a call (empty means no word).
    func lineWords(callId: String, pqState: String?) -> (auth: String, pqstate: String, pqSig: String, rekey: String, round: String) {
        let a = anchor(callId: callId)
        let r = refusal(callId: callId)
        return (a?.auth ?? "", pqState ?? "", a?.result ?? "", r != nil ? "refused" : "", r.map { String($0.round) } ?? "")
    }
}
