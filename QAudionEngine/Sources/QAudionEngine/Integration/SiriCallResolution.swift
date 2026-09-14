import Foundation

/// Pure decision logic for matching a Siri-resolved call target (a raw
/// handle — phone number or email — plus the display name Siri already
/// resolved against the system Contacts app) to a Q-Audion contact.
///
/// Deliberately independent of `Intents`/`CallKit` and of `AppState` — the
/// SiriKit Intents Extension (`QAudionIntents/IntentHandler.swift`) must
/// stay a thin, dependency-free pass-through per Apple's own guidance
/// ("don't try to initiate calls directly from your Intents extension"), so
/// this matching step runs in the MAIN app after the Siri handoff, not in
/// the extension. Kept here (QAudionEngine) rather than inline in
/// `AppState.handleSiriStartCall` so it is unit-testable without a device
/// Contacts store or a live Siri interaction — same rationale as
/// `CallEnrichmentGate` above in `ContactsStore.swift`.
///
/// No pepper/hash matching here: `ContactsStore.StoredContact.phoneHash` is
/// peppered with a server-issued secret this resolver has no reason to hold,
/// so matching is limited to the two fields already stored in the clear —
/// `phoneNumber` (E.164-normalized, when Q-Audion has ever learned a raw
/// number for this peer) and `displayName`. A contact whose only local
/// record is `phoneHash` (discover-v2 / QR-scan import with no raw number
/// learned) cannot be reached this way yet — tracked as a known gap in the
/// CarPlay/Siri state-of-the-art plan, not silently assumed away.
public enum SiriCallResolution {

    public struct Match: Equatable {
        public let userId: String
        public let displayName: String
    }

    /// - Parameters:
    ///   - handle: the raw phone number or email Siri's resolved `INPerson`
    ///     carried, if any (`INPersonHandle.value`).
    ///   - displayName: the name Siri resolved the person to (e.g. from the
    ///     phone's own address book) — never empty-checked by the caller,
    ///     this function treats a blank/whitespace-only name as "no name".
    ///   - contacts: `AppState.cachedContacts` (or any equivalent snapshot)
    ///     — never re-reads `ContactsStore` itself, so this stays a pure
    ///     function of its inputs.
    /// - Returns: the best match, preferring an exact E.164 phone match over
    ///   a display-name match, and a verified contact over an unverified one
    ///   when multiple rows share the same name. `nil` when nothing matches.
    public static func resolve(
        handle: String?,
        displayName: String,
        contacts: [ContactsStore.StoredContact]
    ) -> Match? {
        if let handle,
           let normalizedHandle = try? PhoneHash.normalizeE164(handle) {
            let phoneHit = contacts.first { contact in
                guard let phone = contact.phoneNumber,
                      let normalizedContact = try? PhoneHash.normalizeE164(phone) else { return false }
                return normalizedContact == normalizedHandle
            }
            if let phoneHit {
                return Match(userId: phoneHit.userId, displayName: phoneHit.displayName)
            }
        }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let nameHits = contacts.filter {
            $0.displayName.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }
        if let verified = nameHits.first(where: { $0.isVerified }) {
            return Match(userId: verified.userId, displayName: verified.displayName)
        }
        return nameHits.first.map { Match(userId: $0.userId, displayName: $0.displayName) }
    }
}
