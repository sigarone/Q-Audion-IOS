import Foundation
import CoreBluetooth
import QAudionEngine

/// Real dual-role BLE implementation of `MeshTransport` (QAudionEngine's
/// framework-free protocol — see `Mesh/MeshTransport.swift`).
///
/// Uses only the phone's standard CoreBluetooth stack — no special hardware:
///  - **Peripheral half**: advertises the Q-Audion mesh service UUID and
///    runs a `CBPeripheralManager` GATT server with a single write+notify
///    characteristic, so other phones (acting as centrals) can connect in
///    and exchange packets.
///  - **Central half**: scans for that same service UUID, connects out to
///    peers, subscribes to their notify characteristic, and writes packets
///    to them.
///
/// Any two nearby phones therefore reach each other regardless of which
/// started scanning first. A packet is a `MeshPacket.encode()` split into
/// link-layer frames (a tiny 4-byte header — set id / index / total, since
/// one GATT write is MTU-bounded); the receiver reassembles, `decode()`s,
/// updates its peer view from ANNOUNCEs, floods relayable packets on, and
/// notifies its delegate with the rest.
///
/// **Service/characteristic UUIDs and frame header layout are pinned to the
/// SAME values as the Android client's `BleMeshTransportImpl`**
/// (`b7c1a5e0-9d3a-4f6b-8a21-0d1e2f3a4b01`/`…4b02`, `setId(u16 BE) |
/// index(u8) | total(u8) | chunk`), so a nearby iOS and Android device speak
/// the same link layer — not required by the task, but free once both sides
/// already needed a wire format, and worth keeping true if it is ever
/// exercised.
///
/// ## Concurrency
/// Deliberately NOT `@MainActor`. Both `CBCentralManager` and
/// `CBPeripheralManager` are constructed with an explicit dedicated SERIAL
/// `DispatchQueue` (`bleQueue`, not `nil`/main) — the analogue of the
/// Android Looper-thread lesson from the sibling BLE mesh port: don't
/// assume framework callbacks land on a thread state can be casually
/// touched from. Every delegate method here therefore runs on `bleQueue`,
/// and all mutable connection-tracking state is confined to it. This type
/// never touches `@Published`/SwiftUI state directly — it reports through
/// `MeshTransportDelegate`, whose doc comment obligates the CONFORMER
/// (`MeshRuntime`) to hop to `@MainActor` itself before touching UI state.
/// That split keeps this file itself simple (nonisolated, no
/// `@preconcurrency` dance) while keeping the actual UI-state mutation
/// explicit and correct at the one place it happens.
///
/// Written against the documented CoreBluetooth APIs; no BLE code copied
/// from any third-party project. Not yet exercised on physical hardware —
/// the one validation step this environment cannot perform. Expect
/// on-device tuning of pacing/write-type/congestion handling, exactly like
/// the Android sibling implementation's own caveat.
final class BleMeshTransport: NSObject, MeshTransport {

    static let serviceUUID = CBUUID(string: "b7c1a5e0-9d3a-4f6b-8a21-0d1e2f3a4b01")
    static let characteristicUUID = CBUUID(string: "b7c1a5e0-9d3a-4f6b-8a21-0d1e2f3a4b02")

    private static let frameHeaderSize = 4 // setId(2) + index(1) + total(1)
    private static let maxFrameChunk = 400
    private static let framePacingMs: Int = 12
    private static let announceIntervalMs: Int = 15_000
    private static let maxOutgoingLinks = 6

    // --- Abuse mitigation tuning — mirrors the Android sibling's
    // BleMeshTransportImpl constants of the same purpose; see the
    // "Abuse mitigation" section below for why each exists. ---
    private static let maxServerConnections = 8
    private static let maxPendingReassemblyPerDevice = 4
    private static let reassemblyTTLMs: Int64 = 30_000
    private static let maxMalformedStreak = 10
    private static let blockDurationMs: Int64 = 60_000
    private static let maxRelaysPerWindow = 20
    private static let relayWindowMs: Int64 = 10_000

    let localNodeId: MeshNodeId
    weak var delegate: MeshTransportDelegate?

    private let bleQueue = DispatchQueue(label: "com.qaudion.mesh.ble", qos: .utility)
    private var central: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private var notifyCharacteristic: CBMutableCharacteristic?

    private var active = false
    private var announceScheduled = false
    /// Set on every `start` call; read by `handlePacket`'s relay gate and by `maybeStartScanning`'s gate.
    private var mode: MeshAntennaMode = .fullMesh

    // --- central-role link tracking (we connected OUT) ---
    private var outgoingPeripherals: [UUID: CBPeripheral] = [:]
    private var outgoingCharacteristics: [UUID: CBCharacteristic] = [:]

    // --- peripheral-role link tracking (centrals connected IN to us) ---
    private var subscribedCentrals: [UUID: CBCentral] = [:]

    // --- shared peer bookkeeping, keyed by CoreBluetooth peer identifier ---
    private var deviceToNodeHex: [UUID: String] = [:]
    private var deviceRSSI: [UUID: Int] = [:]
    private var announcedNeighborsByNode: [String: Set<String>] = [:]
    private var reassembly: [String: FrameBuffer] = [:] // key "identifier:setId"

    // --- abuse mitigation state, see the "Abuse mitigation" section below ---
    private var malformedStreak: [UUID: Int] = [:]
    private var blockedUntilMs: [UUID: Int64] = [:]
    private var relayWindows: [UUID: RelayWindow] = [:]
    /// Bounded, oldest-evicted-first identities of packets this device has
    /// already flood-relayed — see `alreadyRelayed(_:)`. Plain arrays/sets,
    /// not a synchronized structure: unlike the Android sibling (concurrent
    /// GATT callback threads), every call into this type is confined to
    /// `bleQueue`, so no extra locking is needed here either.
    private var relayedPacketKeys: [String] = []
    private var relayedPacketKeySet: Set<String> = []
    private static let relayedPacketCacheSize = 256

    private final class FrameBuffer {
        let total: Int
        let createdAtMs: Int64
        var chunks: [Int: Data] = [:]
        init(total: Int, createdAtMs: Int64) {
            self.total = total
            self.createdAtMs = createdAtMs
        }
    }

    private final class RelayWindow {
        var windowStartMs: Int64
        var count: Int
        init(windowStartMs: Int64, count: Int) {
            self.windowStartMs = windowStartMs
            self.count = count
        }
    }

    init(localNodeId: MeshNodeId) {
        self.localNodeId = localNodeId
        super.init()
        // CBCentralManager/CBPeripheralManager are created lazily in
        // start() rather than here so a transport that's never started
        // (feature flag off) never touches the Bluetooth subsystem at all
        // — matches the "never scan/advertise just because the flag is on"
        // constraint; the antenna toggle in the UI is the only call site
        // for start().
    }

    // MARK: - MeshTransport

    func start(schedule: MeshRadioSchedule.Profile, mode: MeshAntennaMode) {
        bleQueue.async { [weak self] in
            self?.startLocked(mode: mode)
        }
    }

    private func startLocked(mode: MeshAntennaMode) {
        guard !active else { return }
        active = true
        self.mode = mode
        if central == nil {
            central = CBCentralManager(delegate: self, queue: bleQueue, options: nil)
        }
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: bleQueue, options: nil)
        }
        // The respective *DidUpdateState callbacks pick up scanning /
        // advertising once poweredOn — see centralManagerDidUpdateState /
        // peripheralManagerDidUpdateState below. Calling scanForPeripherals
        // before poweredOn throws away the call silently, so state changes
        // are the only trigger, not this method.
        maybeStartScanning()
        maybeStartAdvertisingAndServer()
        scheduleAnnounceLoop()
        // Publish current state right away. This matters most on a RESTART
        // (antenna off then on again while Bluetooth was already powered
        // on): *DidUpdateState only fires on an actual power-state change,
        // so without this explicit publish here `radioState` would never
        // move off whatever it was left at by stopLocked() (.idle) — the
        // antenna row would keep showing "Spenta" forever even though
        // scanning/advertising just restarted successfully underneath.
        notifyDelegateRadioState(currentRadioState())
    }

    func stop() {
        bleQueue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func stopLocked() {
        active = false
        announceScheduled = false
        central?.stopScan()
        peripheralManager?.stopAdvertising()
        for peripheral in outgoingPeripherals.values {
            central?.cancelPeripheralConnection(peripheral)
        }
        outgoingPeripherals.removeAll()
        outgoingCharacteristics.removeAll()
        subscribedCentrals.removeAll()
        deviceToNodeHex.removeAll()
        deviceRSSI.removeAll()
        announcedNeighborsByNode.removeAll()
        reassembly.removeAll()
        malformedStreak.removeAll()
        relayWindows.removeAll()
        // blockedUntilMs intentionally survives stop()/start() — cycling the
        // antenna is not a reason to forgive a recent abuser (mirrors the
        // Android sibling's identical stop() comment).
        notifyDelegateRadioState(.idle)
        notifyDelegatePeers([])
    }

    func updateSchedule(_ schedule: MeshRadioSchedule.Profile) {
        // A full implementation would re-issue scan/advertise parameters
        // (scan window/interval, TX power hint via advertise mode) from
        // `schedule`. iOS's CoreBluetooth scan/advertise APIs expose far
        // less duty-cycle control than Android's (no programmatic TX power,
        // no scan window/interval — only a "low duty cycle" advertise hint
        // and `CBCentralManagerScanOptionAllowDuplicatesKey`), so for this
        // first cut the cadence is fixed once started, same simplification
        // the Android sibling's own `updateSchedule` makes for its first
        // increment.
    }

    func send(_ packet: MeshPacket, preferredNextHop: MeshNodeId?, completion: @escaping (MeshSendResult) -> Void) {
        bleQueue.async { [weak self] in
            self?.sendLocked(packet, preferredNextHop: preferredNextHop, completion: completion)
        }
    }

    private func sendLocked(_ packet: MeshPacket, preferredNextHop: MeshNodeId?, completion: @escaping (MeshSendResult) -> Void) {
        guard active else {
            completion(.failed("antenna_off"))
            return
        }
        let bytes = packet.encode()
        let targetHex = (preferredNextHop ?? packet.recipientId).hex
        let isBroadcast = targetHex == MeshNodeId.broadcast.hex
        if !isBroadcast, let identifier = deviceToNodeHex.first(where: { $0.value == targetHex })?.key {
            let delivered = sendFrames(bytes, onlyTo: identifier)
            completion(delivered ? .sentDirect : .queued("write_failed"))
            return
        }
        let anyDelivered = sendFrames(bytes, onlyTo: nil)
        completion(anyDelivered ? .sentViaRelay : .queued("no_links"))
    }

    // MARK: - Central role (scan + connect out)

    private func maybeStartScanning() {
        guard active, mode == .fullMesh, let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    // MARK: - Peripheral role (advertise + GATT server)

    private func maybeStartAdvertisingAndServer() {
        guard active, let peripheralManager, peripheralManager.state == .poweredOn else { return }
        if notifyCharacteristic == nil {
            let characteristic = CBMutableCharacteristic(
                type: Self.characteristicUUID,
                properties: [.write, .writeWithoutResponse, .notify],
                value: nil,
                permissions: [.writeable]
            )
            let service = CBMutableService(type: Self.serviceUUID, primary: true)
            service.characteristics = [characteristic]
            notifyCharacteristic = characteristic
            // Advertising starts from `didAdd(service:error:)` below, once
            // the GATT server actually has the service installed — starting
            // it eagerly here would race the real add on some firmwares.
            peripheralManager.add(service)
            return
        }
        startAdvertisingNow()
    }

    private func startAdvertisingNow() {
        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
        ])
    }

    // MARK: - Announce loop

    private func scheduleAnnounceLoop() {
        guard !announceScheduled else { return }
        announceScheduled = true
        runAnnounceTick()
    }

    private func runAnnounceTick() {
        guard active else { announceScheduled = false; return }
        broadcastAnnounce()
        bleQueue.asyncAfter(deadline: .now() + .milliseconds(Self.announceIntervalMs)) { [weak self] in
            self?.runAnnounceTick()
        }
    }

    private func broadcastAnnounce() {
        guard !outgoingPeripherals.isEmpty || !subscribedCentrals.isEmpty else { return }
        _ = sendFrames(buildAnnouncePacket().encode(), onlyTo: nil)
    }

    private func buildAnnouncePacket() -> MeshPacket {
        let neighbors = Array(Set(deviceToNodeHex.values)).prefix(MeshAnnounce.maxNeighbors)
        let announce = MeshAnnounce(
            nodeIdHex: localNodeId.hex,
            identityFingerprintHex: localNodeId.hex,
            neighborNodeIdsHex: Array(neighbors)
        )
        // Wrapped with MeshDiscoveryCipher, not sent as plain JSON — see
        // that type's header for exactly what this does and doesn't hide.
        // Force-unwrapped: AES.GCM.seal with a fixed, well-formed 32-byte
        // key only fails for pathological inputs this call never produces
        // — same "cannot actually fail" reasoning as the MeshPacket
        // construction below.
        let encryptedPayload = MeshDiscoveryCipher.encrypt(announce.encode())!
        // Constructing this packet can only fail if the announce payload
        // somehow exceeded MeshPacket.maxPayloadBytes (16KB) — an ANNOUNCE
        // body capped at MeshAnnounce.maxNeighbors short hex strings plus
        // AES-GCM's fixed 28-byte overhead never gets remotely close, so a
        // forced unwrap here mirrors the same reasoning as
        // MeshPacket.withTTL(_:).
        return try! MeshPacket(
            type: .announce, senderId: localNodeId, recipientId: .broadcast,
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000), payload: encryptedPayload
        )
    }

    // MARK: - Framing + send (shared by both roles)

    /// Splits `payload` into MTU-bounded link frames and writes/notifies
    /// them to one peer or every known peer. Returns whether at least one
    /// link accepted at least one frame.
    @discardableResult
    private func sendFrames(_ payload: Data, onlyTo identifier: UUID?) -> Bool {
        let setId = UInt16.random(in: UInt16.min...UInt16.max)
        let chunkSize = Self.maxFrameChunk
        let total = max(1, (payload.count + chunkSize - 1) / chunkSize)
        let targets: [UUID]
        if let identifier {
            targets = [identifier]
        } else {
            targets = Array(Set(outgoingPeripherals.keys).union(subscribedCentrals.keys))
        }
        guard !targets.isEmpty else { return false }

        var anyDelivered = false
        for target in targets {
            var delivered = false
            for index in 0..<total {
                let from = payload.index(payload.startIndex, offsetBy: index * chunkSize)
                let to = payload.index(from, offsetBy: min(chunkSize, payload.count - index * chunkSize))
                let frame = frame(setId: setId, index: index, total: total, chunk: payload[from..<to])
                if writeFrame(frame, to: target) { delivered = true }
            }
            if delivered { anyDelivered = true }
        }
        return anyDelivered
    }

    private func frame(setId: UInt16, index: Int, total: Int, chunk: Data) -> Data {
        var out = Data(capacity: Self.frameHeaderSize + chunk.count)
        out.append(UInt8(setId >> 8))
        out.append(UInt8(setId & 0xFF))
        out.append(UInt8(index & 0xFF))
        out.append(UInt8(total & 0xFF))
        out.append(chunk)
        return out
    }

    /// Prefers the outgoing (central) link; falls back to notifying a
    /// subscribed central (we are that device's peripheral). Best-effort —
    /// a `false` return means this one frame didn't go out, not that the
    /// link is dead; the caller only checks whether ANY frame landed.
    private func writeFrame(_ frame: Data, to identifier: UUID) -> Bool {
        if let peripheral = outgoingPeripherals[identifier], let characteristic = outgoingCharacteristics[identifier] {
            let maxLen = peripheral.maximumWriteValueLength(for: .withoutResponse)
            guard frame.count <= maxLen || maxLen == 0 else { return false }
            peripheral.writeValue(frame, for: characteristic, type: .withoutResponse)
            return true
        }
        if let central = subscribedCentrals[identifier], let characteristic = notifyCharacteristic {
            return peripheralManager.updateValue(frame, for: characteristic, onSubscribedCentrals: [central])
        }
        return false
    }

    // MARK: - Receive + reassembly + relay (shared by both roles)

    private func onFrameReceived(from identifier: UUID, frame: Data) {
        guard !isBlocked(identifier) else { return }
        guard frame.count >= Self.frameHeaderSize else {
            registerMalformed(identifier)
            return
        }
        let setId = (UInt16(frame[frame.startIndex]) << 8) | UInt16(frame[frame.startIndex + 1])
        let index = Int(frame[frame.startIndex + 2])
        let total = Int(frame[frame.startIndex + 3])
        let chunk = frame[(frame.startIndex + Self.frameHeaderSize)...]
        guard total > 0, index < total else {
            registerMalformed(identifier)
            return
        }

        sweepStaleReassembly()
        let key = "\(identifier.uuidString):\(setId)"
        let assembled: Data?
        if total == 1 {
            assembled = Data(chunk)
        } else {
            if reassembly[key] == nil {
                let prefix = "\(identifier.uuidString):"
                let pendingForDevice = reassembly.keys.filter { $0.hasPrefix(prefix) }.count
                guard pendingForDevice < Self.maxPendingReassemblyPerDevice else {
                    return // over cap — drop silently, not itself malformed input
                }
            }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let buffer = reassembly[key] ?? FrameBuffer(total: total, createdAtMs: now)
            buffer.chunks[index] = Data(chunk)
            reassembly[key] = buffer
            if buffer.chunks.count == total {
                reassembly.removeValue(forKey: key)
                var out = Data()
                var complete = true
                for i in 0..<total {
                    guard let c = buffer.chunks[i] else { complete = false; break }
                    out.append(c)
                }
                assembled = complete ? out : nil
            } else {
                assembled = nil
            }
        }
        guard let payload = assembled else { return }
        guard let packet = MeshPacket.decode(payload) else {
            registerMalformed(identifier)
            return
        }
        handlePacket(from: identifier, packet: packet)
    }

    private func handlePacket(from identifier: UUID, packet: MeshPacket) {
        deviceToNodeHex[identifier] = packet.senderId.hex

        if packet.type == .announce {
            guard let decrypted = MeshDiscoveryCipher.decrypt(packet.payload) else {
                registerMalformed(identifier)
                return
            }
            guard let announce = MeshAnnounce.decode(decrypted) else {
                registerMalformed(identifier)
                return
            }
            // NOT at the top of this function: resetting the streak before a
            // decode failure above re-bumps it would make the streak
            // un-trippable for exactly that failure mode (reset to 0, then
            // immediately re-incremented to 1, forever) — only a fully valid
            // ANNOUNCE, or falling through to a non-ANNOUNCE type below,
            // counts as "this identifier is behaving".
            registerWellFormed(identifier)
            announcedNeighborsByNode[announce.nodeIdHex] = Set(announce.neighborNodeIdsHex)
            deviceToNodeHex[identifier] = announce.nodeIdHex
            recomputeAndNotifyPeers()
            return
        }

        registerWellFormed(identifier)
        let forUs = packet.recipientId == localNodeId || packet.recipientId == .broadcast
        if forUs {
            let inbound = MeshInboundPacket(packet: packet, fromNodeId: packet.senderId, rssi: deviceRSSI[identifier])
            delegate?.meshTransport(self, didReceive: inbound)
        }

        // Flood relay: a packet not uniquely for us, still with hops left.
        // .visibleOnly explicitly opts out of acting as a relay hop for
        // other people's traffic — it's "reachable", not "participating in
        // routing". allowRelay caps how much of THIS source's traffic gets
        // relayed on, so one adjacent peer can't use this device to amplify
        // spam to everyone else in range — neither gate applies to the
        // forUs branch above.
        guard packet.recipientId != localNodeId, mode == .fullMesh,
              allowRelay(from: identifier), !alreadyRelayed(packet) else { return }
        let decision = MeshRelayPolicy.evaluate(
            packet: packet, localNodeId: localNodeId,
            visiblePeerCount: deviceToNodeHex.count, knownNextHop: nil
        )
        guard decision.shouldForward else { return }
        let relayed = packet.withTTL(decision.nextTTL)
        let relayBytes = relayed.encode()
        let targets = Set(outgoingPeripherals.keys).union(subscribedCentrals.keys).subtracting([identifier])
        for target in targets {
            _ = sendFrames(relayBytes, onlyTo: target)
        }
    }

    private func recomputeAndNotifyPeers() {
        var peers: Set<MeshPeerInfo> = []
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for (identifier, nodeHex) in deviceToNodeHex {
            guard let nodeId = try? MeshNodeId(hex: nodeHex) else { continue }
            let neighbors = Set((announcedNeighborsByNode[nodeHex] ?? []).compactMap { try? MeshNodeId(hex: $0) })
            let connected = outgoingPeripherals[identifier] != nil || subscribedCentrals[identifier] != nil
            peers.insert(MeshPeerInfo(
                nodeId: nodeId, lastSeenAtMs: now, rssi: deviceRSSI[identifier],
                connected: connected, announcedNeighbors: neighbors
            ))
        }
        notifyDelegatePeers(peers)
    }

    private func onDeviceGone(_ identifier: UUID) {
        let nodeHex = deviceToNodeHex.removeValue(forKey: identifier)
        deviceRSSI.removeValue(forKey: identifier)
        if let nodeHex { announcedNeighborsByNode.removeValue(forKey: nodeHex) }
        for key in reassembly.keys where key.hasPrefix("\(identifier.uuidString):") {
            reassembly.removeValue(forKey: key)
        }
        // NOT blockedUntilMs: an identifier that tripped the malformed-streak
        // block must stay refused across its own disconnect/reconnect churn.
        malformedStreak.removeValue(forKey: identifier)
        relayWindows.removeValue(forKey: identifier)
        recomputeAndNotifyPeers()
    }

    // MARK: - Abuse mitigation
    //
    // The GATT server accepts a connection/write from any BLE device in
    // range — that's inherent to the "always visible" discovery model, and
    // message CONTENT stays safe (MessageCrypto ciphertext, produced
    // upstream of this transport), but nothing here bounds the resource
    // cost a misbehaving or hostile peer can impose. These mitigations
    // mirror the Android sibling's `BleMeshTransportImpl` one-for-one in
    // intent, with one real, honest platform difference: CoreBluetooth's
    // peripheral role (`CBPeripheralManager`) has no public API to forcibly
    // disconnect a specific connected central the way Android's
    // `BluetoothGattServer.cancelConnection(device)` or this same file's own
    // `central.cancelPeripheralConnection(peripheral)` (central role) do —
    // the OS Bluetooth stack owns that link, not the app. For an abusive
    // SUBSCRIBED CENTRAL, the mitigation below is therefore
    // application-level refusal (never track it as a live peer, never
    // relay/notify to it, ignore its frames) rather than a true disconnect;
    // for an abusive OUTGOING PERIPHERAL (central role, where this device
    // initiated the connection) a real `cancelPeripheralConnection` is used,
    // same as Android.

    private func isBlocked(_ identifier: UUID) -> Bool {
        guard let until = blockedUntilMs[identifier] else { return false }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if now >= until {
            blockedUntilMs.removeValue(forKey: identifier)
            return false
        }
        return true
    }

    /// Bumps `identifier`'s consecutive-malformed-input counter. Past
    /// `maxMalformedStreak`, refuses it for `blockDurationMs` and — for the
    /// central role only, see this section's header comment — actively
    /// disconnects it. A deterrent against a naive repeat offender
    /// (fuzzer, broken peer), not a strong identity block: a BLE identifier
    /// can rotate, so a determined attacker can evade it by reconnecting;
    /// what this DOES guarantee is that this device's own reassembly/peer
    /// state never grows without bound from a single misbehaving link.
    private func registerMalformed(_ identifier: UUID) {
        let streak = (malformedStreak[identifier] ?? 0) + 1
        malformedStreak[identifier] = streak
        guard streak >= Self.maxMalformedStreak else { return }
        malformedStreak.removeValue(forKey: identifier)
        blockedUntilMs[identifier] = Int64(Date().timeIntervalSince1970 * 1000) + Self.blockDurationMs
        if let peripheral = outgoingPeripherals[identifier] {
            central?.cancelPeripheralConnection(peripheral)
        }
        // Subscribed-central case: no disconnect API — dropping it from
        // subscribedCentrals (done by the isBlocked-gated call sites below)
        // is the whole mitigation available on this side of the role.
        subscribedCentrals.removeValue(forKey: identifier)
    }

    private func registerWellFormed(_ identifier: UUID) {
        malformedStreak.removeValue(forKey: identifier)
    }

    /// Evicts reassembly buffers older than `reassemblyTTLMs` — a peer that
    /// starts a frame set and never finishes it must not hold memory forever.
    private func sweepStaleReassembly() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        reassembly = reassembly.filter { now - $0.value.createdAtMs <= Self.reassemblyTTLMs }
    }

    /// Fixed-window flood-relay cap per immediate sender, so one adjacent
    /// peer can't use this device to amplify spam across the rest of the
    /// mesh. Never applied to packets addressed to this device — only to
    /// relaying someone else's traffic on.
    private func allowRelay(from identifier: UUID) -> Bool {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let window = relayWindows[identifier]
        if window == nil || now - window!.windowStartMs > Self.relayWindowMs {
            relayWindows[identifier] = RelayWindow(windowStartMs: now, count: 1)
            return true
        }
        window!.count += 1
        return window!.count <= Self.maxRelaysPerWindow
    }

    /// True if this device has already flood-relayed this exact packet
    /// (test-and-set: a fresh identity is also recorded as a side effect).
    ///
    /// A flood-relayed packet can arrive here more than once, via different
    /// neighbors, before its TTL runs out — `MeshRelayPolicy.evaluate` has
    /// no memory of what this device already forwarded, so without this
    /// check every redundant arrival got its own independent relay
    /// decision, wasting airtime on a packet already on its way. Mirrors
    /// the Android sibling's `alreadyRelayed` one-for-one.
    ///
    /// The identity key deliberately excludes `ttl` — the one field a relay
    /// hop changes (`packet.withTTL(decision.nextTTL)` below) — so two
    /// arrivals of "the same" flooded packet via paths of different length
    /// still match. Soft/best-effort: end-user delivery correctness comes
    /// from `clientMsgId` dedup on receive, which this does not replace.
    private func alreadyRelayed(_ packet: MeshPacket) -> Bool {
        let key = "\(packet.senderId.hex):\(packet.recipientId.hex):\(packet.type.rawValue):" +
            "\(packet.timestampMs):\(packet.payload.hashValue)"
        if relayedPacketKeySet.contains(key) { return true }
        relayedPacketKeySet.insert(key)
        relayedPacketKeys.append(key)
        if relayedPacketKeys.count > Self.relayedPacketCacheSize {
            let evicted = relayedPacketKeys.removeFirst()
            relayedPacketKeySet.remove(evicted)
        }
        return false
    }

    // MARK: - Delegate notification (see MeshTransportDelegate's own doc:
    // the CONFORMER hops to @MainActor, not this type)

    private func notifyDelegateRadioState(_ state: MeshRadioState) {
        delegate?.meshTransport(self, radioStateDidChange: state)
    }

    private func notifyDelegatePeers(_ peers: Set<MeshPeerInfo>) {
        delegate?.meshTransport(self, knownPeersDidChange: peers)
    }

    private func currentRadioState() -> MeshRadioState {
        guard active else { return .idle }
        let scanning = central?.isScanning ?? false
        let advertising = peripheralManager?.isAdvertising ?? false
        switch (scanning, advertising) {
        case (true, true): return .scanningAndAdvertising
        case (true, false): return .scanningOnly
        case (false, true): return .advertisingOnly
        case (false, false): return .idle
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BleMeshTransport: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            maybeStartScanning()
            notifyDelegateRadioState(currentRadioState())
        case .poweredOff, .unauthorized, .unsupported:
            notifyDelegateRadioState(.error("bluetooth_unavailable"))
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        deviceRSSI[peripheral.identifier] = RSSI.intValue
        guard active else { return }
        guard !isBlocked(peripheral.identifier) else { return }
        guard outgoingPeripherals[peripheral.identifier] == nil else { return }
        guard outgoingPeripherals.count < Self.maxOutgoingLinks else { return }
        // Two phones may briefly form a link in each direction (a known
        // BLE-mesh nuisance, same as Android's own comment on this): both
        // sides connecting out to the other is harmless — ANNOUNCE is
        // idempotent, and real messages carry a clientMsgId the app layer
        // dedups on. No stable tie-break is attempted here either.
        outgoingPeripherals[peripheral.identifier] = peripheral
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        outgoingPeripherals.removeValue(forKey: peripheral.identifier)
        outgoingCharacteristics.removeValue(forKey: peripheral.identifier)
        onDeviceGone(peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        outgoingPeripherals.removeValue(forKey: peripheral.identifier)
        outgoingCharacteristics.removeValue(forKey: peripheral.identifier)
        onDeviceGone(peripheral.identifier)
    }
}

// MARK: - CBPeripheralDelegate (we are the central; this is the remote peer)

extension BleMeshTransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.characteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }
        for characteristic in characteristics where characteristic.uuid == Self.characteristicUUID {
            outgoingCharacteristics[peripheral.identifier] = characteristic
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying else { return }
        // Introduce ourselves once the notify subscription is confirmed —
        // mirrors the Android sibling's "send ANNOUNCE once the link is up"
        // step, triggered here instead of a fixed post-connect delay since
        // iOS gives us an explicit ack for this instead.
        _ = sendFrames(buildAnnouncePacket().encode(), onlyTo: peripheral.identifier)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == Self.characteristicUUID, let value = characteristic.value else { return }
        onFrameReceived(from: peripheral.identifier, frame: value)
    }
}

// MARK: - CBPeripheralManagerDelegate (we are the peripheral; GATT server role)

extension BleMeshTransport: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            maybeStartAdvertisingAndServer()
            notifyDelegateRadioState(currentRadioState())
        case .poweredOff, .unauthorized, .unsupported:
            notifyDelegateRadioState(.error("bluetooth_unavailable"))
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else {
            // Without this, a GATT-add failure leaves the antenna silently
            // stuck at "Spenta" forever — nothing else would ever publish a
            // state change for this device, since startAdvertisingNow() is
            // never reached on this path.
            notifyDelegateRadioState(.error("gatt_add_failed"))
            return
        }
        startAdvertisingNow()
    }

    /// `startAdvertisingNow()` (called from `didAdd` above, or again on a
    /// same-session restart once `notifyCharacteristic` already exists) is
    /// itself async — `peripheralManager.isAdvertising` only flips true once
    /// this fires. Without republishing here, `radioState`/`antennaMode`
    /// stay wrong (stuck at `.idle`/`.scanningOnly`, antenna shown "Spenta")
    /// even though advertising — and therefore the whole "Visibile" mode —
    /// is actually live. This was the real root cause of the antenna
    /// appearing to do nothing when tapped.
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        notifyDelegateRadioState(currentRadioState())
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        let identifier = central.identifier
        // CoreBluetooth's peripheral role has no API to refuse the
        // underlying connection itself (see the "Abuse mitigation" header
        // comment above) — the mitigation available here is refusing to
        // track this central as a live peer at all once over cap, so it
        // never receives a relay/notify and never shows up in the radar.
        let overCap = subscribedCentrals.count >= Self.maxServerConnections && subscribedCentrals[identifier] == nil
        guard !isBlocked(identifier), !overCap else { return }
        subscribedCentrals[identifier] = central
        recomputeAndNotifyPeers()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeValue(forKey: central.identifier)
        onDeviceGone(central.identifier)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if isBlocked(request.central.identifier) {
                peripheral.respond(to: request, withResult: .insufficientAuthorization)
                continue
            }
            if let value = request.value {
                onFrameReceived(from: request.central.identifier, frame: value)
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }
}
