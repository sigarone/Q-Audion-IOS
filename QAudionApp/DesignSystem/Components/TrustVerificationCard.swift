import SwiftUI

/// Stato di verifica del safety number. 1:1 port di
/// `qaudion-android-new/core/core-ui/.../components/TrustVerificationCard.kt`
/// (`SafetyNumberState`).
public enum TrustSafetyNumberState: Equatable {
    /// Calcolo trust ancora in corso (HKDF non completato).
    case unverified
    /// First-contact pinned (TOFU). Stesso fingerprint, mai verificato out-of-band.
    case identityPinnedTofu
    /// Utente ha confermato l'identità out-of-band.
    case userVerified
    /// L'identità del peer è cambiata (rotation rilevata vs pinned).
    case identityChanged
}

/// Risultato della derivazione safety number (HKDF-SHA256 cross-platform).
/// 12 gruppi da 5 cifre = 60 cifre totali, mostrate in griglia 4 colonne × 3 righe.
public struct TrustSafetyNumber: Equatable {

    /// Numero canonico di gruppi in un safety number Q-Audion. Cross-
    /// platform constant (Android `SafetyNumber.GROUP_COUNT`).
    public static let groupCount: Int = 12
    /// Cifre per gruppo (zero-padded). Total digits = `groupCount * digitsPerGroup` = 60.
    public static let digitsPerGroup: Int = 5
    /// Colonne della griglia di display. `groupCount / gridColumns` = 3 righe.
    public static let gridColumns: Int = 4

    public let groups: [String]   // 12 elementi, ognuno 5 cifre zero-padded
    public let fingerprintHex: String  // 60 hex chars (output 30-byte HKDF)

    public init(groups: [String], fingerprintHex: String = "") {
        self.groups = groups
        self.fingerprintHex = fingerprintHex
    }

    /// Helper preview: mock con 12 gruppi numerici.
    public static let mock = TrustSafetyNumber(
        groups: [
            "54000", "44743", "06999", "97232",
            "11827", "39158", "67204", "85019",
            "20473", "88301", "59672", "31048"
        ],
        fingerprintHex: "1f3a8b07c9d514f2a87e2a1d0f5bb1a2e9c3"
            + "d05a4f1e7b6c92d8a3f0"
    )
}

/// Verification method selezionato. Le 5 opzioni hard-coded matchano l'Android source.
public enum TrustVerificationMethod: String, CaseIterable, Equatable {
    case inPerson    = "in-person"
    case qr          = "qr"
    case nfc         = "nfc"
    case antiReplay  = "anti-replay"
    case voice       = "voice"

    public var localized: String {
        switch self {
        case .inPerson:   return "In persona"
        case .qr:         return "QR scan"
        case .nfc:        return "NFC"
        case .antiReplay: return "Anti-replay (in-call SAS)"
        case .voice:      return "Voce"
        }
    }
}

/// Card mission-critical per la verifica safety-number cross-platform.
/// 1:1 visual port di Android `TrustVerificationCard`. Single source of
/// truth per lo stato di verifica del peer.
///
/// Layout (top → bottom):
///   1. Header — icona + label + (opzionale) timestamp verifica
///   2. Hairline divider
///   3. Grid 4×3 dei 12 gruppi safety-number, mono 14pt centered
///   4. Hairline divider
///   5. Action footer state-dependent:
///        UNVERIFIED          → "Calcolo del trust in corso…"
///        IDENTITY_PINNED_TOFU → "Mark as verified" Menu (5 metodi)
///        USER_VERIFIED       → "✓ Verificato {metodo} il {data}" + "Re-verify"
///        IDENTITY_CHANGED    → banner errorContainer + "I trust the new
///                               identity" + ConfirmDialog
public struct TrustVerificationCard: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    public let state: TrustSafetyNumberState
    public let safetyNumber: TrustSafetyNumber
    public let verifiedAt: Date?
    public let verificationMethod: TrustVerificationMethod?
    public let onMarkVerified: (TrustVerificationMethod) -> Void
    public let onAcceptNewFingerprint: () -> Void

    @State private var showingAcceptDialog = false

    public init(state: TrustSafetyNumberState,
                safetyNumber: TrustSafetyNumber,
                verifiedAt: Date? = nil,
                verificationMethod: TrustVerificationMethod? = nil,
                onMarkVerified: @escaping (TrustVerificationMethod) -> Void = { _ in },
                onAcceptNewFingerprint: @escaping () -> Void = {}) {
        self.state = state
        self.safetyNumber = safetyNumber
        self.verifiedAt = verifiedAt
        self.verificationMethod = verificationMethod
        self.onMarkVerified = onMarkVerified
        self.onAcceptNewFingerprint = onAcceptNewFingerprint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            hairline
            grid
            hairline
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor.opacity(0.45), lineWidth: 1)
        )
        .alert("Confermi il nuovo safety number?",
               isPresented: $showingAcceptDialog) {
            Button("Annulla", role: .cancel) {}
            Button("Sì, accetto") { onAcceptNewFingerprint() }
        } message: {
            Text("Procedi solo se hai verificato il nuovo numero col contatto fuori dall'app. Questo accetta la rotazione di chiave permanente.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: headerIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(headerColor)
                .frame(width: 22, height: 22)
            Text(headerLabel)
                .qaudionStyle(type.labelLarge)
                .foregroundStyle(headerColor)
            Spacer()
            if state == .userVerified, let dateLabel {
                Text(dateLabel)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
        }
    }

    private var headerIcon: String {
        switch state {
        case .unverified:          return "exclamationmark.triangle.fill"
        case .identityPinnedTofu:  return "lock.fill"
        case .userVerified:        return "checkmark.circle.fill"
        case .identityChanged:     return "exclamationmark.octagon.fill"
        }
    }

    private var headerLabel: String {
        switch state {
        case .unverified:          return "Non verificato"
        case .identityPinnedTofu:  return "Pinned (TOFU)"
        case .userVerified:        return "Verificato"
        case .identityChanged:     return "🚨 Identità cambiata"
        }
    }

    private var headerColor: Color {
        switch state {
        case .unverified:          return scheme.onSurfaceVariant
        case .identityPinnedTofu:  return scheme.tertiary
        case .userVerified:        return scheme.primary
        case .identityChanged:     return extras.riskHigh
        }
    }

    private var borderColor: Color {
        switch state {
        case .userVerified:    return scheme.primary
        case .identityChanged: return extras.riskHigh
        default:               return scheme.outline
        }
    }

    // MARK: - Hairline

    private var hairline: some View {
        Rectangle()
            .fill(scheme.outline.opacity(0.35))
            .frame(height: 0.5)
    }

    // MARK: - Grid

    private var grid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Safety number")
                .qaudionStyle(type.labelLarge)
                .foregroundStyle(scheme.onSurface)

            // NVIDIA review on v1.0.80 flagged the bare `12` / `4`
            // literals as magic numbers. Promoted to constants on
            // TrustSafetyNumber so any future change (es. groupCount = 8
            // for a shorter format) propagates uniformly.
            let groupCount  = TrustSafetyNumber.groupCount
            let gridColumns = TrustSafetyNumber.gridColumns

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6),
                               count: gridColumns),
                spacing: 6
            ) {
                ForEach(0..<min(groupCount, safetyNumber.groups.count), id: \.self) { idx in
                    digitCell(safetyNumber.groups[idx], index: idx)
                }
                // Padding rows se groups < groupCount — manteniamo la
                // griglia sempre 4×3.
                let missing = max(0, groupCount - safetyNumber.groups.count)
                if missing > 0 {
                    ForEach(0..<missing, id: \.self) { _ in
                        digitCell("·····", index: -1)
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func digitCell(_ digits: String, index: Int) -> some View {
        Text(digits)
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .foregroundStyle(scheme.onSurface)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(scheme.surfaceVariant)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(scheme.outline.opacity(0.4), lineWidth: 1)
            )
            .accessibilityLabel(index >= 0
                ? "Gruppo \(index + 1): \(digits.map(String.init).joined(separator: " "))"
                : "Gruppo non disponibile")
    }

    // MARK: - Footer (state-dependent)

    @ViewBuilder
    private var footer: some View {
        switch state {
        case .unverified:
            Text("Calcolo del trust in corso…")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        case .identityPinnedTofu:
            markAsVerifiedMenu
        case .userVerified:
            verifiedFooter
        case .identityChanged:
            identityChangedActions
        }
    }

    // MARK: - "Mark as verified" menu

    private var markAsVerifiedMenu: some View {
        Menu {
            ForEach(TrustVerificationMethod.allCases, id: \.self) { method in
                Button(method.localized) { onMarkVerified(method) }
            }
        } label: {
            HStack {
                Text("Marca come verificato")
                    .qaudionStyle(type.labelLarge)
                    .foregroundStyle(scheme.onPrimary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(scheme.onPrimary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(scheme.primary)
            )
        }
    }

    // MARK: - Verified footer (timestamp + Re-verify menu)

    @ViewBuilder
    private var verifiedFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let methodLabel, let dateLabel {
                Text("✓ Verificato via \(methodLabel) il \(dateLabel)")
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            Menu {
                ForEach(TrustVerificationMethod.allCases, id: \.self) { method in
                    Button(method.localized) { onMarkVerified(method) }
                }
            } label: {
                HStack {
                    Text("Re-verifica")
                        .qaudionStyle(type.labelLarge)
                        .foregroundStyle(scheme.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(scheme.primary)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(scheme.primary, lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Identity-changed actions

    private var identityChangedActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(extras.riskHigh)
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.top, 1)
                Text("L'identità di questo contatto è cambiata. Verifica il nuovo safety number out-of-band prima di inviare informazioni sensibili.")
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(extras.riskHigh)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(extras.riskHigh.opacity(0.15))
            )

            Button {
                showingAcceptDialog = true
            } label: {
                Text("Accetto la nuova identità")
                    .qaudionStyle(type.labelLarge)
                    .foregroundStyle(scheme.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(extras.riskHigh)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private static let verificationDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var dateLabel: String? {
        guard let verifiedAt else { return nil }
        return Self.verificationDateFormatter.string(from: verifiedAt)
    }

    private var methodLabel: String? {
        verificationMethod?.localized
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(spacing: 16) {
            TrustVerificationCard(
                state: .unverified,
                safetyNumber: TrustSafetyNumber(groups: [], fingerprintHex: "")
            )
            TrustVerificationCard(
                state: .identityPinnedTofu,
                safetyNumber: .mock,
                onMarkVerified: { method in
                    print("[Preview] mark verified via \(method.localized)")
                }
            )
            TrustVerificationCard(
                state: .userVerified,
                safetyNumber: .mock,
                verifiedAt: Date().addingTimeInterval(-86_400),
                verificationMethod: .voice
            )
            TrustVerificationCard(
                state: .identityChanged,
                safetyNumber: .mock,
                onAcceptNewFingerprint: {
                    print("[Preview] accepted new fingerprint")
                }
            )
        }
        .padding(16)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .qAudionTheme(dark: true)
}
