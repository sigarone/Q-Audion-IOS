import Foundation

/// Local handling of the invite code typed on the registration screens
/// (phone flow and interno+email flow). Thin layer over the activation-code
/// format in `ActivationCode.swift` — the server validates invite codes with
/// the same format (prefix + payload + checksum), so the screens share ONE
/// formatter, ONE validity check and ONE wire form instead of each keeping its
/// own copy.
public enum InviteCodeInput {

    /// "As you type" formatter for the text field: uppercases, drops
    /// characters outside the code alphabet, re-inserts dashes, caps the
    /// length.
    public static func format(_ raw: String) -> String {
        liveFormatActivationCodeInput(raw)
    }

    /// True when `raw` is a complete code whose embedded checksum matches.
    /// Pure and offline; the server re-checks it as its own first gate.
    public static func isValid(_ raw: String) -> Bool {
        verifyActivationCodeChecksum(raw)
    }

    /// True when `raw` has the full length of a code but the checksum does
    /// not match (a typo): the screens use it to flag the field.
    public static func isCompleteButInvalid(_ raw: String) -> Bool {
        !normalizeActivationCode(raw).isEmpty && !verifyActivationCodeChecksum(raw)
    }

    /// The value sent as `invite_code`: the normalised dashed form, or nil
    /// when the input is not a valid code.
    public static func wireValue(_ raw: String) -> String? {
        let canon = normalizeActivationCode(raw)
        guard !canon.isEmpty, verifyActivationCodeChecksum(canon) else { return nil }
        return canon
    }
}
