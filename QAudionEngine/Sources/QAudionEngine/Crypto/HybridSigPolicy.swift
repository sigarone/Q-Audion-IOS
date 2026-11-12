import Foundation
import CryptoKit

/// Result of checking the second signature of a received handshake bundle.
public enum PqSigResult: String, Sendable, Equatable {
    case absent
    case unavailable
    case invalid
    case valid
}

/// Why a call shows the safety-code warning. The signature reason comes first, then the call-settings reason.
public enum PqWarnReason: String, Sendable, Equatable, CaseIterable {
    case absent
    case invalid
    case otherkey
    case capsBindV1Missing = "capsBindV1_missing"
}

/// The pure decisions of the second handshake signature: what a round-1 bundle does to the pin record of its signer, and whether a
/// rekey round is used. A direct encoding of the shared table (section `pinPolicy` of the known-answer file): it never reads a
/// vector, never holds media and never ends a call. `armed` is an input only to prove it changes nothing.
///
/// Key ids are lowercase hex strings here and in the stored record.
public enum HybridSigPolicy {

    /// The capability tag of this feature. Needs `capsBindV1` in the same bundle.
    public static let tag = "sigHybridV1"

    public enum PqState: String, Sendable {
        case pinned
        case withdrawnUnsigned = "withdrawn-unsigned"
        case invalid
        case otherKey = "other-key"
    }

    // MARK: - Round 1

    public struct Round1Input: Sendable, Equatable {
        public var record: CapsPinRecord?
        /// The bundle advertises `capsBindV1`.
        public var capsBindV1: Bool
        /// The bundle advertises `sigHybridV1`.
        public var sigHybridV1: Bool
        /// The normalised `capsWithdrawn` names (the list EXTX binds).
        public var withdrawn: [String]
        /// Both bundles of the round carry `capsBindV1`.
        public var ext: Bool
        public var sigHybrid: PqSigResult
        /// The key id the check ran under, or nil.
        public var sigKeyId: String?
        /// The round's key confirmation verified. False ends the call before any record change.
        public var kcmacValid: Bool
        /// The server flag or compiled-in arming: ignored.
        public var armed: Bool
        /// The user confirmed the safety code from the warning.
        public var sasConfirmed: Bool

        public init(record: CapsPinRecord?, capsBindV1: Bool, sigHybridV1: Bool, withdrawn: [String], ext: Bool,
                    sigHybrid: PqSigResult, sigKeyId: String?, kcmacValid: Bool, armed: Bool, sasConfirmed: Bool) {
            self.record = record
            self.capsBindV1 = capsBindV1
            self.sigHybridV1 = sigHybridV1
            self.withdrawn = withdrawn
            self.ext = ext
            self.sigHybrid = sigHybrid
            self.sigKeyId = sigKeyId
            self.kcmacValid = kcmacValid
            self.armed = armed
            self.sasConfirmed = sasConfirmed
        }
    }

    public struct Round1Result: Equatable, Sendable {
        public enum Action: String, Sendable {
            case release
            case warn
            case end
        }

        public let action: Action
        /// Never true: nothing is held.
        public let hold: Bool
        /// `H`, `C`, or `-` when the round's key confirmation failed.
        public let auth: String
        /// `-`, `ok` or `anomaly`.
        public let pin: String
        public let warn: [PqWarnReason]
        /// `-`, `honoured` or `ignored`.
        public let withdraw: String
        /// Log value of `pq_sig=`: a result word or `otherkey`.
        public let pqSig: String
        /// The second log line `pq_sig=anomaly_confirmed`, else `-`.
        public let pqSig2: String
        /// The record after this call.
        public let record: CapsPinRecord?
    }

    private static func reasonState(_ reason: PqWarnReason) -> PqState {
        switch reason {
        case .invalid: return .invalid
        case .otherkey: return .otherKey
        default: return .withdrawnUnsigned
        }
    }

    private static func normalised(_ caps: Set<String>, _ keyId: String?, _ state: String?) -> CapsPinRecord? {
        if caps.isEmpty && keyId == nil && state == nil { return nil }
        return CapsPinRecord(caps: caps.sorted(), mldsaKeyId: keyId, pqState: state)
    }

    /// The table of the design, round 1.
    public static func decideRound1(_ i: Round1Input) -> Round1Result {
        if !i.kcmacValid {
            // `kcmac_mismatch` ends the round as for any tampering; nothing is written.
            return Round1Result(action: .end, hold: false, auth: "-", pin: "-", warn: [], withdraw: "-",
                                pqSig: i.sigHybrid.rawValue, pqSig2: "-", record: i.record)
        }
        var caps = Set(i.record?.caps ?? [])
        var keyId: String? = i.record?.mldsaKeyId
        var state: String? = i.record?.pqState
        let pinnedKey = keyId
        let withdrawnPq = i.withdrawn.contains(tag)
        let tagOffered = i.sigHybridV1 && i.capsBindV1 && !withdrawnPq
        let validUnderPinned = i.sigHybrid == .valid && pinnedKey != nil && i.sigKeyId == pinnedKey
        let capsMissing = caps.contains(CapsBind.tag) && !i.capsBindV1

        var warn: [PqWarnReason] = []
        var auth = "C"
        var pin = "-"
        var withdraw = "-"
        var pqSig = i.sigHybrid.rawValue
        var pqSig2 = "-"

        func reason() -> PqWarnReason {
            if let sk = i.sigKeyId, sk != pinnedKey, i.sigHybrid == .valid || i.sigHybrid == .invalid { return .otherkey }
            if i.sigHybrid == .invalid { return .invalid }
            return .absent
        }

        if capsMissing {
            warn.append(.capsBindV1Missing)
            pin = "anomaly"
        }

        if pinnedKey == nil {
            if i.sigHybrid == .valid {
                auth = "H"
                if tagOffered {
                    keyId = i.sigKeyId
                    state = PqState.pinned.rawValue
                }
            }
        } else if state == PqState.pinned.rawValue {
            if validUnderPinned {
                auth = "H"
                if withdrawnPq {
                    if pin == "-" { pin = "ok" }
                    withdraw = "honoured"
                    keyId = nil
                    state = nil
                } else if tagOffered {
                    if pin == "-" { pin = "ok" }
                } else {
                    // a valid signature under the pinned key id that neither offers nor withdraws the tag lacks a pinned tag
                    auth = "H"
                    pin = "anomaly"
                    warn.insert(.absent, at: 0)
                }
            } else {
                pin = "anomaly"
                let r = reason()
                warn.insert(r, at: 0)
                if r == .otherkey { pqSig = "otherkey" }
                if withdrawnPq { withdraw = "ignored" }
                if i.sasConfirmed {
                    state = reasonState(r).rawValue
                    if r == .invalid || r == .otherkey { pqSig2 = "anomaly_confirmed" }
                }
            }
        } else {
            // a warning-only state (withdrawn-unsigned, invalid, other-key): the key id is kept
            if validUnderPinned {
                if tagOffered {
                    auth = "H"
                    if pin == "-" { pin = "ok" }
                    state = PqState.pinned.rawValue
                } else if withdrawnPq {
                    auth = "H"
                    if pin == "-" { pin = "ok" }
                    withdraw = "honoured"
                    keyId = nil
                    state = nil
                } else {
                    auth = "H"
                    pin = "anomaly"
                    warn.insert(.absent, at: 0)
                }
            } else {
                pin = "anomaly"
                let r = reason()
                warn.insert(r, at: 0)
                if r == .otherkey { pqSig = "otherkey" }
                if withdrawnPq { withdraw = "ignored" }
                state = reasonState(r).rawValue
            }
        }

        if i.ext { caps.insert(CapsBind.tag) }
        if i.sasConfirmed && capsMissing { caps.remove(CapsBind.tag) }
        // record invariant: `sigHybridV1` is a pinned tag, present if and only if the state is `pinned`
        if state == PqState.pinned.rawValue { caps.insert(tag) } else { caps.remove(tag) }

        return Round1Result(
            action: (warn.isEmpty || i.sasConfirmed) ? .release : .warn,
            hold: false, auth: auth, pin: pin, warn: warn, withdraw: withdraw, pqSig: pqSig, pqSig2: pqSig2,
            record: normalised(caps, keyId, state))
    }

    // MARK: - Rekey rounds

    public struct RekeyInput: Sendable {
        /// This side's round-1 auth.
        public var auth1: String
        /// The key id the round-1 signature was valid under (the anchor of the call), when `auth1` is `H`.
        public var anchorKeyId: String?
        public var isOfferer: Bool
        public var round: Int
        public var sigHybrid: PqSigResult
        public var sigKeyId: String?
        public var armed: Bool

        public init(auth1: String, anchorKeyId: String?, isOfferer: Bool, round: Int, sigHybrid: PqSigResult,
                    sigKeyId: String?, armed: Bool) {
            self.auth1 = auth1
            self.anchorKeyId = anchorKeyId
            self.isOfferer = isOfferer
            self.round = round
            self.sigHybrid = sigHybrid
            self.sigKeyId = sigKeyId
            self.armed = armed
        }
    }

    public struct RekeyResult: Equatable, Sendable {
        public enum Action: String, Sendable {
            case accept
            case refuse
        }

        public let action: Action
        public let hold: Bool
        public let auth: String
        /// The warning is shown for the rest of the call.
        public let warn: Bool
        public let effect: String
        public let sendStaysOnCurrentRound: Bool
        public let eraseSlot: Bool
        /// The log line, or empty when the round logs none.
        public let log: String
        /// The reason of a refusal (for the warning), else nil.
        public let reason: PqWarnReason?
    }

    /// In a call that is `auth=H` on this side, a rekey bundle whose signature is not valid under the anchor key id is refused.
    public static func decideRekey(_ i: RekeyInput) -> RekeyResult {
        if i.auth1 == "H" && !(i.sigHybrid == .valid && i.sigKeyId == i.anchorKeyId) {
            let other = i.sigKeyId != nil && i.sigKeyId != i.anchorKeyId && (i.sigHybrid == .valid || i.sigHybrid == .invalid)
            let word = other ? "otherkey" : i.sigHybrid.rawValue
            let reason: PqWarnReason = other ? .otherkey : (i.sigHybrid == .invalid ? .invalid : .absent)
            return RekeyResult(
                action: .refuse, hold: false, auth: i.auth1, warn: true,
                effect: i.isOfferer ? "no_key_installed_no_mac" : "no_accept_sent",
                sendStaysOnCurrentRound: true, eraseSlot: false,
                log: "pq_sig=\(word) round=\(i.round) pin=anomaly hold=0 rekey=refused", reason: reason)
        }
        // an auth=C call logs a valid signature of an accepted rekey round (it does not raise the call to H)
        let log = (i.auth1 == "C" && i.sigHybrid == .valid) ? "pq_sig=valid round=\(i.round) pin=- hold=0 rekey=accepted" : ""
        return RekeyResult(action: .accept, hold: false, auth: i.auth1, warn: false, effect: "proceed",
                           sendStaysOnCurrentRound: false, eraseSlot: false, log: log, reason: nil)
    }
}

// MARK: - What this build does with the tag

/// What this build does with the tag right now.
public enum PqSigPlan: String, Sendable, Equatable {
    /// Advertise the tag and sign every bundle.
    case advertise
    /// A release that withdraws the tag on purpose: not advertised, signing kept, every bundle names the tag in `capsWithdrawn`.
    case withdraw
    /// Nothing: no tag, no signature.
    case off
}

/// The compiled-in decision of a release that withdraws the tag. It is a constant of the build, false in every build: no server
/// flag, setting or call input can make a client withdraw, because a flag that could would let the server release its users'
/// contacts from their pins without a safety-code check.
public enum PqSigRelease {
    public static let withdrawnByRelease: Bool = false
}

public enum PqSigAvailability {
    /// Whether this device already published its second key (acknowledged in this run, or built before as the stored creation
    /// record shows). The server flag that stops NEW publications is deliberately not an input: a device that already
    /// published keeps signing and advertising whatever the flag says.
    public static func isAvailable(deviceIdPublishable: Bool, acknowledgedThisRun: Bool, creationRecordStored: Bool) -> Bool {
        guard deviceIdPublishable else { return false }
        return acknowledgedThisRun || creationRecordStored
    }

    /// The plan of this build. `withdrawnByRelease` is the compiled constant; the parameter exists only so a test can prove what it does.
    public static func plan(capsBindEnabled: Bool, available: Bool,
                            withdrawnByRelease: Bool = PqSigRelease.withdrawnByRelease) -> PqSigPlan {
        guard capsBindEnabled else { return .off }
        if withdrawnByRelease { return available ? .withdraw : .off }
        return available ? .advertise : .off
    }
}

/// Which bindings (uuid, Ed25519 key, device id) of this device had their second key acknowledged by the server in this run. Memory
/// only: a restart falls back to the stored creation record (`MldsaIdentityPublication.hasStoredCreation`).
public enum MldsaOwnPublicationState {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var acknowledged: Set<String> = []

    public static func binding(uuidRaw: Data, edPub: Data, deviceId: String) -> String {
        var input = Data("qaudion-mldsa-own-publication".utf8)
        input.append(uuidRaw)
        input.append(edPub)
        input.append(Data(deviceId.utf8))
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    public static func markAccepted(binding: String) {
        lock.lock()
        acknowledged.insert(binding)
        lock.unlock()
    }

    public static func isAccepted(binding: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acknowledged.contains(binding)
    }

    /// Logout, wipe and the tests.
    public static func reset() {
        lock.lock()
        acknowledged.removeAll()
        lock.unlock()
    }
}
