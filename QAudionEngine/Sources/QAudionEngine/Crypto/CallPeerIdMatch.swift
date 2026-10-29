import Foundation

/// Compares two forms of a contact id. The same person can appear with different letter case, or with the device
/// appended as "<contact>|<device>", depending on where the id came from.
public enum CallPeerIdMatch {
    /// The contact part of an id, lower-cased and trimmed.
    public static func normalized(_ id: String) -> String {
        let base = id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? id
        return base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True when both ids name the same contact. An empty id never matches.
    public static func same(_ a: String, _ b: String) -> Bool {
        let na = normalized(a)
        return !na.isEmpty && na == normalized(b)
    }
}
