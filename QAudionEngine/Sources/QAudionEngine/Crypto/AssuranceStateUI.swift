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
        /// W-NFCBADGE — `true` ONLY for `S2` (`.nfcAuthenticated`). Lets the view
        /// give S2 extra visual prominence (bigger/bolder, distinct from every
        /// other `.badge`-style state such as `S8`) WITHOUT switching on the raw
        /// `AssuranceState` case itself — `InCallScreen.assuranceSectionBody`'s own
        /// doc says it must only ever consume `Presentation`, never re-derive
        /// trust logic from the enum, so a future new state needs only a mapping
        /// here, not a new SwiftUI branch. Same pattern as `sasRequired`.
        public let isPhysicalPresenceProof: Bool

        public init(style: Style, message: String, sasRequired: Bool, isPhysicalPresenceProof: Bool = false) {
            self.style = style
            self.message = message
            self.sasRequired = sasRequired
            self.isPhysicalPresenceProof = isPhysicalPresenceProof
        }
    }

    /// Placeholder name for the shared key when the caller has no contact name.
    /// A computed value, so it follows the in-app language at call time.
    public static var defaultSecretLabel: String {
        String(localized: "trust.assurance.default_secret_label", defaultValue: "questo contatto", comment: "Lowercase fallback used inside the call security line 'Pre-shared key: <name>' when the contact's name is not known: 'this contact'")
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
        secretLabel: String = AssuranceStateUI.defaultSecretLabel
    ) -> Presentation {
        switch state {
        case .peerLegacy: // S0 — evaluated before every other state.
            var message = String(localized: "trust.assurance.peer_legacy", defaultValue: "L'app del contatto non supporta la conferma di presenza fisica multi-chiave.", comment: "In-call security notice: the other person's app is too old to support physical-presence (NFC or in-person) confirmation with several keys")
            if expectedNfc {
                // VERBATIM (design brief, S0's expectedNfc-appended clause).
                message += " " + String(localized: "trust.assurance.peer_legacy_expected_nfc", defaultValue: "L'app del contatto non supporta la conferma di presenza fisica.", comment: "In-call security notice appended to the previous one when an in-person confirmation was expected from this contact: their app does not support physical-presence confirmation")
            }
            return Presentation(style: .info, message: message, sasRequired: true)

        case .kcFailed: // S1
            return Presentation(
                style: .warning,
                message: String(localized: "trust.assurance.kc_failed", defaultValue: "Avviso di sicurezza: la verifica della chiave con l'altro partecipante non è riuscita. Questo può indicare un tentativo di intercettazione attivo.", comment: "In-call security warning: the key confirmation with the other participant failed, which may mean someone is actively intercepting the call"),
                sasRequired: true
            )

        case .nfcAuthenticated: // S2 — reachable since W-NFCBADGE (2026-07-23).
            return Presentation(
                style: .badge,
                message: String(localized: "trust.assurance.nfc_authenticated", defaultValue: "Autenticato di persona (NFC o QR + Bluetooth) + chiave pre-condivisa: \(secretLabel)", comment: "In-call security badge: the other person was authenticated in person (NFC tap or QR + Bluetooth pairing) and a pre-shared key is also in use. %@ is the contact's name"),
                sasRequired: false,
                isPhysicalPresenceProof: true
            )

        case .nfcIdentityMismatch: // S3
            return Presentation(
                style: .warning,
                // VERBATIM (design brief).
                message: String(localized: "trust.assurance.nfc_identity_mismatch", defaultValue: "Questa chiave NFC era stata stabilita con un'altra identità.", comment: "In-call security warning: the NFC key in use was originally established with a different identity than the one on this call"),
                sasRequired: true
            )

        case .nfcUnattestable: // S4
            return Presentation(
                style: .warning,
                // VERBATIM (design brief).
                message: String(localized: "trust.assurance.nfc_unattestable", defaultValue: "Chiave ripristinata da backup: la verifica di persona non è attestabile su questo dispositivo.", comment: "In-call security warning: the key was restored from a backup, so this device cannot prove that it was verified in person"),
                sasRequired: true
            )

        case .identityUnverified: // S5 — W-NOBRICK: warning only, call continues.
            return Presentation(
                style: .warning,
                message: String(localized: "trust.assurance.identity_unverified", defaultValue: "La firma di identità di questo scambio di chiavi non è stata verificata.", comment: "In-call security warning: the identity signature of this key exchange could not be verified; the call continues"),
                sasRequired: true
            )

        case .nfcPresentUnconfirmed: // S6
            return Presentation(
                style: .warning,
                // VERBATIM (design brief).
                message: String(localized: "trust.assurance.nfc_present_unconfirmed", defaultValue: "Chiave di presenza fisica presente, non confermata su questa chiamata.", comment: "In-call security warning: a physical-presence key exists for this contact but was not confirmed on this call"),
                sasRequired: true
            )

        case .expectedNfcStripped: // S7 — persistent in-call notice regardless.
            return Presentation(
                style: .warning,
                // VERBATIM (design brief).
                message: String(localized: "trust.assurance.expected_nfc_stripped", defaultValue: "La chiave di presenza fisica di questo contatto non è stata usata su questa chiamata.", comment: "In-call security warning: this contact has a physical-presence key but it was not used on this call"),
                sasRequired: true
            )

        case .pskConfirmed: // S8 — NEVER the word "authenticated" (design brief).
            return Presentation(
                style: .badge,
                message: String(localized: "trust.assurance.psk_confirmed", defaultValue: "Chiave pre-condivisa: \(secretLabel)", comment: "In-call security badge: a pre-shared key is in use. %@ is the contact's name. Never say 'authenticated' here"),
                sasRequired: false
            )

        case .pskUnconfirmed: // S9 — same wording as S8 + "non confermata".
            return Presentation(
                style: .info,
                message: String(localized: "trust.assurance.psk_unconfirmed", defaultValue: "Chiave pre-condivisa: \(secretLabel) (non confermata)", comment: "In-call security notice: a pre-shared key is in use but it was not confirmed on this call. %@ is the contact's name"),
                sasRequired: true
            )

        case .pqcOnly: // S10 — MUST NOT name any key (design brief).
            return Presentation(
                style: .info,
                // VERBATIM (design brief).
                message: String(localized: "trust.assurance.pqc_only", defaultValue: "Solo PQC (ML-KEM-1024 + X25519)", comment: "In-call security notice: only the post-quantum key exchange protects this call (no pre-shared key). PQC and the algorithm names stay untranslated"),
                sasRequired: true
            )
        }
    }
}
