import Foundation

/// Pure-Swift codec for the `msg_send` WebSocket envelope.
///
/// Wire format (frozen per Android WsCodec.kt `MsgSend` encoder / spec §5.11):
/// ```json
/// { "type": "msg_send", "data": {
///   "recipient_id":    "<user-uuid>",
///   "encrypted_payload": "<base64>",
///   "msg_type":        0,
///   "client_msg_id":   "<uuid>",
///   "expires_in_sec":  0,
///   "reply_to_server_msg_id": "<uuid>"  // optional
/// }}
/// ```
///
/// Outer envelope has no top-level `id` field (lite-server contract).
/// Decoders tolerate unknown future fields.
///
/// This is a standalone codec — NOT coupled to BCryptoMessageApiImpl (USER WT).
public struct MessageSendEnvelope: Equatable {

    public let recipientId: String
    public let encryptedPayload: Data
    public let msgType: Int
    public let clientMsgId: String
    public let expiresInSec: Int64
    public let replyToServerMsgId: String?

    public static let typeName = "msg_send"

    public init(
        recipientId: String,
        encryptedPayload: Data,
        msgType: Int = 0,
        clientMsgId: String,
        expiresInSec: Int64 = 0,
        replyToServerMsgId: String? = nil
    ) {
        self.recipientId = recipientId
        self.encryptedPayload = encryptedPayload
        self.msgType = msgType
        self.clientMsgId = clientMsgId
        self.expiresInSec = expiresInSec
        self.replyToServerMsgId = replyToServerMsgId
    }

    // MARK: - Error

    public enum Error: Swift.Error, LocalizedError {
        case wrongType(String)
        case missingField(String)
        case invalidBase64
        case malformedJson(String)

        public var errorDescription: String? {
            switch self {
            case .wrongType(let t):    return "Expected type=msg_send, got '\(t)'"
            case .missingField(let f): return "Missing field '\(f)'"
            case .invalidBase64:       return "encrypted_payload is not valid base64"
            case .malformedJson(let m): return "Malformed JSON: \(m)"
            }
        }
    }

    // MARK: - Encoding

    public func encodeAsJsonString() throws -> String {
        var inner: [String: Any] = [
            "recipient_id": recipientId,
            "encrypted_payload": encryptedPayload.base64EncodedString(),
            "msg_type": msgType,
            "client_msg_id": clientMsgId,
            "expires_in_sec": expiresInSec,
        ]
        if let reply = replyToServerMsgId {
            inner["reply_to_server_msg_id"] = reply
        }
        let outer: [String: Any] = ["type": MessageSendEnvelope.typeName, "data": inner]
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

        guard let rid = inner["recipient_id"] as? String else { throw Error.missingField("recipient_id") }

        guard let b64 = inner["encrypted_payload"] as? String else { throw Error.missingField("encrypted_payload") }
        let payload: Data
        if b64.isEmpty {
            payload = Data()
        } else {
            guard let d = Data(base64Encoded: b64) else { throw Error.invalidBase64 }
            payload = d
        }

        let msgType: Int
        if let v = inner["msg_type"] as? Int { msgType = v } else if let v = inner["msg_type"] as? NSNumber { msgType = v.intValue } else { msgType = 0 }

        guard let clientMsgId = inner["client_msg_id"] as? String else { throw Error.missingField("client_msg_id") }

        let expiresInSec: Int64
        if let v = inner["expires_in_sec"] as? Int64 { expiresInSec = v } else if let v = inner["expires_in_sec"] as? Int { expiresInSec = Int64(v) } else if let v = inner["expires_in_sec"] as? Double { expiresInSec = Int64(v) } else { expiresInSec = 0 }

        let replyTo = inner["reply_to_server_msg_id"] as? String

        return MessageSendEnvelope(
            recipientId: rid,
            encryptedPayload: payload,
            msgType: msgType,
            clientMsgId: clientMsgId,
            expiresInSec: expiresInSec,
            replyToServerMsgId: replyTo
        )
    }
}
