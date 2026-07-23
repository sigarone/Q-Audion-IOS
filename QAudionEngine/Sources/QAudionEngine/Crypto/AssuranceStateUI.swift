import Foundation

/// W-ASSURANCE (multi-PSK-mixing SYNTHESIS.md ship step 6) — the pure
/// `AssuranceState` → user-facing copy/style mapping consumed by the
/// in-call security sheet (`InCallScreen`) for the LIVE per-call verdict.
///
/// **Deliberately NOT the same type/widget as the historical presence badge**
/// (`ContactsStore.PresenceAuth`, rendered by `ContactDetailScreen
/// .presenceAuthCard` — see that property's doc). This module renders ONLY
/// what THIS handshake, right now, actually proved — never a contact's
/// history. Mixing the two into one widget is exactly the anti-pattern the
/// design doc's "two things that must never share a widget" section calls out.
///
/// **Copy provenance.** The design brief quotes EXACT Italian strings for
/// S3/S4/S6/S7/S10 — those are reproduced VERBATIM below (see the inline
/// `// VERBATIM` markers). S0/S1/S2/S5/S8/S9 are only described
/// semantically ("prominent warning, active-attack signature", "badge names
/// both mixed secrets", …) with no pinned exact string — the copy for those
/// is this file's own reasonable rendering of that semantic description,
/// NOT a quote from the brief. Flagged honestly here (and in the PR/report)
/// as a copy surface a designer/PM should review before shipping user-facing
/// text, same as any other first-draft UI string.
public enum AssuranceStateUI {

    /// Visual treatment bucket — `InCallScreen` picks a chip/banner style
    /// off this rather than switching on the raw `AssuranceState` case
    /// itself, so a future new state only needs a `Style` mapping, not new
    /// SwiftUI branches at every call site.
    public enum Style: Equatable {
        /// Positive/neutral badge chip (S2, S8).
        case badge
        /// Amber/red non-blocking warning banner (S1, S3, S4, S5, S6, S7).
        /// W-NOBRICK: `warning` NEVER means "call dropped" — every one of
        /// these states leaves the call running; `warning` only selects the
        /// visual treatment.
        case warning
        /// Neutral informational banner, no trust claim either way (S0, S9,
        /// S10).
        case info
    }

    /// One presentation — style, the message to render, and whether the
    /// live SAS ceremony (`InCallScreen`'s existing 6-word compare UI) should
    /// be surfaced/insisted on for this state. `sasRequired` mirrors the
    /// design brief's own "SAS required"/"SAS demanded" column; `false` for
    /// S2 (the highest trust tier — physical NFC proximity already exceeds
    /// what a verbal SAS compare proves) and for S8 ("SAS existing rules" in
    /// the brief — read as "this feature adds no NEW requirement here",
    /// deferring to whatever pre-existing per-call SAS policy already
    /// governs the call rather than asserting one).
    public struct Presentation: Equatable {
        public let style: Style
        public let message: String
        public let sasRequired: Bool
    }

    /// - Parameters:
    ///   - state: this call's live `AssuranceState.decide()` verdict.
    ///   - expectedNfc: ONLY consulted for `S0` — whether this contact
    ///     previously reached `S2` (the persisted `presenceFloor`). `S0`'s
    ///     copy in the brief is a COMPOUND: the generic legacy-peer notice,
    ///     PLUS an additional note appended specifically when a physical
    ///     presence proof was expected of this now-legacy peer. Every other
    ///     state's copy is a pure function of `state` alone.
    ///   - secretLabel: the human-readable name to substitute into `S2`'s
    ///     "names both mixed secrets" / `S8`/`S9`'s `"Chiave pre-condivisa:
    ///     <name>"` templates — the CALLER'S contact display name, NEVER a
    ///     raw UUID (standing project rule). Defaults to a generic
    ///     placeholder when the caller has no resolved name at hand; ignored
    ///     entirely for every other state (in particular `S10`, which the
    ///     brief explicitly says "MUST NOT name any key").
    public static func present(
        state: AssuranceState,
        expectedNfc: Bool = false,
        secretLabel: String = "questo contatto"
    ) -> Presentation {
        switch state {
        case .peerLegacy: // S0 — evaluated before every other state.
            var message = "L'app del contatto non supporta la conferma di presenza fisica multi-chiave."
            if expectedNfc {
                // VERBATIM (design brief, S0's expectedNfc-appended clause).
                message += " L'app del contatto non supporta la conferma di presenza fisica."
            }
            return Presentation(style: .info, message: message, sasRequired: true)

        case .kcFailed: // S1
            return Presentation(
                style: .warning,
                message: "Avviso di sicurezza: la verifica della chiave con l'altro partecipante non è riuscita. "
                    + "Questo può indicare un tentativo di intercettazione attivo.",
                sasRequired: true
            )

        case .nfcAuthenticated: // S2 — unreachable this step (N<=1 everywhere).
            return Presentation(
                style: .badge,
                message: "Autenticato di persona (tap NFC) + chiave pre-condivisa: \(secretLabel)",
                sasRequired: false
            )

        case .nfcIdentityMismatch: // S3
            return Presentation(
                style: .warning,
                // VERBATIM (design brief).
                message: "Questa chiave NFC era stata stabilita con un'altra identità.",
                sasRequired: true
            )

        case .nfcUnattestable: // S4
            return Presentation(
                style: .warning,
                // VERBATIM (design brief).
                message: "Chiave ripristinata da backup: la verifica di persona non è attestabile su questo dispositivo.",
                sasRequired: true
            )

        case .identityUnverified: // S5 — W-NOBRICK: warning only, call continues.
            return Presentation(
                style: .warning,
                message: "La firma di identità di questo scambio di chiavi non è stata verificata.",
                sasRequired: true
            )

        case .nfcPresentUnconfirmed: // S6
            return Presentation(
                style: .warning,
                // VERBATIM (design brief).
                message: "Chiave di presenza fisica presente, non confermata su questa chiamata.",
                sasRequired: true
            )

        case .expectedNfcStripped: // S7 — persistent in-call notice regardless.
            return Presentation(
                style: .warning,
                // VERBATIM (design brief).
                message: "La chiave di presenza fisica di questo contatto non è stata usata su questa chiamata.",
                sasRequired: true
            )

        case .pskConfirmed: // S8 — NEVER the word "authenticated" (design brief).
            return Presentation(
                style: .badge,
                message: "Chiave pre-condivisa: \(secretLabel)",
                sasRequired: false
            )

        case .pskUnconfirmed: // S9 — same wording as S8 + "non confermata".
            return Presentation(
                style: .info,
                message: "Chiave pre-condivisa: \(secretLabel) (non confermata)",
                sasRequired: true
            )

        case .pqcOnly: // S10 — MUST NOT name any key (design brief).
            return Presentation(
                style: .info,
                // VERBATIM (design brief).
                message: "Solo PQC (ML-KEM-1024 + X25519)",
                sasRequired: true
            )
        }
    }
}
