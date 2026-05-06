import Foundation

/// Canonical constants for every Short-Authentication-String (SAS)
/// derivation in Q-Audion.
///
/// **Cross-platform contract:** these byte sequences MUST match Android's
/// `qaudion-engine/.../crypto/SasConstants.kt` byte-for-byte. A drift
/// here means two same-version peers see different SAS words and the
/// ceremony silently diverges.
///
/// Adopted 2026-04-28: prior versions of the iOS app had no SAS engine
/// (the InCallScreen displayed hardcoded placeholder words). Going
/// forward the in-call SAS is a deterministic function of the shared
/// session key — see `ComputeSasUseCase.swift`.
public enum SasConstants {
    /// Canonical HKDF salt for both SAS paths. UTF-8, 14 bytes.
    public static let salt = "qaudion-sas-v1"
    public static let saltBytes = Data("qaudion-sas-v1".utf8)

    /// HKDF info for the 6-decimal-digit NFC SAS. Reserved for parity
    /// with the (Android-only) NFC ceremony — iOS doesn't ship the NFC
    /// flow yet, but keep the constant aligned for the future port.
    public static let infoDigits = "sas-digits-v1"
    public static let infoDigitsBytes = Data("sas-digits-v1".utf8)

    /// HKDF info for the 6-PGP-word in-call SAS.
    public static let infoWords = "sas-words-v1"
    public static let infoWordsBytes = Data("sas-words-v1".utf8)

    public static let digitCount = 6
    public static let wordCount = 6
}
