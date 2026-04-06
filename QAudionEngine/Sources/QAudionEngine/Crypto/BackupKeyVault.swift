import Foundation

public final class BackupKeyVault {
    private let keyStore = QAudionKeyStore()

    public init() {}

    public func backupKey(name: String, key: Data) throws {
        try keyStore.storeKey(identifier: "backup_\(name)", keyData: key)
    }

    public func restoreKey(name: String) -> Data? {
        keyStore.loadKey(identifier: "backup_\(name)")
    }

    public func deleteBackup(name: String) {
        keyStore.deleteKey(identifier: "backup_\(name)")
    }
}
