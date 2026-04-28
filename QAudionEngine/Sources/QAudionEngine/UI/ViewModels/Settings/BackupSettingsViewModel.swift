import Foundation

/// Drives Settings → Backup screen.
///
/// **BLOCKED:** the actual backup-upload / restore-download flow is gated by
/// Open Discrepancy §10 in `docs/progress/INVARIANTS_VERIFIED.md`: Desktop
/// uses container magic `QABK` + 32B salt + scrypt N=2^15, Android uses
/// `QAUD` + 16B salt + scrypt N=2^17 — incompatible. Until the three
/// platforms converge on a single `.qabk` layout, iOS Settings UI ships
/// but the upload/download flow is disabled (`cloudBackupEnabled: false`).
public struct BackupSettingsViewModel: ViewModelProtocol {
    public let lastBackupAt: Date?
    public let lastBackupSizeBytes: Int64?
    public let localEncryptionOnly: Bool
    public let cloudBackupEnabled: Bool
    public let restoreInProgress: Bool

    public init(lastBackupAt: Date?, lastBackupSizeBytes: Int64?,
                localEncryptionOnly: Bool, cloudBackupEnabled: Bool,
                restoreInProgress: Bool) {
        self.lastBackupAt = lastBackupAt
        self.lastBackupSizeBytes = lastBackupSizeBytes
        self.localEncryptionOnly = localEncryptionOnly
        self.cloudBackupEnabled = cloudBackupEnabled
        self.restoreInProgress = restoreInProgress
    }

    public static let mock = BackupSettingsViewModel(
        lastBackupAt: Date(timeIntervalSince1970: 1_744_500_000),
        lastBackupSizeBytes: 4_823_104,
        localEncryptionOnly: true,
        cloudBackupEnabled: false,  // BLOCKED by §10 cross-platform format discrepancy
        restoreInProgress: false
    )
}
