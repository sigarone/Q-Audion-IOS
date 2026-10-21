import Foundation
import QAudionEngine

/// One reachable mesh peer, ready for SwiftUI consumption. Presentation-ish
/// but framework-free (no CoreBluetooth type) — the app-target analogue of
/// the Android sibling's `MeshPeerUi`, minus the display-name/contact-match
/// resolution, which stays with the caller (`MeshSheetViewModel`) since that
/// needs `ContactsStore`, not something this runtime should own.
struct MeshRuntimePeer: Identifiable, Equatable {
    var id: String { nodeHex }
    let nodeHex: String
    let rssi: Int?
    let connected: Bool
    /// 0 (closest) ... 1 (edge of range) — derived from RSSI, only a
    /// proximity proxy; BLE gives no bearing. Matches the Android sibling's
    /// `MeshPeerUi.radiusFraction` derivation constants.
    let radiusFraction: Double
    let relayNodeHexes: [String]
}

struct MeshTargetSelection: Equatable {
    let nodeHex: String
    let displayName: String
}

/// Owns the BLE-mesh radio lifecycle, the live peer list, and the
/// per-conversation "send to this mesh peer" selection. This is the single
/// primitive-API surface every other file (new or existing) talks to —
/// nothing here takes `AppState` as a parameter (CLAUDE.md section 16); the
/// two integration points that DO need `AppState`-shaped context
/// (`ChatContainer`'s send path, `AppState`'s receive path) call in through
/// `sendData`/`onInboundData` with only primitives crossing the boundary.
///
/// ## Startup order (docs/mesh/MESH_LINK_SPEC.md section 1.2)
/// The identity comes first. `configureLocalIdentity` derives the node id from the
/// device's long-term key, and only then can a transport exist (`MeshTransportSlot`):
/// there is no random fallback id, and the radio refuses to start until the identity
/// is known. If the identity changes while the process runs, the old transport is
/// stopped and discarded and, if the radio was on, a new one is started with the new
/// node id. `localNodeIdHex` is the one source of the id for every component.
///
/// Mirrors the Android sibling's `MeshService` (antenna + peer list +
/// per-conversation target); the outbox with its retry until a delivery receipt is
/// `MeshOutboxDrain` + `MeshOutboxStore`.
@MainActor
final class MeshRuntime: ObservableObject {

    static let shared = MeshRuntime()

    @Published private(set) var radioState: MeshRadioState = .idle
    @Published private(set) var peers: [MeshRuntimePeer] = []
    @Published private(set) var activeTargets: [String: MeshTargetSelection] = [:]

    var antennaOn: Bool {
        switch radioState {
        case .idle, .error: return false
        default: return true
        }
    }

    /// Which radio mode is active — nil when the antenna is off. Derived from
    /// `radioState` (itself computed live off `CBCentralManager.isScanning` /
    /// `CBPeripheralManager.isAdvertising`), so it never drifts out of sync with
    /// what the radio is actually doing; scanning + advertising is full mesh or
    /// direct, which differ only in relaying, so `requestedMode` tells them apart.
    var antennaMode: MeshAntennaMode? {
        switch radioState {
        case .scanningAndAdvertising: return requestedMode == .direct ? .direct : .fullMesh
        case .advertisingOnly: return .visibleOnly
        default: return nil
        }
    }

    /// The mode last ASKED for (after the consent rules), as opposed to
    /// [antennaMode], which reports what the radio is doing at this instant.
    ///
    /// They differ during every transitional window — powering on, an advert
    /// not yet accepted, a scan between duty cycles — and [setAntenna] needs
    /// the intent, not the instantaneous truth, to decide whether a restart is
    /// required.
    private(set) var requestedMode: MeshAntennaMode?

    /// Whether a phone in the current mode can be reached while the app is in the
    /// background (see `MeshModePolicy.reachableInBackground`): false only for "Visibile".
    var reachableInBackground: Bool {
        guard let mode = requestedMode else { return false }
        return MeshModePolicy.reachableInBackground(mode: mode)
    }

    /// Fired for every `.data` packet addressed to us, once per inbound
    /// message. `fromNodeHex` is the ORIGINATING sender's node id (not
    /// necessarily the immediate radio hop, if the packet was relayed).
    /// `payload` is the still-opaque `MeshChatMessage` envelope bytes —
    /// this runtime never parses it; that's the receive-side integration's
    /// job (see `AppState`'s mesh receive hook). `@MainActor`-typed so it's
    /// always invoked already on the main actor.
    var onInboundData: (@MainActor (_ fromNodeHex: String, _ payload: Data) -> Void)?

    /// Same shape as ``onInboundData`` but for `.receipt` packets — a delivery
    /// or read acknowledgement of a message this device sent. Kept as its own
    /// callback rather than a type flag on the one above so a caller that only
    /// handles messages cannot mistake a receipt for one.
    var onInboundReceipt: (@MainActor (_ fromNodeHex: String, _ payload: Data) -> Void)?

    /// This device's node id, derived from its identity key. Nil until
    /// `configureLocalIdentity` succeeded; callers that need it to seal or check a
    /// packet do nothing while it is nil.
    var localNodeIdHex: String? { slot.nodeId?.hex }

    /// True once the identity is known (a transport can be built).
    var hasIdentity: Bool { slot.nodeId != nil }

    /// The transport of the process, built only once the identity is known.
    private let slot: MeshTransportSlot<BleMeshTransport>
    /// Rebuilt from every `knownPeers` update (each `MeshPeerInfo` already
    /// carries its own announced-neighbor set) rather than fed from raw
    /// ANNOUNCE payloads directly.
    private let topology = MeshTopology()

    /// The user's answer to the consent screen. The radio never starts without one
    /// (see `startAllowed`), and never relays without a yes.
    private let consent: MeshConsent
    private var flagRefreshObserver: NSObjectProtocol?

    private static func makeSlot() -> MeshTransportSlot<BleMeshTransport> {
        MeshTransportSlot<BleMeshTransport>(
            factory: { nodeId in BleMeshTransport(localNodeId: nodeId) },
            retire: { transport in
                transport.delegate = nil
                transport.stop()
            }
        )
    }

    private init() {
        consent = MeshConsent.shared
        slot = Self.makeSlot()
        observeFlagRefresh()
    }

    /// A runtime of its own for unit tests, with a consent of its own, so they
    /// never touch `shared` or the user's stored answer. No observer is armed.
    init(forTesting consent: MeshConsent) {
        self.consent = consent
        slot = Self.makeSlot()
    }

    /// The radio may start, in some mode, when the feature is available (compiled on and
    /// not switched off by the remote kill switch) AND the consent screen was answered.
    /// Full mesh additionally needs the consent to relay; the rule is `MeshModePolicy`.
    var startAllowed: Bool {
        MeshStartGate.mayStart(featureEnabled: MeshFeature.enabled, consent: consent.state)
    }

    /// A kill switch has to reach a radio that is already running, not only the
    /// next start: every fresh copy of the public flags file asks the runtime to
    /// re-check, and a radio that is no longer allowed is switched off.
    private func observeFlagRefresh() {
        flagRefreshObserver = NotificationCenter.default.addObserver(
            forName: FeatureFlags.didRefreshNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopIfNoLongerAllowed()
            }
        }
    }

    /// Switches a running radio off when the gate no longer allows it (the mesh
    /// was switched off remotely). Does nothing while the radio is off.
    func stopIfNoLongerAllowed() {
        guard requestedMode != nil else { return }
        guard !startAllowed else { return }
        setAntenna(mode: nil)
    }

    /// "Attiva": records the consent to relay and brings the antenna up in `mode`
    /// (full mesh unless the caller asks for another). The user just said they
    /// want the mesh, so the stored "antenna off" choice is cleared too.
    func acceptConsentAndStart(mode: MeshAntennaMode = .fullMesh) {
        consent.accept()
        setAutoStart(true)
        setAntenna(mode: mode)
    }

    /// "Solo i miei messaggi", or the Settings switch turned off: relaying is not
    /// allowed from now on. The phone does not go silent because of it: a radio that
    /// is running drops to direct mode (it still finds nearby contacts and exchanges
    /// the user's own messages, and forwards nothing), and with `startIfOff` a radio
    /// that is off comes up in direct mode too. A user who turned the antenna off
    /// ("Spenta") and then switches the relay consent off keeps it off.
    func declineRelayAndUseDirect(startIfOff: Bool, preferred: MeshAntennaMode? = nil) {
        consent.decline()
        if let running = requestedMode {
            // A visible-only antenna stays what it is; full mesh falls back to direct.
            setAntenna(mode: MeshModePolicy.allowedMode(running, consent: .declined))
        } else if startIfOff {
            setAutoStart(true)
            // The mode the user had tapped before the consent screen came up, if relaying does not stop it.
            let tapped: MeshAntennaMode? = preferred.flatMap { MeshModePolicy.allowedMode($0, consent: .declined) }
            setAntenna(mode: tapped ?? MeshModePolicy.defaultMode(consent: .declined))
        }
    }

    /// Call once identity bootstrap has produced a long-term key (or whenever it
    /// changes). `identityKeyRaw` is the raw 32-byte Ed25519 public key; anything
    /// else leaves the runtime without an identity and the radio off. A changed
    /// identity retires the transport built for the old node id; if the radio was
    /// on it is brought back up, on a new transport, under the new id.
    /// - Parameter source: `locked` or `missing`, only for the log line when there is no key.
    func configureLocalIdentity(identityKeyRaw: Data?, source: String = "missing") {
        let result = slot.configure(identityKeyRaw: identityKeyRaw)
        switch result {
        case .unavailable:
            MeshLog.emit(.identity, [("ok", "0"), ("src", source)])
        case .unchanged(let nodeId):
            MeshLog.emit(.identity, [("ok", "1"), ("nh", MeshLog.nodeHash(nodeId.hex)), ("src", "key")])
        case .changed(let nodeId, let retired):
            MeshLog.emit(.identity, [("ok", "1"), ("nh", MeshLog.nodeHash(nodeId.hex)), ("src", "key")])
            if retired {
                peers = []
                if let mode = requestedMode {
                    requestedMode = nil
                    setAntenna(mode: mode)
                }
            }
        }
    }

    /// The account left (logout, remote wipe, account deletion): the radio stops, the identity and the transport built
    /// for it are dropped, and what the old account had queued is cleared. A new account starts from nothing and
    /// brings the radio up again once its own identity is known.
    func accountLeft() {
        setAntenna(mode: nil)
        slot.reset()
        peers = []
        radioState = .idle
        MeshOutboxStore.shared.removeAll()
    }

    /// UserDefaults key recording that the user turned the antenna OFF.
    ///
    /// Absent means "never decided", which is not the same as off — see
    /// `autoStartIfEnabled`.
    private static let autoStartKey = "qaudion.mesh.autostart"

    /// Bring the antenna up at app start, in the mode the consent allows (full mesh for
    /// a user who accepted relaying, direct for one who declined it), unless the user
    /// switched the antenna off. Only after the consent screen was answered: a phone
    /// that never answered stays silent, and so does a phone whose identity is not
    /// known yet (the caller retries once it is).
    ///
    /// A mesh only exists while devices are advertising, so an antenna that
    /// comes up only when somebody opens the radar is a mesh nobody can be
    /// reached on. Starting it with the app is what makes "this contact is
    /// reachable over Bluetooth" a fact the app knows rather than one the user has
    /// to go and check. The default is a mode that can actually form a link:
    /// visible-only advertises but never scans or connects out, so two visible-only
    /// phones sit next to each other seeing nothing.
    func autoStartIfEnabled() {
        guard startAllowed, hasIdentity else { return }
        if UserDefaults.standard.object(forKey: Self.autoStartKey) != nil,
           UserDefaults.standard.bool(forKey: Self.autoStartKey) == false {
            return
        }
        guard requestedMode == nil else { return }
        guard let mode = MeshModePolicy.defaultMode(consent: consent.state) else { return }
        setAntenna(mode: mode)
    }

    /// Remember the user's own on/off decision, so `autoStartIfEnabled`
    /// honours it. "Spenta" is a decision, not a session state.
    func setAutoStart(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.autoStartKey)
    }

    /// Turns the BLE radio off, or on in `mode`. This is the ONLY call site
    /// that ever touches CoreBluetooth — the antenna selector in
    /// `MeshSheetView`, the consent screen and the Settings switch. Switching
    /// OFF is always allowed, whatever the gate says (a kill switch must be
    /// able to stop the radio). Switching ON silently refuses unless the feature
    /// flag is on AND the consent screen was answered AND the identity is known; a
    /// mode the consent does not allow becomes the strongest one it does (a user who
    /// declined relaying never ends up in full mesh), so a stray call cannot bypass
    /// the gate.
    func setAntenna(mode: MeshAntennaMode?) {
        guard let mode else {
            let wasRunning = requestedMode != nil
            slot.existingTransport?.stop()
            requestedMode = nil
            activeTargets.removeAll()
            if wasRunning { MeshOutboxDrain.shared.stop() }
            return
        }
        guard startAllowed, let allowed = MeshModePolicy.allowedMode(mode, consent: consent.state) else { return }
        guard let transport = slot.acquire() else {
            // No identity yet: the radio must not start under any other id.
            MeshLog.emit(.radio, [("state", "error"), ("mode", Self.modeToken(allowed)), ("reason", "no_identity")])
            return
        }
        // Switching modes mid-session: BleMeshTransport.start() is a no-op while
        // already active (it can't reconcile "already active, but in the other
        // mode"), so stop first — the cost (re-advertise/re-discover) is small.
        //
        // The guard is on `requestedMode`, NOT on `antennaMode`. antennaMode is
        // derived live from isScanning/isAdvertising, so it reads nil during
        // every window where the radio is up but a role has not settled yet; the
        // old `if let current = antennaMode` skipped the stop in exactly those
        // windows and the mode change was dropped on the floor.
        if requestedMode != nil, requestedMode != allowed {
            transport.stop()
        }
        transport.delegate = self
        requestedMode = allowed
        transport.start(schedule: MeshRadioSchedule.backgroundIdle, mode: allowed)
        MeshOutboxDrain.shared.start()
    }

    private static func modeToken(_ mode: MeshAntennaMode) -> String {
        switch mode {
        case .fullMesh: return "full"
        case .direct: return "direct"
        case .visibleOnly: return "visible"
        }
    }

    func selectTarget(conversationId: String, nodeHex: String, displayName: String) {
        activeTargets[conversationId] = MeshTargetSelection(nodeHex: nodeHex, displayName: displayName)
    }

    func clearTarget(conversationId: String) {
        activeTargets.removeValue(forKey: conversationId)
    }

    func activeTarget(for conversationId: String) -> MeshTargetSelection? {
        activeTargets[conversationId]
    }

    /// Whether `targetNodeHex` can be reached RIGHT NOW, and through whom.
    ///
    /// Three call sites — the routing-preference subtitle in
    /// `MeshSheetView`, `ChatContainer.resolveMeshRoute`'s auto-routing
    /// decision, and `MeshTransportChip`'s pre-send promise — each used to
    /// ask a narrower question than this one: "is `targetNodeHex` itself a
    /// connected peer", ignoring the bridge case entirely even though
    /// `peers[].relayNodeHexes` (fed by every peer's own ANNOUNCE) has
    /// carried that information the whole time. That collapsed "reachable
    /// through a device in range" into "not reachable", which for
    /// `resolveMeshRoute` was not just a wrong label: it meant a message
    /// under "Preferisci Bluetooth" or "Solo Bluetooth" never even
    /// attempted a bridged mesh send, even though `sendData`'s own
    /// `topology.nextHop(for:)` is fully capable of routing it there once
    /// armed.
    ///
    /// Deliberately ONE hop, not a deep topology walk: this reads only
    /// currently-connected peers' self-reported neighbours, the same
    /// "direct or single bridge hop, from what is live right now" scope
    /// Android's `resolveMeshRoute` documents for its UI-facing decision
    /// (`MeshRouteDecision.kt`) — a peer that merely appears in the
    /// accumulated `topology` graph from a stale ANNOUNCE is not evidence
    /// the bridge is still in range.
    ///
    /// No new engine state: this is a read over `peers`, which was already
    /// published with everything it needs.
    func reach(toNodeHex targetNodeHex: String) -> (reachable: Bool, viaBridgeNodeHex: String?) {
        Self.reach(toNodeHex: targetNodeHex, in: peers)
    }

    /// The rule behind `reach(toNodeHex:)`, over an explicit peer list so it
    /// can be tested without the radio. `peers` must be in the order
    /// `applyKnownPeers` publishes them (strongest signal first).
    static func reach(
        toNodeHex targetNodeHex: String,
        in peers: [MeshRuntimePeer]
    ) -> (reachable: Bool, viaBridgeNodeHex: String?) {
        if peers.contains(where: { $0.nodeHex == targetNodeHex && $0.connected }) {
            return (true, nil)
        }
        // Strongest signal first: `peers` is already RSSI-sorted (see
        // `applyKnownPeers`), so the first connected peer that announces
        // the target is the nearest usable bridge.
        if let bridge = peers.first(where: { $0.connected && $0.relayNodeHexes.contains(targetNodeHex) }) {
            return (true, bridge.nodeHex)
        }
        return (false, nil)
    }

    /// Encrypts nothing, parses nothing — `payload` is already the final
    /// opaque envelope bytes the caller wants delivered. Wraps it in a
    /// `MeshPacket`, resolves a known multi-hop next-hop when one exists
    /// (preferring a direct send over a flood, same as the relay policy's
    /// own rule), and hands it to the transport. The completion reports what the
    /// links did (`MeshSendReport`): `sentDirect` / `sentViaRelay` only if the
    /// packet was accepted by the first hop (every frame of it), otherwise
    /// `queued` / `failed` with the reason.
    func sendData(
        toNodeHex: String,
        payload: Data,
        type: MeshPacketType = .data,
        completion: @escaping (MeshSendReport) -> Void
    ) {
        guard let transport = slot.existingTransport, requestedMode != nil else {
            completion(MeshSendReport(result: .failed("antenna_off"), links: 0, okLinks: 0))
            return
        }
        guard let recipient = try? MeshNodeId(hex: toNodeHex) else {
            completion(MeshSendReport(result: .failed("bad_recipient"), links: 0, okLinks: 0))
            return
        }
        guard let packet = try? MeshPacket(
            type: type, senderId: transport.localNodeId, recipientId: recipient,
            ttl: MeshPacket.defaultTTL, timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            payload: payload
        ) else {
            completion(MeshSendReport(result: .failed("payload_too_large"), links: 0, okLinks: 0))
            return
        }
        let preferredNextHop = topology.nextHop(for: recipient)
        transport.send(packet, preferredNextHop: preferredNextHop) { report in
            Task { @MainActor in
                completion(report)
            }
        }
    }

    // MARK: - Peer list projection

    fileprivate func applyKnownPeers(_ infos: Set<MeshPeerInfo>) {
        for info in infos {
            topology.recordAnnounce(from: info.nodeId, announcedNeighbors: info.announcedNeighbors)
        }
        peers = infos
            .sorted { ($0.rssi ?? Int.min) > ($1.rssi ?? Int.min) }
            .map { info in
                MeshRuntimePeer(
                    nodeHex: info.nodeId.hex,
                    rssi: info.rssi,
                    connected: info.connected,
                    radiusFraction: Self.radiusFraction(rssi: info.rssi),
                    relayNodeHexes: info.announcedNeighbors.map(\.hex)
                )
            }
        // A peer that just became reachable may be the target of a queued
        // outbox entry — retry now rather than waiting out the retry interval.
        MeshOutboxDrain.shared.reachabilityChanged()
    }

    private static let rssiStrong = -40
    private static let rssiWeak = -100

    /// 0 = right at the device (strong signal, `rssiStrong`), 1 = edge of
    /// range (weak signal, `rssiWeak`). NOTE: this intentionally does NOT
    /// mirror the Android sibling's `radiusFraction` formula verbatim —
    /// reading it closely, `(RSSI_WEAK - clamped) / (RSSI_WEAK - RSSI_STRONG)`
    /// actually maps a STRONG (near) signal to `1.0` and a WEAK (far) one to
    /// `0.0`, the opposite of that same file's own doc comment ("0f (right
    /// at the device) ... 1f (edge of range)"). This implements the
    /// DOCUMENTED behavior (matches what a radar visualization needs: close
    /// peers plot near the center) rather than propagating what reads as an
    /// inversion bug in unvalidated spike code.
    private static func radiusFraction(rssi: Int?) -> Double {
        guard let rssi else { return 0.9 }
        let clamped = min(max(rssi, rssiWeak), rssiStrong)
        let fraction = Double(rssiStrong - clamped) / Double(rssiStrong - rssiWeak)
        return min(max(fraction, 0.12), 1.0)
    }
}

// MARK: - MeshTransportDelegate

extension MeshRuntime: MeshTransportDelegate {

    // `MeshTransportDelegate` is not actor-isolated (BleMeshTransport calls
    // these from its own dedicated `bleQueue`, per that type's own doc), so
    // every requirement here is `nonisolated` and hops to `@MainActor`
    // itself before touching any `@Published` property — the obligation
    // `MeshTransportDelegate`'s doc comment places on the conformer.
    nonisolated func meshTransport(_ transport: MeshTransport, radioStateDidChange state: MeshRadioState) {
        Task { @MainActor in
            self.radioState = state
        }
    }

    nonisolated func meshTransport(_ transport: MeshTransport, knownPeersDidChange peers: Set<MeshPeerInfo>) {
        Task { @MainActor in
            self.applyKnownPeers(peers)
        }
    }

    nonisolated func meshTransport(_ transport: MeshTransport, didReceive packet: MeshInboundPacket) {
        let type = packet.packet.type
        guard type == .data || type == .receipt else { return }
        // The ORIGINATING sender (the packet header), not the immediate radio hop.
        let fromHex = packet.packet.senderId.hex
        let payload = packet.packet.payload
        Task { @MainActor in
            if type == .receipt {
                self.onInboundReceipt?(fromHex, payload)
            } else {
                self.onInboundData?(fromHex, payload)
            }
        }
    }
}
