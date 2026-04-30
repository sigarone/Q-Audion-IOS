import Foundation

/// W53: codec per il QR-payload del group-invite. Schema URL consistente
/// con gli altri payload Q-Audion (`qaudion://link/...`,
/// `qaudion://setup/...`):
///
///   qaudion://group-invite/<base64url-json>
///
/// Il base64url-json è la serializzazione UTF-8 di un JSON compact di
/// shape:
///
///   { "v": 1,
///     "kind": "qaudion-group-invite",
///     "groupId": "<UUID-string>",
///     "groupName": "<plaintext>" }
///
/// Engine wiring per la handshake serverside (`POST /groups/:id/join`)
/// è deferred. Oggi il codec gestisce solo encode/decode lato client.
public enum GroupInviteQrCode {

    /// Host parsed sotto lo schema `qaudion://`. Resta separato dagli
    /// altri host (`link`, `setup`) per facilitare il dispatch in
    /// `QrPayloadRouter`.
    public static let urlHost: String = "group-invite"

    /// Versione del payload — bumpare se la shape JSON cambia in modi
    /// non backward-compatible (es. nuovi campi REQUIRED).
    public static let currentVersion: Int = 1

    public struct Payload: Equatable {
        public let version: Int
        public let groupId: UUID
        public let groupName: String

        public init(version: Int = currentVersion,
                    groupId: UUID, groupName: String) {
            self.version = version
            self.groupId = groupId
            self.groupName = groupName
        }
    }

    public enum DecodeError: Error, LocalizedError {
        case missingPath
        case base64Decode
        case jsonDecode(String)
        case missingField(String)
        case versionUnsupported(Int)
        case invalidGroupId(String)

        public var errorDescription: String? {
            switch self {
            case .missingPath: return "URL group-invite senza payload."
            case .base64Decode: return "Payload base64url non valido."
            case .jsonDecode(let r): return "JSON non valido: \(r)"
            case .missingField(let f): return "Campo mancante: \(f)"
            case .versionUnsupported(let v): return "Versione \(v) non supportata."
            case .invalidGroupId(let s): return "groupId non è un UUID: '\(s)'"
            }
        }
    }

    /// Encode `Payload` → `qaudion://group-invite/<base64url-json>`.
    public static func encode(_ payload: Payload) -> URL {
        let dict: [String: Any] = [
            "v": payload.version,
            "kind": "qaudion-group-invite",
            "groupId": payload.groupId.uuidString,
            "groupName": payload.groupName
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: dict, options: []
        )) ?? Data()
        let b64 = base64UrlEncode(data)
        // Force-unwrap is safe — input is always a valid URL string.
        return URL(string: "qaudion://\(urlHost)/\(b64)")!
    }

    /// Decode `qaudion://group-invite/<base64url-json>` → `Payload`.
    public static func decode(url: URL) throws -> Payload {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { throw DecodeError.missingPath }
        guard let data = base64UrlDecode(path) else {
            throw DecodeError.base64Decode
        }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw DecodeError.jsonDecode(error.localizedDescription)
        }
        guard let dict = obj as? [String: Any] else {
            throw DecodeError.jsonDecode("expected object")
        }
        let v = (dict["v"] as? Int) ?? 0
        guard v == currentVersion else {
            throw DecodeError.versionUnsupported(v)
        }
        guard let kind = dict["kind"] as? String, kind == "qaudion-group-invite" else {
            throw DecodeError.missingField("kind")
        }
        guard let gidStr = dict["groupId"] as? String else {
            throw DecodeError.missingField("groupId")
        }
        guard let gid = UUID(uuidString: gidStr) else {
            throw DecodeError.invalidGroupId(gidStr)
        }
        let name = (dict["groupName"] as? String) ?? ""
        return Payload(version: v, groupId: gid, groupName: name)
    }

    // MARK: - Helpers (base64url with no padding)

    private static func base64UrlEncode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }

    private static func base64UrlDecode(_ s: String) -> Data? {
        var t = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4.
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
