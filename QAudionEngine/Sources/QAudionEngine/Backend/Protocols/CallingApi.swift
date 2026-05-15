import Foundation

public protocol CallingApi {
    func sendCallOffer(recipientId: String, sdp: String) async throws
    func sendCallAnswer(recipientId: String, sdp: String) async throws
    func sendIceCandidate(recipientId: String, candidate: String) async throws
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

    /// Get TURN/STUN relay servers with time-limited credentials.
    func getRelays() async throws -> [RelayServer]

    // MARK: - Pre-negotiation (optional — backend-specific)
    // The BCrypto backend implements these. Default impls are no-ops to
    // keep the protocol additive — see CallingApi+PreNegotiation extension.

    /// Tell the caller we received their call_offer and are setting up PQC.
    func sendCallProcessing(callId: String, callerId: String) async throws

    /// Tell the caller we finished setup and are now ringing locally.
    func sendCallReady(callId: String, callerId: String) async throws
}

public extension CallingApi {
    func sendCallProcessing(callId: String, callerId: String) async throws { /* no-op default */ }
    func sendCallReady(callId: String, callerId: String) async throws { /* no-op default */ }

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

    /// Default impl — drops `capabilities` + `callerDisplay` and forwards
    /// to the legacy `sendCallOfferWithId(callId:recipientId:sdp:)`.
    func sendCallOfferWithId(
        callId: String,
        recipientId: String,
        sdp: String,
        capabilities: [String],
        callerDisplay: String?
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
            ?? c.decodeIfPresent(Int.self, forKey: .ttl_seconds)
            ?? 3600
        self.ttl = ttl
    }

    private enum CodingKeys: String, CodingKey {
        case urls, username, credential, ttl
        case ttlSeconds, ttl_seconds
    }
}

public struct RelayResponse: Decodable, Equatable {
    public let relays: [RelayServer]
    public let wssTurnUrl: String?
    public let onionAddress: String?

    public init(relays: [RelayServer], wssTurnUrl: String? = nil, onionAddress: String? = nil) {
        self.relays = relays
        self.wssTurnUrl = wssTurnUrl
        self.onionAddress = onionAddress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.relays = try c.decodeIfPresent([RelayServer].self, forKey: .relays) ?? []
        self.wssTurnUrl = try c.decodeIfPresent(String.self, forKey: .wssTurnUrl)
            ?? c.decodeIfPresent(String.self, forKey: .wss_turn_url)
        self.onionAddress = try c.decodeIfPresent(String.self, forKey: .onionAddress)
            ?? c.decodeIfPresent(String.self, forKey: .onion_address)
    }

    private enum CodingKeys: String, CodingKey {
        case relays
        case wssTurnUrl, wss_turn_url
        case onionAddress, onion_address
    }
}
