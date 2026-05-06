import Foundation

/// FastSetup QR codec — server-issued onboarding bypass.
///
/// Wire format: `qaudion://setup/<base64url-no-padding>` where the
/// blob is a JSON object:
/// ```json
/// {
///   "v": 1,
///   "user_id": "<uuid>",
///   "extension": "<dial-by-extension or null>",
///   "psk": "<32-byte initial PSK base64>",
///   "expires_at": <unix_ms>,
///   "server": "<server_url>"
/// }
/// ```
///
/// Version 1 is currently the only supported version. Decoder rejects
/// other versions explicitly so future bumps are observable.
public enum FastSetupQrCode {

    public static let urlScheme = "qaudion"
    public static let urlHost = "setup"
    public static let pskLength = 32

    public struct Payload: Equatable {
        public let version: Int
        public let userId: String
        public let dialExtension: String?
        public let initialPsk: Data       // 32 bytes
        public let expiresAtUnixMs: Int64
        public let serverUrl: URL

        public init(version: Int, userId: String, dialExtension: String?,
                    initialPsk: Data, expiresAtUnixMs: Int64, serverUrl: URL) {
            self.version = version
            self.userId = userId
            self.dialExtension = dialExtension
            self.initialPsk = initialPsk
            self.expiresAtUnixMs = expiresAtUnixMs
            self.serverUrl = serverUrl
        }
    }

    public enum Error: Swift.Error, LocalizedError {
        case wrongPskLength(Int)
        case invalidUrl
        case base64Failed
        case malformedJson(String)
        case unsupportedVersion(Int)
        case expired
        case missingField(String)

        public var errorDescription: String? {
            switch self {
            case .wrongPskLength(let n): return "initialPsk must be 32B, got \(n)"
            case .invalidUrl: return "URL must be qaudion://setup/<base64url>"
            case .base64Failed: return "base64url decode failed"
            case .malformedJson(let m): return "Malformed JSON: \(m)"
            case .unsupportedVersion(let v): return "Unsupported version: \(v) (only v=1 supported)"
            case .expired: return "Payload has expired"
            case .missingField(let f): return "Missing field '\(f)'"
            }
        }
    }

    public static func encode(payload: Payload) throws -> URL {
        guard payload.initialPsk.count == pskLength else {
            throw Error.wrongPskLength(payload.initialPsk.count)
        }
        var dict: [String: Any] = [
            "v": payload.version,
            "user_id": payload.userId,
            "psk": payload.initialPsk.base64EncodedString(),
            "expires_at": payload.expiresAtUnixMs,
            "server": payload.serverUrl.absoluteString
        ]
        if let ext = payload.dialExtension {
            dict["extension"] = ext
        } else {
            dict["extension"] = NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        let blob = data.base64UrlEncodedNoPadding()
        guard let url = URL(string: "\(urlScheme)://\(urlHost)/\(blob)") else {
            throw Error.invalidUrl
        }
        return url
    }

    public static func decode(url: URL) throws -> Payload {
        guard url.scheme == urlScheme, url.host == urlHost else { throw Error.invalidUrl }

        let path = url.path
        let blobString = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !blobString.isEmpty else { throw Error.invalidUrl }

        guard let data = Data(base64UrlEncodedNoPadding: blobString) else {
            throw Error.base64Failed
        }

        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Error.malformedJson(error.localizedDescription)
        }
        guard let dict = any as? [String: Any] else {
            throw Error.malformedJson("Top-level value not an object")
        }

        guard let v = dict["v"] as? Int else { throw Error.missingField("v") }
        guard v == 1 else { throw Error.unsupportedVersion(v) }

        guard let userId = dict["user_id"] as? String else { throw Error.missingField("user_id") }

        let dialExt: String?
        if let s = dict["extension"] as? String { dialExt = s }
        else { dialExt = nil }

        guard let pskB64 = dict["psk"] as? String else { throw Error.missingField("psk") }
        guard let psk = Data(base64Encoded: pskB64) else { throw Error.base64Failed }
        guard psk.count == pskLength else { throw Error.wrongPskLength(psk.count) }

        let expiresAt: Int64
        if let v = dict["expires_at"] as? Int64 { expiresAt = v }
        else if let v = dict["expires_at"] as? Int { expiresAt = Int64(v) }
        else if let v = dict["expires_at"] as? Double { expiresAt = Int64(v) }
        else { throw Error.missingField("expires_at") }

        // Reject expired payloads.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if expiresAt < nowMs { throw Error.expired }

        guard let serverStr = dict["server"] as? String,
              let serverUrl = URL(string: serverStr) else {
            throw Error.missingField("server")
        }

        return Payload(
            version: v, userId: userId, dialExtension: dialExt,
            initialPsk: psk, expiresAtUnixMs: expiresAt, serverUrl: serverUrl
        )
    }
}

// base64url Data extensions are defined in DeviceLinkBinaryQR.swift and
// are available across the module without re-declaration.
