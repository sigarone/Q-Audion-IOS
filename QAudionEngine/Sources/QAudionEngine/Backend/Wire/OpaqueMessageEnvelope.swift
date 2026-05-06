import Foundation

/// Pure-Swift codec for the `opaque_message` WebSocket envelope.
///
/// Wire format (frozen per spec §5.8 + §5.11):
/// ```json
/// { "type": "opaque_message", "data": { "recipient_id": "<uuid>", "ciphertext": "<base64>" } }
/// ```
///
/// Note: the lite-server variant does NOT consume the `id` correlation
/// field. Encoders MUST NOT include it; decoders ignore unknown fields.
///
/// This is a standalone codec (not coupled to BCryptoWebSocketClient,
/// which is USER WT). Tests import directly to pin wire shape.
public struct OpaqueMessageEnvelope: Equatable {

    public let type: String          // always "opaque_message" for this struct
    public let recipientId: String
    public let ciphertext: Data

    public static let typeName = "opaque_message"

    public init(recipientId: String, ciphertext: Data) {
        self.type = OpaqueMessageEnvelope.typeName
        self.recipientId = recipientId
        self.ciphertext = ciphertext
    }

    public static func makeOutbound(recipientId: String, ciphertext: Data) -> OpaqueMessageEnvelope {
        return OpaqueMessageEnvelope(recipientId: recipientId, ciphertext: ciphertext)
    }

    public enum Error: Swift.Error, LocalizedError {
        case wrongType(String)
        case missingField(String)
        case invalidBase64
        case malformedJson(String)

        public var errorDescription: String? {
            switch self {
            case .wrongType(let t): return "Expected type=opaque_message, got '\(t)'"
            case .missingField(let f): return "Missing required field '\(f)'"
            case .invalidBase64: return "ciphertext is not valid base64"
            case .malformedJson(let m): return "Malformed JSON: \(m)"
            }
        }
    }

    // MARK: - Encoding

    public func encodeAsJsonString() throws -> String {
        let outer: [String: Any] = [
            "type": type,
            "data": [
                "recipient_id": recipientId,
                "ciphertext": ciphertext.base64EncodedString()
            ]
        ]
        // Use `.sortedKeys` so output is deterministic — important for
        // KAT vectors and signature stability.
        let data = try JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw Error.malformedJson("UTF-8 encoding failed")
        }
        return s
    }

    public func encodeAsJsonData() throws -> Data {
        let outer: [String: Any] = [
            "type": type,
            "data": [
                "recipient_id": recipientId,
                "ciphertext": ciphertext.base64EncodedString()
            ]
        ]
        return try JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])
    }

    // MARK: - Decoding

    public static func decode(jsonString: String) throws -> OpaqueMessageEnvelope {
        guard let data = jsonString.data(using: .utf8) else {
            throw Error.malformedJson("Input not UTF-8")
        }
        return try decode(jsonData: data)
    }

    public static func decode(jsonData: Data) throws -> OpaqueMessageEnvelope {
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            throw Error.malformedJson(error.localizedDescription)
        }
        guard let dict = any as? [String: Any] else {
            throw Error.malformedJson("Top-level value is not an object")
        }
        guard let type = dict["type"] as? String else {
            throw Error.missingField("type")
        }
        guard type == OpaqueMessageEnvelope.typeName else {
            throw Error.wrongType(type)
        }
        guard let inner = dict["data"] as? [String: Any] else {
            throw Error.missingField("data")
        }
        guard let recipientId = inner["recipient_id"] as? String else {
            throw Error.missingField("recipient_id")
        }
        guard let b64 = inner["ciphertext"] as? String else {
            throw Error.missingField("ciphertext")
        }
        let ct: Data
        if b64.isEmpty {
            ct = Data()
        } else {
            guard let decoded = Data(base64Encoded: b64) else {
                throw Error.invalidBase64
            }
            ct = decoded
        }
        return OpaqueMessageEnvelope(recipientId: recipientId, ciphertext: ct)
    }
}
