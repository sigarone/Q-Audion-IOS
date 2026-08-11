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
/// Mirrors the Android sibling's `MeshService` (antenna + peer list +
/// per-conversation target) but folds in the packet construction that
/// Android split across `MeshSendCoordinator`/`MeshReceiveCoordinator` too
/// — there is no outbox/store-and-forward tier on iOS yet (see
/// `docs/ble-mesh/` for that scoping note), so one runtime object covers
/// what three Android classes do.
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

    /// Which of the two radio roles is active — nil when the antenna is
    /// off. Derived from `radioState` (itself computed live off
    /// `CBCentralManager.isScanning`/`CBPeripheralManager.isAdvertising` by
    /// `BleMeshTransport.currentRadioState()`), so this never drifts out of
    /// sync with what the radio is actually doing.
    var antennaMode: MeshAntennaMode? {
        switch radioState {
        case .scanningAndAdvertising: return .fullMesh
        case .advertisingOnly: return .visibleOnly
        default: return nil
        }
    }

    /// Fired for every `.data` packet addressed to us, once per inbound
    /// message. `fromNodeHex` is the ORIGINATING sender's node id (not
    /// necessarily the immediate radio hop, if the packet was relayed).
    /// `payload` is the still-opaque `MeshChatMessage` envelope bytes —
    /// this runtime never parses it; that's the receive-side integration's
    /// job (see `AppState`'s mesh receive hook). `@MainActor`-typed (same
    /// convention as `LiveLogStreamer.TokenProvider`) so it's always
    /// invoked already on the main actor — see `meshTransport(_:didReceive:)`
    /// below — and a caller like `AppState` can assign a plain closure that
    /// touches `@MainActor` state directly, no extra `Task` hop needed.
    var onInboundData: (@MainActor (_ fromNodeHex: String, _ payload: Data) -> Void)?

    private(set) var localNodeIdHex: String
    private var transport: BleMeshTransport?
    /// Rebuilt from every `knownPeers` update (each `MeshPeerInfo` already
    /// carries its own announced-neighbor set) rather than fed from raw
    /// ANNOUNCE payloads directly — see the file-level doc for why this
    /// runtime doesn't need its own announce parsing.
    private let topology = MeshTopology()

    private init() {
        localNodeIdHex = MeshNodeId.random().hex
    }

    /// Call once identity bootstrap has produced a long-term key (or
    /// whenever it rotates). Safe to call before the antenna is ever
    /// turned on — it only affects what node id a FUTURE `start()` uses.
    func configureLocalIdentity(identityKeyRaw: Data?) {
        localNodeIdHex = MeshFeature.localNodeId(identityKeyRaw: identityKeyRaw).hex
    }

    /// Turns the BLE radio off, or on in `mode`. This is the ONLY call site
    /// that ever touches CoreBluetooth — the antenna selector in
    /// `MeshSheetView`. Silently refuses when the feature flag is off, so a
    /// stray call (e.g. a race with a flag flip) can never bypass the gate.
    func setAntenna(mode: MeshAntennaMode?) {
        guard MeshFeature.enabled else { return }
        guard let mode else {
            transport?.stop()
            activeTargets.removeAll()
            return
        }
        // Switching .fullMesh <-> .visibleOnly mid-session: BleMeshTransport
        // .start() is a no-op while already active (it can't reconcile
        // "already active, but in the other mode" mid-call), so stop first —
        // the cost (re-advertise/re-discover) is small.
        if let current = antennaMode, current != mode {
            transport?.stop()
        }
        let localId = (try? MeshNodeId(hex: localNodeIdHex)) ?? MeshNodeId.random()
        let t = transport ?? BleMeshTransport(localNodeId: localId)
        t.delegate = self
        transport = t
        t.start(schedule: MeshRadioSchedule.backgroundIdle, mode: mode)
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

    /// Encrypts nothing, parses nothing — `payload` is already the final
    /// opaque envelope bytes the caller wants delivered. Wraps it in a
    /// `MeshPacket`, resolves a known multi-hop next-hop when one exists
    /// (preferring a direct send over a flood, same as the relay policy's
    /// own rule), and hands it to the transport.
    func sendData(toNodeHex: String, payload: Data, completion: @escaping (Bool) -> Void) {
        guard let transport else {
            completion(false)
            return
        }
        guard let recipient = try? MeshNodeId(hex: toNodeHex) else {
            completion(false)
            return
        }
        guard let packet = try? MeshPacket(
            type: .data, senderId: transport.localNodeId, recipientId: recipient,
            ttl: MeshPacket.defaultTTL, timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            payload: payload
        ) else {
            completion(false)
            return
        }
        let preferredNextHop = topology.nextHop(for: recipient)
        transport.send(packet, preferredNextHop: preferredNextHop) { [weak self] result in
            Task { @MainActor in
                _ = self // keep the runtime alive across the hop; no state touched here
                switch result {
                case .sentDirect, .sentViaRelay:
                    completion(true)
                case .queued, .failed:
                    completion(false)
                }
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
        guard packet.packet.type == .data else { return }
        let fromHex = packet.fromNodeId.hex
        let payload = packet.packet.payload
        Task { @MainActor in
            self.onInboundData?(fromHex, payload)
        }
    }
}
