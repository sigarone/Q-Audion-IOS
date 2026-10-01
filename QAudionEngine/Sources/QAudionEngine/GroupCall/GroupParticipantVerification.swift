import Foundation

/// M3 — which participants of a GROUP call are not verified, from the verification state the app
/// already keeps. No new crypto and no new store: this only READS what the 1:1 ceremonies and the
/// contact screens wrote.
///
/// A participant counts as verified when ANY of these holds:
///   - a SAS confirmation (`SasBinding`) applies to one of the identity keys pinned for that peer
///     (the confirmation is bound to the pinned key, so a rotated key invalidates it);
///   - the contact carries the local verified mark (`isVerified`, written by a manual safety-number
///     verification and by an in-person pairing the server confirmed) or a manual verification stamp;
///   - an in-person QR + Bluetooth pairing was completed AND confirmed by the server;
///   - an active in-person (NFC) presence record exists.
/// Everything else (no contact row, a contact never verified, a pairing the server could not confirm,
/// a suspended or revoked presence record) is "not verified". The local participant is never listed.
public enum GroupParticipantVerification {

    /// - Parameters:
    ///   - contact: the stored contact row of the participant, `nil` for someone who is not a contact.
    ///   - sasBinding: the persisted SAS confirmation for that peer, `nil` when none.
    ///   - pinnedKeys: every identity key pinned for that peer (legacy and per-device pins).
    public static func isVerified(
        contact: ContactsStore.StoredContact?,
        sasBinding: SasBinding?,
        pinnedKeys: [Data]
    ) -> Bool {
        if let binding = sasBinding {
            for key in pinnedKeys where binding.appliesTo(currentIdentityTag: SasBinding.identityTag(forPinnedKey: key)) {
                return true
            }
        }
        guard let contact = contact else { return false }
        if contact.isVerified { return true }
        if contact.verifiedAtMs != nil { return true }
        if contact.proximityPairedAtMs != nil && contact.proximityServerConfirmed == true { return true }
        if let presence = contact.presenceAuth, presence.status == .active { return true }
        return false
    }
}

/// The group-call screen's verification state: who is unverified, in roster order, and what the
/// banner offers. A plain value computed from the roster and a verification predicate, so the
/// view-model behaviour is tested without any UI.
public struct GroupVerificationState: Equatable, Sendable {

    /// Unverified participants, in roster order, the local participant excluded.
    public let unverifiedIds: [String]

    public init(unverifiedIds: [String] = []) {
        self.unverifiedIds = unverifiedIds
    }

    /// Build the state for a roster. `isVerified` is asked once per remote participant.
    public init(participantIds: [String], selfId: String, isVerified: (String) -> Bool) {
        var seen = Set<String>()
        var unverified: [String] = []
        for id in participantIds where id != selfId && !id.isEmpty && seen.insert(id).inserted {
            if !isVerified(id) { unverified.append(id) }
        }
        self.unverifiedIds = unverified
    }

    /// True when the call screen shows the banner.
    public var showsBanner: Bool { !unverifiedIds.isEmpty }

    /// How many participants are unverified.
    public var count: Int { unverifiedIds.count }

    /// The participant the banner's action opens the verification of (the first one in roster order).
    public var firstUnverifiedId: String? { unverifiedIds.first }

    /// Whether this participant's tile carries the "not verified" badge.
    public func isUnverified(_ id: String) -> Bool { unverifiedIds.contains(id) }
}
