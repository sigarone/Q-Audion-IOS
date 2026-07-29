import Foundation
import Contacts

/// Shared CNContactStore helpers for phone-number <-> device-address-book
/// lookups. Factored out so the auto-save-from-call enrichment path
/// (`NameResolutionService.enrichFromCallProfile`) does not need a THIRD
/// independent `CNContactStore().enumerateContacts` block — it reuses the
/// same key set and digit-normalization `PhoneContactImportView`'s
/// manual-import flow already established.
///
/// Every function here is synchronous and touches disk (Contacts.framework
/// enumeration) — callers MUST invoke off the main thread / off any
/// call-setup hot path. Read-only: nothing here ever calls
/// `CNContactStore.requestAccess` — callers are responsible for checking
/// `CNContactStore.authorizationStatus(for: .contacts) == .authorized`
/// themselves before calling into this type (see `CallEnrichmentGate` in
/// QAudionEngine for the pure, unit-testable gating decision).
enum DeviceContactLookup {

    /// Keys fetched for both the bulk "list all candidates" (manual
    /// import, `PhoneContactImportView.loadCandidates`) and the
    /// single-number `lookup(phoneNumber:)` below — one shared key set
    /// instead of two independently-maintained copies.
    static let keysToFetch: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactThumbnailImageDataKey as CNKeyDescriptor
    ]

    /// Same digit/plus-only normalization `PhoneContactImportView` already
    /// applied inline to CNContact phone numbers, factored out so every
    /// call site agrees on one definition.
    static func normalizedDigits(_ raw: String) -> String {
        raw.filter { "0123456789+".contains($0) }
    }

    struct Match {
        let name: String
        let thumbnailData: Data?
    }

    /// Enumerates the device address book looking for a CNContact whose
    /// phone number matches `phoneNumber` (tolerant of +CC / leading-zero /
    /// spacing differences via a trailing-digits compare — CNContact
    /// numbers are free-form user-entered text, never guaranteed E.164).
    /// Returns the FIRST match's name + thumbnail, or nil if none is
    /// found. Stops enumerating as soon as a match is found.
    static func lookup(phoneNumber: String, store: CNContactStore = CNContactStore()) -> Match? {
        let target = normalizedDigits(phoneNumber)
        guard target.filter(\.isNumber).count >= 6 else { return nil }

        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var found: Match?
        try? store.enumerateContacts(with: request) { contact, stop in
            guard found == nil else { stop.pointee = true; return }
            let isMatch = contact.phoneNumbers.contains {
                suffixMatches(normalizedDigits($0.value.stringValue), target)
            }
            guard isMatch else { return }
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }.joined(separator: " ")
            guard !name.isEmpty else { return }
            found = Match(name: name, thumbnailData: contact.thumbnailImageData)
            stop.pointee = true
        }
        return found
    }

    /// Tolerant compare on trailing digits (6-9 digits) — handles
    /// "+393331234567" vs "3331234567" vs "0039333..." all matching
    /// without needing full E.164 normalization on the device-address-book
    /// side.
    private static func suffixMatches(_ a: String, _ b: String) -> Bool {
        let da = a.filter(\.isNumber)
        let db = b.filter(\.isNumber)
        guard da.count >= 6, db.count >= 6 else { return false }
        let n = min(9, min(da.count, db.count))
        return da.suffix(n) == db.suffix(n)
    }

    /// Best-effort local cache of a CNContact thumbnail so `StoredContact
    /// .avatarUrl` (a plain `URL?`) can point at it exactly like a remote
    /// avatar — `QAudionAvatar` already loads any `URL` via `AsyncImage`,
    /// `file://` included. No new "local photo data" field needed on
    /// `StoredContact`. Returns nil (never throws) on any I/O failure —
    /// callers simply fall back to initials, same as an absent avatarUrl
    /// today.
    static func cachePhoto(_ data: Data, forUserId userId: String) -> URL? {
        guard !data.isEmpty else { return nil }
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("qaudion-contact-photos", isDirectory: true)
        let safeName = userId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        let fileUrl = dir.appendingPathComponent("\(safeName).jpg")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: fileUrl, options: .atomic)
            return fileUrl
        } catch {
            return nil
        }
    }
}
