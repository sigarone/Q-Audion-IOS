import Foundation

/// Decides what the profile editor sends for the status message.
///
/// `AccountApi.updateProfile` omits a field when its value is `nil` (field
/// unchanged) and sends an empty string as an explicit "clear". The editor
/// therefore has to tell "the user emptied the status" apart from "the status
/// was never loaded" or "it was already empty".
public enum ProfileStatusUpdate {

    /// - Parameters:
    ///   - loadedStatus: status last read from the profile endpoint; `nil`
    ///     when no read has succeeded yet.
    ///   - draftStatus: current content of the status text field.
    /// - Returns: the value to pass as `statusMessage`: the draft when it is
    ///   not empty, `""` when a non-empty loaded status was emptied, `nil`
    ///   (leave unchanged) otherwise.
    public static func statusToSend(loadedStatus: String?, draftStatus: String) -> String? {
        if !draftStatus.isEmpty { return draftStatus }
        guard let loadedStatus, !loadedStatus.isEmpty else { return nil }
        return ""
    }
}
