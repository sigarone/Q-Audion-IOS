import Foundation
import UIKit
import OSLog
import QAudionEngine

/// W415 — collect runtime logs + device context, optionally upload to
/// the BCrypto server's `/api/v1/files/upload` so the maintainer can
/// pull the dump via REST without USB pairing the iPhone to a Mac.
///
/// **Privacy stance:** the dump contains the in-memory ring buffer
/// (RuntimeLogSink) which is APP-AUTHORED text. No user message
/// bodies, no contact list, no auth tokens. iOS bundle metadata
/// (build version, OS version, device model, locale, free disk).
/// Recent N lines from os_log via `OSLogStore` (iOS 15+) when
/// available — those CAN contain other-process noise but the
/// subsystem filter `com.qaudion.app` keeps it scoped.
///
/// **Workflow:**
///   1. User opens Settings → Diagnostica → "Carica log al server".
///   2. iOS: collect snapshot → POST /api/v1/files/upload (auth'd).
///   3. Server returns fileId (UUID).
///   4. iOS shows the fileId in a copy-friendly card.
///   5. User shares fileId via any channel (chat, voice).
///   6. Maintainer pulls via `curl -H "Authorization: Bearer <admin_token>" \
///      https://voip.bcrypto.com/api/v1/files/<fileId>` and analyzes.
@MainActor
public final class LogExportService {

    public static let shared = LogExportService()

    public enum ExportError: Error, LocalizedError {
        case notAuthenticated
        case uploadFailed(String)
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notAuthenticated:    return "Sessione non autenticata."
            case .uploadFailed(let m): return "Upload fallito: \(m)"
            case .writeFailed(let m):  return "Scrittura file fallita: \(m)"
            }
        }
    }

    public init() {}

    /// Compose the dump payload (header + ring buffer snapshot).
    /// Returns Data ready to be uploaded or shared via UIActivityVC.
    func makeDumpData(userId: String?) -> Data {
        var out = String()
        out.reserveCapacity(64 * 1024)

        // ---- Header ---------------------------------------------------
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        out.append("=== Q-Audion iOS runtime log dump ===\n")
        out.append("generated_at  : \(f.string(from: Date()))\n")
        // SECURITY M-17 — only the first 8 chars of the user id
        // (matches the upload-filename prefix convention) so the
        // dump body cannot tie a log to a full account identity.
        // server_url is intentionally REMOVED: the server already
        // knows its own URL and embedding it leaks deployment topology.
        let uidFull: String = userId ?? "<not signed in>"
        let uidShort: String = String(uidFull.prefix(8))
        out.append("user_id       : \(uidShort)\n")
        let bundle = Bundle.main
        let appVer = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildN = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let bundleId = bundle.bundleIdentifier ?? "?"
        out.append("app_version   : \(appVer) (build \(buildN))\n")
        out.append("bundle_id     : \(bundleId)\n")
        let device = UIDevice.current
        out.append("ios_version   : \(device.systemName) \(device.systemVersion)\n")
        out.append("device_model  : \(deviceModelIdentifier())\n")
        out.append("locale        : \(Locale.current.identifier)\n")
        out.append("\n")
        out.append("=== ring buffer (\(RuntimeLogSink.shared.entryCount) entries) ===\n\n")

        // ---- Ring buffer snapshot ------------------------------------
        out.append(RuntimeLogSink.shared.snapshot())

        // ---- W416 OSLogStore snapshot --------------------------------
        // Cattura entries os_log emesse da QAudionEngine (subsystem
        // com.qaudion.app + sottosistemi vari) che NON passano per
        // print() e quindi non sono nel ring buffer via stdout-tee.
        // Cifrature, ratchet, WS dispatch, sealer usano os_log via
        // Logger() — questa sezione li recupera tutti per il dump.
        if #available(iOS 15.0, *) {
            out.append("\n\n=== os_log entries (subsystem com.qaudion.*) ===\n\n")
            out.append(snapshotOSLog())
        }

        return out.data(using: .utf8) ?? Data()
    }

    @available(iOS 15.0, *)
    private func snapshotOSLog() -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            // Pull last 5 minutes of entries.
            let pos = store.position(date: Date().addingTimeInterval(-300))
            let entries = try store.getEntries(at: pos)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem.hasPrefix("com.qaudion") }
            var out = String()
            out.reserveCapacity(64 * 1024)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for e in entries.suffix(2000) {
                out.append(f.string(from: e.date))
                out.append(" ")
                out.append(String(describing: e.level).uppercased())
                out.append(" [")
                out.append(e.category)
                out.append("] ")
                out.append(e.composedMessage)
                out.append("\n")
            }
            if entries.isEmpty {
                out.append("(no os_log entries in the last 5 minutes for com.qaudion subsystems)\n")
            }
            return out
        } catch {
            return "(OSLogStore unavailable: \(error.localizedDescription))\n"
        }
    }

    /// Write the dump to a temporary file under `Caches/qaudion-logs/`
    /// and return the URL. Caller can hand this to UIActivityViewController.
    func writeDumpToTempFile(userId: String?) throws -> URL {
        let data = makeDumpData(userId: userId)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qaudion-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let url = dir.appendingPathComponent("qaudion-runtime-\(stamp).log")
        do {
            try data.write(to: url)
            return url
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    /// Upload the dump to the server via the existing storage API.
    /// Returns the server-side fileId so the user can share it
    /// out-of-band with the maintainer.
    func uploadDump(serverUrl: String, token: String?, userId: String?) async throws -> String {
        guard let token = token, !token.isEmpty else {
            throw ExportError.notAuthenticated
        }
        let data = makeDumpData(userId: userId)
        let backendConfig = BackendConfig.pinned(serverUrl: serverUrl, accessToken: token)
        let provider = BCryptoBackendProvider(config: backendConfig)
        let stamp = Int(Date().timeIntervalSince1970)
        let userPrefix = (userId ?? "anon").prefix(8)
        let filename = "qaudion-log-\(userPrefix)-\(stamp).log"
        do {
            let fileId = try await provider.storageApi.uploadFile(data: data, filename: String(filename))
            return fileId
        } catch {
            throw ExportError.uploadFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    /// Returns "iPhone15,3" / "iPad14,5" / "x86_64" for the simulator.
    private func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        var id = ""
        for child in mirror.children {
            if let v = child.value as? Int8, v != 0 {
                id.append(Character(UnicodeScalar(UInt8(v))))
            }
        }
        return id.isEmpty ? "unknown" : id
    }
}
