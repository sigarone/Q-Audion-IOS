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
///
/// ============================================================
/// SECURITY H-3 — PLAINTEXT CREDENTIAL IN QR
/// ============================================================
/// The `password` field below is the user's account password carried
/// **in cleartext inside the QR code**. Anyone who photographs / shoulder-
/// surfs / screen-records the QR obtains a permanent credential. This
/// is a protocol-level weakness that CANNOT be fixed client-side alone:
/// the bcrypto-server admin panel emits this shape and the iOS client
/// must decode it byte-for-byte to stay wire-compatible with Android.
///
/// REQUIRED SERVER-SIDE FOLLOW-UP (tracked, out of scope here):
///   - Replace the embedded password with a single-use, short-TTL OTP /
///     enrolment token (`/auth/fast-setup-otp`) that the device exchanges
///     for real credentials over TLS, so the QR never carries a reusable
///     secret. Until that endpoint exists this struct keeps the field.
///
/// Client-side mitigations already applied (see `FastSetupAuth`):
///   - `password` is NEVER logged.
///   - the local copy is overwritten/zeroed in memory immediately after
///     the login call returns.
/// ============================================================
public struct FastSetupPayload: Codable, Equatable {

    public let version: Int
    public let kind: String
    public let server: String
    public let extensionNumber: Int64
    public let phoneId: String
    // SECURITY H-3: plaintext credential in QR — server OTP endpoint
    // required (see struct doc block). Never log this; the consumer
    // (`FastSetupAuth`) zeroes its local copy post-login.
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

    /// Resolved display name. Used after login to push the profile name to
    /// the server so peers see the extension number instead of the raw UUID.
    ///
    /// W497 — changed fallback from "Phone #N" to just "N".
    /// The "Phone #" prefix was an Android-side artefact that leaked into
    /// iOS via the Kotlin comment in the source-of-truth struct. Showing
    /// bare "235" is cleaner in CallKit and in the in-app call screen; the
    /// prefix added no information and changed visibly when FastSetupAuth
    /// first ran and pushed the profile to the server (before that push the
    /// server returned the raw extension "235"; afterwards "Phone #235").
    /// If the QR payload carries an explicit display_name it is used as-is
    /// (no prefix added) — that case was correct before and after.
    public var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "\(extensionNumber)" : trimmed
    }
}
