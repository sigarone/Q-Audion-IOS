import Foundation

/// Role interface for a BLE-mesh participant: ONE type covers BOTH the
/// BLE-central (scan + connect-out) and BLE-peripheral (advertise + run a
/// GATT server) roles, because any two nearby phones must be able to
/// discover each other regardless of which one happened to start scanning
/// first — there is no fixed client/server split at the app layer.
///
/// Deliberately framework-free: no `CoreBluetooth` type appears anywhere in
/// this file. The concrete implementation (`BleMeshTransport`, wrapping
/// `CBCentralManager`/`CBPeripheralManager`) lives in the app target
/// (`QAudionApp/Services/`), not here — see the design note in
/// `docs/ble-mesh/` for why the split follows Android's `qaudion-engine`
/// (pure) / app-module (radio glue) boundary.
///
/// Swift has no direct `StateFlow` equivalent without pulling in Combine at
/// the package-API-surface level, so this protocol uses a delegate instead
/// (idiomatic for a CoreBluetooth-adjacent Swift API, and it keeps this
/// whole file Combine-free too).
public enum MeshRadioState: Equatable {
    case idle
    case scanningOnly
    /// Peripheral role only (`MeshAntennaMode.visibleOnly`) — advertising +
    /// GATT server, not scanning.
    case advertisingOnly
    /// Both central + peripheral roles active simultaneously
    /// (`MeshAntennaMode.fullMesh`) — the normal steady state.
    case scanningAndAdvertising
    case error(String)
}

/// Which radio role(s) `MeshTransport.start(schedule:mode:)` activates.
///
/// `.visibleOnly` is for a user who wants to be reachable — advertise +
/// accept incoming GATT connections — without paying the scan/connect-out
/// battery cost or volunteering as a flood-relay hop for other people's
/// packets. `.fullMesh` is the original behaviour: both roles, plus
/// relaying. Mirrors the Android sibling's `MeshAntennaMode` one-for-one.
public enum MeshAntennaMode: Equatable {
    case visibleOnly
    case fullMesh
}

public struct MeshPeerInfo: Equatable, Hashable {
    public let nodeId: MeshNodeId
    public let lastSeenAtMs: Int64
    public let rssi: Int?
    public let connected: Bool
    /// Neighbor set this peer self-reported in its last ANNOUNCE — feeds
    /// `MeshTopology.recordAnnounce(from:announcedNeighbors:)`.
    public let announcedNeighbors: Set<MeshNodeId>

    public init(nodeId: MeshNodeId, lastSeenAtMs: Int64, rssi: Int?, connected: Bool, announcedNeighbors: Set<MeshNodeId> = []) {
        self.nodeId = nodeId
        self.lastSeenAtMs = lastSeenAtMs
        self.rssi = rssi
        self.connected = connected
        self.announcedNeighbors = announcedNeighbors
    }
}

public struct MeshInboundPacket: Equatable {
    public let packet: MeshPacket
    /// The immediate radio-hop sender. Equals `packet.senderId` only for a
    /// direct (non-relayed) delivery — differs once the packet has bounced
    /// through at least one relay.
    public let fromNodeId: MeshNodeId
    public let rssi: Int?

    public init(packet: MeshPacket, fromNodeId: MeshNodeId, rssi: Int?) {
        self.packet = packet
        self.fromNodeId = fromNodeId
        self.rssi = rssi
    }
}

public enum MeshSendResult: Equatable {
    case sentDirect
    case sentViaRelay
    /// No reachable path right now. A real implementation is expected to
    /// ALSO retain the packet internally for store-and-forward and flush it
    /// once the peer is seen again.
    case queued(String)
    case failed(String)
}

/// Delegate callbacks fire on an unspecified queue chosen by the concrete
/// transport (see `BleMeshTransport`'s own doc for which one and why) —
/// conforming types that touch `@Published`/UI state MUST hop to the main
/// actor themselves inside these callbacks rather than assuming they are
/// already on it.
public protocol MeshTransportDelegate: AnyObject {
    func meshTransport(_ transport: MeshTransport, radioStateDidChange state: MeshRadioState)
    func meshTransport(_ transport: MeshTransport, knownPeersDidChange peers: Set<MeshPeerInfo>)
    func meshTransport(_ transport: MeshTransport, didReceive packet: MeshInboundPacket)
}

public protocol MeshTransport: AnyObject {
    /// This device's own mesh identity for the lifetime of the process.
    var localNodeId: MeshNodeId { get }

    var delegate: MeshTransportDelegate? { get set }

    /// (Re)configure BLE scan/advertise cadence + TX power per `schedule`,
    /// in the given `mode`. `.fullMesh` is expected to run BOTH scanning and
    /// advertising concurrently once started; `.visibleOnly` only advertises
    /// + runs the GATT server.
    func start(schedule: MeshRadioSchedule.Profile, mode: MeshAntennaMode)

    func stop()

    /// Called whenever `MeshRadioSchedule.resolve(_:)` produces a different
    /// profile than the one currently active.
    func updateSchedule(_ schedule: MeshRadioSchedule.Profile)

    /// Best-effort single-packet send.
    ///
    /// - Parameter preferredNextHop: a direct-connect hint from a caller
    ///   that already resolved one via `MeshTopology.nextHop(for:)`.
    ///   Implementations SHOULD prefer a direct GATT write to that peer over
    ///   an advertise-based flood fan-out.
    func send(_ packet: MeshPacket, preferredNextHop: MeshNodeId?, completion: @escaping (MeshSendResult) -> Void)
}
