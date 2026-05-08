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
    /// user has not configured one. Always pure digits — callers can
    /// pass the value straight to CallKit / dial.
    public static func phoneNumber(defaults: UserDefaults = .standard) -> String? {
        let raw = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        // Belt-and-braces: strip any non-digit that might have slipped
        // past the input field (e.g. user pasting "+39 333…").
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? nil : digits
    }

    /// Persist the user's standard phone number. Empty / whitespace /
    /// non-digit-only input clears the key. Filters input to digits-only
    /// so the on-disk value is always dial-safe.
    public static func setPhoneNumber(_ value: String?, defaults: UserDefaults = .standard) {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter { $0.isASCII && $0.isNumber }
        if digits.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(digits, forKey: key)
        }
    }
}
