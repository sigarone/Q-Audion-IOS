import Foundation

public protocol StorageApi {
    func uploadBackup(data: Data, key: String) async throws -> String
    func downloadBackup(key: String) async throws -> Data
    func deleteBackup(key: String) async throws
    func listBackups() async throws -> [String]
    /// W82 — generic file upload (chat attachments). Returns the
    /// server-issued file id used in the qfile marker.
    func uploadFile(data: Data, filename: String) async throws -> String
    /// W82 — owner-direct file download. Recipients use the
    /// `BCryptoDownloadTokenClient` capability flow instead.
    func downloadFile(fileId: String) async throws -> Data
}
