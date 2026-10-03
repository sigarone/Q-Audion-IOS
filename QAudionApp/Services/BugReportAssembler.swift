import Foundation
import UIKit

/// W-REPORTFREEZE (2026-10-03) -- the heavy half of a bug report, NOT main-actor isolated.
///
/// In the group call of 2026-10-03 sending a report froze the iPhone's main thread for ~32 s
/// (hang ms=32304, `main_stall_ms_max` 27404, 762 live-log lines dropped): `BugReporter` is
/// `@MainActor` and ran the whole assembly on it -- the redaction of the 1.36 MB log tail
/// (twice: once per entry, once as one blob for the diagnostic summary), the PNG encode of
/// the side-by-side screenshot, three AES-GCM seals and the multipart body. Now the main
/// actor only reads what has to be read there (the ring copy, the app state, the token) and
/// hands plain values to `assemble`, which `BugReporter.uploadReport` runs in a detached
/// utility-priority task, then hops back for the network call.
///
/// Nothing here changes what is sent: same redaction, same ciphertext layout, same multipart
/// fields in the same order.

/// The report log text, built and redacted from a raw copy of the ring. Same layout as
/// `RuntimeLogSink.recentLogsAsString` always had: `timestamp [LEVEL] [tag] message` per line,
/// every message through `LogRedactor.redactStructured` (FIX-11).
enum BugReportLogFormatter {

    static func format(_ entries: [LiveLogRawEntry]) -> String {
        // One formatter per call (the shared one belongs to the main-actor sink); same options.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = String()
        out.reserveCapacity(entries.count * 200)
        for e in entries {
            out.append(iso.string(from: e.timestamp))
            out.append(" [")
            out.append(e.level.uppercased())
            out.append("] [")
            out.append(e.tag)
            out.append("] ")
            out.append(LogRedactor.redactStructured(e.message))
            out.append("\n")
        }
        return out
    }
}

enum BugReportAssembler {

    /// Everything `assemble` needs, as plain values read on the main actor beforehand.
    /// `@unchecked Sendable`: the only reference type inside is the `UIImage`, which is
    /// immutable and safe to read from any thread (`pngData`).
    struct Input: @unchecked Sendable {
        let adminPubKeyHex: String
        let trigger: String
        let appVersion: String
        let osVersion: String
        let deviceModel: String
        let userPrefix: String
        let timestamp: String
        let callId: String
        /// The user's free text (or the abuse report body); feeds `diag_summary`.
        let note: String
        /// Note + diagnostic JSON snapshot: the plaintext of the encrypted `body_enc`.
        let bodyPlaintext: String
        /// The raw log tail; redacted here, off the main actor.
        let logEntries: [LiveLogRawEntry]
        let extraFields: [String: String]
        let screenshot: UIImage?
    }

    struct Output: Sendable {
        let boundary: String
        let body: Data
    }

    /// Builds the multipart upload body: log text and redaction, `diag_summary`, the three
    /// independent encryptions, the PNG, the multipart framing. `nil` when an encryption
    /// fails (the report is then not sent, as before: no plaintext fallback).
    static func assemble(_ input: Input) -> Output? {
        let logs = BugReportLogFormatter.format(input.logEntries)

        let diagSummary = ReportCrypto.buildDiagSummary(logs: logs, note: input.note, trigger: input.trigger)

        guard let bodyEnc = try? ReportCrypto.encrypt(
            adminPubKeyHex: input.adminPubKeyHex, plaintext: Data(input.bodyPlaintext.utf8)
        ) else {
            RTLog.warn("bugreport", "ReportCrypto.encrypt(body) failed — report aborted")
            return nil
        }
        guard let logsEnc = try? ReportCrypto.encrypt(
            adminPubKeyHex: input.adminPubKeyHex, plaintext: Data(logs.utf8)
        ) else {
            RTLog.warn("bugreport", "ReportCrypto.encrypt(logs) failed — report aborted")
            return nil
        }
        let screenshotEnc: ReportCrypto.EncryptedPayload? = input.screenshot
            .flatMap { $0.pngData() }
            .flatMap { try? ReportCrypto.encrypt(adminPubKeyHex: input.adminPubKeyHex, plaintext: $0) }

        let boundary = "BugReportBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var body = Data()
        appendField(&body, boundary: boundary, name: "platform", value: "ios")
        appendField(&body, boundary: boundary, name: "trigger", value: input.trigger)
        appendField(&body, boundary: boundary, name: "app_version", value: input.appVersion)
        appendField(&body, boundary: boundary, name: "os_version", value: input.osVersion)
        appendField(&body, boundary: boundary, name: "device_model", value: input.deviceModel)
        appendField(&body, boundary: boundary, name: "user_id", value: input.userPrefix)
        appendField(&body, boundary: boundary, name: "timestamp", value: input.timestamp)
        if !input.callId.isEmpty {
            appendField(&body, boundary: boundary, name: "call_id", value: input.callId)
        }
        appendField(&body, boundary: boundary, name: "diag_summary", value: diagSummary)
        for (key, value) in input.extraFields.sorted(by: { $0.key < $1.key }) {
            appendField(&body, boundary: boundary, name: key, value: value)
        }
        appendField(&body, boundary: boundary, name: "ephemeral_pub", value: bodyEnc.ephemeralPubHex)
        appendField(&body, boundary: boundary, name: "logs_ephemeral_pub", value: logsEnc.ephemeralPubHex)
        appendFilePart(&body, boundary: boundary, name: "body_enc",
                       filename: "body.enc", mimeType: "application/octet-stream", data: bodyEnc.ciphertext)
        appendFilePart(&body, boundary: boundary, name: "logs_enc",
                       filename: "logs.enc", mimeType: "application/octet-stream", data: logsEnc.ciphertext)
        if let screenshotEnc = screenshotEnc {
            appendField(&body, boundary: boundary, name: "screenshot_ephemeral_pub",
                        value: screenshotEnc.ephemeralPubHex)
            appendFilePart(&body, boundary: boundary, name: "screenshot_enc",
                           filename: "screenshot.enc", mimeType: "application/octet-stream",
                           data: screenshotEnc.ciphertext)
        }
        let closingBoundary = "--" + boundary + "--\r\n"
        if let closingData = closingBoundary.data(using: .utf8) {
            body.append(closingData)
        }
        return Output(boundary: boundary, body: body)
    }

    // MARK: - Multipart helpers (moved unchanged from BugReporter)

    static func appendField(_ body: inout Data, boundary: String, name: String, value: String) {
        var part = "--" + boundary + "\r\n"
        part += "Content-Disposition: form-data; name=\"" + name + "\"\r\n\r\n"
        part += value + "\r\n"
        if let data = part.data(using: .utf8) {
            body.append(data)
        }
    }

    static func appendFilePart(_ body: inout Data, boundary: String,
                               name: String, filename: String,
                               mimeType: String, data: Data) {
        var header = "--" + boundary + "\r\n"
        header += "Content-Disposition: form-data; name=\"" + name
        header += "\"; filename=\"" + filename + "\"\r\n"
        header += "Content-Type: " + mimeType + "\r\n\r\n"
        if let headerData = header.data(using: .utf8) {
            body.append(headerData)
        }
        body.append(data)
        if let tail = "\r\n".data(using: .utf8) {
            body.append(tail)
        }
    }
}
