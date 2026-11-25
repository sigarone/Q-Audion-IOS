import Foundation

/// What the trust stores say about the key pinned at EXACTLY one (peer, device). It is never made from the legacy per-contact
/// item: the caller passes nil when the device has no pin of its own.
public struct VoiceTierTrust: Equatable, Sendable {
    /// The key pinned for this (peer, device).
    public var pinnedKey: Data
    /// Unix seconds at which that key was pinned, nil when unknown.
    public var pinnedAtS: Int64?
    /// An identity change of this contact is recorded and not settled.
    public var pendingChange: Bool
    /// The current key of this (peer, device) was verified in person, by QR or by NFC (not by the in-call SAS).
    public var oobVerified: Bool

    public init(pinnedKey: Data, pinnedAtS: Int64?, pendingChange: Bool, oobVerified: Bool) {
        self.pinnedKey = pinnedKey
        self.pinnedAtS = pinnedAtS
        self.pendingChange = pendingChange
        self.oobVerified = oobVerified
    }
}

/// Builds the platform-neutral tier input of one moment of a 1:1 call from what the app stores and observes. The tier is computed
/// by `VoiceTier` (KAT stage 12); this only gathers the inputs, and every doubt gives the input that is tier 0.
public enum VoiceTierInputs {
    /// The verification methods that count as out of band: in person, by QR or by NFC. The in-call SAS (`anti-replay`, `voice`)
    /// does not, and neither does a method that is not recorded.
    public static let outOfBandMethods: Set<String> = ["in-person", "qr", "nfc"]

    /// Whether a recorded verification method counts as out of band; a missing or unknown one does not.
    public static func isOutOfBand(method: String?) -> Bool {
        guard let method else { return false }
        return outOfBandMethods.contains(method)
    }

    /// The input of one moment, or nil while the call has no protection line of its own yet (nothing is reported before it: a
    /// moment with an input that is merely not known yet would only lower the tier of the call for nothing).
    ///
    /// - `peerDeviceId`: the device that THIS call is bound to; nil or blank means the call had none (tier 0).
    /// - `trust`: the exact (peer, device) pin, nil when there is none.
    /// - `callStartS`: unix seconds at which the call started (the age is measured to it, not to now).
    static func build(
        callId: String, peerDeviceId: String?, trust: VoiceTierTrust?, auth: CallIdentityAuth,
        protection: CallPqProtection?, kcmacOk: Bool, callStartS: Int64
    ) -> VoiceTierInput? {
        guard let line = IdentityShieldRules.protection(protection, forCall: callId) else { return nil }
        let noDevice = peerDeviceId?.trimmingCharacters(in: .whitespaces).isEmpty ?? true
        let row: VoiceTierTrust? = noDevice ? nil : trust
        let sameCall = auth.callIdOrNil == callId.lowercased()
        var heldUnresolved = false
        if sameCall, case .held(_, let code, let releasedAdopted, _) = auth,
           code == IdentityShieldRules.codeIdentityUnresolved, !releasedAdopted {
            heldUnresolved = true
        }
        let pinState: TierPinState
        if let row {
            if heldUnresolved {
                pinState = .unresolved
            } else if !sameCall {
                pinState = .unresolved
            } else {
                switch auth {
                case .authenticated(_, let key):
                    pinState = key != row.pinnedKey || row.pendingChange ? .identityChanged : .pinned
                case .held(_, let code, let releasedAdopted, _):
                    pinState = code == IdentityShieldRules.codeIdentityUnresolved && releasedAdopted ? .unresolved : .identityChanged
                case .lost:
                    pinState = .identityChanged
                case .pending, .noIdentity:
                    pinState = .unresolved
                }
            }
        } else {
            pinState = .unpinned
        }
        let ageS: Int
        if let row, let pinnedAt = row.pinnedAtS {
            ageS = Int(clamping: callStartS - pinnedAt)
        } else {
            ageS = -1
        }
        let word: TierAuthWord
        switch line.auth {
        case "H": word = .h
        case "C": word = .c
        default: word = .noWord
        }
        return VoiceTierInput(
            pinState: pinState, keyAgeS: ageS, viaLegacyRow: row == nil, oobVerified: row?.oobVerified ?? false,
            pinAnomaly: line.pin == "anomaly", kcmacOk: kcmacOk, heldUnresolved: heldUnresolved, authWord: word)
    }

    /// The device that THIS call is bound to, from the stash that holds a device id per call id (the id of the call that stamped
    /// it). Never a value that belongs to the peer or to another call: a call whose own entry is missing or blank has no device
    /// (tier 0), whatever an earlier call from the same peer left behind.
    public static func peerDeviceId(forCall callId: String, callScopedStash: [String: String]) -> String? {
        guard !callId.isEmpty, let id = callScopedStash[callId.lowercased()],
              !id.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return id
    }
}
