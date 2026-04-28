import Foundation

/// Pure-Swift codec for the `msg_typing` WebSocket envelope.
///
/// Transient presence hint — not stored by the server. Sent whenever
/// the local user starts or stops typing in a conversation.
///
/// Wire format (frozen per spec §5.11 / Android `WsCommand.kt` reference):
/// ```json
/// { "type": "msg_typing", "data": {
///   "recipient_id": "<user-uuid>",
///   "is_typing": true|false
/// }}
/// ```
///
/// No `message_id` or timestamp field — the server does not persist this.
/// Outer envelope has no top-level `id` field (lite-server contract).
/// Decoders tolerate unknown future fields.
///
/// This is a standalone codec — NOT coupled to BCryptoWebSocketClient (USER WT).
public struct MessageTypingEnvelope: Equatable {

    public let recipientId: String
    public let isTyping: Bool

    public static let typeName = "msg_typing"

    public init(recipientId: String, isTyping: Bool) {
        self.recipientId = recipientId
        self.isTyping = isTyping
    }

    // MARK: - Error

    public enum Error: Swift.Error, LocalizedError {
        case wrongType(String)
        case missingField(String)
        case malformedJson(String)

        public var errorDescription: String? {
            switch self {
            case .wrongType(let t):    return "Expected type=msg_typing, got '\(t)'"
            case .missingField(let f): return "Missing field '\(f)'"
            case .malformedJson(let m): return "Malformed JSON: \(m)"
            }
        }
    }

    // MARK: - Encoding

    public func encodeAsJsonString() throws -> String {
        let outer: [String: Any] = [
            "type": MessageTypingEnvelope.typeName,
            "data": [
                "is_typing": isTyping,
                "recipient_id": recipientId
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw Error.malformedJson("UTF-8 encoding failed")
        }
        return s
    }

    // MARK: - Decoding

    public static func decode(jsonString: String) throws -> MessageTypingEnvelope {
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

        guard let rid = inner["recipient_id"] as? String else { throw Error.missingField("recipient_id") }
        guard let typing = inner["is_typing"] as? Bool else { throw Error.missingField("is_typing") }

        return MessageTypingEnvelope(recipientId: rid, isTyping: typing)
    }
}
