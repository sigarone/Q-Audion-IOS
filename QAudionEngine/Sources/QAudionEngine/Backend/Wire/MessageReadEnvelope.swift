import Foundation

/// Pure-Swift codec for the `msg_read` WebSocket envelope.
///
/// The recipient emits this when the message is opened in the UI.
///
/// Wire format (frozen per spec §5.11 / Android `WsCommand.kt` reference):
/// ```json
/// { "type": "msg_read", "data": {
///   "message_id": "<uuid>",
///   "reader_id": "<user-uuid>",
///   "read_ts": <unix_ms>
/// }}
/// ```
///
/// Outer envelope has no top-level `id` field (lite-server contract).
/// Decoders tolerate unknown future fields.
///
/// This is a standalone codec — NOT coupled to BCryptoWebSocketClient (USER WT).
public struct MessageReadEnvelope: Equatable {

    public let messageId: UUID
    public let readerId: String
    public let readTs: Int64  // unix milliseconds

    public static let typeName = "msg_read"

    public init(messageId: UUID, readerId: String, readTs: Int64) {
        self.messageId = messageId
        self.readerId = readerId
        self.readTs = readTs
    }

    // MARK: - Error

    public enum Error: Swift.Error, LocalizedError {
        case wrongType(String)
        case missingField(String)
        case invalidUuid(String)
        case malformedJson(String)

        public var errorDescription: String? {
            switch self {
            case .wrongType(let t):    return "Expected type=msg_read, got '\(t)'"
            case .missingField(let f): return "Missing field '\(f)'"
            case .invalidUuid(let s):  return "Bad UUID: '\(s)'"
            case .malformedJson(let m): return "Malformed JSON: \(m)"
            }
        }
    }

    // MARK: - Encoding

    public func encodeAsJsonString() throws -> String {
        let outer: [String: Any] = [
            "type": MessageReadEnvelope.typeName,
            "data": [
                "message_id": messageId.uuidString.lowercased(),
                "reader_id": readerId,
                "read_ts": readTs
            ] as [String: Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw Error.malformedJson("UTF-8 encoding failed")
        }
        return s
    }

    // MARK: - Decoding

    public static func decode(jsonString: String) throws -> MessageReadEnvelope {
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

        guard let rid = inner["reader_id"] as? String else { throw Error.missingField("reader_id") }

        let ts: Int64
        if let v = inner["read_ts"] as? Int64 { ts = v } else if let v = inner["read_ts"] as? Int { ts = Int64(v) } else if let v = inner["read_ts"] as? Double { ts = Int64(v) } else { throw Error.missingField("read_ts") }

        return MessageReadEnvelope(messageId: mid, readerId: rid, readTs: ts)
    }
}
