import Foundation

/// Pure-Swift codec for the `msg_send` WebSocket envelope.
///
/// Wire format (frozen per spec §5.11 / Android `WsCommand.kt` reference):
/// ```json
/// { "type": "msg_send", "data": {
///   "message_id": "<uuid>",
///   "recipient_id": "<user-uuid>",
///   "ciphertext": "<base64>",
///   "client_ts": <unix_ms>
/// }}
/// ```
///
/// Outer envelope has no top-level `id` field (lite-server contract).
/// Decoders tolerate unknown future fields (e.g. `server_ts`).
///
/// This is a standalone codec — NOT coupled to BCryptoWebSocketClient (USER WT).
public struct MessageSendEnvelope: Equatable {

    public let messageId: UUID
    public let recipientId: String
    public let ciphertext: Data
    public let clientTs: Int64  // unix milliseconds

    public static let typeName = "msg_send"

    public init(messageId: UUID, recipientId: String, ciphertext: Data, clientTs: Int64) {
        self.messageId = messageId
        self.recipientId = recipientId
        self.ciphertext = ciphertext
        self.clientTs = clientTs
    }

    // MARK: - Error

    public enum Error: Swift.Error, LocalizedError {
        case wrongType(String)
        case missingField(String)
        case invalidUuid(String)
        case invalidBase64
        case malformedJson(String)

        public var errorDescription: String? {
            switch self {
            case .wrongType(let t):    return "Expected type=msg_send, got '\(t)'"
            case .missingField(let f): return "Missing field '\(f)'"
            case .invalidUuid(let s):  return "Bad UUID: '\(s)'"
            case .invalidBase64:       return "ciphertext is not valid base64"
            case .malformedJson(let m): return "Malformed JSON: \(m)"
            }
        }
    }

    // MARK: - Encoding

    public func encodeAsJsonString() throws -> String {
        let outer: [String: Any] = [
            "type": MessageSendEnvelope.typeName,
            "data": [
                "message_id": messageId.uuidString.lowercased(),
                "recipient_id": recipientId,
                "ciphertext": ciphertext.base64EncodedString(),
                "client_ts": clientTs
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw Error.malformedJson("UTF-8 encoding failed")
        }
        return s
    }

    // MARK: - Decoding

    public static func decode(jsonString: String) throws -> MessageSendEnvelope {
        guard let raw = jsonString.data(using: .utf8) else {
            throw Error.malformedJson("Input not UTF-8")
        }
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: raw)
        } catch {
            throw Error.malformedJson(error.localizedDescription)
        }
        guard let dict = any as? [String: Any] else {
            throw Error.malformedJson("Not an object")
        }
        guard let type = dict["type"] as? String else { throw Error.missingField("type") }
        guard type == typeName else { throw Error.wrongType(type) }
        guard let inner = dict["data"] as? [String: Any] else { throw Error.missingField("data") }

        guard let midStr = inner["message_id"] as? String else { throw Error.missingField("message_id") }
        guard let mid = UUID(uuidString: midStr) else { throw Error.invalidUuid(midStr) }

        guard let rid = inner["recipient_id"] as? String else { throw Error.missingField("recipient_id") }

        guard let b64 = inner["ciphertext"] as? String else { throw Error.missingField("ciphertext") }
        let ct: Data
        if b64.isEmpty {
            ct = Data()
        } else {
            guard let d = Data(base64Encoded: b64) else { throw Error.invalidBase64 }
            ct = d
        }

        let ts: Int64
        if let v = inner["client_ts"] as? Int64 { ts = v }
        else if let v = inner["client_ts"] as? Int { ts = Int64(v) }
        else if let v = inner["client_ts"] as? Double { ts = Int64(v) }
        else { throw Error.missingField("client_ts") }

        return MessageSendEnvelope(messageId: mid, recipientId: rid, ciphertext: ct, clientTs: ts)
    }
}
