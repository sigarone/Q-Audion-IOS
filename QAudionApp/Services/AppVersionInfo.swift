import Foundation

/// The one place the interface reads the running build's version from.
/// Values come straight from the bundle (the release workflow stamps them
/// from the release tag and the store build number), so what the user sees
/// is what the store lists: "1.0.1279 (build 345)", with " · TestFlight"
/// added on a TestFlight install.
enum AppVersionInfo {
    static func marketing(bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }

    static func build(bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    }

    /// Short commit the release was built from (stamped by the release
    /// workflow); "dev" for local and test builds.
    static func commit(bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "QAGitCommit") as? String) ?? "dev"
    }

    /// A TestFlight install carries a sandbox receipt; App Store installs a "receipt".
    static func isTestFlight(receiptURL: URL?) -> Bool {
        receiptURL?.lastPathComponent == "sandboxReceipt"
    }

    static func isTestFlight(bundle: Bundle = .main) -> Bool {
        isTestFlight(receiptURL: bundle.appStoreReceiptURL)
    }

    static func format(version: String, build: String, testFlight: Bool = false) -> String {
        let base = "\(version) (build \(build))"
        return testFlight ? base + " · TestFlight" : base
    }

    static func display(bundle: Bundle = .main) -> String {
        format(version: marketing(bundle: bundle), build: build(bundle: bundle),
               testFlight: isTestFlight(bundle: bundle))
    }
}
