import Foundation

/// Call-scoped book of the signer identity keys a 1:1 call saw while the peer's identity could not be
/// resolved (no stored pin, no server key: `identity_unresolved`), and of the one the user confirmed by
/// SAS.
///
/// Why it exists: with no pin and no server key the v5 handshake never trusts the key the peer
/// asserts about itself, so media is held until the user compares the SAS words. The words come from
/// the session key, which is bound to the signed transcript and therefore to the signer key of that
/// round. Confirming them is the out-of-band proof that THAT key belongs to the person on the line:
///   1. the key of the confirmed round becomes the call-scoped pin, so later key rounds of the same call
///      verify against it (a round signed by another key re-holds media, as against any pin);
///   2. the app also persists it as the durable pin of that peer device (existing pin store), see
///      `AppState.adoptSasConfirmedSignerKeyIfUnresolved`.
///
/// Nothing is ever recorded as confirmed here without an explicit `confirm` call, and a key is only
/// confirmable for the round whose session key the user compared (`signerAwaitingSas(callId:round:)`
/// is looked up by the signed round of the session key the SAS words were derived from), so a
/// rekey OFFER signed by a different key that arrives while the SAS is on screen can never be adopted
/// by confirming the words of the earlier round.
///
/// Conflict rule (Opus review): until the user confirms, every round of the call must be signed by the
/// SAME key as the first `identity_unresolved` round (the candidate). A later unresolved round signed by
/// another key, or any round with another abort verdict (`sig_invalid`: a relay replaying the peer's
/// public key over its own key material; `identity_key_mismatch`; a downgrade), before or after the
/// candidate, puts the call in conflict: no round of it can then be adopted, and the app refuses the
/// confirmation (nothing pinned, nothing recorded, media still held). Without it a well-timed relay rekey
/// landing between the moment the user compared the words and the tap would be the round adopted.
///
/// In-memory only; keyed by lowercased callId; cleared when the call ends.
public final class CallScopedSasPinBook: @unchecked Sendable {

    private let lock = NSLock()
    /// callId -> signed round -> signer key of that round's bundle (an `identity_unresolved` verdict).
    private var unresolvedByCall: [String: [UInt32: Data]] = [:]
    /// callId -> the signer key the user confirmed by SAS (the call-scoped pin).
    private var confirmedByCall: [String: Data] = [:]
    /// callId -> the signer key of the call's FIRST `identity_unresolved` round (never replaced).
    private var candidateByCall: [String: Data] = [:]
    /// Calls with a round (before the confirmation) the candidate key cannot vouch for.
    private var taintedCalls: Set<String> = []
    /// Calls where a round judged `identity_unresolved` (its verification raced the confirmation) carried
    /// a key other than the confirmed one.
    private var lateConflictCalls: Set<String> = []

    /// Bound on remembered unresolved rounds per call (oldest rounds drop first).
    static let maxRoundsPerCall = 8

    public init() {}

    /// Remember the signer key of a round whose identity could not be resolved. `round` must be the
    /// bundle's signed `rekeyRound` (>= 1); anything else is ignored. A 32-byte key is required. A key
    /// that differs from the call's first unresolved key puts the call in conflict.
    public func noteUnresolved(callId: String, round: Int?, signerKey: Data?) {
        guard let round = round, round >= 1, round <= Int(UInt32.max),
              let key = signerKey, key.count == 32 else { return }
        let id = callId.lowercased()
        guard !id.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        // Once confirmed, later rounds are judged against the call-scoped pin, not by this book. The one
        // exception is a round whose verification read the book just BEFORE the confirmation landed (it
        // was judged unresolved, not against the pin): signed by another key, it must never be released by
        // a later confirmation of this call.
        if let confirmed = confirmedByCall[id] {
            if confirmed != key { lateConflictCalls.insert(id) }
            return
        }
        if let candidate = candidateByCall[id] {
            if candidate != key { taintedCalls.insert(id) }
        } else {
            candidateByCall[id] = key
        }
        var rounds = unresolvedByCall[id] ?? [:]
        rounds[UInt32(round)] = key
        while rounds.count > Self.maxRoundsPerCall, let oldest = rounds.keys.min() {
            rounds.removeValue(forKey: oldest)
        }
        unresolvedByCall[id] = rounds
    }

    /// A round of the call whose verdict was an abort OTHER than `identity_unresolved` (`sig_invalid`,
    /// `identity_key_mismatch`, `ratchet_v5_downgrade`), before the confirmation: the call's candidate
    /// (present or later) can never be adopted. No effect on a call that never had an unresolved round.
    public func noteOtherAbort(callId: String) {
        let id = callId.lowercased()
        guard !id.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if confirmedByCall[id] != nil { return }
        taintedCalls.insert(id)
    }

    /// True when the call had an `identity_unresolved` round AND a round that key cannot vouch for (or,
    /// after the confirmation, an unresolved round of another key that raced it): a SAS confirmation of
    /// this call must be refused (nothing pinned, recorded or released).
    public func isConflicted(callId: String) -> Bool {
        let id = callId.lowercased()
        lock.lock(); defer { lock.unlock() }
        if lateConflictCalls.contains(id) { return true }
        return confirmedByCall[id] == nil && candidateByCall[id] != nil && taintedCalls.contains(id)
    }

    /// The signer key of `round` when that round's verdict was `identity_unresolved`, the call has no
    /// confirmed signer yet and is not in conflict; `nil` otherwise.
    public func signerAwaitingSas(callId: String, round: UInt32?) -> Data? {
        guard let round = round else { return nil }
        let id = callId.lowercased()
        lock.lock(); defer { lock.unlock() }
        if confirmedByCall[id] != nil { return nil }
        if candidateByCall[id] != nil && taintedCalls.contains(id) { return nil }
        return unresolvedByCall[id]?[round]
    }

    /// Record the user's explicit SAS confirmation of `key` as this call's pin.
    public func confirm(callId: String, key: Data) {
        guard key.count == 32 else { return }
        let id = callId.lowercased()
        guard !id.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        confirmedByCall[id] = key
    }

    /// The call-scoped pin: the signer key the user confirmed by SAS for this call, if any.
    public func confirmedSigner(callId: String) -> Data? {
        let id = callId.lowercased()
        lock.lock(); defer { lock.unlock() }
        return confirmedByCall[id]
    }

    /// The key to verify under: a stored (durable) pin always wins; the call-scoped one only fills in
    /// when there is none. A stored pin that differs from the call-scoped key therefore keeps the
    /// ordinary `identity_key_mismatch` behaviour.
    public static func effectivePin(stored: Data?, callScoped: Data?) -> Data? {
        stored ?? callScoped
    }

    /// Forget everything about one call.
    public func clear(callId: String) {
        let id = callId.lowercased()
        lock.lock(); defer { lock.unlock() }
        unresolvedByCall.removeValue(forKey: id)
        confirmedByCall.removeValue(forKey: id)
        candidateByCall.removeValue(forKey: id)
        taintedCalls.remove(id)
        lateConflictCalls.remove(id)
    }

    /// Forget every call (the integration instance is reused across calls).
    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        unresolvedByCall.removeAll()
        confirmedByCall.removeAll()
        candidateByCall.removeAll()
        taintedCalls.removeAll()
        lateConflictCalls.removeAll()
    }
}

/// What a SAS confirmation of the live round does with the SAS-PIN book (see `CallScopedSasPinBook`).
public enum SasSignerAdoption: Equatable {
    /// The live round was not held as `identity_unresolved`: the ordinary confirmation path applies.
    case notApplicable
    /// Pin this signer key of the live round (call-scoped, and durable through the app's pin store).
    case adopt(Data)
    /// The call is in conflict: the confirmation is refused (nothing pinned, recorded or released).
    case refused

    /// The key to pin, for `.adopt`.
    public var adoptedKey: Data? {
        if case .adopt(let key) = self { return key }
        return nil
    }
}

/// What the app does with the signer key of a SAS-confirmed `identity_unresolved` round, given the
/// pin store's current content for that peer device. Pure, so it is unit-tested.
public enum SasSignerPinPolicy {
    public enum Decision: Equatable {
        /// No pin exists: persist the confirmed key as the durable pin of the peer device.
        case pin
        /// The stored pin already equals the confirmed key: nothing to write.
        case alreadyPinned
        /// A different pin exists: it is never overwritten here (`identity_key_mismatch` territory) and
        /// the confirmation does not become a call-scoped pin either.
        case conflict
    }

    public static func decide(storedPin: Data?, confirmedKey: Data) -> Decision {
        guard confirmedKey.count == 32 else { return .conflict }
        guard let stored = storedPin else { return .pin }
        return stored == confirmedKey ? .alreadyPinned : .conflict
    }
}
