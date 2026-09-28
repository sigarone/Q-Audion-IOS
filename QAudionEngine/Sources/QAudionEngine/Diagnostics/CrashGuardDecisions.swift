import Foundation

/// W-MEDIAATACCEPT (option b) — §10 (I9): with the media plane no longer
/// built at ring, a crash while merely RINGING (no PeerConnection exists
/// yet) must never count toward the native-SRTP crash streak — only a
/// crash while the PC is being built/used (`phase=pc`/`phase=media`)
/// reflects the native audio path actually being exercised.
///
/// Pulled out of `QAudionApp.init()`'s two inline `.contains(...)` checks
/// (see that call site) so the decision itself is a plain, testable
/// function — the crash-time call site stays a single `guard`.
public enum CrashGuardDecisions {

    /// The call phases `CrashBreadcrumbs.setCallContext(phase:)` writes.
    /// `snapshot` is the ONE pre-existing value this repo already ships
    /// (`AppState.logNativeSrtpSnapshot`, phase="snapshot") — kept counting
    /// for exactly one release (spec §10) so a crash-context string written
    /// by the PREVIOUS build (before `ring`/`pc`/`media` existed) is not
    /// silently dropped from the streak the instant this build ships.
    public enum Phase: String {
        case ring
        case pc
        case media
        case snapshot
    }

    /// Parses the `phase=<value>` token out of a `CrashBreadcrumbs`
    /// call-context line (`"in_call=1 native=1 role=callee call8=... phase=pc"`).
    /// `nil` when absent or unrecognized — a persisted context from an even
    /// OLDER build than the one that added `phase` at all.
    public static func phase(fromContext context: String) -> Phase? {
        for token in context.split(separator: " ") {
            guard token.hasPrefix("phase=") else { continue }
            return Phase(rawValue: String(token.dropFirst("phase=".count)))
        }
        return nil
    }

    /// Whether a persisted crash-context line indicates a crash that should
    /// advance the native-SRTP crash streak. Requires `in_call=1` AND
    /// `native=1` (unchanged from the pre-existing check) AND a phase where
    /// a PeerConnection actually existed (`pc`/`media`), or the one-release
    /// `snapshot` grandfather case. `phase=ring` (or no phase token at all,
    /// on a line from a build even older than `phase` itself) never counts.
    public static func countsTowardStreak(context: String) -> Bool {
        guard context.contains("in_call=1"), context.contains("native=1") else { return false }
        guard let p = phase(fromContext: context) else { return false }
        switch p {
        case .pc, .media, .snapshot:
            return true
        case .ring:
            return false
        }
    }
}
