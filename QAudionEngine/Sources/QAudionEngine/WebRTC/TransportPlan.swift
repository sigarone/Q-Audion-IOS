import Foundation

/// One ICE server entry as plain values, with no WebRTC type in it. The call controller and the transport check turn it
/// into an `RTCIceServer` at the last moment, so the rules below can be pinned by unit tests without a PeerConnection.
public struct TransportIceServer: Equatable, Sendable {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

/// What each mode of Settings > Trasporto really does, as one pure function.
///
/// Before this type the screen only stored the mode: `auto` and `p2p` produced the same configuration, and so did `turn`
/// and `relay`. Now the call controller (`QAudionWebRtcCallController`, at call setup and at every ICE restart) and the
/// transport check (`TransportCandidateProbe`) both ask `TransportPlan.make` and build their ICE server list from
/// `servers(pool:bridgeIceUrl:)`, so what the check measures is the configuration a call uses.
///
/// | mode  | ICE policy | server list                                                                      |
/// |-------|------------|----------------------------------------------------------------------------------|
/// | auto  | all        | STUN and TURN of the server pool, plus the WSS bridge when UDP looks blocked      |
/// | p2p   | all        | only the STUN servers of the pool: no TURN, no relay, no bridge, never            |
/// | turn  | relay      | only the TURN servers of the pool: no bridge                                      |
/// | relay | relay      | only the WSS bridge; if it cannot start, the TURN servers of the pool instead     |
///
/// The plan shapes THIS phone's candidates only. The candidates the other phone sends reach ICE unfiltered
/// (`QAudionWebRtcCallController.handleRemoteIce`), so in p2p a relay offered by the other phone can still be paired with
/// a local host or srflx candidate and carry the call. The Settings text for p2p therefore says "your phone", not "no
/// relay in the call".
///
/// A custom TURN server (`TransportCustomTurn`: address, user name, password, all typed by the user) replaces the whole
/// server pool in `auto`, `turn` and `relay`, and no bridge is started. In `p2p` it cannot be used, because a TURN server
/// is a relay: it is ignored there (`customTurnIgnored`).
///
/// libwebrtc rejects the WHOLE configuration (no PeerConnection at all) when a TURN server has an empty user name or
/// password. The custom server is therefore a server WITH its own credentials, or it is not a custom server: an address
/// typed without them reads as no address (`TransportCustomTurn.Parsed.missingCredentials`), and Settings refuses to save
/// it. The temporary TURN credentials of the server pool (`poolTurnCredentials(in:)`) are used for the WSS bridge only;
/// the server typed by the user never receives them, and the pool is not even read to build its list.
///
/// Pure: no WebRTC, no network, no stored state.
public struct TransportPlan: Equatable, Sendable {

    public typealias Mode = TransportSettingsViewModel.Mode

    /// Maps to `RTCIceTransportPolicy`: `.all` gathers host, srflx and relay candidates, `.relay` only relay ones.
    public enum IcePolicy: String, Equatable, Sendable {
        case all
        case relay
    }

    /// When the WSS-TURN bridge (loopback UDP to a WebSocket on the server) is wanted.
    public enum BridgeRole: String, Equatable, Sendable {
        /// Never: p2p, turn, and every mode with a custom TURN address.
        case never
        /// Only when no relay answered the UDP probe (W-RELAYGATE): `auto`.
        case whenUdpBlocked
        /// Always, and it is the only route: `relay`.
        case always
    }

    /// The route the ICE server list gives a call, for texts and reports.
    public enum Route: String, Equatable, Sendable, CaseIterable {
        /// p2p: STUN servers only on this phone. The name is kept for the summary; it does not mean the call is direct (the
        /// other phone may offer a relay), and the Settings row says what this phone uses, not that.
        case directOnly
        /// auto: STUN and TURN servers of the pool.
        case serverPool
        /// auto, UDP blocked: the pool plus the WSS bridge.
        case serverPoolWithBridge
        /// turn: TURN servers of the pool.
        case poolTurn
        /// relay: the WSS bridge alone.
        case wssBridge
        /// relay, the bridge could not be started: TURN servers of the pool.
        case poolTurnFallback
        /// A custom TURN address, alone.
        case customServer
    }

    public let mode: Mode
    public let icePolicy: IcePolicy
    /// The custom TURN server when this plan really uses it; `nil` otherwise. It carries a password: never log it.
    public let customTurn: TransportCustomTurn?
    /// A custom server was given but this mode cannot use it (p2p).
    public let customTurnIgnored: Bool
    public let includePoolStun: Bool
    public let includePoolTurn: Bool
    public let includeBridge: Bool
    public let bridgeRole: BridgeRole

    public init(mode: Mode, icePolicy: IcePolicy, customTurn: TransportCustomTurn?, customTurnIgnored: Bool,
                includePoolStun: Bool, includePoolTurn: Bool, includeBridge: Bool, bridgeRole: BridgeRole) {
        self.mode = mode
        self.icePolicy = icePolicy
        self.customTurn = customTurn
        self.customTurnIgnored = customTurnIgnored
        self.includePoolStun = includePoolStun
        self.includePoolTurn = includePoolTurn
        self.includeBridge = includeBridge
        self.bridgeRole = bridgeRole
    }

    // MARK: - The plan

    /// The ICE policy of a mode alone (what `TransportGate.forcesRelay` asks).
    public static func icePolicy(for mode: Mode) -> IcePolicy {
        switch mode {
        case .auto, .p2p: return .all
        case .turn, .relay: return .relay
        }
    }

    /// `bridgeAvailable`: a WSS-TURN bridge is running and can be offered to ICE. The caller asks first what the mode
    /// wants (`make(..., bridgeAvailable: true).wantsBridge(udpReachable:)`), tries to start the bridge, then asks again
    /// with the real answer. Only `auto` and `relay` ever include the bridge.
    public static func make(mode: Mode, customTurnUrl: URL?, bridgeAvailable: Bool) -> TransportPlan {
        // Only an address with its own credentials is a custom server; the text kept by an earlier build without them
        // reads as no address here (the screen shows it and asks for the credentials).
        let custom: TransportCustomTurn? = customTurnUrl.flatMap { TransportCustomTurn.parse($0.absoluteString).server }
        let policy = icePolicy(for: mode)
        switch mode {
        case .auto:
            if let custom = custom {
                return TransportPlan(mode: mode, icePolicy: policy, customTurn: custom, customTurnIgnored: false,
                                     includePoolStun: false, includePoolTurn: false, includeBridge: false,
                                     bridgeRole: .never)
            }
            return TransportPlan(mode: mode, icePolicy: policy, customTurn: nil, customTurnIgnored: false,
                                 includePoolStun: true, includePoolTurn: true, includeBridge: bridgeAvailable,
                                 bridgeRole: .whenUdpBlocked)
        case .p2p:
            return TransportPlan(mode: mode, icePolicy: policy, customTurn: nil, customTurnIgnored: custom != nil,
                                 includePoolStun: true, includePoolTurn: false, includeBridge: false,
                                 bridgeRole: .never)
        case .turn:
            if let custom = custom {
                return TransportPlan(mode: mode, icePolicy: policy, customTurn: custom, customTurnIgnored: false,
                                     includePoolStun: false, includePoolTurn: false, includeBridge: false,
                                     bridgeRole: .never)
            }
            return TransportPlan(mode: mode, icePolicy: policy, customTurn: nil, customTurnIgnored: false,
                                 includePoolStun: false, includePoolTurn: true, includeBridge: false,
                                 bridgeRole: .never)
        case .relay:
            if let custom = custom {
                return TransportPlan(mode: mode, icePolicy: policy, customTurn: custom, customTurnIgnored: false,
                                     includePoolStun: false, includePoolTurn: false, includeBridge: false,
                                     bridgeRole: .never)
            }
            return TransportPlan(mode: mode, icePolicy: policy, customTurn: nil, customTurnIgnored: false,
                                 includePoolStun: false, includePoolTurn: !bridgeAvailable, includeBridge: bridgeAvailable,
                                 bridgeRole: .always)
        }
    }

    /// Whether the caller should try to start the WSS bridge. `udpReachable`: at least one relay of the pool answered
    /// the UDP STUN probe on this network (an empty probe result is "no evidence UDP works").
    public func wantsBridge(udpReachable: Bool) -> Bool {
        switch bridgeRole {
        case .never: return false
        case .always: return true
        case .whenUdpBlocked: return !udpReachable
        }
    }

    public var route: Route {
        if customTurn != nil { return .customServer }
        switch mode {
        case .p2p: return .directOnly
        case .auto: return includeBridge ? .serverPoolWithBridge : .serverPool
        case .turn: return .poolTurn
        case .relay: return includeBridge ? .wssBridge : .poolTurnFallback
        }
    }

    // MARK: - The server list

    /// The ICE servers of this plan, in the order the call gives them to libwebrtc: the bridge first (when included and
    /// started), then the pool entries the mode allows, each keeping only the URLs the mode allows. A custom server is the
    /// whole list, with the user name and password the user typed, and no pool entry: the pool is not read and its
    /// temporary credentials never reach that server (see the type's doc).
    public func servers(pool: [RelayServer], bridgeIceUrl: String?) -> [TransportIceServer] {
        if let custom = customTurn {
            return [TransportIceServer(urls: [custom.iceUrl], username: custom.username, credential: custom.credential)]
        }
        var out: [TransportIceServer] = []
        if includeBridge, let bridgeUrl = bridgeIceUrl, let creds = Self.poolTurnCredentials(in: pool) {
            out.append(TransportIceServer(urls: [bridgeUrl], username: creds.username, credential: creds.credential))
        }
        for entry in pool {
            let kept = entry.urls.filter { keepsPoolUrl($0) }
            if kept.isEmpty { continue }
            out.append(TransportIceServer(urls: kept, username: entry.username, credential: entry.credential))
        }
        return out
    }

    /// Every URL of `servers(pool:bridgeIceUrl:)`, flattened.
    public func urls(pool: [RelayServer], bridgeIceUrl: String?) -> [String] {
        servers(pool: pool, bridgeIceUrl: bridgeIceUrl).flatMap { $0.urls }
    }

    private func keepsPoolUrl(_ url: String) -> Bool {
        if Self.isTurnUrl(url) { return includePoolTurn }
        if Self.isStunUrl(url) { return includePoolStun }
        // A scheme that is neither: only where everything of the pool is allowed (auto).
        return includePoolTurn && includePoolStun
    }

    // MARK: - URL helpers

    public static func isTurnUrl(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("turn:") || lower.hasPrefix("turns:")
    }

    public static func isStunUrl(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("stun:") || lower.hasPrefix("stuns:")
    }

    /// The temporary TURN credentials of the pool: the ones of its FIRST TURN entry. The WSS bridge presents them in its
    /// TURN ALLOCATE (the bridge is a link to the BCrypto server). A custom TURN server does NOT get them. `nil` when that
    /// entry has none, even if a later entry does.
    public static func poolTurnCredentials(in pool: [RelayServer]) -> (username: String, credential: String)? {
        guard let firstTurn = pool.first(where: { entry in entry.urls.contains(where: { isTurnUrl($0) }) }),
              let username = firstTurn.username,
              let credential = firstTurn.credential else { return nil }
        return (username, credential)
    }

    /// A custom TURN address as typed in Settings, when it is usable: `turn:` or `turns:`, a user name and a password
    /// (`turn:user:password@host:port`), a host name or IPv4 address, an optional port and an optional `?query`
    /// (`TransportCustomTurn.parse` has the full rules). The result is the text the storage keeps, credentials included.
    /// Anything else gives `nil`: `turn://host` (libwebrtc cannot parse it), `http://...`, a missing host, a bad port, and
    /// an address without user name and password (`TransportCustomTurn.Parsed.missingCredentials`): libwebrtc would reject
    /// the whole configuration for it.
    public static func validatedCustomTurnUrl(_ raw: String) -> URL? {
        TransportCustomTurn.parse(raw).server?.storedURL
    }
}
