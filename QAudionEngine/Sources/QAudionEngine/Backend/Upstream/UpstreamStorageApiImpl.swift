import Foundation

public final class UpstreamStorageApiImpl: StorageApi {
    public init() {}
    public func uploadBackup(data: Data, key: String) async throws -> String { "" }
    public func downloadBackup(key: String) async throws -> Data { Data() }
    public func deleteBackup(key: String) async throws {}
    public func listBackups() async throws -> [String] { [] }
}
