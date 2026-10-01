import Foundation

/// Group calls v2 (docs/GROUP_CALLS_V2_SPEC.md §2) — the server <-> client
/// WebSocket messages that replace the LiveKit token round-trip. Pure parsing
/// and validation, no I/O and no WebRTC types, so every rule below is pinned
/// by `GroupCallWireTests` without a live socket.
///
/// Logging rule for this whole directory: ids only, never in full. Call ids
/// and pseudonyms are cut to 8 characters (`GroupTelemetry.id8`), tokens,
/// fingerprints, ICE credentials and ip addresses are never logged at all.
public enum GroupCallWire {

    /// A pseudonym / room id / join token is 128 random bits as 32 lowercase
    /// hex characters (spec §2.1 / §2.3).
    public static func isHex128(_ value: String) -> Bool {
        guard value.utf8.count == 32 else { return false }
        for byte in value.utf8 {
            let isDigit = byte >= 0x30 && byte <= 0x39
            let isLowerHex = byte >= 0x61 && byte <= 0x66
            if !isDigit && !isLowerHex { return false }
        }
        return true
    }

    /// ICE server as delivered inside `group_call_media_ready`. The username
    /// and credential are secrets of this call: never printed.
    public struct IceServer: Equatable, Sendable {
        public let urls: [String]
        public let username: String?
        public let credential: String?

        public init(urls: [String], username: String?, credential: String?) {
            self.urls = urls
            self.username = username
            self.credential = credential
        }
    }

    // MARK: - group_call_media_ready (S->C, spec §2.3)

    public struct MediaReady: Equatable, Sendable {
        public let callId: String
        public let nodeId: String
        /// `wss://<host>/janus`. Only `wss` is accepted (see `parse`).
        public let wsUrl: String
        /// Janus string room id (random, NOT the call id).
        public let room: String
        /// Janus participant id (`string_ids`) AND display name.
        public let pseudonym: String
        /// Janus core signed token, sent on every request of the session.
        public let sessionToken: String
        /// VideoRoom `allowed` token of this participant.
        public let joinToken: String
        /// Pinned DTLS certificate fingerprint of the node, normalised by
        /// `GroupSdpRules.normalizeFingerprint` ("sha-256 AB:CD:..").
        public let dtlsFingerprint: String
        public let iceServers: [IceServer]
        public let ttlSeconds: Int

        public init(callId: String, nodeId: String, wsUrl: String, room: String, pseudonym: String,
                    sessionToken: String, joinToken: String, dtlsFingerprint: String,
                    iceServers: [IceServer], ttlSeconds: Int) {
            self.callId = callId
            self.nodeId = nodeId
            self.wsUrl = wsUrl
            self.room = room
            self.pseudonym = pseudonym
            self.sessionToken = sessionToken
            self.joinToken = joinToken
            self.dtlsFingerprint = dtlsFingerprint
            self.iceServers = iceServers
            self.ttlSeconds = ttlSeconds
        }

        /// nil when any field is missing or malformed. Fail-closed on purpose:
        /// a plain `ws://` url, a pseudonym that is not 128-bit hex or a
        /// fingerprint that is not SHA-256 would each silently weaken the
        /// pinned, encrypted path, so the whole message is refused instead.
        public static func parse(_ data: [String: Any]) -> MediaReady? {
            guard let callId = data["call_id"] as? String, !callId.isEmpty,
                  let nodeId = data["node_id"] as? String, !nodeId.isEmpty,
                  let wsUrl = data["ws_url"] as? String,
                  let room = data["room"] as? String, !room.isEmpty,
                  let pseudonym = data["pseudonym"] as? String,
                  let sessionToken = data["session_token"] as? String, !sessionToken.isEmpty,
                  let joinToken = data["join_token"] as? String, !joinToken.isEmpty,
                  let fingerprintRaw = data["dtls_fingerprint"] as? String else { return nil }
            guard isHex128(pseudonym) else { return nil }
            guard let url = URL(string: wsUrl), url.scheme?.lowercased() == "wss",
                  let host = url.host, !host.isEmpty else { return nil }
            guard let fingerprint = GroupSdpRules.normalizeFingerprint(fingerprintRaw) else { return nil }
            var servers: [IceServer] = []
            if let list = data["ice_servers"] as? [[String: Any]] {
                for entry in list {
                    var urls: [String] = []
                    if let many = entry["urls"] as? [String] {
                        urls = many
                    } else if let one = entry["urls"] as? String {
                        urls = [one]
                    }
                    guard !urls.isEmpty else { continue }
                    servers.append(IceServer(
                        urls: urls,
                        username: entry["username"] as? String,
                        credential: entry["credential"] as? String))
                }
            }
            let ttl = (data["ttl_s"] as? NSNumber)?.intValue ?? 0
            return MediaReady(
                callId: callId, nodeId: nodeId, wsUrl: wsUrl, room: room, pseudonym: pseudonym,
                sessionToken: sessionToken, joinToken: joinToken, dtlsFingerprint: fingerprint,
                iceServers: servers, ttlSeconds: ttl)
        }
    }

    // MARK: - group_call_media_token (S->C, spec §11)

    /// The answer to `group_call_media_refresh`: a fresh Janus session token.
    /// Janus re-validates the token on every request, so the client swaps it in
    /// for all later requests. A secret: never printed.
    public struct MediaToken: Equatable, Sendable {
        public let callId: String
        public let sessionToken: String
        public let ttlSeconds: Int

        public init(callId: String, sessionToken: String, ttlSeconds: Int) {
            self.callId = callId
            self.sessionToken = sessionToken
            self.ttlSeconds = ttlSeconds
        }

        /// nil when the call id or the token is missing.
        public static func parse(_ data: [String: Any]) -> MediaToken? {
            guard let callId = data["call_id"] as? String, !callId.isEmpty,
                  let token = data["session_token"] as? String, !token.isEmpty else { return nil }
            return MediaToken(callId: callId, sessionToken: token, ttlSeconds: (data["ttl_s"] as? NSNumber)?.intValue ?? 0)
        }
    }

    // MARK: - group_call_media_unavailable (S->C, spec §2.4)

    public enum UnavailableReason: Equatable, Sendable {
        case noNode
        case roomCreateFailed
        case notMember
        case full
        /// The member that would establish the room does not hold the group-video
        /// entitlement: the server answers the denial of `group_call_media_join` with this
        /// instead of a bare `error`. Fatal and never retried, asking again cannot change it.
        case entitlement
        /// Anything else, a reason a newer server adds included: handled generically (a
        /// visible error, no retry), never guessed at. The server never answers a request
        /// that is over its budget (spec 10.2), so there is no "throttled" reason either.
        case other(String)

        public init(wire: String) {
            switch wire {
            case "no_node": self = .noNode
            case "room_create_failed": self = .roomCreateFailed
            case "not_member": self = .notMember
            case "full": self = .full
            case "entitlement", "entitlement_required": self = .entitlement
            default: self = .other(String(wire.prefix(32)))
            }
        }
    }

    // MARK: - group_call_update (S->C, spec §2.1)

    public struct Update: Equatable, Sendable {
        public let callId: String
        public let participants: [String]
        /// Server-authoritative epoch, bumps on EVERY roster change.
        public let epoch: UInt32
        public let nodeId: String?
        /// user id -> pseudonym. Empty until the room exists.
        public let pseudonyms: [String: String]

        public init(callId: String, participants: [String], epoch: UInt32, nodeId: String?, pseudonyms: [String: String]) {
            self.callId = callId
            self.participants = participants
            self.epoch = epoch
            self.nodeId = nodeId
            self.pseudonyms = pseudonyms
        }

        /// pseudonym -> user id, for mapping Janus feeds back to tiles.
        public var userByPseudonym: [String: String] {
            var out: [String: String] = [:]
            for (user, pseudonym) in pseudonyms { out[pseudonym] = user }
            return out
        }

        public static func parse(_ data: [String: Any]) -> Update? {
            guard let callId = data["call_id"] as? String,
                  let participants = data["participants"] as? [String],
                  let epochNumber = data["sender_key_epoch"] as? NSNumber else { return nil }
            let epochValue = epochNumber.int64Value
            guard epochValue >= 0, epochValue <= Int64(UInt32.max) else { return nil }
            var nodeId: String?
            var pseudonyms: [String: String] = [:]
            if let media = data["media"] as? [String: Any] {
                nodeId = media["node_id"] as? String
                if let raw = media["pseudonyms"] as? [String: Any] {
                    for (user, value) in raw {
                        if let pseudonym = value as? String, isHex128(pseudonym) { pseudonyms[user] = pseudonym }
                    }
                }
            }
            return Update(callId: callId, participants: participants, epoch: UInt32(epochValue),
                          nodeId: nodeId, pseudonyms: pseudonyms)
        }
    }
}
