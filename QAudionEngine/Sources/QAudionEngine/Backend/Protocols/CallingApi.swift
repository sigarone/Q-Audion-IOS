import Foundation

public protocol CallingApi {
    func sendCallOffer(recipientId: String, sdp: String) async throws
    func sendCallAnswer(recipientId: String, sdp: String) async throws
    func sendIceCandidate(recipientId: String, candidate: String) async throws

    /// Send an ICE candidate with the media stream identifier and m-line index
    /// from the WebRTC stack. Android WsCodec.kt uses `sdp_mid` to route the
    /// candidate to the correct m-line (audio vs video). Sending "" and 0
    /// always routes to the audio m-line, silently breaking video ICE for
    /// multi-stream calls. Default impl falls back to the sdp-less overload.
    func sendIceCandidate(
        recipientId: String,
        candidate: String,
        sdpMid: String?,
        sdpMLineIndex: Int32
    ) async throws
    func sendHangup(recipientId: String) async throws
    func sendOpaqueMessage(recipientId: String, data: Data) async throws

    /// Outbound `call_offer` carrying the local SFrame capability tags.
    /// Mirrors Android `WsCommand.CallOffer.capabilities` field added in
    /// commit 540b79c0. The wire JSON key is `"capabilities"` and the
    /// value is a list of strings (e.g. `["sframe-v1"]`). Default impl
    /// drops the field and falls back to ``sendCallOffer(recipientId:sdp:)``
    /// for backends that haven't migrated yet.
    ///
    /// `callerDisplay` (when non-nil) ships as the optional `caller_display`
    /// JSON field — the callee uses it as the CallKit caller-id when
    /// present (highest-priority source, beats the server-assigned
    /// extension). Pure digits expected so the callee can dial it back.
    /// When nil, the field is omitted and the server fills it with the
    /// caller's internal extension.
    ///
    /// `hasVideo` sets `has_video` and `call_type` on the wire. Default
    /// impl forwards to the non-video overload (audio call).
    func sendCallOffer(
        recipientId: String,
        sdp: String,
        capabilities: [String],
        callerDisplay: String?,
        hasVideo: Bool
    ) async throws

    func sendCallOffer(
        recipientId: String,
        sdp: String,
        capabilities: [String],
        callerDisplay: String?
    ) async throws

    /// Outbound `call_answer` carrying the local SFrame capability tags.
    /// See ``sendCallOffer(recipientId:sdp:capabilities:callerDisplay:)`` for
    /// the wire format contract. Default impl drops the field and falls
    /// back to ``sendCallAnswer(recipientId:sdp:)``.
    func sendCallAnswer(
        recipientId: String,
        sdp: String,
        capabilities: [String]
    ) async throws

    /// Outbound `call_answer` that also advertises whether the callee
    /// accepts the video track. Android WsCodec.kt reads `has_video`
    /// from the answer to confirm the callee's camera state; sending
    /// `false` on a video call makes Android mute remote video.
    /// Default impl drops `hasVideo` and forwards to the non-video
    /// overload (preserves compat for backends that haven't migrated).
    func sendCallAnswer(
        recipientId: String,
        sdp: String,
        capabilities: [String],
        hasVideo: Bool
    ) async throws

    /// Originator-side helper that ships a `call_offer` with an
    /// EXTERNALLY-CHOSEN callId AND the local SFrame capability tags.
    /// Mirrors Android's commit 540b79c0 wire format. Default impl
    /// drops the capabilities and falls back to
    /// ``sendCallOfferWithId(callId:recipientId:sdp:)``.
    /// `callerDisplay` — see
    /// ``sendCallOffer(recipientId:sdp:capabilities:callerDisplay:)``.
    func sendCallOfferWithId(
        callId: String,
        recipientId: String,
        sdp: String,
        capabilities: [String],
        callerDisplay: String?
    ) async throws

    /// Originator-side `call_offer` with externally-chosen callId carrying
    /// both capability tags and the `has_video` / `call_type` fields.
    /// Required so both the PQC-signaling rail and the WebRTC rail agree on
    /// call type: if the PQC offer says `call_type:"audio"` and the WebRTC
    /// offer says `call_type:"video"`, Android's `WsCallSignaller` may set
    /// up the wrong media pipeline on the first offer it processes.
    /// Default impl drops `hasVideo` and forwards to the non-video overload.
    func sendCallOfferWithId(
        callId: String,
        recipientId: String,
        sdp: String,
        capabilities: [String],
        callerDisplay: String?,
        hasVideo: Bool
    ) async throws

    /// Ship a literal UTF-8 string in the `data` field of an
    /// `opaque_message` (NOT base64-wrapped). Used for the Android JSON
    /// HandshakeBundle wire format `"<callId>|<JSON>"` — wrapping in
    /// base64 would hide the `|` separator and Android's `dispatch()`
    /// would reject the envelope as malformed. WIRE_SPEC.md §3.1.
    /// Default impl falls back to UTF-8 bytes through `sendOpaqueMessage`
    /// for any backend that hasn't migrated yet (will be base64-wrapped
    /// — backends supporting Android JSON interop MUST override).
    func sendOpaqueMessageString(recipientId: String, payload: String) async throws

    /// Originator-side helper that ships a `call_offer` with an
    /// EXTERNALLY-CHOSEN callId. The default `sendCallOffer` mints a
    /// fresh UUID internally; this variant lets AppState mint the
    /// canonical callId and pass it through so the WS-level call_id,
    /// the engine's `onAndroidCallSetupStarted(callId:)` and the
    /// PQC handshake bundle's `callId` field all converge on the same
    /// string. Per WIRE_SPEC §5 + OpenRouter glm-5.1 review 2026-05-06
    /// (CallId mismatch P0 issue).
    /// Default impl invokes `sendCallOffer` + best-effort
    /// `bindIncomingCallId`-equivalent (backend-specific). Backends MUST
    /// override to actually pin the callId on the server-side state
    /// machine.
    func sendCallOfferWithId(callId: String, recipientId: String, sdp: String) async throws

    /// Send a call_hangup envelope explicitly bound to a specific
    /// callId. Used by the Android-originator cleanup path when the
    /// opaque OFFER fails after the call_offer has already woken the
    /// peer — without this, the peer's UI sits on a phantom incoming
    /// call. Default impl falls back to `sendHangup` (which uses the
    /// active callId on most backends).
    func sendCallHangupForId(callId: String, recipientId: String) async throws

    /// W-SILENTPATHDEATH / W-RESTARTOFFERPARK (2026-08-25) — the
    /// INITIATOR-side send primitive for a mid-call ICE-restart offer.
    /// Ships a `call_offer` reusing the ALREADY-BOUND active call id (no
    /// callId parameter — mirrors `sendIceCandidate`/`sendHangup`, which
    /// read the backend's own internally-tracked active call id rather
    /// than requiring the caller to carry it around) — a restart offer is
    /// never a new call session.
    ///
    /// Returns `true` the moment the envelope reaches an authenticated
    /// socket, `false` when it could not (caller-owned retry/park loop —
    /// `QAudionWebRtcCallController.restartIce` — decides what to do
    /// next). This is a THIN, non-blocking-beyond-the-single-attempt
    /// primitive by design: `sendCallOfferWithId`'s own W-SETUPRETRY
    /// ladder is gated off once the call has demonstrably progressed past
    /// setup (see `BCryptoCallingApiImpl._setupProgressed`), which is
    /// always true by the time an ICE restart can happen — reusing it here
    /// would silently drop the retry coverage this method exists to
    /// provide.
    ///
    /// Default impl returns `false` unconditionally (no-op) — backends
    /// that haven't wired ICE-restart support keep compiling; only
    /// `BCryptoCallingApiImpl` overrides with the real W-RESTARTOFFERPARK
    /// send+park behavior (mirrors `deliverHangup`'s proven two-phase
    /// shape: best-effort immediate send, then a detached park up to the
    /// server's disconnect-grace ceiling).
    func sendIceRestartOffer(
        recipientId: String,
        sdp: String,
        capabilities: [String]
    ) async -> Bool

    /// Get TURN/STUN relay servers with time-limited credentials.
    func getRelays() async throws -> [RelayServer]

    /// Get the full relay response including the optional WS-TURN URL and
    /// Tor onion address used by transport fallback selectors. Default impl
    /// wraps `getRelays()` and leaves the top-level fields nil — backends
    /// that decode a full `RelayResponse` SHOULD override to preserve them.
    func getRelaysResponse() async throws -> RelayResponse

    // MARK: - Pre-negotiation (optional — backend-specific)
    // The BCrypto backend implements these. Default impls are no-ops to
    // keep the protocol additive — see CallingApi+PreNegotiation extension.

    /// Tell the caller we received their call_offer and are setting up PQC.
    func sendCallProcessing(callId: String, callerId: String) async throws

    /// Tell the caller we finished setup and are now ringing locally.
    func sendCallReady(callId: String, callerId: String) async throws

    /// Tell the caller a real user (or equivalent human-input surface —
    /// system Answer UI, notification action, hardware/watch button)
    /// explicitly accepted the call. Distinct from `call_answer`, which
    /// MAY be sent automatically ahead of any user action as a
    /// network-readiness optimization. Gates the caller's SAS/active-call
    /// display — see WIRE_SPEC.md §3.5. Default impl no-ops for backends
    /// that haven't migrated yet.
    func sendCallAccepted(callId: String) async throws
}

public extension CallingApi {
    func sendCallProcessing(callId: String, callerId: String) async throws { /* no-op default */ }
    func sendCallReady(callId: String, callerId: String) async throws { /* no-op default */ }
    func sendCallAccepted(callId: String) async throws { /* no-op default */ }

    /// Default impl — wraps `getRelays()` into a `RelayResponse` with nil
    /// top-level fields. Backends that decode the full server response SHOULD
    /// override to preserve wssTurnUrl / onionAddress so the transport fallback
    /// selectors can use WS-TURN and Tor paths.
    func getRelaysResponse() async throws -> RelayResponse {
        let servers = try await getRelays()
        return RelayResponse(relays: servers, wssTurnUrl: nil, onionAddress: nil)
    }

    /// Default impl — falls back to the sdp-less overload (drops sdpMid /
    /// sdpMLineIndex). Backends that send multi-stream ICE (audio + video)
    /// MUST override to pass the real values or Android will route every
    /// candidate to the audio m-line, silently breaking video ICE.
    func sendIceCandidate(
        recipientId: String,
        candidate: String,
        sdpMid: String?,
        sdpMLineIndex: Int32
    ) async throws {
        try await sendIceCandidate(recipientId: recipientId, candidate: candidate)
    }

    /// Default impl — drops `capabilities` + `callerDisplay` + `hasVideo`
    /// and forwards to the legacy `sendCallOffer`. Backends supporting the
    /// SFrame handshake AND video calls MUST override (see
    /// BCryptoCallingApiImpl.sendCallOffer(... capabilities:callerDisplay:hasVideo:)).
    func sendCallOffer(
        recipientId: String,
        sdp: String,
        capabilities: [String],
        callerDisplay: String?,
        hasVideo: Bool
    ) async throws {
        try await sendCallOffer(
            recipientId: recipientId,
            sdp: sdp,
            capabilities: capabilities,
            callerDisplay: callerDisplay
        )
    }

    /// Default impl — drops `capabilities` + `callerDisplay` and forwards
    /// to the legacy `sendCallOffer`.
    func sendCallOffer(
        recipientId: String,
        sdp: String,
        capabilities: [String],
        callerDisplay: String?
    ) async throws {
        try await sendCallOffer(recipientId: recipientId, sdp: sdp)
    }

    /// Default impl — drops `capabilities` and forwards to the legacy
    /// `sendCallAnswer`.
    func sendCallAnswer(
        recipientId: String,
        sdp: String,
        capabilities: [String]
    ) async throws {
        try await sendCallAnswer(recipientId: recipientId, sdp: sdp)
    }

    /// Default impl — drops `hasVideo` and forwards to the legacy
    /// `sendCallAnswer(capabilities:)`.
    func sendCallAnswer(
        recipientId: String,
        sdp: String,
        capabilities: [String],
        hasVideo: Bool
    ) async throws {
        try await sendCallAnswer(recipientId: recipientId, sdp: sdp, capabilities: capabilities)
    }

    /// Default impl — drops `capabilities` + `callerDisplay` and forwards
    /// to the legacy `sendCallOfferWithId(callId:recipientId:sdp:)`.
    func sendCallOfferWithId(
        callId: String,
        recipientId: String,
        sdp: String,
        capabilities: [String],
        callerDisplay: String?
    ) async throws {
        try await sendCallOfferWithId(
            callId: callId,
            recipientId: recipientId,
            sdp: sdp,
            capabilities: capabilities,
            callerDisplay: callerDisplay,
            hasVideo: false
        )
    }

    /// Default impl — drops `capabilities` + `callerDisplay` + `hasVideo` and
    /// falls back to the legacy 3-param overload. This is the fallback leaf for
    /// backends that haven't migrated; BCryptoCallingApiImpl MUST override to
    /// ship the real `has_video` / `call_type` wire fields.
    func sendCallOfferWithId(
        callId: String,
        recipientId: String,
        sdp: String,
        capabilities: [String],
        callerDisplay: String?,
        hasVideo: Bool
    ) async throws {
        try await sendCallOfferWithId(callId: callId, recipientId: recipientId, sdp: sdp)
    }

    /// Default impl — falls back to UTF-8 bytes through `sendOpaqueMessage`.
    /// Backends that base64-wrap (e.g. BCryptoCallingApi) MUST override
    /// to ship the literal string verbatim, otherwise Android JSON
    /// HandshakeBundle interop breaks (see protocol kdoc).
    func sendOpaqueMessageString(recipientId: String, payload: String) async throws {
        try await sendOpaqueMessage(
            recipientId: recipientId,
            data: payload.data(using: .utf8) ?? Data()
        )
    }

    /// Default impl — fallback path for backends that don't yet
    /// support externally-chosen callIds. Calls the legacy
    /// sendCallOffer which mints its own UUID. Will produce the
    /// "callId mismatch P0" bug the reviewer flagged when paired with
    /// onAndroidCallSetupStarted; backends supporting Android interop
    /// MUST override.
    func sendCallOfferWithId(callId: String, recipientId: String, sdp: String) async throws {
        try await sendCallOffer(recipientId: recipientId, sdp: sdp)
    }

    /// Default impl — fallback path for backends without per-callId
    /// hangup. Uses the legacy sendHangup which targets the active
    /// callId (best-effort). Backends supporting interop SHOULD
    /// override to actually pin the supplied callId.
    func sendCallHangupForId(callId: String, recipientId: String) async throws {
        try await sendHangup(recipientId: recipientId)
    }

    /// Default impl — no-op, `false`. Backends supporting ICE-restart
    /// recovery (BCryptoCallingApiImpl) MUST override; see the protocol
    /// kdoc for why the setup-retry ladder cannot be reused here.
    func sendIceRestartOffer(
        recipientId: String,
        sdp: String,
        capabilities: [String]
    ) async -> Bool {
        return false
    }
}

/// Bcrypto-server `/api/v1/calling/relays` response shape.
/// Mirrors Android `RelayDto` / `RelaysResponse`:
/// - `username` and `credential` are **optional** (STUN-only relays omit
///   them); previous iOS revs declared them non-optional, which made the
///   JSON decoder reject any STUN-only entry with `keyNotFound`.
/// - `wssTurnUrl` / `onionAddress` are top-level fields used by the
///   transport selector for the WS-TURN and Tor onion fallbacks.
public struct RelayServer: Decodable, Equatable {
    public let urls: [String]
    public let username: String?
    public let credential: String?
    public let ttl: Int

    public init(urls: [String], username: String? = nil, credential: String? = nil, ttl: Int = 3600) {
        self.urls = urls
        self.username = username
        self.credential = credential
        self.ttl = ttl
    }

    /// Tolerant init: Android may serialize `ttl` as `ttlSeconds` /
    /// `ttl_seconds`. Try both shapes and fall back to a sane default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.urls = try c.decodeIfPresent([String].self, forKey: .urls) ?? []
        self.username = try c.decodeIfPresent(String.self, forKey: .username)
        self.credential = try c.decodeIfPresent(String.self, forKey: .credential)
        let ttl = try c.decodeIfPresent(Int.self, forKey: .ttl)
            ?? c.decodeIfPresent(Int.self, forKey: .ttlSeconds)
            ?? c.decodeIfPresent(Int.self, forKey: .ttlSecondsSnake)
            ?? 3600
        self.ttl = ttl
    }

    private enum CodingKeys: String, CodingKey {
        case urls, username, credential, ttl
        case ttlSeconds
        case ttlSecondsSnake = "ttl_seconds"
    }
}

public struct RelayResponse: Decodable, Equatable {
    public let relays: [RelayServer]
    public let wssTurnUrl: String?
    public let onionAddress: String?
    /// Top-level `reality` block — the VLESS+REALITY censorship-bypass front
    /// parameters (design doc §4 / bcrypto-server
    /// CENSORSHIP_RESISTANT_TRANSPORT_DESIGN.md). Present ONLY when the server
    /// has provisioned a Reality front; nil on un-provisioned / older
    /// deployments (the whole Reality path stays inert when this is nil).
    /// Consumed by the transport-fallback selector, exactly like
    /// `onionAddress` — never a default route.
    public let reality: RealityRelayParams?

    public init(relays: [RelayServer], wssTurnUrl: String? = nil, onionAddress: String? = nil, reality: RealityRelayParams? = nil) {
        self.relays = relays
        self.wssTurnUrl = wssTurnUrl
        self.onionAddress = onionAddress
        self.reality = reality
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.relays = try c.decodeIfPresent([RelayServer].self, forKey: .relays) ?? []
        self.wssTurnUrl = try c.decodeIfPresent(String.self, forKey: .wssTurnUrl)
            ?? c.decodeIfPresent(String.self, forKey: .wssTurnUrlSnake)
        self.onionAddress = try c.decodeIfPresent(String.self, forKey: .onionAddress)
            ?? c.decodeIfPresent(String.self, forKey: .onionAddressSnake)
        self.reality = try c.decodeIfPresent(RealityRelayParams.self, forKey: .reality)
    }

    private enum CodingKeys: String, CodingKey {
        case relays
        case wssTurnUrl
        case wssTurnUrlSnake = "wss_turn_url"
        case onionAddress
        case onionAddressSnake = "onion_address"
        case reality
    }
}

/// Server-issued VLESS+REALITY front parameters, decoded from the top-level
/// `reality` object of `/api/v1/calling/relays` (authoritative wire contract
/// in bcrypto-server's CENSORSHIP_RESISTANT_TRANSPORT_DESIGN.md). Every field
/// is a SERVER deployment decision — the client hardcodes NONE of them (the
/// disguise SNI, the Reality keys, and the front endpoint are all chosen
/// server-side, design doc §4.2). The client dials `hostname:port`, presents
/// `serverName` as the camouflage SNI, and authenticates with
/// `publicKey` + `uuid` + `shortId` + `flow`. These feed straight into
/// `RealityManager.Params` (see `AppState.activateRealityFallback`).
public struct RealityRelayParams: Decodable, Equatable, Sendable {
    /// VPS public IP / host the client dials directly (NOT voip.bcrypto.com —
    /// a separate, un-Cloudflared Reality-front endpoint, design doc §4.3).
    public let hostname: String
    /// Reality-front (xray VLESS+REALITY inbound) TCP port.
    public let port: Int
    /// Server Reality public key (x25519, base64url).
    public let publicKey: String
    /// VLESS client id.
    public let uuid: String
    /// Reality shortId (hex). May be empty.
    public let shortId: String
    /// Disguise SNI presented in the camouflage TLS handshake (e.g.
    /// `www.microsoft.com`) — to any observer the connection looks like an
    /// ordinary TLS session to this host.
    public let serverName: String
    /// VLESS flow (e.g. `xtls-rprx-vision`).
    public let flow: String

    public init(
        hostname: String,
        port: Int = 8447,
        publicKey: String,
        uuid: String,
        shortId: String = "",
        serverName: String,
        flow: String = "xtls-rprx-vision"
    ) {
        self.hostname = hostname
        self.port = port
        self.publicKey = publicKey
        self.uuid = uuid
        self.shortId = shortId
        self.serverName = serverName
        self.flow = flow
    }

    /// Tolerant decode: the server contract uses snake_case
    /// (`public_key`/`short_id`/`server_name`), but accept camelCase too so a
    /// future server rename can't silently null the fields (same defensive
    /// shape as `RelayResponse`/`RelayServer` above). `port`/`flow` fall back
    /// to the documented defaults when omitted.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        self.port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8447
        self.publicKey = try c.decodeIfPresent(String.self, forKey: .publicKey)
            ?? c.decodeIfPresent(String.self, forKey: .publicKeySnake) ?? ""
        self.uuid = try c.decodeIfPresent(String.self, forKey: .uuid) ?? ""
        self.shortId = try c.decodeIfPresent(String.self, forKey: .shortId)
            ?? c.decodeIfPresent(String.self, forKey: .shortIdSnake) ?? ""
        self.serverName = try c.decodeIfPresent(String.self, forKey: .serverName)
            ?? c.decodeIfPresent(String.self, forKey: .serverNameSnake) ?? ""
        self.flow = try c.decodeIfPresent(String.self, forKey: .flow) ?? "xtls-rprx-vision"
    }

    private enum CodingKeys: String, CodingKey {
        case hostname, port, uuid, flow
        case publicKey
        case publicKeySnake = "public_key"
        case shortId
        case shortIdSnake = "short_id"
        case serverName
        case serverNameSnake = "server_name"
    }

    /// True when the block carries the minimum set of fields needed to dial
    /// the Reality front. A server that emits a partial/empty object (e.g.
    /// mid-provisioning) is treated as "not provisioned" rather than
    /// attempting a doomed connection.
    public var isUsable: Bool {
        !hostname.isEmpty && !publicKey.isEmpty && !uuid.isEmpty && !serverName.isEmpty && port > 0
    }
}
