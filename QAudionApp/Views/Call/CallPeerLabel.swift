import Foundation

/// Label rule for the peer of a call-history row.
///
/// Title: the contact name, otherwise the extension or number stored on the call record, otherwise a
/// localized "Unknown". An internal user id (or any UUID-shaped text) is never shown.
enum CallPeerLabel {

    struct Result: Equatable {
        /// Row title.
        let title: String
        /// Extension digits for the avatar and the subtitle, nil when none is known.
        let extensionDigits: String?
        /// True when neither a name nor an extension nor a number is known (generic person avatar).
        let isUnknown: Bool
    }

    /// - Parameters:
    ///   - contactName: name from the contacts, nil or empty when the peer is not a contact.
    ///   - storedDisplay: display text stored on the call record at call time.
    ///   - storedExtension: extension stored on the call record.
    ///   - unknownText: localized "Unknown", injected so the rule stays a pure function.
    static func resolve(contactName: String?,
                        storedDisplay: String?,
                        storedExtension: Int?,
                        unknownText: String) -> Result {
        let ext: String? = {
            if let e = storedExtension, e > 0 { return String(e) }
            // A legacy stored label such as "Int. 103" still carries the digits.
            return DisplayName.resolvedExtension(for: "", serverDisplay: storedDisplay,
                                                 knownExtension: nil, contacts: [])
        }()
        if let name = contactName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, !DisplayName.isPlaceholderName(name) {
            return Result(title: name, extensionDigits: ext, isUnknown: false)
        }
        if let ext {
            return Result(title: ext, extensionDigits: ext, isUnknown: false)
        }
        if let number = phoneNumber(storedDisplay) {
            return Result(title: number, extensionDigits: nil, isUnknown: false)
        }
        return Result(title: unknownText, extensionDigits: nil, isUnknown: true)
    }

    /// A stored value that is a phone number: digits with an optional leading "+", spaces and dashes,
    /// at least 5 digits. Anything else (names, ids, placeholders) is not a number.
    static func phoneNumber(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        guard !DisplayName.looksLikeUUID(t) else { return nil }
        let allowed = CharacterSet(charactersIn: "+-() 0123456789")
        guard t.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard t.filter({ $0.isNumber }).count >= 5 else { return nil }
        return t
    }
}
