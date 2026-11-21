import SwiftUI
import QAudionEngine

// MARK: - The shield every badge is drawn on

/// The Material "shield" filled-icon outline (24x24 grid) as a `Shape`, so the same outline can be filled with the state colour
/// AND stroked with the gold rim at once. Same path data as the other platforms, for a pixel-identical shape.
struct TrustShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var p = Path()
        p.move(to: pt(12, 1))
        p.addLine(to: pt(3, 5))
        p.addLine(to: pt(3, 11))
        p.addCurve(to: pt(12, 23), control1: pt(3, 16.55), control2: pt(6.84, 21.74))
        p.addCurve(to: pt(21, 11), control1: pt(17.16, 21.74), control2: pt(21, 16.55))
        p.addLine(to: pt(21, 5))
        p.addLine(to: pt(12, 1))
        p.closeSubpath()
        return p
    }
}

/// A colored shield with a small black symbol, template image or short label centered on it. `tint` alone carries the state; the
/// glyph says what the badge is about.
struct ShieldGlyph: View {
    enum Content {
        /// An SF Symbol.
        case symbol(String)
        /// A template image of the asset catalog (the two shared custom glyphs).
        case asset(String)
        /// A short text label (an acronym), shown as is.
        case text(String)
        case none
    }

    let tint: Color
    let content: Content
    var size: CGFloat = 36

    static let gold = LinearGradient(
        colors: [Color(red: 0.953, green: 0.824, blue: 0.478), Color(red: 0.831, green: 0.686, blue: 0.216), Color(red: 0.592, green: 0.443, blue: 0.106)],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        let k = size / 36
        ZStack {
            TrustShieldShape().fill(tint)
            TrustShieldShape().stroke(Self.gold, lineWidth: 1.6 * k)
            Circle().fill(Self.gold).frame(width: 3.4 * k, height: 3.4 * k).offset(x: -12.6 * k, y: -10.2 * k)
            Circle().fill(Self.gold).frame(width: 3.4 * k, height: 3.4 * k).offset(x: 12.6 * k, y: -10.2 * k)
            switch content {
            case .symbol(let name):
                Image(systemName: name)
                    .qaudionScaledFont(size: 15 * k, weight: .bold, maxSize: .xLarge)
                    .foregroundStyle(.black)
            case .asset(let name):
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18 * k, height: 18 * k)
                    .foregroundStyle(.black)
            case .text(let text):
                Text(verbatim: text)
                    .qaudionScaledFont(size: 9 * k, weight: .bold, design: .monospaced, family: .label, maxSize: .xLarge)
                    .tracking(0.2)
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            case .none:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - The identity shield

extension IdentityShield {

    /// The colour of the state, from the one colour language: grey pending, green verified, purple to verify, red changed.
    func tint(_ extras: QAudionColorsExtra) -> Color {
        switch self {
        case .pending: return extras.neutral
        case .verified: return extras.success
        case .toVerify: return extras.toVerify
        case .changed: return extras.riskHigh
        }
    }

    /// The state glyph of the small shield: check, question mark, exclamation mark, dash.
    var symbolName: String {
        switch self {
        case .pending: return "minus"
        case .verified: return "checkmark"
        case .toVerify: return "questionmark"
        case .changed: return "exclamationmark"
        }
    }

    /// The short word of the state, for a chip or a header line.
    var stateWord: String {
        switch self {
        case .pending:
            return String(localized: "trust.state.pending", defaultValue: "Verifica non disponibile", comment: "Identity shield state word of a contact: the check is not available yet")
        case .verified:
            return String(localized: "trust.state.verified", defaultValue: "Verificato", comment: "Identity shield state word of a contact: the key of the contact is verified")
        case .toVerify:
            return String(localized: "trust.state.to_verify", defaultValue: "Da verificare", comment: "Identity shield state word of a contact: the key was never verified")
        case .changed:
            return String(localized: "trust.state.changed", defaultValue: "Identità cambiata", comment: "Identity shield state word of a contact: the key of the contact changed after the verification")
        }
    }

    /// VoiceOver sentence of the contact-level shield (list, detail, chats, car).
    var contactAccessibilityLabel: String {
        switch self {
        case .pending:
            return String(localized: "trust.a11y.pending", defaultValue: "Verifica non disponibile", comment: "VoiceOver label of the contact identity shield while the check is not available")
        case .verified:
            return String(localized: "trust.a11y.verified", defaultValue: "Contatto verificato", comment: "VoiceOver label of the contact identity shield: verified")
        case .toVerify:
            return String(localized: "trust.a11y.to_verify", defaultValue: "Contatto da verificare", comment: "VoiceOver label of the contact identity shield: never verified")
        case .changed:
            return String(localized: "trust.a11y.changed", defaultValue: "Identità del contatto cambiata", comment: "VoiceOver label of the contact identity shield: the key changed")
        }
    }

    /// VoiceOver sentence of the call-level shield (the SAS badge of the trust bar).
    var callAccessibilityLabel: String {
        switch self {
        case .pending:
            return String(localized: "sas.accessibility.pending", defaultValue: "Identità in verifica", comment: "Call screen, VoiceOver label of the SAS shield while the identity check of the call is running")
        case .verified:
            return String(localized: "sas.accessibility.verified", defaultValue: "Identità verificata: la chiave di questa chiamata è quella che hai già verificato", comment: "Call screen, VoiceOver label of the SAS shield: the key of this call is the one already verified")
        case .toVerify:
            return String(localized: "sas.accessibility.to_verify", defaultValue: "Identità da verificare: non hai mai verificato la chiave di questo contatto", comment: "Call screen, VoiceOver label of the SAS shield: the key of this contact was never verified")
        case .changed:
            return String(localized: "sas.accessibility.changed", defaultValue: "Attenzione: la chiave del contatto non è quella che avevi verificato", comment: "Call screen, VoiceOver label of the SAS shield: the key is not the one that was verified")
        }
    }

    /// The explanation under the shield of the contact detail.
    var contactExplanation: String {
        switch self {
        case .pending:
            return String(localized: "trust.explain.pending", defaultValue: "L'identità di questo contatto non è ancora disponibile.", comment: "Contact detail, explanation of the identity shield while the identity is not available")
        case .verified:
            return String(localized: "trust.explain.verified", defaultValue: "Hai verificato la chiave attuale di questo contatto. Decade da sola se cambia chiave.", comment: "Contact detail, explanation of the identity shield: verified")
        case .toVerify:
            return String(localized: "trust.explain.to_verify", defaultValue: "Chiave fissata al primo contatto, mai verificata. Se qualcuno si fosse messo in mezzo fin dall'inizio non te ne accorgeresti: confronta il codice di sicurezza.", comment: "Contact detail, explanation of the identity shield: pinned at first contact, never verified")
        case .changed:
            return String(localized: "trust.explain.changed", defaultValue: "La chiave di questo contatto è cambiata dopo la tua verifica. Verifica di nuovo prima di fidarti.", comment: "Contact detail, explanation of the identity shield: the key changed after the verification")
        }
    }
}

/// The ONE view of the identity shield, for every surface: the call bar (36, with the "SAS" label), the contact detail (36, with
/// the label), the chat header (28) and the lists (20, with the state glyph). Purely a function of the shield value.
struct IdentityShieldBadge: View {
    @Environment(\.qaudionExtras) private var extras

    let shield: IdentityShield
    var size: CGFloat = 20
    /// Draw the "SAS" label instead of the state glyph (the call bar and the contact detail).
    var showsLabel: Bool = false
    /// VoiceOver text; the contact-level sentence when nil.
    var accessibilityText: String?

    var body: some View {
        ShieldGlyph(tint: shield.tint(extras),
                    content: showsLabel ? .text("SAS") : .symbol(shield.symbolName),
                    size: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText ?? shield.contactAccessibilityLabel)
    }
}

/// The identity shield of a stored contact outside a call: the same badge as the contact list and the contact detail, read from the
/// shared cache so a list of conversations does not read the stores once per row. Grey for a user that is not a stored contact.
struct ContactShieldBadge: View {
    @ObservedObject private var cache = ContactShieldCache.shared

    let userId: String
    var size: CGFloat = 20

    var body: some View {
        IdentityShieldBadge(shield: cache.shield(for: userId), size: size)
    }
}
