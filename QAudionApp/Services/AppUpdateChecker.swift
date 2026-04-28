import Foundation
import UIKit

@MainActor
final class AppUpdateChecker: ObservableObject {

    struct UpdateInfo: Equatable {
        let availableVersion: String
        let releaseNotes: String
        let downloadUrl: URL?
        let isMandatory: Bool
    }

    enum CheckResult: Equatable {
        case noUpdate
        case updateAvailable(UpdateInfo)
        case error(String)
    }

    @Published private(set) var lastResult: CheckResult?
    @Published private(set) var isChecking: Bool = false
    @Published private(set) var lastChecked: Date?

    private let appState: AppState
    private let currentVersion: String

    init(appState: AppState, currentVersion: String? = nil) {
        self.appState = appState
        if let v = currentVersion {
            self.currentVersion = v
        } else if let info = Bundle.main.infoDictionary,
                  let v = info["CFBundleShortVersionString"] as? String {
            self.currentVersion = v
        } else {
            self.currentVersion = "unknown"
        }
    }

    func checkForUpdates() async {
        isChecking = true
        defer {
            Task { @MainActor in
                self.isChecking = false
                self.lastChecked = Date()
            }
        }

        guard var components = URLComponents(string: appState.serverUrl) else {
            lastResult = .error("Invalid server URL")
            return
        }
        components.path = "/api/v1/updates/check"
        components.queryItems = [
            URLQueryItem(name: "current_version", value: currentVersion),
            URLQueryItem(name: "channel", value: "ios-stable")
        ]
        guard let url = components.url else {
            lastResult = .error("Could not construct URL")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                lastResult = .error("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }
            // Parse: {available: bool, version, changelog, download_url, mandatory?}
            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastResult = .error("Invalid JSON")
                return
            }
            let available = (dict["available"] as? Bool) ?? false
            if !available {
                lastResult = .noUpdate
                return
            }
            let v = (dict["version"] as? String) ?? "unknown"
            let notes = (dict["changelog"] as? String) ?? ""
            let dlString = dict["download_url"] as? String
            let dlUrl = dlString.flatMap(URL.init(string:))
            let mandatory = (dict["mandatory"] as? Bool) ?? false
            lastResult = .updateAvailable(UpdateInfo(
                availableVersion: v,
                releaseNotes: notes,
                downloadUrl: dlUrl,
                isMandatory: mandatory
            ))
        } catch {
            lastResult = .error(error.localizedDescription)
        }
    }

    /// On iOS, "open update" routes to the App Store via the configured downloadUrl
    /// (typically an itms-apps:// link or the public App Store page).
    func openAppStoreLink(for info: UpdateInfo) {
        guard let url = info.downloadUrl else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
