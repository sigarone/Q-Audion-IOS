import SwiftUI

/// Brand-specific color extras NOT covered by the Material 3 ColorScheme.
/// 1:1 port of Android `QAudionColorsExtra` from QAudionColors.kt.
///
/// Trust / risk semantics for the security UI: `riskLow / riskMedium /
/// riskHigh`, `trustUnverified / trustSas / trustVoice / trustEnterprise`.
/// PQC accent color drives the "ML-KEM 1024" feature pill on Welcome
/// and any security-emphasis surface.
public struct QAudionColorsExtra: Equatable {
    public let success: Color
    public let onSuccess: Color
    public let warning: Color
    public let onWarning: Color

    public let riskLow: Color
    public let riskMedium: Color
    public let riskHigh: Color

    public let pqcAccent: Color
    public let trustUnverified: Color
    public let trustSas: Color
    public let trustVoice: Color
    public let trustEnterprise: Color

    public static let dark = QAudionColorsExtra(
        success:           Color(hex: 0x3DD598),
        onSuccess:         Color(hex: 0x00382A),
        warning:           Color(hex: 0xF2B73A),
        onWarning:         Color(hex: 0x3A2700),
        riskLow:           Color(hex: 0x3DD598),
        riskMedium:        Color(hex: 0xF2B73A),
        riskHigh:          Color(hex: 0xEB4D5D),
        pqcAccent:         Color(hex: 0xB388FF),
        trustUnverified:   Color(hex: 0x8892A6),
        trustSas:          Color(hex: 0x6EE7C5),
        trustVoice:        Color(hex: 0x3DD598),
        trustEnterprise:   Color(hex: 0x3E7BFF)
    )

    public static let light = QAudionColorsExtra(
        success:           Color(hex: 0x00A381),
        onSuccess:         Color(hex: 0xFFFFFF),
        warning:           Color(hex: 0xB07A00),
        onWarning:         Color(hex: 0xFFFFFF),
        riskLow:           Color(hex: 0x00A381),
        riskMedium:        Color(hex: 0xB07A00),
        riskHigh:          Color(hex: 0xEB4D5D),
        pqcAccent:         Color(hex: 0x6A3DDB),
        trustUnverified:   Color(hex: 0x5E6677),
        trustSas:          Color(hex: 0x00A381),
        trustVoice:        Color(hex: 0x00A381),
        trustEnterprise:   Color(hex: 0x3E7BFF)
    )
}

// MARK: - Environment plumbing

private struct QAudionExtrasKey: EnvironmentKey {
    static let defaultValue: QAudionColorsExtra = .dark
}

public extension EnvironmentValues {
    /// Brand color extras (`success / warning / risk* / trust* / pqcAccent`).
    /// Available everywhere `.qAudionTheme(...)` has been applied to the
    /// view tree.
    var qaudionExtras: QAudionColorsExtra {
        get { self[QAudionExtrasKey.self] }
        set { self[QAudionExtrasKey.self] = newValue }
    }
}

// MARK: - TrustChipColors (scheme-independent)

/// Phase-14d trust-chip swatches shared with Desktop. AAA against
/// `#141B22` (Q-Audion dark surface). Same value light + dark.
/// Source: Android `TrustChipColors.kt`.
public enum TrustChipColors {
    public static let cyan       = Color(hex: 0x00DAF3)
    public static let jade       = Color(hex: 0x52E3A5)
    public static let gold       = Color(hex: 0xF2B552)
    public static let mutedGrey  = Color(hex: 0x8892A0)
}
