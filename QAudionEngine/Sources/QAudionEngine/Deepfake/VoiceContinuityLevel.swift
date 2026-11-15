import Foundation

/// The reading of a continuity self-check as it goes on the wire in `OWNER_CONT`
/// and as the other side shows it: `verified`, `uncertain` or `mismatch`, and
/// `unknown` while nothing has been announced. The raw values are the wire words.
public enum VoiceContinuityLevel: String {
    case unknown, verified, uncertain, mismatch
}
