import Foundation

/// Soglie cross-platform per il confidence-index del DeepfakeMonitor.
/// Identiche a Android `ConfidenceLevel` enum (Verified/Caution/HighRisk).
///
/// Promosse a costanti tipate dopo che NVIDIA review (v1.0.81) ha
/// flaggato le 3 occorrenze duplicate dei letterali `0.80` / `0.50`
/// across `InCallScreen`, `SessionStatusStrip`, `VoiceTrustIndicator` e
/// `LiveInCallScreen`. Adesso un solo edit propaga il threshold a tutto
/// il design system.
public enum ConfidenceThresholds {
    // Calibrated for the 2.63% EER model. Genuine voice scores 0.7–0.99 reliably.
    /// `index >= verified` → `extras.success` (verde, "Voce verificata")
    public static let verified: Double = 0.70   // was 0.80
    /// `verified > index >= caution` → `extras.warning` (ambra, "Voce incerta")
    public static let caution: Double = 0.25    // was 0.50 — alarm only at extremely low scores
    // Sotto `caution` → `extras.riskHigh` (rosso, "Voce sconosciuta")

    /// Helper di categorizzazione comune. Restituisce 0 (verified),
    /// 1 (caution), 2 (high-risk).
    public static func category(of index: Double) -> Int {
        let clamped = max(0, min(1, index))
        if clamped >= verified { return 0 }
        if clamped >= caution  { return 1 }
        return 2
    }

    /// Display tone of a confidence value that may be "no reading".
    public enum Tone: Equatable {
        /// No score yet (`AppState.confidenceScore`'s -1 sentinel, or a non-finite value): painted neutral,
        /// like the "C=—" text — never green, amber or red.
        case noReading
        case verified
        case caution
        case highRisk
    }

    /// W-CONFNEUTRAL (2026-10-07). `category(of:)` clamps first, so the -1 "no score yet" sentinel became 0 and
    /// painted the in-call avatar halo RED until Tier 2's first reading (10-16 s into a call, the whole call if
    /// it never reads). Views that may receive the sentinel use this instead.
    public static func tone(of index: Double) -> Tone {
        guard index.isFinite, index >= 0 else { return .noReading }
        switch category(of: index) {
        case 0:  return .verified
        case 1:  return .caution
        default: return .highRisk
        }
    }
}
