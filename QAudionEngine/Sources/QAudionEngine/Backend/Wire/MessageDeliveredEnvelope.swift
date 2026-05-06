import Foundation

/// Pure-Swift codec for the `msg_delivered` WebSocket envelope.
///
/// Server emits this to the original sender when the recipient's WS
/// connection picks up the message.
///
/// Wire format (frozen per spec §5.11 / Android `WsCommand.kt` reference):
/// ```json
/// { "type": "msg_delivered", "data": {
///   "message_id": "<uuid>",
///   "delivered_to": "<user-uuid>",
///   "delivered_ts": <unix_ms>
/// }}
/// ```
///
/// Outer envelope has no top-level `id` field (lite-server contract).
/// Decoders tolerate unknown future fields.
///
/// This is a standalone codec — NOT coupled to BCryptoWebSocketClient (USER WT).
public struct MessageDeliveredEnvelope: Equatable {

    public let messageId: UUID
    public let deliveredTo: String
    public let deliveredTs: Int64  // unix milliseconds

    public static let typeName = "msg_delivered"

    public init(messageId: UUID, deliveredTo: String, deliveredTs: Int64) {
        self.messageId = messageId
        self.deliveredTo = deliveredTo
        self.deliveredTs = deliveredTs
    }

    // MARK: - Error

    public enum Error: Swift.Error, LocalizedError {
        case wrongType(String)
        case missingField(String)
        case invalidUuid(String)
        case malformedJson(String)

        public var errorDescription: String? {
            switch self {
            case .wrongType(let t):    return "Expected type=msg_delivered, got '\(t)'"
            case .missingField(let f): return "Missing field '\(f)'"
            case .invalidUuid(let s):  return "Bad UUID: '\(s)'"
            case .malformedJson(let m): return "Malformed JSON: \(m)"
            }
        }
    }

    // MARK: - Encoding

    public func encodeAsJsonString() throws -> String {
        let outer: [String: Any] = [
            "type": MessageDeliveredEnvelope.typeName,
            "data": [
                "message_id": messageId.uuidString.lowercased(),
                "delivered_to": deliveredTo,
                "delivered_ts": deliveredTs
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw Error.malformedJson("UTF-8 encoding failed")
        }
        return s
    }

    // MARK: - Decoding

    public static func decode(jsonString: String) throws -> MessageDeliveredEnvelope {
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

        guard let dto = inner["delivered_to"] as? String else { throw Error.missingField("delivered_to") }

        let ts: Int64
        if let v = inner["delivered_ts"] as? Int64 { ts = v }
        else if let v = inner["delivered_ts"] as? Int { ts = Int64(v) }
        else if let v = inner["delivered_ts"] as? Double { ts = Int64(v) }
        else { throw Error.missingField("delivered_ts") }

        return MessageDeliveredEnvelope(messageId: mid, deliveredTo: dto, deliveredTs: ts)
    }
}
