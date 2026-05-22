import Foundation
import AVFoundation
import CryptoKit
import LocalAuthentication

// MARK: - iOS Security Probes
//
// Builds the real async probes for `SecurityComponentDetector` from on-device
// APIs. Swift counterpart of the Android `AndroidSecurityProbes`. Every probe
// is non-throwing and fail-safe: an unavailable framework simply yields
// `false`, so a component is shown ONLY when its presence is positively
// confirmed (never over-promises a guarantee).

enum IOSSecurityProbes {

    /// Lower-cased name fragments that identify a Q-Audion earbud audio route.
    /// Mirrors the Android `EarbudAvailability` bonded-name match.
    static let earbudNameFragments = ["q-audion", "qaudion", "q audion"]

    /// Earbud presence — true when the current audio route carries a Bluetooth
    /// output port whose name matches a Q-Audion earbud. Detecting the *route*
    /// (not just any paired device) means the icon flips to the earbud profile
    /// exactly while the earbud is the active audio endpoint.
    static func earbudConnectedProbe() -> () async -> Bool {
        return {
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            return outputs.contains { out in
                let isBluetooth = out.portType == .bluetoothA2DP
                    || out.portType == .bluetoothLE
                    || out.portType == .bluetoothHFP
                guard isBluetooth else { return false }
                let name = out.portName.lowercased()
                return earbudNameFragments.contains { name.contains($0) }
            }
        }
    }

    /// Hardware Secure Enclave — runtime-detectable on iOS via CryptoKit.
    static func secureEnclaveProbe() -> () async -> Bool {
        return { SecureEnclave.isAvailable }
    }

    /// CryptoKit ships with every iOS version this app supports.
    static func cryptoKitProbe() -> () async -> Bool {
        return { true }
    }

    /// The iOS keychain is always present on a real device.
    static func keychainProbe() -> () async -> Bool {
        return { true }
    }

    /// Strong biometric (Face ID / Touch ID) availability.
    static func biometricProbe() -> () async -> Bool {
        return {
            let ctx = LAContext()
            var error: NSError?
            return ctx.canEvaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                error: &error
            )
        }
    }

    /// Assemble a detector wired to the real on-device probes.
    static func makeDetector() -> SecurityComponentDetector {
        SecurityComponentDetector(
            earbudConnectedProbe: earbudConnectedProbe(),
            secureEnclaveProbe: secureEnclaveProbe(),
            cryptoKitProbe: cryptoKitProbe(),
            keychainProbe: keychainProbe(),
            biometricProbe: biometricProbe()
        )
    }
}
