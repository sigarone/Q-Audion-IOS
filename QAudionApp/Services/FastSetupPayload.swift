import Foundation

/// Decoded body of a Fast-Setup QR code.
///
/// Wire format is **raw JSON encoded as the QR data** (NOT a `qaudion://...`
/// URL — that was a mistake in the earlier `FastSetupQrCode` codec). The
/// admin panel of `bcrypto-server` produces the QR string verbatim from the
/// JSON below.
///
/// Source of truth: `qaudion-android-new` →
/// `feature/feature-auth/navigation/AuthFlowViewModel.kt:384` (Kotlin
/// `@Serializable data class FastSetupPayload`).
///
/// Example payload as embedded in the QR:
/// ```json
/// {
///   "v": 1,
///   "kind": "bcrypto-fast-setup",
///   "server": "https://voip.bcrypto.com",
///   "extension": 100,
///   "phone_id": "fastsetup-7c1e9b3a-...",
///   "password": "<hex>",
///   "display_name": "Phone #100"
/// }
/// ```
///
/// The scanner validates `kind == "bcrypto-fast-setup"` AND `version == 1`
/// AND `server` matches the pinned host before handing the payload to
/// `FastSetupAuth.run(...)`.
public struct FastSetupPayload: Codable, Equatable {

    public let version: Int
    public let kind: String
    public let server: String
    public let extensionNumber: Int64
    public let phoneId: String
    public let password: String
    public let displayName: String

    /// Maps Kotlin `@SerialName` keys onto Swift property names.
    /// Kotlin uses snake_case + a "v" alias for version; we keep the same
    /// wire keys so the JSON produced by the server admin panel decodes
    /// unchanged on iOS.
    enum CodingKeys: String, CodingKey {
        case version = "v"
        case kind
        case server
        case extensionNumber = "extension"
        case phoneId = "phone_id"
        case password
        case displayName = "display_name"
    }

    public init(version: Int,
                kind: String,
                server: String,
                extensionNumber: Int64,
                phoneId: String,
                password: String,
                displayName: String) {
        self.version = version
        self.kind = kind
        self.server = server
        self.extensionNumber = extensionNumber
        self.phoneId = phoneId
        self.password = password
        self.displayName = displayName
    }

    public enum DecodeError: Swift.Error, LocalizedError {
        case notJson
        case unexpectedKind(String)
        case unsupportedVersion(Int)
        case missingField(String)

        public var errorDescription: String? {
            switch self {
            case .notJson:
                return "QR code non valido (non è JSON)."
            case .unexpectedKind(let k):
                return "QR code non valido (kind = \(k), atteso bcrypto-fast-setup)."
            case .unsupportedVersion(let v):
                return "Versione QR non supportata (v=\(v), atteso 1)."
            case .missingField(let f):
                return "QR code non valido (campo \(f) mancante)."
            }
        }
    }

    /// Parse a raw QR string (JSON) into a validated `FastSetupPayload`.
    /// Throws `DecodeError` for any wire-shape problem so the scanner UI
    /// can show the user a precise reason for the rejection.
    public static func decode(jsonString raw: String) throws -> FastSetupPayload {
        guard let data = raw.data(using: .utf8) else {
            throw DecodeError.notJson
        }
        let decoder = JSONDecoder()
        let payload: FastSetupPayload
        do {
            payload = try decoder.decode(FastSetupPayload.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw DecodeError.missingField(key.stringValue)
        } catch {
            throw DecodeError.notJson
        }

        guard payload.kind == "bcrypto-fast-setup" else {
            throw DecodeError.unexpectedKind(payload.kind)
        }
        guard payload.version == 1 else {
            throw DecodeError.unsupportedVersion(payload.version)
        }
        return payload
    }

    /// Resolved display name. Mirrors Android logic:
    /// `payload.displayName.ifBlank { "Phone #${extension}" }`.
    /// Used after the login completes to push the profile name to the server
    /// so peers calling THIS user see "Phone #100" instead of the raw UUID.
    public var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Phone #\(extensionNumber)" : trimmed
    }
}
