import Foundation

// MARK: - Security Icon Model (iOS port)
//
// Faithful Swift port of the Android pure model
// (core-common/.../securityicon/SecurityIconModel.kt + BuiltInProfiles.kt +
// SecurityComponentDetector.kt). NO SwiftUI / UIKit imports here — this is the
// portable contract; only `SecurityIconView` (the draw layer) is platform UI.
//
// The Android model was explicitly designed for this: "the single contract the
// rendering engine and the ViewModel consume, and that iOS/desktop reimplement
// only the draw layer for."

/// Lifecycle state the icon animates to.
enum IconState {
    case idle, connected, encrypting, rekeying
}

/// Which built-in device profile is active.
enum DeviceProfileID: String {
    case earbudQaudion
    case phoneIPhone
}

/// Outer silhouette the renderer draws.
enum SilhouetteShape {
    case earbud
    case phoneIsland   // iPhone slab with the Dynamic Island notch
}

/// Semantic role → the draw layer maps a role to a colour.
enum ComponentRole {
    case crypto, compute, memory, secureElement, attestation, biometric
}

/// How a component's presence was established.
/// `detectedRuntime` → really probed on this device (honest live guarantee).
/// `declared`        → illustrative; the UI must never imply a false guarantee.
enum DetectionKind {
    case detectedRuntime, declared
}

struct SecurityComponent: Equatable {
    let id: String
    let label: String
    let role: ComponentRole
    let detection: DetectionKind
}

struct DeviceProfile {
    let id: DeviceProfileID
    let displayName: String
    let silhouette: SilhouetteShape
    /// Label of the secure-boundary container (e.g. "TrustZone", "Secure Enclave").
    let secureBoundaryLabel: String
    /// Every component this profile could show; runtime detection filters it.
    let candidateComponents: [SecurityComponent]
}

/// The contract the renderer consumes.
struct SecurityIconSpec {
    let profile: DeviceProfile
    let state: IconState
    let activeComponents: [SecurityComponent]

    /// Keep a candidate component when it is either DECLARED (illustrative
    /// profiles always show their declared parts) or its id was runtime-detected.
    static func of(
        profile: DeviceProfile,
        state: IconState,
        detectedComponentIDs: Set<String>
    ) -> SecurityIconSpec {
        let active = profile.candidateComponents.filter { c in
            c.detection == .declared || detectedComponentIDs.contains(c.id)
        }
        return SecurityIconSpec(profile: profile, state: state, activeComponents: active)
    }
}

// MARK: - Built-in profiles

/// The canonical device profiles. Mirrors Android `BuiltInProfiles`
/// (only the two an iOS device can resolve to: earbud or iPhone).
enum BuiltInProfiles {

    /// Q-Audion earbud — identical physical hardware regardless of phone OS,
    /// so the component set matches the Android earbud profile exactly:
    /// cracen · arm · npu · secure_mem (boundary "TrustZone").
    static let earbud = DeviceProfile(
        id: .earbudQaudion,
        displayName: "Q-Audion Earbud",
        silhouette: .earbud,
        secureBoundaryLabel: "TrustZone",
        candidateComponents: [
            SecurityComponent(id: "cracen",     label: "CRACEN",     role: .crypto,  detection: .detectedRuntime),
            SecurityComponent(id: "arm",        label: "ARM",        role: .compute, detection: .detectedRuntime),
            SecurityComponent(id: "npu",        label: "NPU",        role: .compute, detection: .detectedRuntime),
            SecurityComponent(id: "secure_mem", label: "SECURE MEM", role: .memory,  detection: .detectedRuntime),
        ]
    )

    /// iPhone — the Secure Enclave is runtime-detectable on iOS, so unlike the
    /// Android illustrative iPhone profile these are DETECTED_RUNTIME.
    static let iPhone = DeviceProfile(
        id: .phoneIPhone,
        displayName: "iPhone",
        silhouette: .phoneIsland,
        secureBoundaryLabel: "Secure Enclave",
        candidateComponents: [
            SecurityComponent(id: "secure_enclave", label: "SECURE ENCLAVE", role: .secureElement, detection: .detectedRuntime),
            SecurityComponent(id: "cryptokit",      label: "CRYPTOKIT",      role: .crypto,        detection: .detectedRuntime),
            SecurityComponent(id: "keychain",       label: "KEYCHAIN",       role: .memory,        detection: .detectedRuntime),
            SecurityComponent(id: "biometric",      label: "FACE / TOUCH ID", role: .biometric,    detection: .detectedRuntime),
        ]
    )
}

/// Chooses the auto-active profile: earbud connected → earbud, else iPhone.
enum ProfileSelector {
    static func select(earbudConnected: Bool) -> DeviceProfileID {
        earbudConnected ? .earbudQaudion : .phoneIPhone
    }
}

// MARK: - Detection

/// What detection resolved: the active profile + the ids actually found.
struct DetectionResult {
    let activeProfile: DeviceProfileID
    let detectedComponentIDs: Set<String>
}

/// Resolves the active profile and the runtime-present component id set from
/// injected probes. Pure orchestration — no platform calls here; the real
/// probes (CoreBluetooth / SecureEnclave / LAContext) are supplied by
/// `IOSSecurityProbes`. Each probe is fail-closed: a throwing probe ⇒ that
/// component is treated as absent.
struct SecurityComponentDetector {
    let earbudConnectedProbe: () async -> Bool
    let secureEnclaveProbe: () async -> Bool
    let cryptoKitProbe: () async -> Bool
    let keychainProbe: () async -> Bool
    let biometricProbe: () async -> Bool

    func detect() async -> DetectionResult {
        let earbud = await earbudConnectedProbe()
        let active = ProfileSelector.select(earbudConnected: earbud)

        var ids = Set<String>()
        if earbud {
            // The earbud chip set is implied by a connected Q-Audion earbud
            // (same rule as Android SecurityComponentDetector.kt:50).
            ids.formUnion(["cracen", "arm", "npu", "secure_mem"])
        }
        if await secureEnclaveProbe() { ids.insert("secure_enclave") }
        if await cryptoKitProbe()     { ids.insert("cryptokit") }
        if await keychainProbe()      { ids.insert("keychain") }
        if await biometricProbe()     { ids.insert("biometric") }

        return DetectionResult(activeProfile: active, detectedComponentIDs: ids)
    }
}

// MARK: - Spec factory

/// Builds the `SecurityIconSpec` from a `DetectionResult`, mirroring the
/// Android `EarbudUiStateFactory`. Returns `nil` when the icon should be
/// HIDDEN (no active components and no call activity) — never a dead blob.
enum SecurityIconSpecFactory {
    static func build(
        detection: DetectionResult,
        state: IconState
    ) -> SecurityIconSpec? {
        let profile: DeviceProfile = {
            switch detection.activeProfile {
            case .earbudQaudion: return BuiltInProfiles.earbud
            case .phoneIPhone:   return BuiltInProfiles.iPhone
            }
        }()
        let spec = SecurityIconSpec.of(
            profile: profile,
            state: state,
            detectedComponentIDs: detection.detectedComponentIDs
        )
        let hidden = state == .idle && spec.activeComponents.isEmpty
        return hidden ? nil : spec
    }
}
