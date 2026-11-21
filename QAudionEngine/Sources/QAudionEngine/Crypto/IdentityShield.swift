import Foundation

// MARK: - The identity shield
//
// The single answer the call bar, the contact list, the contact detail, the chat surfaces and the car screen give to
// "is this the contact whose key I verified". Pure: no UI type, no store, no clock, no network. Every input is computed by
// the caller from the key that the call's handshake authenticated and from the key-bound verification record, and NEVER
// from the words of a call, from a per-call flag or from a contact-level boolean.
//
// This lives in the engine on purpose: `QAudionAppTests` is not compiled by the CI job that runs on every push and
// `QAudionEngineTests` is, so a rule that decides what a green shield means must be in the half the gate can see.
//
// Colours: pending grey, verified green, to verify purple, changed red.

public enum IdentityShield: Hashable, Sendable {
    case pending
    case verified
    case toVerify
    case changed

    /// Closed-vocabulary word of the `QA-SHIELD` log line.
    public var logWord: String {
        switch self {
        case .pending: return "pending"
        case .verified: return "verified"
        case .toVerify: return "to_verify"
        case .changed: return "changed"
        }
    }
}

/// How the durable record relates to the key a call was authenticated by.
///  - `.forKey`: a verification applies to exactly this key.
///  - `.otherKeySameDevice`: the pin of this device is a DIFFERENT key and a verification applies to that pin.
///  - `.none`: neither (never verified, or only another device is).
public enum KeyVerification: Equatable, Sendable {
    case none
    case forKey
    case otherKeySameDevice
}

/// Colour of a badge that is not the identity shield. `.grey` = not applicable, not connected or not known yet.
public enum ShieldTone: Equatable, Sendable {
    case grey
    case green
    case purple
    case amber
    case red
}

/// What round 1 of the call's handshake proved about the peer's identity key, tagged with the call it belongs to.
///  - `.pending`: no verdict yet.
///  - `.authenticated`: sigV6 of round 1 verified under `key` (the BUNDLE key, never the pin or a server key).
///  - `.noIdentity`: the verdict is known and the call carries no peer identity bundle at all.
///  - `.held`: an abort verdict. The media is held until the user confirms the words. `releasedAdopted` is true only after the
///    signer key of an `identity_unresolved` hold was adopted. `signerKey` is the bundle key of the round that raised the hold.
///  - `.lost`: a later round was verified under another key than the one the call was authenticated by.
public enum CallIdentityAuth: Equatable, Sendable {
    case pending
    case authenticated(callId: String, key: Data)
    case noIdentity(callId: String)
    case held(callId: String, code: String, releasedAdopted: Bool, signerKey: Data?)
    case lost(callId: String)

    /// The call this value belongs to (lowercased), `nil` for `.pending`.
    public var callIdOrNil: String? {
        switch self {
        case .pending: return nil
        case .authenticated(let id, _): return id.lowercased()
        case .noIdentity(let id): return id.lowercased()
        case .held(let id, _, _, _): return id.lowercased()
        case .lost(let id): return id.lowercased()
        }
    }

    /// The key this value stands on: the authenticated key, or the signer key of the hold.
    public var trackedKey: Data? {
        switch self {
        case .authenticated(_, let key): return key
        case .held(_, _, _, let signer): return signer
        default: return nil
        }
    }
}

/// How the identity key of a peer device relates to the verification the user did, for a pure decision.
/// `bindingTag` is the identity tag of the stored in-call confirmation, `verifiedFingerprintHex` the safety number the user
/// attested on the contact screen (or that an in-person ceremony wrote). Either one applies to a key when it was made for
/// exactly that key.
public struct IdentityVerificationRecord: Equatable, Sendable {
    public let bindingTag: String?
    public let verifiedFingerprintHex: String?

    public init(bindingTag: String?, verifiedFingerprintHex: String?) {
        self.bindingTag = bindingTag
        self.verifiedFingerprintHex = verifiedFingerprintHex
    }

    public static let empty = IdentityVerificationRecord(bindingTag: nil, verifiedFingerprintHex: nil)

    /// Does a stored verification apply to exactly `key`? Both halves are compared in constant time; an absent half
    /// never applies. `selfUserId` / `selfIdentityKey` are needed only for the safety-number half (it is the number of
    /// the pair of identities): without them that half does not apply.
    public func applies(to key: Data, selfUserId: String?, selfIdentityKey: Data?, peerUserId: String) -> Bool {
        guard key.count == 32 else { return false }
        var holds = false
        if let tag = bindingTag, !tag.isEmpty {
            let expected = SasBinding.identityTag(forPinnedKey: key)
            if SasBinding.constantTimeEquals(tag, expected) { holds = true }
        }
        if let recorded = verifiedFingerprintHex, !recorded.isEmpty,
           let selfUserId, let selfIdentityKey,
           let fp = SasPinVerification.fingerprintHex(
            selfUserId: selfUserId, selfIdentityKey: selfIdentityKey,
            peerUserId: peerUserId, peerIdentityKey: key) {
            if SasBinding.constantTimeEquals(recorded, fp) { holds = true }
        }
        return holds
    }
}

/// The two post-quantum facts a badge needs from the protection line of a call. `levelToken` is `PQ2`, `PQ2S`, `PQ1` or `CL`.
/// `auth` is `H` once the hybrid signature of the handshake verified; `pin` is the sticky-pin word (`anomaly` turns any
/// level amber).
public struct CallPqProtection: Equatable, Sendable {
    public let levelToken: String
    public let auth: String
    public let pin: String
    /// The call this protection line belongs to. A value of another call is never read for this one (`IdentityShieldRules.protection`).
    public let callId: String

    public init(levelToken: String, auth: String, pin: String, callId: String = "") {
        self.levelToken = levelToken
        self.auth = auth
        self.pin = pin
        self.callId = callId
    }
}

public enum IdentityShieldRules {

    public static let codeIdentityUnresolved = "identity_unresolved"
    public static let codeKeyMismatch = "identity_key_mismatch"
    public static let codeSigInvalid = "sig_invalid"
    public static let codeRatchetDowngrade = "ratchet_v5_downgrade"

    // MARK: Call-level shield

    /// The decision table (first match wins):
    ///  1. no verdict -> pending; 2. authLost -> changed; 3. any abort other than `identity_unresolved` -> changed, even after
    ///  the user released the media; 4. `identity_unresolved` not released -> toVerify; 5. `identity_unresolved` released by an
    ///  adopted signer key -> verified; 6. no key -> toVerify; 7. record forKey -> verified; 8. otherKeySameDevice -> changed;
    ///  9. otherwise toVerify. An unknown abort code is treated like a mismatch: red.
    public static func callShield(
        verdictKnown: Bool,
        abortCode: String?,
        releasedBySas: Bool,
        hasAuthKey: Bool,
        authLost: Bool,
        record: KeyVerification
    ) -> IdentityShield {
        if !verdictKnown { return .pending }
        if authLost { return .changed }
        if let code = abortCode, code != codeIdentityUnresolved { return .changed }
        if abortCode == codeIdentityUnresolved { return releasedBySas ? .verified : .toVerify }
        if !hasAuthKey { return .toVerify }
        switch record {
        case .forKey: return .verified
        case .otherKeySameDevice: return .changed
        case .none: return .toVerify
        }
    }

    /// `callShield` from the published state of one call. A value tagged with another call than `callId` counts as no
    /// verdict yet.
    public static func callShield(auth: CallIdentityAuth, callId: String, record: KeyVerification) -> IdentityShield {
        if let tag = auth.callIdOrNil, tag != callId.lowercased() { return .pending }
        switch auth {
        case .pending:
            return callShield(verdictKnown: false, abortCode: nil, releasedBySas: false, hasAuthKey: false, authLost: false, record: .none)
        case .authenticated:
            return callShield(verdictKnown: true, abortCode: nil, releasedBySas: false, hasAuthKey: true, authLost: false, record: record)
        case .noIdentity:
            return callShield(verdictKnown: true, abortCode: nil, releasedBySas: false, hasAuthKey: false, authLost: false, record: .none)
        case .held(_, let code, let adopted, _):
            return callShield(verdictKnown: true, abortCode: code, releasedBySas: adopted, hasAuthKey: false, authLost: false, record: .none)
        case .lost:
            return callShield(verdictKnown: true, abortCode: nil, releasedBySas: false, hasAuthKey: false, authLost: true, record: .none)
        }
    }

    /// How the stored verification relates to `authKey`, the key a call was authenticated by, for the device whose pin is
    /// `devicePin` (the key pinned for exactly this peer device; `nil` when none):
    ///  - `.forKey` when a verification applies to `authKey`;
    ///  - `.otherKeySameDevice` when the pin of this device is another key and a verification applies to that pin (the call is
    ///    authenticated by a key the user never verified while this device was verified for another one);
    ///  - `.none` otherwise (never verified, or only another device is: a new device is "to verify", not "changed").
    public static func keyVerification(
        authKey: Data,
        devicePin: Data?,
        record: IdentityVerificationRecord,
        selfUserId: String?,
        selfIdentityKey: Data?,
        peerUserId: String
    ) -> KeyVerification {
        if record.applies(to: authKey, selfUserId: selfUserId, selfIdentityKey: selfIdentityKey, peerUserId: peerUserId) {
            return .forKey
        }
        if let pin = devicePin, pin != authKey,
           record.applies(to: pin, selfUserId: selfUserId, selfIdentityKey: selfIdentityKey, peerUserId: peerUserId) {
            return .otherKeySameDevice
        }
        return .none
    }

    // MARK: Contact-level shield

    /// Contact-level shield (no call). `.pending` when no key is pinned yet; `.changed` when a verification applies to a pinned
    /// key and a change was recorded; `.verified` only when EVERY pinned key is verified (a device pinned later and never
    /// verified must not hide behind a verified one); `.toVerify` otherwise.
    public static func contactShield(
        pinnedKeys: [Data],
        record: IdentityVerificationRecord,
        selfUserId: String?,
        selfIdentityKey: Data?,
        peerUserId: String,
        pendingChange: Bool
    ) -> IdentityShield {
        let keys = pinnedKeys.filter { $0.count == 32 }
        if keys.isEmpty { return .pending }
        let flags = keys.map { record.applies(to: $0, selfUserId: selfUserId, selfIdentityKey: selfIdentityKey, peerUserId: peerUserId) }
        if pendingChange && flags.contains(true) { return .changed }
        return flags.allSatisfy { $0 } ? .verified : .toVerify
    }

    // MARK: Post-quantum shield, Massima sicurezza

    /// The protection line of THIS call: a value tagged with another call (a late value of the call that just ended) is no value yet,
    /// so the post-quantum shield stays grey and "Massima sicurezza" stays hidden until this call's own level arrives.
    public static func protection(_ value: CallPqProtection?, forCall callId: String) -> CallPqProtection? {
        guard let value, !callId.isEmpty, value.callId.lowercased() == callId.lowercased() else { return nil }
        return value
    }

    /// Colour of the post-quantum shield. Never green before a level exists; `pin == "anomaly"` turns any level amber; PQ2 and
    /// PQ2S are green; PQ1 and CL are amber.
    public static func pqcShield(_ protection: CallPqProtection?) -> ShieldTone {
        guard let p = protection else { return .grey }
        if p.pin == "anomaly" { return .amber }
        switch p.levelToken {
        case "PQ2", "PQ2S": return .green
        default: return .amber
        }
    }

    /// "Massima sicurezza", crypto only: verified identity, two post-quantum layers, a verified hybrid signature and no pin
    /// anomaly.
    public static func massimaSicurezza(shield: IdentityShield, protection: CallPqProtection?) -> Bool {
        guard shield == .verified, let p = protection else { return false }
        return p.levelToken == "PQ2" && p.auth == "H" && p.pin != "anomaly"
    }

    /// Closed-vocabulary pq word of the `QA-SHIELD` log line: `pending|pq2|pq|reduced|cl`.
    public static func pqLogWord(_ protection: CallPqProtection?) -> String {
        guard let p = protection else { return "pending" }
        switch p.levelToken {
        case "PQ2": return p.auth == "H" ? "pq2" : "pq"
        case "PQ2S": return "pq"
        case "PQ1": return "reduced"
        default: return "cl"
        }
    }

    /// The whole `QA-SHIELD` line. `callId` is cut to its first 8 characters; nothing else of the call is written.
    public static func logLine(callId: String, shield: IdentityShield, protection: CallPqProtection?) -> String {
        let short = String(callId.lowercased().filter { $0.isHexDigit }.prefix(8))
        let max = massimaSicurezza(shield: shield, protection: protection) ? "1" : "0"
        return "QA-SHIELD call=\(short) id=\(shield.logWord) pq=\(pqLogWord(protection)) max=\(max)"
    }
}

// MARK: - The state of a call's identity verdict

/// What one handshake round reported about the peer's identity key. Produced by the call integration at the place where the
/// verdict is acted on, consumed by `CallIdentityReducer`.
public struct IdentityVerdictReport: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// sigV6 verified under `key`, the bundle key.
        case authenticated(key: Data)
        /// An abort verdict. `signerKey` is the bundle key of the round. The two flags are only meaningful for
        /// `identity_key_mismatch` (proof of possession of the bundle key, and the bundle key is the key the server published for
        /// exactly this peer device in a fetch that succeeded for that device in this resolution).
        case held(code: String, signerKey: Data?, bundleSigValid: Bool, bundleKeyPublishedForDevice: Bool)
    }

    public let callId: String
    public let peerId: String
    public let deviceId: String?
    public let round: Int
    public let kind: Kind
    /// Identity of the handshake round that produced the report (the signature of the received bundle: distinct for every OFFER).
    /// A proof of possession is valid only for the round it was computed for: a replaced OFFER is another session.
    public let sessionTag: String

    public init(callId: String, peerId: String, deviceId: String?, round: Int, kind: Kind, sessionTag: String = "") {
        self.callId = callId
        self.peerId = peerId
        self.deviceId = deviceId
        self.round = round
        self.kind = kind
        self.sessionTag = sessionTag
    }

    /// True for the second report of an `identity_key_mismatch` round: the proof of possession, not a new verdict.
    public var isProofReport: Bool {
        if case .held(_, _, let sigValid, let published) = kind { return sigValid || published }
        return false
    }
}

/// A rotated key that confirming the words of THIS call may adopt. Created only from the verdict of this call's handshake
/// (never from a background lookup), tagged with the call, and dropped at the start and at the end of every call.
public struct IdentityRotationCandidate: Equatable, Sendable {
    public let callId: String
    public let peerId: String
    public let deviceId: String?
    public let key: Data

    public init(callId: String, peerId: String, deviceId: String?, key: Data) {
        self.callId = callId
        self.peerId = peerId
        self.deviceId = deviceId
        self.key = key
    }
}

/// What the proof of possession on an `identity_key_mismatch` hold found. Decided here, not at the call site, so the
/// "adoptable only with both proofs" rule is tested.
public enum MismatchProof {

    /// The outcome of the per-device fetch of the published key, as the handshake layer saw it.
    public enum DeviceFetch: Equatable, Sendable {
        /// The server answered with a key for exactly this device in this resolution.
        case key(Data)
        /// Anything else: not attempted (device id unknown), offline, timeout, 404, a cached value.
        case unavailable
    }

    /// `bundleSigValid`: sigV6 verified under the BUNDLE key and the bundle does not downgrade the ratchet
    /// (a downgrading bundle is never adoptable). `bundleKeyPublishedForDevice`: true only when the fetch for this device
    /// succeeded and returned byte-for-byte the bundle key.
    public static func evaluate(
        bundleKey: Data,
        sigVerifiedUnderBundleKey: Bool,
        advertisedRatchetV5: Bool,
        ratchetV5CapablePinned: Bool,
        deviceIdKnown: Bool,
        fetch: DeviceFetch
    ) -> (bundleSigValid: Bool, bundleKeyPublishedForDevice: Bool) {
        let downgrades = !advertisedRatchetV5 && ratchetV5CapablePinned
        var published = false
        if deviceIdKnown, case .key(let fetched) = fetch, fetched.count == 32, fetched == bundleKey { published = true }
        return (sigVerifiedUnderBundleKey && !downgrades, published)
    }
}

public enum CallIdentityReducer {

    /// Fold one round's report into the published state of the call.
    ///  - First verdict of a call: set from the report.
    ///  - Later round verified under another key than the one the call stands on (the authenticated key, or from the moment of the
    ///    hold the signer key of the hold): `.lost`, never "unknown" (H5). This does not wait for any asynchronous pin write.
    ///  - Later round with an abort other than `identity_unresolved` while the call is authenticated or released by an adopted key:
    ///    `.lost`.
    ///  - `.lost` is terminal for the call.
    public static func apply(_ report: IdentityVerdictReport, to current: CallIdentityAuth) -> CallIdentityAuth {
        let cid = report.callId.lowercased()
        // A report of another call than the one the state belongs to (a late round, a late proof of a call that ended) changes nothing:
        // the state of a call starts from `.pending` at the start of the call, never from another call's value.
        if let tag = current.callIdOrNil, tag != cid { return current }
        switch current {
        case .pending:
            return fresh(report, cid: cid)
        case .lost:
            return current
        case .noIdentity:
            return current
        case .authenticated, .held:
            break
        }
        // Round 1 again for a call that already has a verdict. A replaced, unanswered round-1 OFFER never gets here: the app resets the
        // state of the call BEFORE the replacing round is reported (`onUnansweredRound1Superseded`), so that round meets `.pending`.
        // Anything else is a second round-1 for an answered session: a proof of possession only completes the hold it follows; an
        // identical verdict changes nothing; a DIFFERENT verdict is never taken as the identity of the call (a late genuine OFFER must
        // not turn an attacker's hold green): the call is lost.
        if report.round <= 1 {
            if report.isProofReport { return current }
            switch (report.kind, current) {
            case (.authenticated(let key), .authenticated(_, let tracked)) where key == tracked:
                return current
            case (.held(let code, let signer, _, _), .held(_, let heldCode, _, let heldSigner)) where code == heldCode && signer == heldSigner:
                return current
            default:
                return .lost(callId: cid)
            }
        }
        switch report.kind {
        case .authenticated(let key):
            if let tracked = current.trackedKey, tracked != key { return .lost(callId: cid) }
            return current
        case .held(let code, let signerKey, _, _):
            if code == IdentityShieldRules.codeIdentityUnresolved {
                if let tracked = current.trackedKey, let signer = signerKey, tracked != signer { return .lost(callId: cid) }
                return current
            }
            switch current {
            case .authenticated:
                return .lost(callId: cid)
            case .held(_, _, let adopted, _):
                return adopted ? .lost(callId: cid) : current
            default:
                return current
            }
        }
    }

    private static func fresh(_ report: IdentityVerdictReport, cid: String) -> CallIdentityAuth {
        switch report.kind {
        case .authenticated(let key):
            return .authenticated(callId: cid, key: key)
        case .held(let code, let signerKey, _, _):
            return .held(callId: cid, code: code, releasedAdopted: false, signerKey: signerKey)
        }
    }

    /// The rotation candidate a first-round report allows: only an `identity_key_mismatch` hold whose bundle key signed sigV6 and
    /// is the key the server published for exactly this device. Everything else is release-only.
    public static func candidate(from report: IdentityVerdictReport) -> IdentityRotationCandidate? {
        guard report.round <= 1,
              case .held(let code, let signerKey, let sigValid, let published) = report.kind,
              code == IdentityShieldRules.codeKeyMismatch, sigValid, published,
              let key = signerKey, key.count == 32 else { return nil }
        return IdentityRotationCandidate(callId: report.callId.lowercased(), peerId: report.peerId, deviceId: report.deviceId, key: key)
    }

    /// Compare-and-set after an asynchronous adoption of the signer key of an `identity_unresolved` hold: the hold becomes
    /// "released by an adopted key" only if the state is STILL the hold of this call under exactly this key.
    public static func markReleasedAdopted(_ current: CallIdentityAuth, callId: String, signerKey: Data) -> CallIdentityAuth {
        guard case .held(let id, let code, _, let held) = current,
              id.lowercased() == callId.lowercased(),
              code == IdentityShieldRules.codeIdentityUnresolved,
              let held, held == signerKey else { return current }
        return .held(callId: id, code: code, releasedAdopted: true, signerKey: held)
    }

    /// Compare-and-set after an asynchronous adoption of a rotated key: the call becomes `.authenticated` under that key only if
    /// the state is STILL the `identity_key_mismatch` hold of this call under exactly this key. A `.lost` published while the
    /// adoption was awaited stays `.lost`.
    public static func adoptedRotation(_ current: CallIdentityAuth, candidate: IdentityRotationCandidate) -> CallIdentityAuth {
        guard case .held(let id, let code, _, let held) = current,
              id.lowercased() == candidate.callId.lowercased(),
              code == IdentityShieldRules.codeKeyMismatch,
              let held, held == candidate.key else { return current }
        return .authenticated(callId: id.lowercased(), key: candidate.key)
    }
}

// MARK: - Confirming the words

public enum SasPinOutcome: Equatable, Sendable {
    case pinned
    case alreadyPinned
    case conflict
    case unavailable
}

public enum SasConfirmPolicy {

    /// What confirming the words of this call does.
    public enum Action: Equatable, Sendable {
        /// Record the confirmation for `key` (the key this call authenticated).
        case recordForAuthenticatedKey(key: Data)
        /// The signer key of an `identity_unresolved` hold: adopt it (pin) then record, through the existing SAS-pin path.
        case adoptUnresolvedSigner
        /// An `identity_key_mismatch` hold with a proven rotation candidate: release the media, then adopt the candidate under the
        /// adoption guards.
        case adoptHeldRotation(IdentityRotationCandidate)
        /// A hold that no signature vouches for: release the media and write NOTHING.
        case releaseOnly
        /// Nothing may be recorded or released.
        case refuse
    }

    /// The action for the state of the call. `candidate` is the rotation candidate of THIS call (or nil).
    public static func action(auth: CallIdentityAuth, callId: String, candidate: IdentityRotationCandidate?) -> Action {
        if let tag = auth.callIdOrNil, tag != callId.lowercased() { return .refuse }
        switch auth {
        case .pending, .noIdentity, .lost:
            // Nothing vouches for a key, but the media may still be held (a verdict that never arrived, a call that lost its key): the
            // no-brick rule releases it, writing nothing, and the shield stays as it is. Releasing a call that is not held is a no-op.
            // The call stands on no key anymore, but the media may be held: the no-brick rule releases it, writing nothing, and the
            // shield stays red. (Releasing a call that is not held is a no-op.)
            return .releaseOnly
        case .authenticated(_, let key):
            return .recordForAuthenticatedKey(key: key)
        case .held(let id, let code, _, let signer):
            if code == IdentityShieldRules.codeIdentityUnresolved { return .adoptUnresolvedSigner }
            if code == IdentityShieldRules.codeKeyMismatch,
               let c = candidate, c.callId.lowercased() == id.lowercased(), let signer, c.key == signer {
                return .adoptHeldRotation(c)
            }
            return .releaseOnly
        }
    }

    /// The precondition of recording a confirmation, evaluated AFTER any adoption attempt:
    ///  - `.authenticated(K)`: the pin of this device must now be exactly K (the confirmation never binds the words of a call
    ///    authenticated by K2 to a pin K1);
    ///  - an `identity_unresolved` hold: only with an adopted signer key equal to the held signer key;
    ///  - everything else: never.
    public static func mayRecord(auth: CallIdentityAuth, callId: String, pinnedKey: Data?, adoptedSignerKey: Data?) -> Bool {
        if let tag = auth.callIdOrNil, tag != callId.lowercased() { return false }
        switch auth {
        case .authenticated(_, let key):
            return pinnedKey == key
        case .held(_, let code, _, let signer):
            guard code == IdentityShieldRules.codeIdentityUnresolved, let adopted = adoptedSignerKey, let signer else { return false }
            return adopted == signer
        default:
            return false
        }
    }
}

// MARK: - The contact-level change marker

public enum ChangeMarker {
    /// The key whose change a verdict shows, to be recorded on the CONTACT (a fact about the contact, not call state: it is recorded
    /// whatever call the verdict belongs to, the live one or not): a key-mismatch hold carries the signer key; an authenticated key that
    /// is not the pin of the device is a rotated key. nil when the verdict shows no changed key.
    /// Every round counts (a rekey round verified under another key than the pin is the same finding as round 1). A key-mismatch hold
    /// without a usable signer key is recorded as unknown (fail closed).
    public enum Recorded: Equatable {
        case key(Data)
        case unknown
    }

    public static func keyToRecord(report: IdentityVerdictReport, devicePin: Data?) -> Recorded? {
        switch report.kind {
        case .authenticated(let key):
            guard let pin = devicePin, pin != key else { return nil }
            return .key(key)
        case .held(let code, let signerKey, _, _):
            guard code == IdentityShieldRules.codeKeyMismatch else { return nil }
            if let signerKey, signerKey.count == 32 { return .key(signerKey) }
            return .unknown
        }
    }
}

// MARK: - The silent re-pin gate

public enum RepinGate {
    /// A key the server publishes may replace the pin of a peer device silently only when nothing the user verified applies to the
    /// pin being replaced. EVERY form of verification counts: the in-call confirmation (identity tag), the safety number attested on
    /// the contact screen and an in-person ceremony (both stored as the safety number of the key compared). When one applies the
    /// re-pin is refused: the change is recorded, the call shows red and only the confirmation of the words adopts the new key.
    public static func refusesSilentRepin(
        priorPin: Data, newKey: Data, record: IdentityVerificationRecord,
        selfUserId: String?, selfIdentityKey: Data?, peerUserId: String
    ) -> Bool {
        guard priorPin != newKey else { return false }
        return record.applies(to: priorPin, selfUserId: selfUserId, selfIdentityKey: selfIdentityKey, peerUserId: peerUserId)
    }
}

// MARK: - Adopting a rotated key

public enum RotationAdoption {

    /// The guards of the adoption of a rotated key, in order. Returns the outcome when a guard decides, `nil` when every guard
    /// passed and the pin may be written:
    ///  1. peer id and key are well-formed (32 bytes, an acceptable Ed25519 key);
    ///  2. the own user id is known and is not the peer;
    ///  3. the own identity key is available (the safety number can be computed);
    ///  4. a pin exists for exactly this peer device;
    ///  5. the pin already is this key: `.alreadyPinned`, nothing is rewritten;
    ///  6. a candidate recorded by THIS call's handshake for exactly (peer, device, key), same call id, same key: else `.conflict`;
    ///  7. the key is in the server-published set right now (checked just before the write): else `.conflict`.
    public static func guardOutcome(
        peerUserId: String,
        selfUserId: String?,
        key: Data,
        selfIdentityKeyAvailable: Bool,
        deviceId: String?,
        pinnedKeyForDevice: Data?,
        candidate: IdentityRotationCandidate?,
        callId: String,
        keyPublishedNow: Bool
    ) -> SasPinOutcome? {
        guard !peerUserId.isEmpty, key.count == 32, Ed25519IdentityKeyPolicy.isAcceptable(key) else { return .unavailable }
        guard let selfUserId, !selfUserId.isEmpty, selfUserId != peerUserId else { return .unavailable }
        guard selfIdentityKeyAvailable else { return .unavailable }
        guard let pin = pinnedKeyForDevice else { return .unavailable }
        if pin == key { return .alreadyPinned }
        guard let c = candidate,
              !callId.isEmpty,
              c.callId.lowercased() == callId.lowercased(),
              c.peerId == peerUserId,
              (c.deviceId ?? "") == (deviceId ?? ""),
              c.key == key else { return .conflict }
        guard keyPublishedNow else { return .conflict }
        return nil
    }
}
