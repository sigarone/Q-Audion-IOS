import Foundation

/// Local-only "standard phone number" that the user advertises as their
/// caller-id when placing outbound calls. This is a SEPARATE concept from
/// `MyPhonesContainer.phones` (multi-phone E.164 list pushed as peppered
/// hashes for discovery) — the value stored here is:
///   * pure digits (no '+', no spaces, no prefix), so it can be dialed
///     verbatim by a callee whose CallKit feeds it into `CXHandle`;
///   * never persisted on the server — lives only in `UserDefaults`
///     under the `qaudion.local.phone` key;
///   * optional — if unset, the server fills the `caller_display` field
///     in the outbound `call_offer` envelope with the user's internal
///     extension instead.
///
/// Resolution priority on the callee side (CallKit caller-id):
///   1. `caller_display` from the wire envelope (this value, if set).
///   2. Server's stored extension (e.g. "100").
///   3. Local rubrica (ContactsStore) lookup by sender_id UUID.
///   4. Bare sender_id UUID as last resort.
public enum LocalCallerIdSettings {
    /// UserDefaults key for the local public phone number.
    public static let key = "qaudion.local.phone"

    /// Read the locally-set standard phone number. Returns nil when the
    /// user has not configured one. Supports E.164 format (leading "+")
    /// or plain digits.
    public static func phoneNumber(defaults: UserDefaults = .standard) -> String? {
        let raw = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        return raw
    }

    /// Persist the user's standard phone number. Accepts E.164 format
    /// ("+39331234567") or plain digits ("331234567"). Strips spaces,
    /// dashes and parentheses but preserves a leading "+". Empty input
    /// clears the key.
    public static func setPhoneNumber(_ value: String?, defaults: UserDefaults = .standard) {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        let hasPlus = trimmed.hasPrefix("+")
        let digitsOnly = trimmed.filter { $0.isASCII && $0.isNumber }
        if digitsOnly.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(hasPlus ? "+" + digitsOnly : digitsOnly, forKey: key)
        }
    }
}
