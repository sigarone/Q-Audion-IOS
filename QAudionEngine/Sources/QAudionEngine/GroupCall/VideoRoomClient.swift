import Foundation

/// Group calls v2 (spec §4.2 / §4.3) — the Janus VideoRoom plugin API (v1.4
/// multistream) on top of `JanusClient`: publisher join / publish / configure,
/// multistream subscriber join / start / subscribe / unsubscribe / configure.

// MARK: - Model

/// One m-line of a publisher, or one stream a subscriber receives.
public struct VideoRoomStream: Equatable, Sendable {
    /// "audio" | "video" | "data"
    public let type: String
    /// Publisher: the publisher's own mid. Subscriber: the subscriber PC's mid.
    public let mid: String
    public let mindex: Int?
    /// Subscriber streams only: which publisher / which of its mids feeds this.
    public let feedId: String?
    public let feedMid: String?
    public let codec: String?
    /// The description the publisher gave it ("camera" / "screen").
    public let description: String?
    public let disabled: Bool
    public let simulcast: Bool

    public init(type: String, mid: String, mindex: Int? = nil, feedId: String? = nil, feedMid: String? = nil,
                codec: String? = nil, description: String? = nil, disabled: Bool = false, simulcast: Bool = false) {
        self.type = type
        self.mid = mid
        self.mindex = mindex
        self.feedId = feedId
        self.feedMid = feedMid
        self.codec = codec
        self.description = description
        self.disabled = disabled
        self.simulcast = simulcast
    }

    public var isVideo: Bool { type == "video" }
    public var isAudio: Bool { type == "audio" }
    public var isScreenShare: Bool { description == "screen" }

    static func parse(_ object: [String: Any], feedId defaultFeed: String? = nil) -> VideoRoomStream? {
        guard let type = object["type"] as? String else { return nil }
        // `mid` may be a string or a number depending on the Janus build.
        let midValue: String?
        if let text = object["mid"] as? String {
            midValue = text
        } else if let number = object["mid"] as? NSNumber {
            midValue = number.stringValue
        } else {
            midValue = nil
        }
        guard let mid = midValue else { return nil }
        var feedMid: String?
        if let text = object["feed_mid"] as? String {
            feedMid = text
        } else if let number = object["feed_mid"] as? NSNumber {
            feedMid = number.stringValue
        }
        let feed: String?
        if let text = object["feed_id"] as? String {
            feed = text
        } else if let number = object["feed_id"] as? NSNumber {
            feed = number.stringValue
        } else {
            feed = defaultFeed
        }
        return VideoRoomStream(
            type: type,
            mid: mid,
            mindex: (object["mindex"] as? NSNumber)?.intValue,
            feedId: feed,
            feedMid: feedMid,
            codec: object["codec"] as? String,
            description: object["description"] as? String ?? object["feed_description"] as? String,
            // Janus keeps a removed stream's mid in the subscriber's SDP as `active:false`.
            disabled: ((object["disabled"] as? NSNumber)?.boolValue ?? false)
                || ((object["active"] as? NSNumber)?.boolValue == false),
            simulcast: (object["simulcast"] as? NSNumber)?.boolValue ?? false)
    }
}

public struct VideoRoomPublisher: Equatable, Sendable {
    /// The pseudonym.
    public let id: String
    public let display: String?
    public let streams: [VideoRoomStream]

    public init(id: String, display: String?, streams: [VideoRoomStream]) {
        self.id = id
        self.display = display
        self.streams = streams
    }

    static func parseList(_ raw: Any?) -> [VideoRoomPublisher] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { entry -> VideoRoomPublisher? in
            let id: String
            if let text = entry["id"] as? String {
                id = text
            } else if let number = entry["id"] as? NSNumber {
                id = number.stringValue
            } else {
                return nil
            }
            let streamObjects = entry["streams"] as? [[String: Any]] ?? []
            let streams = streamObjects.compactMap { VideoRoomStream.parse($0) }
            return VideoRoomPublisher(id: id, display: entry["display"] as? String, streams: streams)
        }
    }
}

/// What a VideoRoom `event` on a handle means.
public enum VideoRoomEvent: Equatable, Sendable {
    case publishers([VideoRoomPublisher])
    /// A publisher stopped publishing (`unpublished`) or left (`leaving`).
    /// The value is the pseudonym, or "ok" for our own confirmation.
    case unpublished(String)
    case leaving(String)
    /// Subscriber: the current stream mapping (with or without a new offer).
    case attached([VideoRoomStream])
    case updated([VideoRoomStream])
    /// We were kicked out of the room (server-side roster removal).
    case kicked
    case destroyed
    case other(String)

    public static func parse(_ data: [String: Any]) -> VideoRoomEvent {
        if let list = data["publishers"] { return .publishers(VideoRoomPublisher.parseList(list)) }
        if let value = data["unpublished"] { return .unpublished(idString(value)) }
        if let value = data["leaving"] {
            if (data["reason"] as? String) == "kicked" { return .kicked }
            return .leaving(idString(value))
        }
        if (data["kicked"] as? String) != nil { return .kicked }
        let kind = data["videoroom"] as? String ?? ""
        if kind == "destroyed" { return .destroyed }
        if kind == "attached" || kind == "updated" {
            let list = (data["streams"] as? [[String: Any]] ?? []).compactMap { VideoRoomStream.parse($0) }
            return kind == "attached" ? .attached(list) : .updated(list)
        }
        return .other(kind)
    }

    private static func idString(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
}

// MARK: - Errors (spec §8)

public enum JanusErrorAction: Equatable, Sendable {
    /// One automatic `group_call_media_join`, then an error if it fails again.
    case retryMediaJoin
    /// Show an error.
    case fail
}

public enum JanusErrorPolicy {
    /// Spec §8 maps 428 / 433 to "one automatic media_join retry" and 426 / 436
    /// to a plain error. The real VideoRoom codes are 426 = no such room,
    /// 428 = no such feed, 433 = unauthorized (token / room), 436 = id exists:
    /// a missing room is exactly what a fresh media_join repairs (the server
    /// re-creates it), so 426 is retried too. Janus core 403 (token refused),
    /// 458 / 459 (session / handle gone) need a fresh session, so they retry
    /// the same way. 436 stays an error (the stale ghost is kicked by the
    /// server on the retry that the connection loss path already makes).
    public static func action(for error: JanusClientError) -> JanusErrorAction {
        switch error {
        case .plugin(let code, _):
            switch code {
            case 426, 428, 433: return .retryMediaJoin
            default: return .fail
            }
        case .janus(let code, _):
            switch code {
            case 403, 458, 459: return .retryMediaJoin
            default: return .fail
            }
        case .timeout, .closed, .notConnected, .malformed:
            return .fail
        }
    }
}

// MARK: - Client

public struct VideoRoomSubscribeTarget: Equatable, Sendable {
    public let feed: String
    public let mid: String?

    public init(feed: String, mid: String?) {
        self.feed = feed
        self.mid = mid
    }

    var dictionary: [String: Any] {
        var out: [String: Any] = ["feed": feed]
        if let mid = mid { out["mid"] = mid }
        return out
    }
}

public struct VideoRoomLayerConfig: Equatable, Sendable {
    /// Subscriber-side mid.
    public let mid: String
    public let substream: Int?
    public let temporal: Int?
    public let send: Bool?

    public init(mid: String, substream: Int? = nil, temporal: Int? = nil, send: Bool? = nil) {
        self.mid = mid
        self.substream = substream
        self.temporal = temporal
        self.send = send
    }

    var dictionary: [String: Any] {
        var out: [String: Any] = ["mid": mid]
        if let substream = substream { out["substream"] = substream }
        if let temporal = temporal { out["temporal"] = temporal }
        if let send = send { out["send"] = send }
        return out
    }
}

public final class VideoRoomClient: @unchecked Sendable {

    /// The order of the simulcast rids in our SDP (`GroupPublisherPeer.simulcast`).
    static let ridOrder = "lmh"

    /// Every publisher offer (publish, ICE restart) is end-to-end encrypted and
    /// lists its rids ascending: both flags travel on the JSEP object (spec §11),
    /// not in the request body.
    static func offerJsep(_ sdp: String) -> JanusJsep {
        JanusJsep(type: "offer", sdp: sdp, e2ee: true, ridOrder: ridOrder)
    }

    public let janus: JanusClient
    public let room: String
    public let pseudonym: String
    private let joinToken: String

    public init(janus: JanusClient, room: String, pseudonym: String, joinToken: String) {
        self.janus = janus
        self.room = room
        self.pseudonym = pseudonym
        self.joinToken = joinToken
    }

    public struct Joined: Sendable {
        /// Needed to join the subscriber handle (`require_pvtid`).
        public let privateId: Int64
        public let publishers: [VideoRoomPublisher]
    }

    /// `join {ptype:"publisher", room, id:pseudonym, display:pseudonym, token}`
    public func joinPublisher(handle: Int64) async throws -> Joined {
        let reply = try await janus.send(handle: handle, body: [
            "request": "join", "ptype": "publisher", "room": room,
            "id": pseudonym, "display": pseudonym, "token": joinToken,
        ])
        guard let data = reply.pluginData,
              let privateNumber = data["private_id"] as? NSNumber else { throw JanusClientError.malformed }
        let others = VideoRoomPublisher.parseList(data["publishers"]).filter { $0.id != pseudonym }
        return Joined(privateId: privateNumber.int64Value, publishers: others)
    }

    /// `publish` with the local offer; returns Janus' answer.
    public func publish(handle: Int64, offer: String, audio: Bool, video: Bool,
                        descriptions: [(mid: String, description: String)]) async throws -> String {
        let reply = try await janus.send(handle: handle, body: [
            "request": "publish", "audio": audio, "video": video,
            "descriptions": descriptions.map { ["mid": $0.mid, "description": $0.description] },
        ], jsep: Self.offerJsep(offer))
        guard let answer = reply.jsep, answer.type == "answer" else { throw JanusClientError.malformed }
        return answer.sdp
    }

    /// Publisher `configure`. With `restartOffer` it is the ICE restart
    /// (`restart:true` + a fresh offer) and returns Janus' answer.
    @discardableResult
    public func configurePublisher(handle: Int64, audio: Bool? = nil, video: Bool? = nil,
                                   keyframe: Bool? = nil, restartOffer: String? = nil) async throws -> String? {
        var body: [String: Any] = ["request": "configure"]
        if let audio = audio { body["audio"] = audio }
        if let video = video { body["video"] = video }
        if let keyframe = keyframe { body["keyframe"] = keyframe }
        var jsep: JanusJsep?
        if let offer = restartOffer {
            body["restart"] = true
            jsep = Self.offerJsep(offer)
        }
        let reply = try await janus.send(handle: handle, body: body, jsep: jsep)
        if restartOffer != nil {
            guard let answer = reply.jsep, answer.type == "answer" else { throw JanusClientError.malformed }
            return answer.sdp
        }
        return nil
    }

    /// Subscriber `join`. The reply is an `attached` event carrying Janus' offer.
    public func joinSubscriber(handle: Int64, privateId: Int64, targets: [VideoRoomSubscribeTarget]) async throws -> JanusMessage {
        try await janus.send(handle: handle, body: [
            // Only `private_id` (`require_pvtid`): the join token is the publisher's.
            "request": "join", "ptype": "subscriber", "room": room,
            "private_id": privateId,
            "streams": targets.map { $0.dictionary },
        ])
    }

    /// Sends the answer to Janus' offer (`start`).
    public func start(handle: Int64, answer: String) async throws {
        _ = try await janus.send(handle: handle, body: ["request": "start", "room": room],
                                 jsep: JanusJsep(type: "answer", sdp: answer))
    }

    public func subscribe(handle: Int64, targets: [VideoRoomSubscribeTarget]) async throws -> JanusMessage {
        try await janus.send(handle: handle, body: [
            "request": "subscribe", "streams": targets.map { $0.dictionary },
        ])
    }

    public func unsubscribe(handle: Int64, targets: [VideoRoomSubscribeTarget]) async throws -> JanusMessage {
        try await janus.send(handle: handle, body: [
            "request": "unsubscribe", "streams": targets.map { $0.dictionary },
        ])
    }

    /// Subscriber `configure`: substream / temporal layer per mid, or
    /// `restart:true` for an ICE restart (Janus answers with a new offer).
    public func configureSubscriber(handle: Int64, layers: [VideoRoomLayerConfig], restart: Bool = false) async throws -> JanusMessage {
        var body: [String: Any] = ["request": "configure"]
        if !layers.isEmpty { body["streams"] = layers.map { $0.dictionary } }
        if restart { body["restart"] = true }
        return try await janus.send(handle: handle, body: body)
    }

    /// Fire-and-forget; the server kicks the participant on leave anyway.
    public func leave(handle: Int64) {
        Task { [janus] in
            _ = try? await janus.send(handle: handle, body: ["request": "leave"])
        }
    }
}
