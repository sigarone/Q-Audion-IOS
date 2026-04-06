import Foundation

public final class OtaUpdateChecker {
    private let downloadManager: OtaDownloadManager
    private var timer: Timer?
    private let checkIntervalSeconds: TimeInterval = 3600  // 1 hour
    public var onUpdateAvailable: ((String) -> Void)?

    public init(downloadManager: OtaDownloadManager) { self.downloadManager = downloadManager }

    public func startChecking(currentVersion: String) {
        stopChecking()
        check(currentVersion: currentVersion)
        timer = Timer.scheduledTimer(withTimeInterval: checkIntervalSeconds, repeats: true) { [weak self] _ in
            self?.check(currentVersion: currentVersion)
        }
    }

    public func stopChecking() { timer?.invalidate(); timer = nil }

    private func check(currentVersion: String) {
        Task {
            if let newVersion = try? await downloadManager.checkForUpdate(currentVersion: currentVersion) {
                onUpdateAvailable?(newVersion)
            }
        }
    }
}
