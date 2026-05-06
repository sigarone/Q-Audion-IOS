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
    /// `index >= verified` → `extras.success` (verde, "Voce verificata")
    public static let verified: Double = 0.80
    /// `verified > index >= caution` → `extras.warning` (ambra, "Voce incerta")
    public static let caution: Double = 0.50
    // Sotto `caution` → `extras.riskHigh` (rosso, "Voce sconosciuta")

    /// Helper di categorizzazione comune. Restituisce 0 (verified),
    /// 1 (caution), 2 (high-risk).
    public static func category(of index: Double) -> Int {
        let clamped = max(0, min(1, index))
        if clamped >= verified { return 0 }
        if clamped >= caution  { return 1 }
        return 2
    }
}
