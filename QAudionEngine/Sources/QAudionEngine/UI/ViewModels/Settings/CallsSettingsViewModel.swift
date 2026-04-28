import Foundation

/// Drives Settings → Calls screen.
///
/// Exposes codec preference, audio processing flags (AEC / NS / AGC), VoIP
/// background-mode state, and preferred call quality.  All three audio
/// processing flags default to enabled — disabling them is an advanced
/// power-user action that degrades call quality.
public struct CallsSettingsViewModel: ViewModelProtocol {

    public enum Codec: String, Sendable { case opus }
    public enum CallQuality: String, Sendable, CaseIterable { case low, medium, high }

    public let codecPreference: Codec
    public let isAecEnabled: Bool
    public let isNsEnabled: Bool
    public let isAgcEnabled: Bool
    /// Read-only — set by `UIBackgroundModes [voip, audio]` entitlement.
    public let isVoipBackgroundModeActive: Bool
    public let preferredCallQuality: CallQuality

    public init(codecPreference: Codec, isAecEnabled: Bool, isNsEnabled: Bool,
                isAgcEnabled: Bool, isVoipBackgroundModeActive: Bool,
                preferredCallQuality: CallQuality) {
        self.codecPreference = codecPreference
        self.isAecEnabled = isAecEnabled
        self.isNsEnabled = isNsEnabled
        self.isAgcEnabled = isAgcEnabled
        self.isVoipBackgroundModeActive = isVoipBackgroundModeActive
        self.preferredCallQuality = preferredCallQuality
    }

    public static let mock = CallsSettingsViewModel(
        codecPreference: .opus,
        isAecEnabled: true,
        isNsEnabled: true,
        isAgcEnabled: true,
        isVoipBackgroundModeActive: true,
        preferredCallQuality: .medium
    )
}
