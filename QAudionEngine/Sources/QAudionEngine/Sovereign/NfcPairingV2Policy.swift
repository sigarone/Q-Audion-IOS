import Foundation

/// What the confirmation screen shows about the other phone once its identity proof verified
/// (docs/security/NFC_PAIRING_V2.md sections 9 and 10).
struct NfcPeerAssessment: Equatable, Sendable {
    /// The name of the known contact for the verified identity; nil for an unknown phone.
    let contactName: String?
    /// A warning for the confirmation screen, or nil.
    let warning: String?
    /// The verified identity belongs to a contact in the address book.
    let peerKnown: Bool
    /// The contact has pinned identity keys (so the comparison below was meaningful).
    let pinned: Bool
}

/// The identity policy of proximity pairing applied to the verified identity block of an NFC pairing: a pinned key
/// of the same account that differs, or an account whose published keys do not include the proven one, adds a
/// warning. Nothing here changes a contact, a pin or a key: "a completion never rewrites a known contact".
///
/// The identity block carries no X25519 key, so the address-book key of a contact added from an identity QR (an
/// X25519 key) cannot be compared; the pins and the server's published keys carry the check.
enum NfcPairingV2Policy {

    /// Result of the comparison with the keys the account publishes.
    enum ServerCheck: Equatable {
        case unavailable
        case confirmed
        case mismatch
    }

    /// Empty set (offline, nothing published) is `unavailable`; the presented key among the published ones is
    /// `confirmed`; otherwise `mismatch`.
    static func serverVerdict(published: Set<Data>, presented: Data) -> ServerCheck {
        if published.isEmpty { return .unavailable }
        return published.contains(presented) ? .confirmed : .mismatch
    }

    static func assess(peer: NfcPairingV2Identity, pinnedKeys: [Data], contactName: String?,
                       serverCheck: ServerCheck) -> NfcPeerAssessment {
        var warnings: [String] = []
        if !pinnedKeys.isEmpty, !pinnedKeys.contains(where: { $0 == peer.publicKey }) {
            warnings.append(String(localized: "nfc.warning.pin_changed",
                                   defaultValue: "Attenzione: la chiave di identità di questo contatto è diversa da quella verificata in precedenza. Conferma solo se sei sicuro che la persona davanti a te sia davvero questo contatto.",
                                   comment: "NFC pairing: the other phone proved a different identity key than the one pinned for this contact."))
        }
        if serverCheck == .mismatch {
            warnings.append(String(localized: "nfc.warning.server_mismatch",
                                   defaultValue: "Attenzione: l\u{2019}account indicato da questo telefono non ha pubblicato questa chiave di identità.",
                                   comment: "NFC pairing: the account the other phone names has not published the identity key it proved."))
        }
        return NfcPeerAssessment(contactName: contactName,
                                 warning: warnings.isEmpty ? nil : warnings.joined(separator: " "),
                                 peerKnown: contactName != nil,
                                 pinned: !pinnedKeys.isEmpty)
    }

    /// The address-book name for a verified identity. The account id in the identity block is the peer's own claim,
    /// so a contact found by id alone is named only when something independent confirms the proven key: a pin of
    /// that account or the keys the account publishes. A contact holding the same key is named. Otherwise nil: the
    /// screen says "unknown phone".
    static func contactName(for peer: NfcPairingV2Identity, contacts: [ContactsStore.StoredContact],
                            pinnedKeys: [Data] = [], serverCheck: ServerCheck = .unavailable) -> String? {
        if let byKey = contacts.first(where: { $0.pubkey == peer.publicKey }) {
            return byKey.displayName
        }
        guard !peer.userId.isEmpty, let byId = contacts.first(where: { $0.userId == peer.userId }) else { return nil }
        let confirmed = pinnedKeys.contains(peer.publicKey) || serverCheck == .confirmed
        return confirmed ? byId.displayName : nil
    }

    /// The assessment against the real pin store and address book.
    static func liveAssessment(peer: NfcPairingV2Identity, serverCheck: ServerCheck) -> NfcPeerAssessment {
        let pins: [Data] = peer.userId.isEmpty ? [] : PeerIdentityPinStore().allPinnedKeys(contactId: peer.userId)
        let name = contactName(for: peer, contacts: ContactsStore().load(), pinnedKeys: pins, serverCheck: serverCheck)
        return assess(peer: peer, pinnedKeys: pins, contactName: name, serverCheck: serverCheck)
    }
}
