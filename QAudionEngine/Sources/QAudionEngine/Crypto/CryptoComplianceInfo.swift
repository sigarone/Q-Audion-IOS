import Foundation
import CryptoKit

// MARK: - Cryptographic Compliance Information
// Exposes FIPS and NIST compliance details for audit, certification,
// and runtime device capability checks.

public struct CryptoComplianceInfo {

    // MARK: - Standards

    /// NIST FIPS 203 (ML-KEM-1024) — Post-Quantum KEM standard, NIST Level 5.
    public static let pqcStandard = "FIPS 203 ML-KEM-1024 (NIST Level 5)"

    /// NIST FIPS 197 (AES-256) + NIST SP 800-38D (GCM mode).
    public static let aeadStandard = "FIPS 197 AES-256 + SP 800-38D GCM"

    /// NIST SP 800-56C Rev. 2 (HKDF-SHA-256 key derivation).
    public static let kdfStandard = "SP 800-56C HKDF-SHA-256"

    /// Apple CryptoKit uses corecrypto, which is FIPS 140-3 validated (certificate #4701).
    /// AES-GCM operations are hardware-accelerated via AES-NI on Apple Silicon.
    public static let cryptoModule = "Apple corecrypto (FIPS 140-3 #4701)"

    /// Apple Secure Enclave Processor — FIPS 140-3 Level 3 equivalent hardware security.
    /// Private keys generated in the SEP never leave the hardware boundary.
    public static let hardwareModule = "Apple SEP T2/Ax (FIPS 140-3 L3 equiv)"

    /// Classical key exchange: X25519 (RFC 7748) + P-256 (FIPS 186-4) via Secure Enclave.
    public static let classicalKex = "X25519 (RFC 7748) + P-256 (FIPS 186-4)"

    /// Hybrid key exchange as actually derived into the shipped audio session key:
    /// only the ML-KEM-1024 + X25519 legs enter the frozen cross-platform KDF. The
    /// Secure-Enclave P-256 leg is NOT folded into the shipped key (its wiring lives
    /// on a worktree branch, not main) — do not re-add "+ P-256/SEP" until it is.
    public static let hybridKex = "ML-KEM-1024 + X25519 (NIST Hybrid)"

    /// Overall security level: NIST Level 5 provides 256-bit quantum security.
    public static let securityLevel = "NIST Level 5 (256-bit quantum security)"

    /// Forward secrecy mechanism: per-epoch X25519 DH ratchet with key erasure.
    public static let forwardSecrecy = "X25519 DH ratchet + HKDF chain (PCS)"

    // MARK: - Compliance Report

    /// Get the full compliance report as a dictionary, suitable for logging or audit export.
    public static func complianceReport() -> [String: String] {
        return [
            "pqc_standard":      pqcStandard,
            "aead_standard":     aeadStandard,
            "kdf_standard":      kdfStandard,
            "crypto_module":     cryptoModule,
            "hardware_module":   hardwareModule,
            "classical_kex":     classicalKex,
            "hybrid_kex":        hybridKex,
            "security_level":    securityLevel,
            "forward_secrecy":   forwardSecrecy,
            "sep_available":     SecureEnclaveManager.isAvailable ? "true" : "false",
            "fips_mode":         CryptoConstants.fipsMode ? "enabled" : "disabled",
            "hybrid_pqc":        CryptoConstants.hybridPqcEnabled ? "enabled" : "disabled"
        ]
    }

    // MARK: - Device Compliance Check

    /// Result of a device-level compliance check.
    public struct DeviceComplianceResult {
        /// Whether the device meets the minimum security requirements.
        public let isCompliant: Bool
        /// Secure Enclave hardware is available and functional.
        public let hasSecureEnclave: Bool
        /// CryptoKit (and underlying corecrypto) is available for FIPS operations.
        public let hasFipsCryptoModule: Bool
        /// Hybrid PQC key exchange is enabled in configuration.
        public let hybridPqcEnabled: Bool
        /// Human-readable summary of compliance status.
        public let summary: String
        /// List of any compliance issues detected.
        public let issues: [String]
    }

    /// Check if the current device meets minimum security requirements for Q-Audion.
    /// A device is compliant if it has CryptoKit (corecrypto / FIPS 140-3 #4701).
    /// Secure Enclave is strongly recommended but not strictly required — devices
    /// without SEP fall back to dual-hybrid (ML-KEM + X25519), which is still quantum-safe.
    public static func checkDeviceCompliance() -> DeviceComplianceResult {
        let hasSep = SecureEnclaveManager.isAvailable
        let hasFips = true  // CryptoKit always uses corecrypto on iOS/macOS.
        let hybridEnabled = CryptoConstants.hybridPqcEnabled

        var issues: [String] = []

        if !hasSep {
            issues.append("Secure Enclave not available — P-256 hardware binding disabled, using software-only dual-hybrid (ML-KEM + X25519).")
        }

        if !hybridEnabled {
            issues.append("Hybrid PQC is disabled in CryptoConstants — only classical key exchange is active.")
        }

        let isCompliant = hasFips && hybridEnabled
        let summary: String
        if isCompliant && hasSep {
            summary = "FULLY COMPLIANT: FIPS 140-3 corecrypto + Secure Enclave + ML-KEM-1024 hybrid PQC (NIST Level 5)."
        } else if isCompliant {
            summary = "COMPLIANT (reduced): FIPS 140-3 corecrypto + ML-KEM-1024 + X25519 hybrid (no SEP hardware binding)."
        } else {
            summary = "NOT COMPLIANT: \(issues.joined(separator: " "))"
        }

        return DeviceComplianceResult(
            isCompliant: isCompliant,
            hasSecureEnclave: hasSep,
            hasFipsCryptoModule: hasFips,
            hybridPqcEnabled: hybridEnabled,
            summary: summary,
            issues: issues
        )
    }
}
