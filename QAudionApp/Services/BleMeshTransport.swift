import Foundation
import CoreBluetooth
import UIKit
import QAudionEngine

/// Real dual-role BLE implementation of `MeshTransport` (QAudionEngine's
/// framework-free protocol, see `Mesh/MeshTransport.swift`). The link layer it
/// implements is specified in `docs/mesh/MESH_LINK_SPEC.md`; the framing, the
/// reassembly, the malformed-streak guard, the relay conditions and the frame
/// sender state machine are engine types pinned by `mesh-vectors.json`, so this
/// file is the CoreBluetooth glue around them.
///
/// - Peripheral half: advertises the mesh service UUID and runs a
///   `CBPeripheralManager` GATT server with one write + notify characteristic.
/// - Central half: scans for that UUID, connects out, subscribes, and writes.
///
/// Service and characteristic UUIDs and the 4-byte frame header are shared with
/// the Android client; the two interoperate when the per-link value limit, the
/// write type and the flow control below are respected:
///
/// - the chunk size of a link is `valueLimit - 4`, with the value limit read for
///   EVERY packet: `maximumWriteValueLength(for: .withoutResponse)` for a link
///   we opened (that variant even though frames go out with response, because
///   the `.withResponse` variant reports the long-write limit), and
///   `maximumUpdateValueLength` of the subscribed central for a link that opened
///   to us. A long write is never produced;
/// - frames to a peripheral are write requests, one outstanding per link, the
///   next one only after `didWriteValueFor` reported success; a characteristic
///   without the write property falls back to write-without-response gated by
///   `canSendWriteWithoutResponse` / `peripheralIsReady`;
/// - frames to a central are notifications; a refused `updateValue` is retried
///   from `peripheralManagerIsReady(toUpdateSubscribers:)`;
/// - a frame not confirmed in 2 s fails its set, and the set (and with it the
///   packet on that link) counts as accepted only if EVERY frame was;
/// - a link is bound to a node only by an ANNOUNCE received on that link.
///
/// ## Background
/// With `bluetooth-central` / `bluetooth-peripheral` in `UIBackgroundModes` and
/// the two restore identifiers below, the system keeps scanning for and
/// serving the mesh service while the app is in the background and relaunches
/// the app for Bluetooth events. A backgrounded iPhone advertises its service
/// UUID only in an overflow area that other platforms do not match, so a
/// backgrounded iPhone is found only if IT connects out: scanning (with the
/// service UUID filter, which background scanning requires) stays on in
/// `.direct` and `.fullMesh`, and is re-armed after every link loss.
///
/// ## Concurrency
/// Deliberately NOT `@MainActor`. Both managers use the dedicated serial queue
/// `bleQueue`, every delegate method runs on it, and all state is confined to
/// it. Results leave through `MeshTransportDelegate`, whose conformer
/// (`MeshRuntime`) hops to the main actor itself.
final class BleMeshTransport: NSObject, MeshTransport {

    static let serviceUUID = CBUUID(string: "b7c1a5e0-9d3a-4f6b-8a21-0d1e2f3a4b01")
    static let characteristicUUID = CBUUID(string: "b7c1a5e0-9d3a-4f6b-8a21-0d1e2f3a4b02")

    /// State-restoration identifiers (spec 12): required for the system to relaunch the app for mesh events.
    static let centralRestoreIdentifier = "com.qaudion.mesh.central"
    static let peripheralRestoreIdentifier = "com.qaudion.mesh.peripheral"

    private static let announceIntervalMs: Int = 15_000
    private static let sweepIntervalMs: Int = 5_000
    private static let maxOutgoingLinks = 6
    private static let maxIncomingLinks = 8
    private static let connectTimeoutMs: Int = 10_000
    private static let setupTimeoutMs: Int = 10_000
    private static let idleOutgoingMs: Int64 = 120_000
    private static let unsubscribedEvictionMs: Int64 = 30_000

    let localNodeId: MeshNodeId
    weak var delegate: MeshTransportDelegate?

    private let bleQueue = DispatchQueue(label: "com.qaudion.mesh.ble", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var notifyCharacteristic: CBMutableCharacteristic?
    private var serviceInstalled = false

    private var active = false
    private var announceScheduled = false
    private var sweepScheduled = false
    private var mode: MeshAntennaMode = .fullMesh
    private var inBackground = false
    private var lifecycleObservers: [NSObjectProtocol] = []

    private var outgoing: [UUID: Link] = [:]
    private var incoming: [UUID: Link] = [:]

    /// Links the system handed back through state restoration, set up once the central manager is powered on.
    private var restoredLinks: [UUID] = []
    /// Centrals subscribed to our characteristic before the relaunch; adopted (and announced to) once the peripheral
    /// manager is powered on.
    private var restoredSubscribers: [CBCentral] = []
    /// When a link to a peer last failed before it was ready: no redial within `redialSpacingMs`.
    private var failedSetupAtMs: [UUID: Int64] = [:]
    private static let redialSpacingMs: Int64 = 3_000

    private var malformedGuard = MeshMalformedGuard()
    private var relayGate = MeshRelayGate()
    private var announcedNeighborsByNode: [String: Set<String>] = [:]

    // MARK: - Link and job types

    /// One Bluetooth link, in either role.
    private final class Link {
        enum State {
            case connecting
            case settingUp
            case ready
        }

        let handle: String
        let identifier: UUID
        let isOutgoing: Bool
        let createdAtMs: Int64
        var peripheral: CBPeripheral?
        var characteristic: CBCharacteristic?
        var central: CBCentral?
        var state: State
        var subscribed = false
        var useWriteWithoutResponse = false
        var nodeHex: String?
        var rssi: Int?
        var lastActivityMs: Int64
        var reassembler = MeshLinkReassembler()
        var jobs: [SendJob] = []
        var activeJob: SendJob?
        var setupTimer: DispatchWorkItem?
        var downReason: String?
        /// Write requests whose frame already timed out: their late response must not confirm the next frame.
        var staleConfirmations = 0

        init(handle: String, identifier: UUID, isOutgoing: Bool, nowMs: Int64, state: State) {
            self.handle = handle
            self.identifier = identifier
            self.isOutgoing = isOutgoing
            self.createdAtMs = nowMs
            self.lastActivityMs = nowMs
            self.state = state
        }
    }

    /// One set of frames on one link.
    private final class SendJob {
        var sender: MeshFrameSetSender
        let ph: String
        let completion: (MeshFrameFailure?) -> Void
        var frameTimer: DispatchWorkItem?
        var frameSequence = 0
        var waitingForReady = false

        init(frames: [Data], ph: String, completion: @escaping (MeshFrameFailure?) -> Void) {
            self.sender = MeshFrameSetSender(frames: frames)
            self.ph = ph
            self.completion = completion
        }
    }

    /// The outcome of one packet over a set of links.
    private struct TransmitSummary {
        var links = 0
        var okLinks = 0
        var frames = 0
        var minLimit = 0
        var failure: MeshFrameFailure?
        var chosenOk = false
        var elapsedMs = 0
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var outgoingValue = 0
        private var incomingValue = 0
        func next(outgoing: Bool) -> Int {
            lock.lock()
            defer { lock.unlock() }
            if outgoing {
                outgoingValue += 1
                return outgoingValue
            }
            incomingValue += 1
            return incomingValue
        }
    }

    /// Link handles are never reused within the process, even across a rebuilt transport.
    private static let handles = Counter()

    // MARK: - Init

    init(localNodeId: MeshNodeId) {
        self.localNodeId = localNodeId
        super.init()
        bleQueue.setSpecific(key: queueKey, value: true)
        // CBCentralManager / CBPeripheralManager are created in start(), not
        // here, so a transport that is never started never touches the
        // Bluetooth subsystem.
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
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
        observeLifecycle()
        log(.radio, [("state", "starting"), ("mode", modeToken()), ("reason", "start")])
        if central == nil {
            let options: [String: Any] = [CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreIdentifier]
            central = CBCentralManager(delegate: self, queue: bleQueue, options: options)
        }
        if peripheralManager == nil {
            let options: [String: Any] = [CBPeripheralManagerOptionRestoreIdentifierKey: Self.peripheralRestoreIdentifier]
            peripheralManager = CBPeripheralManager(delegate: self, queue: bleQueue, options: options)
        }
        // The *DidUpdateState callbacks pick up scanning / advertising once
        // poweredOn; calling scanForPeripherals earlier is silently dropped.
        maybeStartScanning()
        maybeStartAdvertisingAndServer()
        scheduleAnnounceLoop()
        scheduleSweepLoop()
        // Publish the current state right away: on a restart while Bluetooth
        // was already powered on, *DidUpdateState does not fire again.
        notifyDelegateRadioState(currentRadioState())
    }

    /// Synchronous: when this returns the managers are released, so a new transport can be built with the same
    /// restore identifiers (a mode switch, an identity change) without two managers sharing them.
    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            stopLocked()
        } else {
            bleQueue.sync { stopLocked() }
        }
    }

    private func stopLocked() {
        let wasActive = active
        active = false
        announceScheduled = false
        sweepScheduled = false
        central?.stopScan()
        peripheralManager?.stopAdvertising()
        for link in allLinks() {
            tearDown(link, reason: "stop", cancelConnection: true)
        }
        outgoing.removeAll()
        incoming.removeAll()
        restoredLinks.removeAll()
        restoredSubscribers.removeAll()
        announcedNeighborsByNode.removeAll()
        relayGate = MeshRelayGate()
        // Release the managers (and with them the restore identifiers); start() builds fresh ones.
        central?.delegate = nil
        peripheralManager?.delegate = nil
        peripheralManager?.removeAllServices()
        central = nil
        peripheralManager = nil
        notifyCharacteristic = nil
        serviceInstalled = false
        // The malformed guard intentionally survives stop() / start(): cycling
        // the antenna is not a reason to forgive a recent abuser.
        if wasActive {
            log(.radio, [("state", "off"), ("mode", modeToken()), ("reason", "stop")])
        }
        notifyDelegateRadioState(.idle)
        notifyDelegatePeers([])
    }

    func updateSchedule(_ schedule: MeshRadioSchedule.Profile) {
        // CoreBluetooth exposes no scan window / interval or TX power control,
        // so the cadence is fixed once started.
    }

    func send(_ packet: MeshPacket, preferredNextHop: MeshNodeId?, completion: @escaping (MeshSendReport) -> Void) {
        bleQueue.async { [weak self] in
            self?.sendLocked(packet, preferredNextHop: preferredNextHop, completion: completion)
        }
    }

    // MARK: - Lifecycle (foreground / background)

    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let background = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.bleQueue.async { self?.setBackground(true) }
        }
        let foreground = center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.bleQueue.async { self?.setBackground(false) }
        }
        lifecycleObservers = [background, foreground]
        DispatchQueue.main.async { [weak self] in
            let isBackground = UIApplication.shared.applicationState == .background
            self?.bleQueue.async { self?.setBackground(isBackground) }
        }
    }

    private func setBackground(_ value: Bool) {
        guard inBackground != value else { return }
        inBackground = value
        guard active else { return }
        log(.radio, [("state", "on"), ("mode", modeToken()), ("reason", value ? "background" : "foreground")])
        // Background scans coalesce duplicates; re-arm so a peer that is already
        // around is reported again under the new rules.
        restartScan()
    }

    private func modeToken() -> String {
        switch mode {
        case .fullMesh: return "full"
        case .direct: return "direct"
        case .visibleOnly: return "visible"
        }
    }

    // MARK: - Link bookkeeping

    private func allLinks() -> [Link] {
        Array(outgoing.values) + Array(incoming.values)
    }

    private func linkHandle(outgoing isOutgoing: Bool) -> String {
        MeshLog.linkHandle(outgoing: isOutgoing, ordinal: Self.handles.next(outgoing: isOutgoing))
    }

    /// A link that can carry frames right now.
    private func isWritable(_ link: Link) -> Bool {
        if link.isOutgoing {
            guard link.state == .ready, let peripheral = link.peripheral else { return false }
            return peripheral.state == .connected && link.characteristic != nil
        }
        return link.subscribed && link.central != nil
    }

    private func writableLinks() -> [Link] {
        allLinks().filter { isWritable($0) }
    }

    /// The writable link to `nodeHex`, the outgoing one first.
    private func directLink(to nodeHex: String) -> Link? {
        let candidates = writableLinks().filter { $0.nodeHex == nodeHex }
        return candidates.first(where: { $0.isOutgoing }) ?? candidates.first
    }

    /// One link per distinct node (the outgoing one first), plus every writable link not yet bound to a node.
    private func floodLinks(excluding excluded: Link?) -> [Link] {
        var chosen: [Link] = []
        var seen: Set<String> = []
        let ordered = writableLinks().sorted { ($0.isOutgoing ? 0 : 1) < ($1.isOutgoing ? 0 : 1) }
        for link in ordered where link !== excluded {
            if let nodeHex = link.nodeHex {
                if seen.contains(nodeHex) { continue }
                seen.insert(nodeHex)
            }
            chosen.append(link)
        }
        return chosen
    }

    private func linkedNodeCount() -> Int {
        Set(writableLinks().compactMap { $0.nodeHex }).count
    }

    // MARK: - Central role (scan + connect out)

    private func maybeStartScanning() {
        guard active, mode.connectsOut, let central, central.state == .poweredOn else { return }
        let options: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: options)
    }

    private func restartScan() {
        guard active, mode.connectsOut, let central, central.state == .poweredOn else { return }
        central.stopScan()
        maybeStartScanning()
    }

    // MARK: - Peripheral role (advertise + GATT server)

    private func maybeStartAdvertisingAndServer() {
        guard active, let peripheralManager, peripheralManager.state == .poweredOn else { return }
        if notifyCharacteristic == nil || !serviceInstalled {
            let characteristic = CBMutableCharacteristic(
                type: Self.characteristicUUID,
                properties: [.write, .writeWithoutResponse, .notify],
                value: nil,
                permissions: [.writeable]
            )
            let service = CBMutableService(type: Self.serviceUUID, primary: true)
            service.characteristics = [characteristic]
            notifyCharacteristic = characteristic
            // Advertising starts from didAdd(service:), once the GATT server has
            // the service installed.
            peripheralManager.add(service)
            return
        }
        startAdvertisingNow()
    }

    private func startAdvertisingNow() {
        // Connectable, the service UUID only: no name, no manufacturer data.
        let data: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]]
        peripheralManager?.startAdvertising(data)
    }

    // MARK: - Periodic work

    private func scheduleAnnounceLoop() {
        guard !announceScheduled else { return }
        announceScheduled = true
        runAnnounceTick()
    }

    private func runAnnounceTick() {
        guard active else {
            announceScheduled = false
            return
        }
        for link in writableLinks() {
            sendAnnounce(on: link)
        }
        bleQueue.asyncAfter(deadline: .now() + .milliseconds(Self.announceIntervalMs)) { [weak self] in
            self?.runAnnounceTick()
        }
    }

    private func scheduleSweepLoop() {
        guard !sweepScheduled else { return }
        sweepScheduled = true
        runSweepTick()
    }

    private func runSweepTick() {
        guard active else {
            sweepScheduled = false
            return
        }
        sweep()
        bleQueue.asyncAfter(deadline: .now() + .milliseconds(Self.sweepIntervalMs)) { [weak self] in
            self?.runSweepTick()
        }
    }

    /// Reassembly expiry and the idle-outgoing-link rule (spec 3.3, 6.3).
    private func sweep() {
        let now = nowMs()
        for link in allLinks() {
            let expired = link.reassembler.sweep(nowMs: now)
            if expired > 0 {
                log(.rxDrop, [("link", link.handle), ("reason", "set_expired"), ("streak", String(malformedGuard.streak(link.identifier.uuidString)))])
            }
            if link.isOutgoing, link.state == .ready, now - link.lastActivityMs > Self.idleOutgoingMs {
                disconnect(link, reason: "timeout")
            }
        }
    }

    // MARK: - ANNOUNCE

    private func buildAnnouncePacket() -> MeshPacket {
        let neighbors: [String] = Array(Set(writableLinks().compactMap { $0.nodeHex })).sorted().prefix(MeshAnnounce.maxNeighbors).map { $0 }
        let announce = MeshAnnounce(
            nodeIdHex: localNodeId.hex,
            identityFingerprintHex: localNodeId.hex,
            neighborNodeIdsHex: neighbors
        )
        // Wrapped with MeshDiscoveryCipher (an app-recognition boundary, not a
        // secret). Force-unwraps: AES-GCM with the fixed key cannot fail on
        // this input, and the payload is far below the packet limit.
        let encryptedPayload = MeshDiscoveryCipher.encrypt(announce.encode())!
        return try! MeshPacket(
            type: .announce, senderId: localNodeId, recipientId: .broadcast,
            timestampMs: nowMs(), payload: encryptedPayload
        )
    }

    private func sendAnnounce(on link: Link) {
        guard isWritable(link) else { return }
        let packet = buildAnnouncePacket()
        let bytes = packet.encode()
        let neighborCount = min(linkedNodeCount(), MeshAnnounce.maxNeighbors)
        let handle = link.handle
        let ph = MeshLog.payloadHash(packet.payload)
        transmit(bytes, ph: ph, links: [link], chosen: nil) { [weak self] summary in
            let ok = summary.okLinks > 0
            self?.log(.annTx, [("link", handle), ("nbrs", String(neighborCount)), ("bytes", String(bytes.count)), ("ok", MeshLog.flag(ok))])
        }
    }

    // MARK: - Sending

    private func sendLocked(_ packet: MeshPacket, preferredNextHop: MeshNodeId?, completion: @escaping (MeshSendReport) -> Void) {
        guard active else {
            completion(MeshSendReport(result: .failed("antenna_off"), links: 0, okLinks: 0))
            return
        }
        let bytes = packet.encode()
        let ph = MeshLog.payloadHash(packet.payload)
        let typeToken = String(packet.type.rawValue)
        let isBroadcast = packet.recipientId == .broadcast
        var route = "flood"
        var links: [Link] = []
        var chosen: Link?
        if !isBroadcast, let direct = directLink(to: packet.recipientId.hex) {
            // A direct link to the recipient always wins over a next-hop hint.
            route = "direct"
            chosen = direct
            links = [direct]
        } else if !isBroadcast, let hint = preferredNextHop, hint != packet.recipientId, let hop = directLink(to: hint.hex) {
            // The announced topology says the hint reaches the recipient. The ANNOUNCE does not say whether a
            // peer relays (its mode is not on the wire), so a hint that does not is only found out by its absence.
            route = "direct"
            chosen = hop
            links = [hop]
        } else {
            links = floodLinks(excluding: nil)
        }
        guard !links.isEmpty else {
            log(.tx, [("ph", ph), ("type", typeToken), ("bytes", String(bytes.count)), ("route", route), ("links", "0"), ("okLinks", "0"),
                      ("frames", "0"), ("l", "0"), ("result", "queued"), ("reason", "no_links"), ("ms", "0")])
            completion(MeshSendReport(result: .queued("no_links"), links: 0, okLinks: 0))
            return
        }
        let isDirect = route == "direct"
        transmit(bytes, ph: ph, links: links, chosen: chosen) { [weak self] summary in
            let report = Self.report(for: summary, direct: isDirect)
            var resultToken = "sent"
            var reasonToken = "none"
            if case .failed(let reason) = report.result {
                resultToken = "failed"
                reasonToken = reason
            }
            self?.log(.tx, [("ph", ph), ("type", typeToken), ("bytes", String(bytes.count)), ("route", route),
                            ("links", String(summary.links)), ("okLinks", String(summary.okLinks)),
                            ("frames", String(summary.frames)), ("l", String(summary.minLimit)),
                            ("result", resultToken), ("reason", reasonToken), ("ms", String(summary.elapsedMs))])
            completion(report)
        }
    }

    /// Spec 10.1: a direct send succeeds only if the packet was accepted on the chosen link; a flood succeeds if it
    /// was accepted on at least one.
    private static func report(for summary: TransmitSummary, direct: Bool) -> MeshSendReport {
        let accepted = direct ? summary.chosenOk : summary.okLinks > 0
        if accepted {
            return MeshSendReport(result: direct ? .sentDirect : .sentViaRelay, links: summary.links, okLinks: summary.okLinks)
        }
        let reason = summary.failure?.rawValue ?? "write_failed"
        return MeshSendReport(result: .failed(reason), links: summary.links, okLinks: summary.okLinks)
    }

    /// Splits `bytes` for every link (each with its own value limit), queues one set per link, and calls
    /// `completion` once, after every set finished or failed.
    private func transmit(
        _ bytes: Data, ph: String, links: [Link], chosen: Link?,
        completion: @escaping (TransmitSummary) -> Void
    ) {
        let started = nowMs()
        var summary = TransmitSummary()
        summary.links = links.count
        summary.minLimit = Int.max
        var pending = links.count
        let chosenHandle = chosen?.handle

        func finishOne(_ link: Link, failure: MeshFrameFailure?) {
            pending -= 1
            if failure == nil {
                summary.okLinks += 1
                if link.handle == chosenHandle { summary.chosenOk = true }
            } else if summary.failure == nil {
                summary.failure = failure
            }
            if pending == 0 {
                summary.elapsedMs = Int(nowMs() - started)
                if summary.minLimit == Int.max { summary.minLimit = 0 }
                completion(summary)
            }
        }

        for link in links {
            let limit = valueLimit(of: link)
            summary.minLimit = min(summary.minLimit, limit)
            let setId = MeshLinkFraming.randomSetId()
            switch MeshLinkFraming.split(bytes, valueLimit: limit, setId: setId) {
            case .failure(let error):
                let reason: MeshFrameFailure = (error == .tooManyFrames) ? .tooManyFrames : .tooBig
                log(.txFrameFail, [("link", link.handle), ("ph", ph), ("idx", "0"), ("total", "0"), ("reason", reason.rawValue)])
                finishOne(link, failure: reason)
            case .success(let frames):
                summary.frames = max(summary.frames, frames.count)
                let job = SendJob(frames: frames, ph: ph) { failure in
                    finishOne(link, failure: failure)
                }
                link.jobs.append(job)
                pump(link)
            }
        }
    }

    /// `L` of a link, re-read for every packet.
    private func valueLimit(of link: Link) -> Int {
        if link.isOutgoing {
            guard let peripheral = link.peripheral else { return 0 }
            return peripheral.maximumWriteValueLength(for: .withoutResponse)
        }
        return link.central?.maximumUpdateValueLength ?? 0
    }

    // MARK: - Per-link frame sender

    private func pump(_ link: Link) {
        guard link.activeJob == nil, !link.jobs.isEmpty else { return }
        let job = link.jobs.removeFirst()
        link.activeJob = job
        let step = job.sender.advance()
        perform(step, job: job, link: link)
    }

    private func perform(_ step: MeshFrameSetSender.Step, job: SendJob, link: Link) {
        switch step {
        case .send(let frame):
            emit(frame, job: job, link: link)
        case .finished:
            finish(job, link: link, failure: nil, frameIndex: 0)
        case .failed(let reason, let frameIndex):
            finish(job, link: link, failure: reason, frameIndex: frameIndex)
        }
    }

    private func finish(_ job: SendJob, link: Link, failure: MeshFrameFailure?, frameIndex: Int) {
        job.frameTimer?.cancel()
        job.frameTimer = nil
        if link.activeJob === job { link.activeJob = nil }
        if let failure {
            log(.txFrameFail, [("link", link.handle), ("ph", job.ph), ("idx", String(frameIndex)),
                               ("total", String(job.sender.frameCount)), ("reason", failure.rawValue)])
        }
        job.completion(failure)
        pump(link)
    }

    private func armFrameTimer(_ job: SendJob, link: Link) {
        job.frameTimer?.cancel()
        job.frameSequence += 1
        let sequence = job.frameSequence
        let work = DispatchWorkItem { [weak self, weak link] in
            guard let self, let link, link.activeJob === job, job.frameSequence == sequence else { return }
            let reason: MeshFrameFailure = job.waitingForReady ? .notReady : .timeout
            if link.isOutgoing, !link.useWriteWithoutResponse, !job.waitingForReady {
                link.staleConfirmations += 1
            }
            let step = job.sender.timedOut(reason: reason)
            self.perform(step, job: job, link: link)
        }
        job.frameTimer = work
        bleQueue.asyncAfter(deadline: .now() + .milliseconds(MeshFrameSetSender.frameTimeoutMs), execute: work)
    }

    /// Puts one frame on the air. The confirmation arrives through `frameConfirmed`.
    private func emit(_ frame: Data, job: SendJob, link: Link) {
        armFrameTimer(job, link: link)
        job.waitingForReady = false
        if link.isOutgoing {
            guard let peripheral = link.peripheral, let characteristic = link.characteristic,
                  peripheral.state == .connected else {
                resolve(job, link: link) { $0.linkLost() }
                return
            }
            // A peer may renegotiate to a smaller value: a frame that no longer fits is refused, never
            // turned into a long write.
            let limit = peripheral.maximumWriteValueLength(for: .withoutResponse)
            guard frame.count <= limit else {
                resolve(job, link: link) { $0.timedOut(reason: .tooBig) }
                return
            }
            if link.useWriteWithoutResponse {
                if peripheral.canSendWriteWithoutResponse {
                    peripheral.writeValue(frame, for: characteristic, type: .withoutResponse)
                    bleQueue.async { [weak self, weak link] in
                        guard let self, let link else { return }
                        self.frameConfirmed(link, job: job, success: true)
                    }
                } else {
                    job.waitingForReady = true // peripheralIsReady(toSendWriteWithoutResponse:) resumes
                }
            } else {
                peripheral.writeValue(frame, for: characteristic, type: .withResponse)
            }
            return
        }
        guard let central = link.central, let characteristic = notifyCharacteristic, let manager = peripheralManager else {
            resolve(job, link: link) { $0.linkLost() }
            return
        }
        let limit = central.maximumUpdateValueLength
        guard frame.count <= limit else {
            resolve(job, link: link) { $0.timedOut(reason: .tooBig) }
            return
        }
        if manager.updateValue(frame, for: characteristic, onSubscribedCentrals: [central]) {
            bleQueue.async { [weak self, weak link] in
                guard let self, let link else { return }
                self.frameConfirmed(link, job: job, success: true)
            }
        } else {
            job.waitingForReady = true // peripheralManagerIsReady(toUpdateSubscribers:) retries this frame
        }
    }

    private func resolve(_ job: SendJob, link: Link, _ transition: (inout MeshFrameSetSender) -> MeshFrameSetSender.Step) {
        let step = transition(&job.sender)
        perform(step, job: job, link: link)
    }

    private func frameConfirmed(_ link: Link, job: SendJob, success: Bool) {
        guard link.activeJob === job, !job.sender.isTerminal else { return }
        job.frameTimer?.cancel()
        if success { link.lastActivityMs = nowMs() }
        let step = job.sender.confirmed(success: success)
        perform(step, job: job, link: link)
    }

    /// Re-sends the frame that was waiting for the radio to be ready again.
    private func resumeWaiting(_ link: Link) {
        guard let job = link.activeJob, job.waitingForReady, !job.sender.isTerminal else { return }
        job.waitingForReady = false
        let step = job.sender.advance()
        perform(step, job: job, link: link)
    }

    private func failJobs(of link: Link, frameFailure: MeshFrameFailure) {
        // Queued sets first, so failing the active one cannot start the next.
        let queued = link.jobs
        link.jobs.removeAll()
        if let job = link.activeJob {
            let step: MeshFrameSetSender.Step
            if frameFailure == .linkLost {
                step = job.sender.linkLost()
            } else {
                step = job.sender.timedOut(reason: frameFailure)
            }
            perform(step, job: job, link: link)
        }
        for job in queued {
            job.completion(frameFailure)
        }
    }

    // MARK: - Receive, reassembly, relay

    private func isBlocked(_ identifier: UUID) -> Bool {
        malformedGuard.isBlocked(identifier.uuidString, nowMs: nowMs())
    }

    private func onFrameReceived(on link: Link, frame: Data) {
        let now = nowMs()
        guard !malformedGuard.isBlocked(link.identifier.uuidString, nowMs: now) else { return }
        let outcome = link.reassembler.offer(frame, nowMs: now)
        if outcome.expiredSets > 0 {
            log(.rxDrop, [("link", link.handle), ("reason", "set_expired"), ("streak", String(malformedGuard.streak(link.identifier.uuidString)))])
        }
        if outcome.evictedSets > 0 {
            log(.rxDrop, [("link", link.handle), ("reason", "set_evicted"), ("streak", String(malformedGuard.streak(link.identifier.uuidString)))])
        }
        switch outcome.status {
        case .pending, .duplicateIgnored:
            return
        case .malformed(let reason):
            registerMalformed(link, reason: reason.rawValue)
        case .complete(let bytes):
            link.lastActivityMs = now
            switch MeshPacket.decodeStrict(bytes) {
            case .failure:
                registerMalformed(link, reason: "decode")
            case .success(let packet):
                handlePacket(on: link, packet: packet, frames: outcome.completedFrames, bytes: bytes.count)
            }
        }
    }

    private func registerMalformed(_ link: Link, reason: String) {
        let key = link.identifier.uuidString
        let streakBefore = malformedGuard.streak(key) + 1
        log(.rxDrop, [("link", link.handle), ("reason", reason), ("streak", String(streakBefore))])
        guard let streak = malformedGuard.registerMalformed(key, nowMs: nowMs()) else { return }
        log(.guardBlock, [("link", link.handle), ("streak", String(streak)), ("ms", String(MeshMalformedGuard.blockMs))])
        // Where the platform allows it the link is closed (a link we opened); for a central that opened to us
        // the app can only ignore its frames and never write to it.
        disconnect(link, reason: "blocked")
    }

    private func handlePacket(on link: Link, packet: MeshPacket, frames: Int, bytes: Int) {
        let key = link.identifier.uuidString
        if packet.type == .announce {
            handleAnnounce(on: link, packet: packet)
            return
        }
        malformedGuard.registerWellFormed(key)
        let ph = MeshLog.payloadHash(packet.payload)
        let typeToken = String(packet.type.rawValue)
        guard packet.type == .data || packet.type == .receipt else {
            // FRAGMENT and ACK are reserved: receivers drop them.
            log(.rx, [("link", link.handle), ("ph", ph), ("type", typeToken), ("bytes", String(bytes)),
                      ("frames", String(frames)), ("forUs", "0"), ("relay", "0")])
            return
        }
        let forUs = packet.recipientId == localNodeId || packet.recipientId == .broadcast
        if forUs {
            let fromNode: MeshNodeId = (link.nodeHex.flatMap { try? MeshNodeId(hex: $0) }) ?? packet.senderId
            let inbound = MeshInboundPacket(packet: packet, fromNodeId: fromNode, rssi: link.rssi)
            delegate?.meshTransport(self, didReceive: inbound)
        }
        let relayed = relayIfWanted(packet, arrivedOn: link, ph: ph)
        log(.rx, [("link", link.handle), ("ph", ph), ("type", typeToken), ("bytes", String(bytes)),
                  ("frames", String(frames)), ("forUs", MeshLog.flag(forUs)), ("relay", MeshLog.flag(relayed))])
    }

    private func handleAnnounce(on link: Link, packet: MeshPacket) {
        guard let opened = MeshDiscoveryCipher.decrypt(packet.payload) else {
            registerMalformed(link, reason: "ann_decrypt")
            return
        }
        guard let announce = MeshAnnounce.decode(opened), announce.nodeIdHex == packet.senderId.hex else {
            registerMalformed(link, reason: "ann_parse")
            return
        }
        // Only a fully valid ANNOUNCE counts as the link behaving.
        malformedGuard.registerWellFormed(link.identifier.uuidString)
        link.lastActivityMs = nowMs()
        var bound = false
        if announce.nodeIdHex != localNodeId.hex {
            // The ONLY place a link is bound to a node. The sender id of any other packet is its originator,
            // which for a relayed packet is not the device at the other end of this link.
            bound = link.nodeHex != announce.nodeIdHex
            link.nodeHex = announce.nodeIdHex
            announcedNeighborsByNode[announce.nodeIdHex] = Set(announce.neighborNodeIdsHex)
        }
        log(.annRx, [("link", link.handle), ("nh", MeshLog.nodeHash(announce.nodeIdHex)),
                     ("nbrs", String(announce.neighborNodeIdsHex.count)), ("bound", MeshLog.flag(bound))])
        recomputeAndNotifyPeers()
    }

    /// Applies the relay conditions (spec 9.2); returns whether the packet was forwarded.
    private func relayIfWanted(_ packet: MeshPacket, arrivedOn link: Link, ph: String) -> Bool {
        let decision = relayGate.decide(
            packet: packet, payloadHash: ph, linkKey: link.identifier.uuidString, localNodeId: localNodeId,
            mode: mode, linkedNodes: linkedNodeCount(), nowMs: nowMs()
        )
        let ttlToken = String(packet.ttl ?? 0)
        switch decision {
        case .skip(let reason):
            if let reason {
                log(.relay, [("ph", ph), ("ttl", ttlToken), ("p", "0"), ("fwd", "0"), ("okLinks", "0"), ("reason", reason.rawValue)])
            }
            return false
        case .dropped(let permille):
            log(.relay, [("ph", ph), ("ttl", ttlToken), ("p", String(permille)), ("fwd", "0"), ("okLinks", "0")])
            return false
        case .forward(let nextTTL, let permille):
            let targets = floodLinks(excluding: link)
            guard !targets.isEmpty else {
                log(.relay, [("ph", ph), ("ttl", ttlToken), ("p", String(permille)), ("fwd", "0"), ("okLinks", "0")])
                return false
            }
            let bytes = packet.withTTL(nextTTL).encode()
            let forwardCount = targets.count
            transmit(bytes, ph: ph, links: targets, chosen: nil) { [weak self] summary in
                self?.log(.relay, [("ph", ph), ("ttl", ttlToken), ("p", String(permille)),
                                   ("fwd", String(forwardCount)), ("okLinks", String(summary.okLinks))])
            }
            return true
        }
    }

    // MARK: - Peers

    /// One `MeshPeerInfo` per node, however many links reach it (an outgoing and an incoming link to the same device
    /// are common): the strongest RSSI of its links, connected if any of them is writable.
    private func recomputeAndNotifyPeers() {
        let now = nowMs()
        struct Accum {
            var rssi: Int?
            var connected = false
        }
        var byNode: [String: Accum] = [:]
        for link in allLinks() {
            guard let nodeHex = link.nodeHex else { continue }
            var acc = byNode[nodeHex] ?? Accum()
            if let candidate = link.rssi {
                acc.rssi = max(acc.rssi ?? Int.min, candidate)
            }
            if isWritable(link) { acc.connected = true }
            byNode[nodeHex] = acc
        }
        var peers: Set<MeshPeerInfo> = []
        for (nodeHex, acc) in byNode {
            guard let nodeId = try? MeshNodeId(hex: nodeHex) else { continue }
            let neighborHexes: Set<String> = announcedNeighborsByNode[nodeHex] ?? []
            var neighbors: Set<MeshNodeId> = []
            for hex in neighborHexes {
                if let id = try? MeshNodeId(hex: hex) { neighbors.insert(id) }
            }
            peers.insert(MeshPeerInfo(
                nodeId: nodeId, lastSeenAtMs: now, rssi: acc.rssi,
                connected: acc.connected, announcedNeighbors: neighbors
            ))
        }
        notifyDelegatePeers(peers)
    }

    // MARK: - Link teardown

    /// Removes the link from every table, fails what it was sending, and logs `link.down`.
    private func tearDown(_ link: Link, reason: String, cancelConnection: Bool) {
        link.setupTimer?.cancel()
        link.setupTimer = nil
        if link.isOutgoing, link.state != .ready, reason != "stop" {
            let now = nowMs()
            failedSetupAtMs[link.identifier] = now
            if failedSetupAtMs.count > 64 {
                failedSetupAtMs = failedSetupAtMs.filter { now - $0.value < Self.redialSpacingMs }
            }
        }
        failJobs(of: link, frameFailure: .linkLost)
        if cancelConnection, let peripheral = link.peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        if link.isOutgoing {
            outgoing.removeValue(forKey: link.identifier)
        } else {
            incoming.removeValue(forKey: link.identifier)
        }
        relayGate.linkGone(link.identifier.uuidString)
        malformedGuard.linkGone(link.identifier.uuidString)
        let held = Int(nowMs() - link.createdAtMs)
        let finalReason = link.downReason ?? reason
        log(.linkDown, [("link", link.handle), ("reason", finalReason), ("heldMs", String(held))])
        if let nodeHex = link.nodeHex, !allLinks().contains(where: { $0.nodeHex == nodeHex }) {
            announcedNeighborsByNode.removeValue(forKey: nodeHex)
        }
    }

    /// Closes a link where the platform allows it: a link we opened is cancelled; a central that opened to us
    /// cannot be disconnected by the app, so it is dropped from the tables and its frames are ignored from now on.
    private func disconnect(_ link: Link, reason: String) {
        link.downReason = reason
        tearDown(link, reason: reason, cancelConnection: link.isOutgoing)
        recomputeAndNotifyPeers()
        restartScanSoon()
    }

    private func restartScanSoon() {
        guard active, mode.connectsOut else { return }
        bleQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            self?.restartScan()
        }
    }

    private func armSetupTimer(_ link: Link, afterMs: Int, reason: String) {
        link.setupTimer?.cancel()
        let work = DispatchWorkItem { [weak self, weak link] in
            guard let self, let link else { return }
            let stillPending = link.state != .ready
            guard stillPending, self.outgoing[link.identifier] === link else { return }
            self.disconnect(link, reason: reason)
        }
        link.setupTimer = work
        bleQueue.asyncAfter(deadline: .now() + .milliseconds(afterMs), execute: work)
    }

    // MARK: - Logging and delegate notification

    private func log(_ event: MeshLog.Event, _ fields: [(String, String)]) {
        MeshLog.emit(event, fields)
    }

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

    // MARK: - Incoming links (central opened a connection to our GATT server)

    /// The incoming link for `central`, created on first sight. At the cap, the oldest link that never subscribed and
    /// is older than 30 s makes room; otherwise the newcomer is refused (nil).
    private func incomingLink(for central: CBCentral) -> Link? {
        let identifier = central.identifier
        if let existing = incoming[identifier] {
            existing.central = central
            return existing
        }
        guard !isBlocked(identifier) else {
            log(.linkRefused, [("reason", "blocked"), ("role", "p")])
            return nil
        }
        if incoming.count >= Self.maxIncomingLinks {
            let now = nowMs()
            let stale = incoming.values
                .filter { !$0.subscribed && now - $0.createdAtMs > Self.unsubscribedEvictionMs }
                .min(by: { $0.createdAtMs < $1.createdAtMs })
            guard let stale else {
                log(.linkRefused, [("reason", "cap"), ("role", "p")])
                return nil
            }
            stale.downReason = "evicted"
            tearDown(stale, reason: "evicted", cancelConnection: false)
        }
        let link = Link(handle: linkHandle(outgoing: false), identifier: identifier, isOutgoing: false, nowMs: nowMs(), state: .ready)
        link.central = central
        incoming[identifier] = link
        log(.linkUp, [("link", link.handle), ("role", "p"), ("n", String(allLinks().count))])
        return link
    }

    private func markReady(_ link: Link) {
        if link.isOutgoing { link.state = .ready }
        link.setupTimer?.cancel()
        link.setupTimer = nil
        link.lastActivityMs = nowMs()
        let limit = valueLimit(of: link)
        log(.linkReady, [("link", link.handle), ("mtu", "0"), ("l", String(limit)), ("sub", MeshLog.flag(link.subscribed))])
    }
}

// MARK: - CBCentralManagerDelegate

extension BleMeshTransport: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            maybeStartScanning()
            setUpRestoredLinks()
            notifyDelegateRadioState(currentRadioState())
            log(.radio, [("state", "on"), ("mode", modeToken()), ("reason", "powered_on")])
        case .poweredOff, .unauthorized, .unsupported, .resetting:
            // CoreBluetooth invalidates every connection of a manager that is not powered on.
            for link in Array(outgoing.values) {
                tearDown(link, reason: "remote", cancelConnection: false)
            }
            outgoing.removeAll()
            recomputeAndNotifyPeers()
            if central.state != .resetting {
                notifyDelegateRadioState(.error("bluetooth_unavailable"))
                log(.radio, [("state", "error"), ("mode", modeToken()), ("reason", "bluetooth_unavailable")])
            }
        default:
            break
        }
    }

    /// State restoration: the system relaunched the app for a Bluetooth event and hands back the connections it kept.
    /// Nothing is started from here (the manager is not powered on yet): the links are only recorded, and set up from
    /// `centralManagerDidUpdateState(.poweredOn)`.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
        for peripheral in restored {
            let identifier = peripheral.identifier
            guard active, mode.connectsOut, outgoing[identifier] == nil, outgoing.count < Self.maxOutgoingLinks else {
                central.cancelPeripheralConnection(peripheral)
                continue
            }
            let link = Link(handle: linkHandle(outgoing: true), identifier: identifier, isOutgoing: true, nowMs: nowMs(), state: .connecting)
            link.peripheral = peripheral
            peripheral.delegate = self
            outgoing[identifier] = link
            restoredLinks.append(identifier)
        }
        if central.state == .poweredOn { setUpRestoredLinks() }
    }

    private func setUpRestoredLinks() {
        let identifiers = restoredLinks
        restoredLinks.removeAll()
        for identifier in identifiers {
            guard let link = outgoing[identifier], let peripheral = link.peripheral else { continue }
            if peripheral.state == .connected {
                log(.linkUp, [("link", link.handle), ("role", "c"), ("n", String(allLinks().count))])
                beginSetup(link)
            } else {
                armSetupTimer(link, afterMs: Self.connectTimeoutMs, reason: "timeout")
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard active, mode.connectsOut else { return }
        let identifier = peripheral.identifier
        if let existing = outgoing[identifier] {
            existing.rssi = RSSI.intValue
            return
        }
        guard !isBlocked(identifier) else { return }
        guard outgoing.count < Self.maxOutgoingLinks else { return }
        if let failedAt = failedSetupAtMs[identifier], nowMs() - failedAt < Self.redialSpacingMs { return }
        // Two phones may open a link to each other at the same time; both links are kept and senders prefer the
        // outgoing one (spec 3.3).
        let link = Link(handle: linkHandle(outgoing: true), identifier: identifier, isOutgoing: true, nowMs: nowMs(), state: .connecting)
        link.peripheral = peripheral
        link.rssi = RSSI.intValue
        peripheral.delegate = self
        outgoing[identifier] = link
        armSetupTimer(link, afterMs: Self.connectTimeoutMs, reason: "timeout")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let link = outgoing[peripheral.identifier] else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        log(.linkUp, [("link", link.handle), ("role", "c"), ("n", String(allLinks().count))])
        beginSetup(link)
    }

    /// Connected: discover the service and subscribe, all within the setup timeout.
    private func beginSetup(_ link: Link) {
        link.state = .settingUp
        armSetupTimer(link, afterMs: Self.setupTimeoutMs, reason: "timeout")
        link.peripheral?.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let link = outgoing[peripheral.identifier] else { return }
        tearDown(link, reason: "remote", cancelConnection: false)
        recomputeAndNotifyPeers()
        restartScanSoon()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let link = outgoing[peripheral.identifier] else { return }
        tearDown(link, reason: "remote", cancelConnection: false)
        recomputeAndNotifyPeers()
        restartScanSoon()
    }
}

// MARK: - CBPeripheralDelegate (we are the central; this is the remote peer)

extension BleMeshTransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let link = outgoing[peripheral.identifier] else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            disconnect(link, reason: "remote")
            return
        }
        peripheral.discoverCharacteristics([Self.characteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let link = outgoing[peripheral.identifier] else { return }
        let found = service.characteristics?.first(where: { $0.uuid == Self.characteristicUUID })
        guard error == nil, let characteristic = found else {
            disconnect(link, reason: "remote")
            return
        }
        let properties = characteristic.properties
        guard properties.contains(.notify) else {
            disconnect(link, reason: "remote")
            return
        }
        if properties.contains(.write) {
            link.useWriteWithoutResponse = false
        } else if properties.contains(.writeWithoutResponse) {
            link.useWriteWithoutResponse = true
        } else {
            disconnect(link, reason: "remote")
            return
        }
        link.characteristic = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = outgoing[peripheral.identifier] else { return }
        guard error == nil else {
            disconnect(link, reason: "remote")
            return
        }
        guard characteristic.isNotifying else { return }
        link.subscribed = true
        markReady(link)
        recomputeAndNotifyPeers()
        // Introduce ourselves as soon as the subscription is confirmed (spec 4.3), not after a fixed delay.
        sendAnnounce(on: link)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = outgoing[peripheral.identifier] else { return }
        guard error == nil, characteristic.uuid == Self.characteristicUUID, let value = characteristic.value else { return }
        onFrameReceived(on: link, frame: value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = outgoing[peripheral.identifier] else { return }
        if link.staleConfirmations > 0 {
            // The response to a write whose frame already timed out.
            link.staleConfirmations -= 1
            return
        }
        guard let job = link.activeJob else { return }
        frameConfirmed(link, job: job, success: error == nil)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let link = outgoing[peripheral.identifier] else { return }
        resumeWaiting(link)
    }
}

// MARK: - CBPeripheralManagerDelegate (we are the peripheral; GATT server role)

extension BleMeshTransport: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            maybeStartAdvertisingAndServer()
            adoptRestoredSubscribers()
            notifyDelegateRadioState(currentRadioState())
        case .poweredOff, .unauthorized, .unsupported, .resetting:
            restoredSubscribers.removeAll()
            for link in Array(incoming.values) {
                tearDown(link, reason: "remote", cancelConnection: false)
            }
            incoming.removeAll()
            // The GATT database does not survive a power cycle.
            notifyCharacteristic = nil
            serviceInstalled = false
            recomputeAndNotifyPeers()
            if peripheral.state != .resetting {
                notifyDelegateRadioState(.error("bluetooth_unavailable"))
            }
        default:
            break
        }
    }

    /// State restoration: reuse the service the system kept, and adopt the centrals that were subscribed to it.
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        guard let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] else { return }
        for service in services where service.uuid == Self.serviceUUID {
            let characteristic = service.characteristics?
                .compactMap { $0 as? CBMutableCharacteristic }
                .first(where: { $0.uuid == Self.characteristicUUID })
            guard let characteristic else { continue }
            notifyCharacteristic = characteristic
            serviceInstalled = true
            guard active else { continue }
            // Recorded only: announcing needs the manager powered on (peripheralManagerDidUpdateState).
            restoredSubscribers = characteristic.subscribedCentrals ?? []
            if peripheral.state == .poweredOn { adoptRestoredSubscribers() }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else {
            // Without this a GATT-add failure leaves the antenna silently stuck.
            notifyDelegateRadioState(.error("gatt_add_failed"))
            log(.radio, [("state", "error"), ("mode", modeToken()), ("reason", "gatt_add_failed")])
            return
        }
        serviceInstalled = true
        startAdvertisingNow()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        notifyDelegateRadioState(currentRadioState())
        if error == nil {
            log(.radio, [("state", "on"), ("mode", modeToken()), ("reason", "advertising")])
        } else {
            log(.radio, [("state", "error"), ("mode", modeToken()), ("reason", "advertise_failed")])
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        adoptSubscriber(central)
    }

    private func adoptRestoredSubscribers() {
        let subscribers = restoredSubscribers
        restoredSubscribers.removeAll()
        for subscriber in subscribers {
            adoptSubscriber(subscriber)
        }
    }

    /// A central subscribed (CCCD 0x0001): it is a live link, and we introduce ourselves at once (spec 4.3).
    private func adoptSubscriber(_ subscriber: CBCentral) {
        guard let link = incomingLink(for: subscriber) else { return }
        let wasSubscribed = link.subscribed
        link.subscribed = true
        guard !wasSubscribed else { return }
        markReady(link)
        recomputeAndNotifyPeers()
        sendAnnounce(on: link)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard let link = incoming[central.identifier] else { return }
        link.subscribed = false
        tearDown(link, reason: "remote", cancelConnection: false)
        recomputeAndNotifyPeers()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        // A non-zero offset marks a long write (Prepare/Execute Write): every value in the call is discarded and the
        // call is answered once, on the first request (spec 5).
        if requests.contains(where: { $0.offset != 0 }) {
            peripheral.respond(to: first, withResult: .invalidOffset)
            return
        }
        guard let link = incomingLink(for: first.central), !isBlocked(first.central.identifier) else {
            peripheral.respond(to: first, withResult: .insufficientResources)
            return
        }
        for request in requests {
            if let value = request.value {
                onFrameReceived(on: link, frame: value)
            }
        }
        // CoreBluetooth expects one response per call.
        peripheral.respond(to: first, withResult: .success)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        for link in Array(incoming.values) {
            resumeWaiting(link)
        }
    }
}
