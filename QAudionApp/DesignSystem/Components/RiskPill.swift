import SwiftUI

/// Risk level capsule. 1:1 port di
/// `qaudion-android-new/core/core-ui/.../components/RiskPill.kt`.
///
/// Tre livelli di rischio mutuamente esclusivi:
///   - `.low`     → `extras.riskLow` (verde) — "RISCHIO BASSO"
///   - `.medium`  → `extras.riskMedium` (ambra) — "RISCHIO MEDIO"
///   - `.high`    → `extras.riskHigh` (rosso) — "RISCHIO ALTO"
///
/// Capsule mono labelSmall 1.2sp tracking, fill `accent @ 0.18α`,
/// border `accent @ 0.55α`. Etichetta opzionalmente sostituibile via
/// `customLabel:` (es. "ALTO RISCHIO · DEEPFAKE" durante una chiamata).
struct RiskPill: View {
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    enum Level: Equatable {
        case low
        case medium
        case high
    }

    let level: Level
    let customLabel: String?

    init(_ level: Level, customLabel: String? = nil) {
        self.level = level
        self.customLabel = customLabel
    }

    var body: some View {
        label
            .qaudionStyle(type.labelSmall)
            .tracking(1.2)
            .foregroundStyle(accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(accent.opacity(0.18)))
            .overlay(Capsule().stroke(accent.opacity(0.55), lineWidth: 1))
    }

    /// The three standard labels are catalog keys (`risk_pill.low`, `.medium`,
    /// `.high`, in the six app languages). `customLabel` is shown as given:
    /// whoever passes it passes text that is already localized.
    private var label: Text {
        if let customLabel { return Text(verbatim: customLabel) }
        switch level {
        case .low:    return Text("risk_pill.low")
        case .medium: return Text("risk_pill.medium")
        case .high:   return Text("risk_pill.high")
        }
    }

    private var accent: Color {
        switch level {
        case .low:    return extras.riskLow
        case .medium: return extras.riskMedium
        case .high:   return extras.riskHigh
        }
    }
}

#Preview {
    HStack(spacing: 8) {
        RiskPill(.low)
        RiskPill(.medium)
        RiskPill(.high)
        RiskPill(.high, customLabel: "ALTO · DEEPFAKE")
    }
    .padding()
    .frame(maxWidth: .infinity)
    .background(Color.black)
    .qAudionTheme(dark: true)
}
