import Foundation

/// Drives Settings → About screen.
///
/// Surfaces app version, build number, short git commit SHA, iOS deployment
/// target, ML-KEM-1024 status, and the ONNX Runtime version.
///
/// - Important: `onnxruntimeVersion` MUST remain "1.17.0".  Per CLAUDE.md §4,
///   upgrading onnxruntime-swift-package-manager past 1.17.0 raises the
///   MinimumOSVersion to iOS 18+, which defeats the iOS 16 deployment target.
///   Tests pin this value to catch accidental upgrades surfaced via mock drift.
public struct AboutSettingsViewModel: ViewModelProtocol {
    public let appVersion: String          // e.g. "1.0.24"
    public let buildNumber: String         // e.g. "40"
    public let gitCommitShort: String      // 7-char short SHA
    public let iosDeploymentTarget: String // "16.0"
    public let mlKem1024Enabled: Bool      // always true (liboqs pinned)
    public let onnxruntimeVersion: String  // MUST be "1.17.0" per CLAUDE.md §4

    public init(appVersion: String, buildNumber: String, gitCommitShort: String,
                iosDeploymentTarget: String, mlKem1024Enabled: Bool, onnxruntimeVersion: String) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.gitCommitShort = gitCommitShort
        self.iosDeploymentTarget = iosDeploymentTarget
        self.mlKem1024Enabled = mlKem1024Enabled
        self.onnxruntimeVersion = onnxruntimeVersion
    }

    public static let mock = AboutSettingsViewModel(
        appVersion: "1.0.24",
        buildNumber: "40",
        gitCommitShort: "35c5e52",
        iosDeploymentTarget: "16.0",
        mlKem1024Enabled: true,
        onnxruntimeVersion: "1.17.0"
    )
}
