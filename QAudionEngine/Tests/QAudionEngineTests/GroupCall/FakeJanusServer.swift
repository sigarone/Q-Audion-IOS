import Foundation
@testable import QAudionEngine

/// A scripted Janus + VideoRoom in one `JanusSocket`: it answers the requests
/// the client sends the way qjanus does (ack first, then the final event, with
/// the JSEP where the plugin sends one) so `JanusClient`, `VideoRoomClient` and
/// `GroupMediaSession` can be tested end to end without a network. Nothing in
/// here is a real host, id or address.
final class FakeJanusServer: JanusSocket, @unchecked Sendable {

    var onText: ((String) -> Void)?
    var onClosed: ((Error?) -> Void)?

    // Scripting
    var openError: Error?
    var sessionId: Int64 = 1001
    var privateId: Int64 = 4242
    var publishersOnJoin: [[String: Any]] = []
    var publishAnswerSdp = FakeJanusServer.sdp(setup: "a=setup:active")
    var subscriberOfferSdp = FakeJanusServer.sdp(setup: "a=setup:actpass")
    /// Mapping returned by subscriber join / subscribe: [(feed, feedMid, type, mid)].
    var subscriberStreams: [(feed: String, feedMid: String, type: String, mid: String)] = []
    /// request name -> plugin error code, consumed once.
    var pluginErrors: [String: Int] = [:]
    /// Plugin error code for the next SUBSCRIBER join only (the publisher join is untouched).
    var subscriberJoinError: Int?
    /// request names whose replies are swallowed (timeout tests).
    var swallow: Set<String> = []
    var swallowOnce: Set<String> = []
    var claimError: Int?
    var requireToken: String?

    // Recording
    private let lock = NSLock()
    private var _requests: [[String: Any]] = []
    private var nextHandle: Int64 = 2000
    private var handles: [Int64: String] = [:]
    private(set) var closedByClient = false
    private let queue = DispatchQueue(label: "fake.janus")

    var requests: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    /// Plugin `request` names in order (join, publish, configure, ...).
    var pluginRequests: [String] {
        requests.compactMap { ($0["body"] as? [String: Any])?["request"] as? String }
    }

    func bodies(for request: String) -> [[String: Any]] {
        requests.compactMap { $0["body"] as? [String: Any] }.filter { ($0["request"] as? String) == request }
    }

    func jsep(for request: String) -> [[String: Any]] {
        requests.filter { (($0["body"] as? [String: Any])?["request"] as? String) == request }.compactMap { $0["jsep"] as? [String: Any] }
    }

    func handle(forRole role: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return handles.first { $0.value == role }?.key
    }

    // MARK: JanusSocket

    func open() async throws {
        if let error = openError { throw error }
    }

    func send(_ text: String, completion: @escaping (Error?) -> Void) {
        completion(nil)
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        lock.lock()
        _requests.append(object)
        lock.unlock()
        queue.async { [weak self] in self?.respond(to: object) }
    }

    func close() {
        lock.lock(); closedByClient = true; lock.unlock()
    }

    // MARK: Server side

    /// Delivers an unsolicited message (event, slowlink, ...).
    func push(_ message: [String: Any]) {
        queue.async { [weak self] in self?.deliver(message) }
    }

    /// The connection drops without a `close()` from the client.
    func dropConnection(error: Error? = nil) {
        queue.async { [weak self] in self?.onClosed?(error) }
    }

    private func deliver(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        onText?(text)
    }

    private func reply(_ kind: String, _ request: [String: Any], extra: [String: Any] = [:]) {
        var message: [String: Any] = ["janus": kind]
        if let transaction = request["transaction"] { message["transaction"] = transaction }
        for (key, value) in extra { message[key] = value }
        deliver(message)
    }

    private func event(_ request: [String: Any], handle: Int64, data: [String: Any], jsep: [String: Any]? = nil) {
        var message: [String: Any] = [
            "janus": "event", "session_id": sessionId, "sender": handle,
            "plugindata": ["plugin": JanusWire.pluginVideoRoom, "data": data],
        ]
        if let transaction = request["transaction"] { message["transaction"] = transaction }
        if let jsep = jsep { message["jsep"] = jsep }
        deliver(message)
    }

    private func respond(to request: [String: Any]) {
        let kind = request["janus"] as? String ?? ""
        if let required = requireToken, (request["token"] as? String) != required {
            reply("error", request, extra: ["error": ["code": 403, "reason": "Unauthorized request"]])
            return
        }
        switch kind {
        case "create":
            reply("success", request, extra: ["data": ["id": sessionId]])
        case "claim":
            if let code = claimError {
                reply("error", request, extra: ["error": ["code": code, "reason": "No such session"]])
            } else {
                reply("success", request, extra: ["session_id": sessionId])
            }
        case "keepalive":
            reply("ack", request, extra: ["session_id": sessionId])
        case "attach":
            lock.lock()
            nextHandle += 1
            let handle = nextHandle
            handles[handle] = handles.isEmpty ? "publisher" : "subscriber"
            lock.unlock()
            reply("success", request, extra: ["session_id": sessionId, "data": ["id": handle]])
        case "message":
            handleMessage(request)
        case "trickle", "detach":
            reply("ack", request)
        case "destroy":
            reply("success", request)
        default:
            break
        }
    }

    private func handleMessage(_ request: [String: Any]) {
        let handle = (request["handle_id"] as? NSNumber)?.int64Value ?? 0
        let body = request["body"] as? [String: Any] ?? [:]
        let name = body["request"] as? String ?? ""
        let hasJsep = request["jsep"] != nil
        if swallow.contains(name) { return }
        if swallowOnce.remove(name) != nil { return }
        reply("ack", request)
        if let code = pluginErrors.removeValue(forKey: name) {
            event(request, handle: handle, data: ["videoroom": "event", "error_code": code, "error": "scripted"])
            return
        }
        switch name {
        case "join":
            if (body["ptype"] as? String) == "publisher" {
                event(request, handle: handle, data: [
                    "videoroom": "joined", "room": body["room"] ?? "", "id": body["id"] ?? "",
                    "private_id": privateId, "publishers": publishersOnJoin,
                ])
            } else if let code = subscriberJoinError {
                subscriberJoinError = nil
                event(request, handle: handle, data: ["videoroom": "event", "error_code": code, "error": "scripted"])
            } else {
                event(request, handle: handle, data: [
                    "videoroom": "attached", "room": body["room"] ?? "", "streams": streamObjects(),
                ], jsep: ["type": "offer", "sdp": subscriberOfferSdp])
            }
        case "publish":
            event(request, handle: handle, data: ["videoroom": "event", "configured": "ok"],
                  jsep: ["type": "answer", "sdp": publishAnswerSdp])
        case "configure":
            if hasJsep {
                event(request, handle: handle, data: ["videoroom": "event", "configured": "ok"],
                      jsep: ["type": "answer", "sdp": publishAnswerSdp])
            } else if body["restart"] as? Bool == true {
                event(request, handle: handle, data: ["videoroom": "event", "configured": "ok"],
                      jsep: ["type": "offer", "sdp": subscriberOfferSdp])
            } else {
                event(request, handle: handle, data: ["videoroom": "event", "configured": "ok"])
            }
        case "subscribe", "unsubscribe":
            event(request, handle: handle, data: ["videoroom": "updated", "room": "r", "streams": streamObjects()],
                  jsep: ["type": "offer", "sdp": subscriberOfferSdp])
        case "start", "leave":
            event(request, handle: handle, data: ["videoroom": "event", "started": "ok"])
        default:
            event(request, handle: handle, data: ["videoroom": "event"])
        }
    }

    private func streamObjects() -> [[String: Any]] {
        subscriberStreams.map { item in
            ["type": item.type, "mindex": Int(item.mid) ?? 0, "mid": item.mid,
             "feed_id": item.feed, "feed_mid": item.feedMid, "codec": item.type == "audio" ? "opus" : "vp8"]
        }
    }

    // MARK: SDP fixtures

    static let fingerprintPair = "AB"

    static func sdp(setup: String, fingerprintPair pair: String = fingerprintPair) -> String {
        [
            "v=0", "o=- 1 2 IN IP4 127.0.0.1", "s=-", "t=0 0", "a=group:BUNDLE 0 1",
            "a=fingerprint:sha-256 " + Array(repeating: pair, count: 32).joined(separator: ":"),
            "m=audio 9 UDP/TLS/RTP/SAVPF 111", "c=IN IP4 0.0.0.0", "a=mid:0", setup,
            "a=rtpmap:111 opus/48000/2", "a=fmtp:111 minptime=10;useinbandfec=1",
            "m=video 9 UDP/TLS/RTP/SAVPF 96", "c=IN IP4 0.0.0.0", "a=mid:1", setup, "a=rtpmap:96 VP8/90000", "",
        ].joined(separator: "\r\n")
    }

    static func publisher(id: String, videoMid: String = "1", audioMid: String = "0", screen: Bool = false) -> [String: Any] {
        var video: [String: Any] = ["type": "video", "mindex": 1, "mid": videoMid, "codec": "vp8", "simulcast": true]
        if screen { video["description"] = "screen" }
        return [
            "id": id, "display": id,
            "streams": [
                ["type": "audio", "mindex": 0, "mid": audioMid, "codec": "opus"],
                video,
            ],
        ]
    }
}
