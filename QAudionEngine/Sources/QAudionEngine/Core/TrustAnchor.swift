import Foundation

public struct TrustReport {
    public enum TrustLevel: String { case verified; case suspicious; case compromised; case unknown }
    public let level: TrustLevel
    public let isDebugBuild: Bool
    public let isJailbroken: Bool
    public let bundleHash: String?
    public let issues: [String]
}

public enum TrustAnchor {
    public static func verifyIntegrity() -> TrustReport {
        var issues: [String] = []
        let debug = isDebugBuild()
        let jailbreak = isJailbroken()
        if debug { issues.append("Debug build detected") }
        if jailbreak { issues.append("Jailbreak detected") }
        let level: TrustReport.TrustLevel
        if jailbreak { level = .compromised }
        else if debug { level = .suspicious }
        else if issues.isEmpty { level = .verified }
        else { level = .unknown }
        return TrustReport(level: level, isDebugBuild: debug, isJailbroken: jailbreak,
            bundleHash: getBundleHash(), issues: issues)
    }

    public static func isDebugBuild() -> Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    public static func isJailbroken() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let paths = ["/Applications/Cydia.app", "/private/var/lib/apt",
            "/usr/sbin/sshd", "/usr/bin/ssh", "/bin/bash", "/etc/apt"]
        for path in paths { if FileManager.default.fileExists(atPath: path) { return true } }
        return false
        #endif
    }

    public static func getBundleHash() -> String? {
        guard let path = Bundle.main.executablePath,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        var hash: UInt64 = 0
        data.prefix(4096).forEach { hash = hash &* 31 &+ UInt64($0) }
        return String(format: "%016llx", hash)
    }
}
