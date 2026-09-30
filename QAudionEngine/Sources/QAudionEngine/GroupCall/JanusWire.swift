import Foundation

/// Group calls v2 (spec §4.1) — Janus JSON-over-WebSocket messages. Requests
/// are plain dictionaries built here; replies and events are decoded into
/// `JanusMessage`. Pure, so the protocol codec is unit-tested without a socket.
///
/// Nothing that identifies a participant or carries a secret is ever printed:
/// callers log kinds and codes only.
public struct JanusJsep: Equatable, Sendable {
    public let type: String
    public let sdp: String

    public init(type: String, sdp: String) {
        self.type = type
        self.sdp = sdp
    }

    var dictionary: [String: Any] { ["type": type, "sdp": sdp] }
}

public struct JanusMessage: @unchecked Sendable {

    public enum Kind: String, Sendable {
        case ack
        case success
        case error
        case event
        case webrtcup
        case media
        case slowlink
        case hangup
        case detached
        case timeout
        case trickle
        case other
    }

    public let kind: Kind
    public let transaction: String?
    public let sessionId: Int64?
    /// Handle id of the plugin handle the message belongs to.
    public let sender: Int64?
    /// `data.id` of a `success` reply (session id or handle id).
    public let dataId: Int64?
    /// `plugindata.data` of an `event` / synchronous `success`.
    public let pluginData: [String: Any]?
    public let jsep: JanusJsep?
    public let errorCode: Int?
    public let errorReason: String?
    /// The whole decoded object, for the rare field not modelled above.
    public let raw: [String: Any]

    /// `slowlink` payload.
    public var slowlinkUplink: Bool? { (raw["uplink"] as? NSNumber)?.boolValue }
    public var slowlinkNacks: Int? { (raw["nacks"] as? NSNumber)?.intValue }
    /// `hangup` payload.
    public var hangupReason: String? { raw["reason"] as? String }
    /// `media` payload.
    public var mediaType: String? { raw["type"] as? String }
    public var mediaReceiving: Bool? { (raw["receiving"] as? NSNumber)?.boolValue }

    /// The VideoRoom plugin's own error code inside an `event`, if any.
    public var pluginErrorCode: Int? { (pluginData?["error_code"] as? NSNumber)?.intValue }
    public var pluginErrorReason: String? { pluginData?["error"] as? String }

    public static func parse(_ text: String) -> JanusMessage? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let janus = object["janus"] as? String else { return nil }
        let kind = Kind(rawValue: janus) ?? .other
        var jsep: JanusJsep?
        if let j = object["jsep"] as? [String: Any], let type = j["type"] as? String, let sdp = j["sdp"] as? String {
            jsep = JanusJsep(type: type, sdp: sdp)
        }
        var pluginData: [String: Any]?
        if let plugin = object["plugindata"] as? [String: Any] {
            pluginData = plugin["data"] as? [String: Any]
        }
        var errorCode: Int?
        var errorReason: String?
        if let err = object["error"] as? [String: Any] {
            errorCode = (err["code"] as? NSNumber)?.intValue
            errorReason = err["reason"] as? String
        }
        return JanusMessage(
            kind: kind,
            transaction: object["transaction"] as? String,
            sessionId: (object["session_id"] as? NSNumber)?.int64Value,
            sender: (object["sender"] as? NSNumber)?.int64Value,
            dataId: ((object["data"] as? [String: Any])?["id"] as? NSNumber)?.int64Value,
            pluginData: pluginData,
            jsep: jsep,
            errorCode: errorCode,
            errorReason: errorReason,
            raw: object)
    }
}

public enum JanusWire {

    public static let pluginVideoRoom = "janus.plugin.videoroom"
    public static let subprotocol = "janus-protocol"

    /// Random transaction id, 128 bits (spec: >= 64).
    public static func newTransaction() -> String {
        var generator = SystemRandomNumberGenerator()
        var out = ""
        out.reserveCapacity(32)
        for _ in 0..<16 {
            let byte = UInt8.random(in: 0...255, using: &generator)
            out += String(format: "%02x", byte)
        }
        return out
    }

    // Requests. `transaction` is added by the client; `token` is the session
    // token, sent on EVERY request (Janus checks it on each one, not only on
    // `create`).

    public static func create(token: String) -> [String: Any] {
        ["janus": "create", "token": token]
    }

    public static func claim(sessionId: Int64, token: String) -> [String: Any] {
        ["janus": "claim", "session_id": sessionId, "token": token]
    }

    public static func keepalive(sessionId: Int64, token: String) -> [String: Any] {
        ["janus": "keepalive", "session_id": sessionId, "token": token]
    }

    public static func attach(sessionId: Int64, plugin: String, token: String) -> [String: Any] {
        ["janus": "attach", "session_id": sessionId, "plugin": plugin, "token": token]
    }

    public static func detach(sessionId: Int64, handleId: Int64, token: String) -> [String: Any] {
        ["janus": "detach", "session_id": sessionId, "handle_id": handleId, "token": token]
    }

    public static func destroy(sessionId: Int64, token: String) -> [String: Any] {
        ["janus": "destroy", "session_id": sessionId, "token": token]
    }

    public static func message(sessionId: Int64, handleId: Int64, body: [String: Any], jsep: JanusJsep?, token: String) -> [String: Any] {
        var out: [String: Any] = [
            "janus": "message", "session_id": sessionId, "handle_id": handleId, "body": body, "token": token,
        ]
        if let jsep = jsep { out["jsep"] = jsep.dictionary }
        return out
    }

    /// `candidate == nil` sends the end-of-candidates marker.
    public static func trickle(sessionId: Int64, handleId: Int64, candidate: (sdpMid: String?, sdpMLineIndex: Int32, candidate: String)?, token: String) -> [String: Any] {
        var out: [String: Any] = ["janus": "trickle", "session_id": sessionId, "handle_id": handleId, "token": token]
        if let c = candidate {
            var body: [String: Any] = ["candidate": c.candidate, "sdpMLineIndex": Int(c.sdpMLineIndex)]
            if let mid = c.sdpMid { body["sdpMid"] = mid }
            out["candidate"] = body
        } else {
            out["candidate"] = ["completed": true]
        }
        return out
    }

    public static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
