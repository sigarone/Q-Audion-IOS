import SwiftUI

/// Traffic-light voice-trust indicator. 1:1 port di
/// `qaudion-android-new/core/core-ui/.../components/VoiceTrustIndicator.kt`.
///
/// Mappa un confidence index `[0.0, 1.0]` su 3 livelli:
///   - `index ≥ 0.80` → `.success` ("Voce verificata")
///   - `index ≥ 0.50` → `.warning` ("Voce incerta")
///   - `index  < 0.50` → `.riskHigh` ("Voce sconosciuta")
///
/// Animazione: cerchio 28pt con border + glow tinted alla soglia
/// corrente, smoothly cross-fade quando l'index cambia categoria.
///
/// Layout opzionale:
///   - `showLabel == true` (default) → cerchio + label inline
///   - `showLabel == false` → solo cerchio (uso compatto in chip)
struct VoiceTrustIndicator: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    let index: Float
    let showLabel: Bool

    init(index: Float, showLabel: Bool = true) {
        self.index = index
        self.showLabel = showLabel
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(toneColor.opacity(0.18))
                    .frame(width: 28, height: 28)
                Circle()
                    .stroke(toneColor.opacity(0.55), lineWidth: 1)
                    .frame(width: 28, height: 28)
                Circle()
                    .fill(toneColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: toneColor.opacity(0.5), radius: 4)
            }
            .animation(.easeInOut(duration: 0.25), value: toneCategory)

            if showLabel {
                VStack(alignment: .leading, spacing: 2) {
                    Text(toneLabel)
                        .qaudionStyle(type.labelMedium)
                        .foregroundStyle(toneColor)
                    Text(String(format: "C=%.2f", clampedIndex))
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
            }
        }
    }

    // MARK: - Helpers

    private var clampedIndex: Double {
        Double(max(0, min(1, index)))
    }

    private var toneCategory: Int {
        if clampedIndex >= 0.80 { return 0 }
        if clampedIndex >= 0.50 { return 1 }
        return 2
    }

    private var toneColor: Color {
        switch toneCategory {
        case 0:  return extras.success
        case 1:  return extras.warning
        default: return extras.riskHigh
        }
    }

    private var toneLabel: String {
        switch toneCategory {
        case 0:  return "Voce verificata"
        case 1:  return "Voce incerta"
        default: return "Voce sconosciuta"
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        VoiceTrustIndicator(index: 0.95)
        VoiceTrustIndicator(index: 0.72)
        VoiceTrustIndicator(index: 0.30)
        VoiceTrustIndicator(index: 0.95, showLabel: false)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .qAudionTheme(dark: true)
}
