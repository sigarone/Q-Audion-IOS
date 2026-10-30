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
/// ## Pause during a call on a Bluetooth audio route (spec 2.1)
/// While a call is active (any connected call on the device, `MeshCallDefinition`) and its audio uses a Bluetooth
/// device (`MeshAudioRoute`), scanning and advertising stop and no new outgoing link is opened; the links that exist
/// stay up and keep carrying ANNOUNCE and packets. The decision is `MeshBtCallPause`; this class is given the two
/// facts together (`setCallFacts`, from `MeshRuntime`, which reads the call state and the route on the main thread:
/// this class never reads the audio route, a read that can wait on the audio system does not belong on `bleQueue`)
/// and applies what the decision returns. It evaluates again whenever the facts arrive, when the app changes between
/// foreground and background and when Bluetooth powers on, asking `MeshRuntime` for fresh facts at those two moments
/// (`setCallFactsRequest`). The pause is not a radio state of its own: the antenna is still on, so
/// `currentRadioState()` keeps reporting the roles the mode runs.
///
/// ## Retry backoff (spec 3.5)
/// An outgoing attempt that fails before the first ANNOUNCE on its link puts the peripheral identifier into
/// `MeshConnectBackoff`; `didDiscover` skips an identifier whose backoff has not expired.
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

    private static let sweepIntervalMs: Int = 5_000
    private static let maxOutgoingLinks = 6
    private static let maxIncomingLinks = 8
    /// One connection beyond a cap may exist until it has announced (spec 3.3 / 3.4).
    private static let probationSlots = 1
    private static let connectTimeoutMs: Int = 10_000
    private static let setupTimeoutMs: Int = 10_000
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

    /// Spec 3.6: address -> (claimed node, remembered until) for outgoing links closed as a duplicate.
    private var redialMemory = MeshRedialMemory()
    /// Spec 3.4: centrals dropped as duplicates; the platform cannot close their link, so their frames are refused.
    private var inboundRefusals = MeshRefusalTable()
    private var collapseGuard = MeshCollapseGuard()
    private var evictionLimiter = MeshEvictionLimiter()
    private var evictionMemory = MeshEvictionMemory()
    /// Verified (address, node, key) triples, so a reconnect is trusted at once while its proof is pending (section 8.5).
    private var verifiedCache = MeshVerifiedCache()
    private let signProof: @Sendable (Data) -> (publicKey: Data, signature: Data)?
    private var annSummary = MeshAnnounceSummary(startMs: 0)
    private var txFailThrottle = MeshTxFailThrottle()
    private var malformedGuard = MeshMalformedGuard()
    private var relayGate = MeshRelayGate()
    private var announcedNeighborsByNode: [String: Set<String>] = [:]

    /// A connected call exists on the device (any app, cellular included); given by `MeshRuntime` together with
    /// `btRoute`, kept across stop() / start() (the owner gives fresh facts before every start).
    private var callActive = false
    /// The audio route has a Bluetooth input or output; given by `MeshRuntime`, which reads it on the main thread.
    /// Never read here: `bleQueue` must not wait on the audio system.
    private var btRoute = false
    /// Spec 2.1: when discovery is suspended. Reset whenever the antenna is turned off.
    private var callPause = MeshBtCallPause()
    /// Asks the owner to read the call and route facts again and send them through `setCallFacts`.
    private var callFactsRequest: (@Sendable () -> Void)?
    /// The re-evaluation that a rate-limited resume waits for.
    private var pauseRecheck: DispatchWorkItem?
    /// Spec 3.5: advertisers that did not answer, by peripheral identifier. Emptied whenever the antenna is turned off.
    private var connectBackoff = MeshConnectBackoff()

    /// Scanning, advertising and new outgoing links are suspended (spec 2.1).
    private var discoveryPaused: Bool { callPause.isPaused }

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
        /// When `nodeHex` was set; set once (spec 3.6).
        var boundAtMs: Int64 = 0
        /// Spec 3.6: a claimant the collapse guard refused to close: kept open but not a route.
        var unroutable = false
        /// The last time a validated DATA or RECEIPT packet arrived on this link (spec 3.6), 0 if never.
        var lastDataMs: Int64 = 0
        /// The challenge and proof state of this link (section 8.5).
        let proof = MeshLinkProofState()
        /// When the subscription was confirmed, 0 before (spec 3.3 / 3.4: no ANNOUNCE within 35 s closes the link).
        var subscribedAtMs: Int64 = 0
        /// When the last ANNOUNCE went out on this link, for the pacing of spec 8.4 (0: none yet).
        var lastAnnounceTxMs: Int64 = 0
        var rssi: Int?
        var lastActivityMs: Int64
        var reassembler = MeshLinkReassembler()
        var jobs: [SendJob] = []
        var activeJob: SendJob?
        var setupTimer: DispatchWorkItem?
        var downReason: String?
        /// A valid ANNOUNCE was received on this link; until then a link that goes down counts as a failed attempt
        /// (spec 3.5).
        var announceReceived = false
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

    /// `signProof` signs a message with this device's identity key and returns the public key with the signature (section
    /// 8.5); nil when the key cannot be read. It is called off `bleQueue` and nothing waits for it.
    init(localNodeId: MeshNodeId, signProof: @escaping @Sendable (Data) -> (publicKey: Data, signature: Data)? = { _ in nil }) {
        self.localNodeId = localNodeId
        self.signProof = signProof
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

    /// The clock of every link timer (bind time, activity, refusals, redial memory, collapse guard, pacing): monotonic and
    /// counting sleep (`CLOCK_MONOTONIC` on Darwin), so a wall-clock change cannot shorten or stretch them. Replaced by
    /// tests.
    var clockMs: () -> Int64 = { Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000) }

    private func nowMs() -> Int64 {
        clockMs()
    }

    /// Wall-clock milliseconds, for what leaves the process as a date: the packet timestamp and the time a peer was seen.
    private func wallMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Monotonic milliseconds, for the pause and the backoff: a wall-clock change must not shorten or stretch them.
    private func uptimeMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
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
        // Spec 2.1: a radio that starts during a call on a Bluetooth route starts paused, so decide before anything
        // is armed, from the facts the owner gave before start().
        evaluateCallPause()
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
    ///
    /// Called from the main thread (`MeshRuntime`), so nothing that runs on `bleQueue` may wait for the main thread or
    /// for the audio system, or this would deadlock: the delegate callbacks and `callFactsRequest` hop to the main
    /// thread asynchronously, and the audio route and the call list are read on the main thread only.
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
        redialMemory = MeshRedialMemory()
        evictionMemory = MeshEvictionMemory()
        inboundRefusals = MeshRefusalTable()
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
        // Antenna off: the pause (which never brings anything back on its own) and the backoff table (spec 3.5) go.
        // `callActive` and `btRoute` stay: they are facts the owner gives, and it gives fresh ones before a later start.
        pauseRecheck?.cancel()
        pauseRecheck = nil
        callPause.reset()
        connectBackoff.removeAll()
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
        // Spec 2.1: a call or a route change may have gone unnoticed while the process was suspended. Ask the owner for
        // fresh facts (they arrive through `setCallFacts`) and decide with the ones known now, before the scan is re-armed
        // (a scan is not re-armed while discovery is paused).
        requestCallFacts()
        evaluateCallPause()
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

    // MARK: - Pause during a call on a Bluetooth audio route (spec 2.1)

    /// The two facts of the pause, read together by the owner on the main thread: a connected call exists on the device
    /// (`MeshCallDefinition`) and the audio route has a Bluetooth input or output. Safe before `start()` and after
    /// `stop()`: the values are kept and decide the next start. Not part of `MeshTransport`: only `MeshRuntime`, which
    /// owns this concrete type, calls it.
    func setCallFacts(callActive: Bool, btRoute: Bool) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.callActive = callActive
            self.btRoute = btRoute
            self.evaluateCallPause()
        }
    }

    /// What `MeshRuntime` gives so this class can ask for fresh facts: it reads them on the main thread and answers
    /// through `setCallFacts`. Set before `start()`; the closure only hops to the main thread.
    func setCallFactsRequest(_ request: @escaping @Sendable () -> Void) {
        bleQueue.async { [weak self] in
            self?.callFactsRequest = request
        }
    }

    /// Asks the owner for fresh facts (answered asynchronously, on `bleQueue`, through `setCallFacts`).
    private func requestCallFacts() {
        callFactsRequest?()
    }

    /// Feeds the two facts to `MeshBtCallPause` and applies its decision. Does nothing while the antenna is off:
    /// a pause can end only while the antenna is on, so it can never switch on an antenna that is off for consent,
    /// the kill switch or the user's choice.
    private func evaluateCallPause() {
        guard active else { return }
        pauseRecheck?.cancel()
        pauseRecheck = nil
        let decision = callPause.evaluate(callActive: callActive, btRoute: btRoute, nowMs: uptimeMs())
        switch decision.action {
        case .keep:
            break
        case .pause:
            applyPause()
        case .resume(let reason, let pausedMs):
            applyResume(reason: reason, pausedMs: pausedMs)
        }
        if let delayMs = decision.recheckInMs {
            // The route flipped back and forth: the resume waits for the rest of the 5 s interval.
            let work = DispatchWorkItem { [weak self] in
                self?.pauseRecheck = nil
                self?.evaluateCallPause()
            }
            pauseRecheck = work
            bleQueue.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: work)
        }
    }

    /// Stops scanning and advertising and gives up the attempts that have not connected yet. Established links, their
    /// ANNOUNCE loop and their traffic are left alone.
    private func applyPause() {
        log(.radioPause, [("reason", MeshBtCallPause.pauseReason)])
        central?.stopScan()
        peripheralManager?.stopAdvertising()
        // A connection that is still being opened is a new outgoing link: cancel it (not a failure, so no backoff).
        // One that is already connected and setting up is let finish.
        for link in Array(outgoing.values) where link.state == .connecting && link.peripheral?.state != .connected {
            disconnect(link, reason: "stop")
        }
        notifyDelegateRadioState(currentRadioState())
    }

    /// Starts discovery again, in the roles the mode runs.
    private func applyResume(reason: MeshBtCallPause.ResumeReason, pausedMs: Int64) {
        log(.radioResume, [("reason", reason.rawValue), ("pausedMs", String(pausedMs))])
        maybeStartScanning()
        maybeStartAdvertisingAndServer()
        notifyDelegateRadioState(currentRadioState())
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
        if link.unroutable { return false }
        if link.isOutgoing {
            guard link.state == .ready, let peripheral = link.peripheral else { return false }
            return peripheral.state == .connected && link.characteristic != nil
        }
        return link.subscribed && link.central != nil
    }

    private func writableLinks() -> [Link] {
        allLinks().filter { isWritable($0) }
    }

    private func candidate(of link: Link) -> MeshLinkCandidate {
        MeshLinkCandidate(key: (link.isOutgoing ? "w:" : "n:") + link.identifier.uuidString, central: link.isOutgoing,
                          address: link.identifier.uuidString, subscribed: link.subscribed,
                          lastActivityMs: link.lastActivityMs, boundAtMs: link.boundAtMs > 0 ? link.boundAtMs : link.createdAtMs,
                          lastDataMs: link.lastDataMs, nodeHex: link.nodeHex, verified: link.proof.verifiedAt(nowMs()),
                          failed: link.proof.state == .failed)
    }

    private func links(forKeys keys: [String]) -> [Link] {
        let wanted = Set(keys)
        return allLinks().filter { wanted.contains(candidate(of: $0).key) }
            .sorted { ($0.isOutgoing ? 0 : 1) < ($1.isOutgoing ? 0 : 1) }
    }

    /// The writable links a direct send to `nodeHex` goes to: every healthy one, up to four (spec 3.6), the outgoing one first. The node id of
    /// a link is only a claim, and the receiver drops a copy it already has by message id.
    private func directLinks(to nodeHex: String) -> [Link] {
        let candidates = writableLinks().filter { $0.nodeHex == nodeHex }.map { candidate(of: $0) }
        return links(forKeys: MeshNodeLinkPolicy.fanOut(links: candidates, nowMs: nowMs()))
    }

    /// Where a flood goes (spec 9.2): every link not yet bound to a node, and up to four links of each node. The link the
    /// packet arrived on, and all links of the node it came from, are left out.
    private func floodLinks(excluding excluded: Link?, excludingNode: String? = nil) -> [Link] {
        let candidates = writableLinks().map { candidate(of: $0) }
        let keys = MeshNodeLinkPolicy.floodTargets(
            links: candidates, excludingKey: excluded.map { candidate(of: $0).key }, excludingNode: excludingNode, nowMs: nowMs()
        )
        return links(forKeys: keys)
    }

    /// Spec 3.3 / 3.4: the slots of a role are over the cap by the probation slot, and `newcomer` has just announced. Only
    /// now may a link make room, and only one per role per 30 s: an excluded link first, then the one that carried no
    /// validated data for the longest time, never the newcomer and never the only healthy link to a node. With no victim
    /// the newcomer itself goes.
    private func makeRoom(for newcomer: Link) {
        let centralRole = newcomer.isOutgoing
        let count = centralRole ? outgoing.count : incoming.count
        let cap = centralRole ? Self.maxOutgoingLinks : Self.maxIncomingLinks
        guard count > cap else { return }
        let now = nowMs()
        let all = allLinks().map { candidate(of: $0) }
        var victim: Link?
        if MeshNodeLinkPolicy.canTriggerEviction(newcomer: candidate(of: newcomer)) {
            let pool = centralRole ? Array(outgoing.values) : Array(incoming.values)
            var chosen = pool.first(where: { $0.unroutable && $0 !== newcomer && $0.nodeHex != newcomer.nodeHex })
            if chosen == nil,
               let key = MeshNodeLinkPolicy.evictionVictim(links: all, centralRole: centralRole,
                                                           excludingKey: candidate(of: newcomer).key, nowMs: now) {
                chosen = pool.first(where: { candidate(of: $0).key == key })
            }
            if chosen != nil, evictionLimiter.allow(centralRole: centralRole, nowMs: now) { victim = chosen }
        }
        let target = victim ?? newcomer
        target.downReason = "evicted"
        if target.isOutgoing {
            // An evicted address is not dialled again at once: it would be bound and evicted in a loop (spec 3.3).
            evictionMemory.note(target.identifier.uuidString, nowMs: now)
            disconnect(target, reason: "evicted")
        } else {
            // The same for a central that connects to us (spec 3.4).
            let wait = max(MeshLinkTiming.evictRefuseMs, evictionMemory.note(target.identifier.uuidString, nowMs: now))
            inboundRefusals.refuse(target.identifier.uuidString, untilMs: now + wait)
            tearDown(target, reason: "evicted", cancelConnection: false)
            recomputeAndNotifyPeers()
        }
    }

    private func linkedNodeCount() -> Int {
        Set(writableLinks().compactMap { $0.nodeHex }).count
    }

    // MARK: - Central role (scan + connect out)

    private func maybeStartScanning() {
        guard active, !discoveryPaused, mode.connectsOut, let central, central.state == .poweredOn else { return }
        let options: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: options)
    }

    private func restartScan() {
        guard active, !discoveryPaused, mode.connectsOut, let central, central.state == .poweredOn else { return }
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
        // Spec 2.1: no advertising while discovery is paused; the GATT service itself stays installed.
        guard !discoveryPaused else { return }
        // Connectable, the service UUID only: no name, no manufacturer data.
        let data: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]]
        peripheralManager?.startAdvertising(data)
    }

    // MARK: - Periodic work

    private func scheduleAnnounceLoop() {
        guard !announceScheduled else { return }
        announceScheduled = true
        annSummary = MeshAnnounceSummary(startMs: nowMs())
        runAnnounceTick()
    }

    private func runAnnounceTick() {
        guard active else {
            announceScheduled = false
            return
        }
        // Spec 8.4: one link per tick, the most overdue first, so the links are not all announced at one instant.
        let now = nowMs()
        var last: [String: Int64] = [:]
        var byKey: [String: Link] = [:]
        for link in writableLinks() where link.lastAnnounceTxMs != 0 {
            let key = (link.isOutgoing ? "w:" : "n:") + link.identifier.uuidString
            last[key] = link.lastAnnounceTxMs
            byKey[key] = link
        }
        if let key = MeshAnnouncePacer.next(lastSentMs: last, nowMs: now), let link = byKey[key] {
            sendAnnounce(on: link, intro: false)
        }
        let boundLinks = allLinks().filter { $0.nodeHex != nil }
        annSummary.flushIfDue(nowMs: now, links: allLinks().count, verified: boundLinks.filter { $0.proof.verifiedAt(now) }.count,
                              unverified: boundLinks.filter { !$0.proof.verifiedAt(now) }.count)
        inboundRefusals.prune(nowMs: now)
        bleQueue.asyncAfter(deadline: .now() + .milliseconds(Int(MeshLinkTiming.announceTickMs))) { [weak self] in
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
            // Spec 3.3 / 3.4: a link that subscribed and has not announced within 35 s is closed, so it cannot hold a slot.
            if MeshNodeLinkPolicy.unboundExpired(subscribedAtMs: link.subscribedAtMs, nodeHex: link.nodeHex, nowMs: now) {
                disconnect(link, reason: "timeout")
                continue
            }
            // Spec 3.4: an incoming link that never subscribed is released after 30 s, also below the cap.
            if !link.isOutgoing, !link.subscribed, now - link.createdAtMs > Self.unsubscribedEvictionMs {
                link.downReason = "evicted"
                tearDown(link, reason: "evicted", cancelConnection: false)
                continue
            }
            // Spec 3.3 / 3.4: the same idle rule for both roles.
            let live = link.isOutgoing ? link.state == .ready : link.subscribed
            if live, now - link.lastActivityMs > MeshLinkTiming.linkIdleTimeoutMs {
                disconnect(link, reason: "timeout")
            }
        }
    }

    // MARK: - ANNOUNCE

    private func buildAnnouncePacket(challenge: Data, peerVerified: Bool) -> MeshPacket {
        let neighbors: [String] = Array(Set(writableLinks().compactMap { $0.nodeHex })).sorted().prefix(MeshAnnounce.maxNeighbors).map { $0 }
        let announce = MeshAnnounce(
            nodeIdHex: localNodeId.hex,
            identityFingerprintHex: localNodeId.hex,
            neighborNodeIdsHex: neighbors,
            challengeHex: challenge.map { String(format: "%02x", $0) }.joined(),
            peerVerified: peerVerified
        )
        // Wrapped with MeshDiscoveryCipher (an app-recognition boundary, not a
        // secret). Force-unwraps: AES-GCM with the fixed key cannot fail on
        // this input, and the payload is far below the packet limit.
        let encryptedPayload = MeshDiscoveryCipher.encrypt(announce.encode())!
        return try! MeshPacket(
            type: .announce, senderId: localNodeId, recipientId: .broadcast,
            timestampMs: wallMs(), payload: encryptedPayload
        )
    }

    /// `intro`: the ANNOUNCE sent when the link becomes writable (spec 4.3), the only one that gets its own `ann.tx` line.
    private func sendAnnounce(on link: Link, intro: Bool = true) {
        guard isWritable(link) else { return }
        link.lastAnnounceTxMs = nowMs()
        let packet = buildAnnouncePacket(challenge: link.proof.nonce, peerVerified: link.proof.state == .verified)
        let bytes = packet.encode()
        let neighborCount = min(linkedNodeCount(), MeshAnnounce.maxNeighbors)
        let handle = link.handle
        let ph = MeshLog.payloadHash(packet.payload)
        transmit(bytes, ph: ph, links: [link], chosen: nil) { [weak self] summary in
            let ok = summary.okLinks > 0
            self?.annSummary.recordTx(ok: ok)
            if ok {
                link.proof.announceSent = true
                self?.maybeSendProof(on: link)
            }
            if intro {
                self?.log(.annTx, [("link", handle), ("nbrs", String(neighborCount)), ("bytes", String(bytes.count)), ("ok", MeshLog.flag(ok))])
            }
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
        let chosen: Link? = nil
        let directToRecipient = isBroadcast ? [] : directLinks(to: packet.recipientId.hex)
        let directToHint = (isBroadcast || preferredNextHop == nil || preferredNextHop == packet.recipientId)
            ? [] : directLinks(to: preferredNextHop!.hex)
        if !directToRecipient.isEmpty {
            // Every direct link to the recipient gets the frame, and it wins over a next-hop hint.
            route = "direct"
            links = directToRecipient
        } else if !directToHint.isEmpty {
            // The announced topology says the hint reaches the recipient. The ANNOUNCE does not say whether a
            // peer relays (its mode is not on the wire), so a hint that does not is only found out by its absence.
            route = "direct"
            links = directToHint
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
        let accepted = summary.okLinks > 0
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
            txFailThrottle.warn(link: link.handle, ph: job.ph, idx: frameIndex, total: job.sender.frameCount,
                                reason: failure.rawValue, nowMs: nowMs())
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
        // Section 8.5: a proof never counts as data, is never relayed and is never malformed for being wrong.
        if packet.type == .announceProof {
            handleProof(on: link, packet: packet)
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
        // Only a validated DATA or RECEIPT packet counts as data activity (spec 3.6).
        link.lastDataMs = nowMs()
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
        // Spec 3.6: a link keeps the node id its first ANNOUNCE named; another one closes the link, it never rebinds.
        guard MeshNodeLinkPolicy.mayBind(boundTo: link.nodeHex, announced: announce.nodeIdHex) else {
            if !link.isOutgoing {
                inboundRefusals.refuse(link.identifier.uuidString, untilMs: nowMs() + MeshLinkTiming.dupRedialSuppressMs)
            }
            disconnect(link, reason: "rebind")
            return
        }
        // Only a fully valid ANNOUNCE counts as the link behaving.
        malformedGuard.registerWellFormed(link.identifier.uuidString)
        link.lastActivityMs = nowMs()
        // Spec 3.5: the device at the other end answered, so its backoff history is over.
        link.announceReceived = true
        connectBackoff.clear(link.identifier.uuidString)
        annSummary.recordRx(node: announce.nodeIdHex, address: link.identifier.uuidString)
        var bound = false
        if announce.nodeIdHex != localNodeId.hex {
            // The ONLY place a link is bound to a node. The sender id of any other packet is its originator,
            // which for a relayed packet is not the device at the other end of this link.
            bound = link.nodeHex != announce.nodeIdHex
            if link.nodeHex == nil {
                link.nodeHex = announce.nodeIdHex
                link.boundAtMs = nowMs()
                makeRoom(for: link)
            }
            // Section 8.5: the peer's challenge, from the first ANNOUNCE that has one. A peer without one stays unverified.
            if let hex = announce.challengeHex {
                // `pv=1`: the peer verified us, so our proof need not be resent (it never changes routing).
                if announce.peerVerified { link.proof.peerVerifiedUs = true }
                if link.proof.peerNonce == nil {
                    var raw = Data(capacity: MeshAnnounceProof.nonceBytes)
                    var index = hex.startIndex
                    while index < hex.endIndex {
                        let next = hex.index(index, offsetBy: 2)
                        raw.append(UInt8(hex[index..<next], radix: 16) ?? 0)
                        index = next
                    }
                    link.proof.peerNonce = raw
                }
                // Later ANNOUNCEs resend the proof until the link is verified, at most once per period (8.5).
                maybeSendProof(on: link)
            }
            announcedNeighborsByNode[announce.nodeIdHex] = Set(announce.neighborNodeIdsHex)
        }
        // Spec 13: only a change of the link-to-node mapping gets its own line; the rest is counted in `ann.sum`.
        if bound {
            log(.annRx, [("link", link.handle), ("nh", MeshLog.nodeHash(announce.nodeIdHex)),
                         ("nbrs", String(announce.neighborNodeIdsHex.count)), ("bound", "1")])
        }
        if announce.nodeIdHex != localNodeId.hex { collapseLinks(to: announce.nodeIdHex) }
        recomputeAndNotifyPeers()
    }

    /// Section 8.5: answers the peer's challenge once its node is known and our own ANNOUNCE (with our challenge) went out on this
    /// link, and sends it again on later ANNOUNCEs (at most once per ANNOUNCE period) until the link is verified. A signature or
    /// a write that failed, a locked Keychain included, is retried the same way. The signature is made off `bleQueue` and
    /// nothing waits for it: the link works meanwhile.
    private func maybeSendProof(on link: Link) {
        guard let peerNonce = link.proof.peerNonce, let peerHex = link.nodeHex,
              link.proof.proofDue(nowMs: nowMs(), bound: true),
              let verifier = try? MeshNodeId(hex: peerHex),
              let message = MeshAnnounceProof.message(prover: localNodeId, verifier: verifier, proverNonce: link.proof.nonce,
                                                      verifierNonce: peerNonce, proverIsCentral: link.isOutgoing) else { return }
        link.proof.lastProofAttemptMs = nowMs()
        link.proof.proofSends += 1
        let sign = signProof
        DispatchQueue.global(qos: .utility).async { [weak self, weak link] in
            guard let signed = sign(message),
                  let payload = MeshAnnounceProof.payload(publicKey: signed.publicKey, signature: signed.signature) else { return }
            self?.bleQueue.async {
                guard let self, let link, self.active, self.isWritable(link),
                      let packet = try? MeshPacket(type: .announceProof, senderId: self.localNodeId, recipientId: verifier,
                                                   timestampMs: self.wallMs(), payload: payload) else { return }
                self.transmit(packet.encode(), ph: MeshLog.payloadHash(payload), links: [link], chosen: nil) { _ in }
            }
        }
    }

    /// Section 8.5: checks a proof received on `link`; the link is never closed for a proof that does not verify.
    private func handleProof(on link: Link, packet: MeshPacket) {
        guard let nodeHex = link.nodeHex, let peerNonce = link.proof.peerNonce, link.proof.state != .verified,
              let prover = try? MeshNodeId(hex: nodeHex) else { return }
        // At most 3 proofs are checked per link, and they go through the per-link rate limit of the relay path.
        // The cap of 3 comes first, so a proof beyond it does not use up the relay budget of the link.
        guard link.proof.takeVerifyAttempt(), relayGate.allowControl(linkKey: link.identifier.uuidString, nowMs: nowMs()) else { return }
        var result: MeshAnnounceProof.Result
        if packet.senderId.hex != nodeHex {
            result = .nodeMismatch
        } else {
            result = MeshAnnounceProof.verify(payload: packet.payload, prover: prover, verifier: localNodeId, proverNonce: peerNonce,
                                              verifierNonce: link.proof.nonce, proverIsCentral: !link.isOutgoing)
        }
        // The key is pinned per node id (8.5): a valid proof with another key than the pinned one is not accepted.
        let key = MeshAnnounceProof.publicKey(of: packet.payload)
        if result == .ok, let key, !verifiedCache.keyMatches(nodeHex, key: key, nowMs: nowMs()) {
            result = .keyChanged
        }
        if result == .ok {
            link.proof.state = .verified
            if let key { verifiedCache.put(nodeHex, key: key, nowMs: nowMs()) }
            // The ranking and the collapse change with a verified link.
            collapseLinks(to: nodeHex)
            recomputeAndNotifyPeers()
        } else {
            link.proof.state = .failed
            annSummary.recordBadSig()
            // One line per link, and no key, challenge or signature on it.
            if !link.proof.badLogged {
                link.proof.badLogged = true
                log(.annProof, [("link", link.handle), ("reason", result.rawValue)])
            }
        }
    }

    private func isHealthy(_ link: Link, at now: Int64) -> Bool {
        link.subscribed && now - link.lastActivityMs <= MeshLinkTiming.linkIdleTimeoutMs
    }

    private func hasHealthyLink(to node: String, at now: Int64) -> Bool {
        allLinks().contains(where: { $0.nodeHex == node && isHealthy($0, at: now) })
    }

    /// Spec 3.6: called when an ANNOUNCE has bound a link to `nodeHex` and when a link bound to it is gone. The node id is only
    /// a claim, so links with different identifiers are all kept and used. A link is closed only when it provably duplicates
    /// another on the same physical device (same identifier, opposite role), which the platform's own identifiers make rare.
    private func collapseLinks(to nodeHex: String) {
        let now = nowMs()
        // A link excluded earlier gets another chance.
        for link in allLinks() where link.nodeHex == nodeHex { link.unroutable = false }
        var byKey: [String: Link] = [:]
        var candidates: [MeshLinkCandidate] = []
        for link in allLinks() where link.nodeHex == nodeHex && link.subscribed {
            let entry = candidate(of: link)
            byKey[entry.key] = link
            candidates.append(entry)
        }
        let toClose = MeshNodeLinkPolicy.sameDeviceDuplicates(localHex: localNodeId.hex, peerHex: nodeHex, links: candidates)
        guard !toClose.isEmpty else { return }
        // The budget is per link key; a link the guard refuses to close stays open but is not a route.
        let plan = MeshNodeLinkPolicy.plan(toClose: toClose) { collapseGuard.allow($0, nowMs: now) }
        for key in plan.exclude { byKey[key]?.unroutable = true }
        for key in plan.close {
            guard let link = byKey[key] else { continue }
            if link.isOutgoing {
                redialMemory.note(link.identifier.uuidString, node: nodeHex, nowMs: now)
                disconnect(link, reason: "dup")
            } else {
                // The platform cannot close a central's link: drop it and refuse its frames for a while.
                inboundRefusals.refuse(link.identifier.uuidString, untilMs: now + MeshLinkTiming.dupRedialSuppressMs)
                link.downReason = "dup"
                tearDown(link, reason: "dup", cancelConnection: false)
            }
        }
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
            // A recipient that is directly linked gets it on its own links; otherwise every other node, up to four links
            // each, and none of the links of the node it came from.
            let recipient = (packet.recipientId == .broadcast || packet.recipientId == localNodeId) ? nil : packet.recipientId.hex
            let candidates = writableLinks().map { candidate(of: $0) }
            let keys = MeshNodeLinkPolicy.relayTargets(
                links: candidates, recipientNode: recipient, arrivalKey: candidate(of: link).key, arrivalNode: link.nodeHex,
                nowMs: nowMs()
            )
            let targets = links(forKeys: keys)
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
        let now = wallMs()
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
    /// - Parameter countsAsFailure: whether an outgoing link that never received an ANNOUNCE goes into the retry
    ///   backoff (spec 3.5). False where the link is lost for a reason that says nothing about the advertiser
    ///   (Bluetooth switched off).
    private func tearDown(_ link: Link, reason: String, cancelConnection: Bool, countsAsFailure: Bool = true) {
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
        // Spec 3.5: an outgoing attempt that ended (connect or setup timeout, a drop, a refusal) before the first
        // ANNOUNCE arrived on it failed, and the advertiser is left alone for a while.
        if countsAsFailure,
           MeshConnectBackoff.isFailedAttempt(outgoing: link.isOutgoing, announceReceived: link.announceReceived, reason: finalReason) {
            let failure = connectBackoff.recordFailure(link.identifier.uuidString, nowMs: uptimeMs())
            log(.connectBackoff, [("link", link.handle), ("failures", String(failure.failures)), ("waitMs", String(failure.waitMs))])
        }
        // Spec 3.6: the links left to the node are decided again at once, so a survivor becomes the keeper and routable.
        // Closes made by the collapse itself do not come back here.
        if active, let nodeHex = link.nodeHex, reason != "stop", finalReason != "dup", finalReason != "rebind" {
            collapseLinks(to: nodeHex)
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
        guard active, !discoveryPaused, mode.connectsOut else { return }
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
        var scanning = central?.isScanning ?? false
        var advertising = peripheralManager?.isAdvertising ?? false
        if discoveryPaused {
            // Spec 2.1: only discovery is suspended, the antenna and its mode are unchanged. Report the roles the mode
            // runs (where the managers are powered on), so nothing shows an antenna that is off for the length of a call.
            scanning = mode.connectsOut && central?.state == .poweredOn
            advertising = peripheralManager?.state == .poweredOn
        }
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
        if inboundRefusals.isRefused(identifier.uuidString, nowMs: nowMs()) { return nil }
        if incoming.count >= Self.maxIncomingLinks {
            let now = nowMs()
            // A connection that never subscribed yields to a newcomer after 30 s. No subscribed link is ever evicted by a
            // newcomer that has not yet announced: it gets the one probation slot, and `makeRoom` decides once it is bound.
            if let stale = incoming.values
                .filter({ !$0.subscribed && now - $0.createdAtMs > Self.unsubscribedEvictionMs })
                .min(by: { $0.createdAtMs < $1.createdAtMs }) {
                stale.downReason = "evicted"
                tearDown(stale, reason: "evicted", cancelConnection: false)
            } else if incoming.count >= Self.maxIncomingLinks + Self.probationSlots
                        || !MeshNodeLinkPolicy.probationUseful(
                            links: allLinks().map { candidate(of: $0) }, centralRole: false, nowMs: now,
                            limiterAllows: evictionLimiter.wouldAllow(centralRole: false, nowMs: now)) {
                log(.linkRefused, [("reason", "cap"), ("role", "p")])
                return nil
            }
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
            // Spec 2.1: Bluetooth was off or the process asleep, so a call or a route change may have gone unnoticed. Ask
            // for fresh facts and decide with the ones known now before anything is armed.
            requestCallFacts()
            evaluateCallPause()
            maybeStartScanning()
            setUpRestoredLinks()
            notifyDelegateRadioState(currentRadioState())
            log(.radio, [("state", "on"), ("mode", modeToken()), ("reason", "powered_on")])
        case .poweredOff, .unauthorized, .unsupported, .resetting:
            // CoreBluetooth invalidates every connection of a manager that is not powered on.
            for link in Array(outgoing.values) {
                tearDown(link, reason: "remote", cancelConnection: false, countsAsFailure: false)
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
            // Spec 2.1: a connection the system kept pending is a new outgoing link too; during a pause only the ones
            // that are already connected are adopted.
            let pendingWhilePaused = discoveryPaused && peripheral.state != .connected
            guard active, mode.connectsOut, !pendingWhilePaused, outgoing[identifier] == nil,
                  outgoing.count < Self.maxOutgoingLinks else {
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
        // Spec 2.1: a result that was already queued when the scan stopped must not open a new link.
        guard !discoveryPaused else { return }
        guard !isBlocked(identifier) else { return }
        if let failedAt = failedSetupAtMs[identifier], nowMs() - failedAt < Self.redialSpacingMs { return }
        // Spec 3.6: an address closed as a duplicate of node N is not dialled while a healthy link to N exists (longer each
        // time on the keeper's own device); once that link is gone the address is dialled like any other. An identifier that
        // already works as a healthy link in the other role is not dialled either, and no other address is skipped.
        let healthyNow = nowMs()
        if redialMemory.blocks(identifier.uuidString, nowMs: healthyNow, healthy: { hasHealthyLink(to: $0, at: healthyNow) }) { return }
        let healthyIdentifiers = Set(allLinks().filter { isHealthy($0, at: healthyNow) }.map { $0.identifier.uuidString })
        if MeshNodeLinkPolicy.dialBlockedByLink(target: identifier.uuidString, healthyLinkIdentifiers: healthyIdentifiers) { return }
        // Spec 3.5: an advertiser that did not answer is left alone until its backoff expires (silently: the
        // `connect.backoff` line was written when the backoff was set, not for every advertisement heard since).
        guard !connectBackoff.isBackedOff(identifier.uuidString, nowMs: uptimeMs()) else { return }
        // One probation slot lets a newcomer announce first; `makeRoom` decides then (spec 3.3).
        guard outgoing.count < Self.maxOutgoingLinks + Self.probationSlots else { return }
        if evictionMemory.blocks(identifier.uuidString, nowMs: healthyNow) { return }
        // Beyond the cap only a node that is not linked yet is worth the probation slot.
        if outgoing.count >= Self.maxOutgoingLinks {
            if let known = allLinks().first(where: { $0.identifier == identifier })?.nodeHex, hasHealthyLink(to: known, at: healthyNow) { return }
            // Only when there would be a link to make room (dry run), otherwise the newcomer could only evict itself.
            let candidates = allLinks().map { candidate(of: $0) }
            guard MeshNodeLinkPolicy.probationUseful(
                links: candidates, centralRole: true, nowMs: healthyNow,
                limiterAllows: evictionLimiter.wouldAllow(centralRole: true, nowMs: healthyNow)
            ) else { return }
        }
        // Two phones may open a link to each other at the same time; both links are used, and one is closed only when it
        // provably is the same device in the other role (spec 3.6).
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
        link.subscribedAtMs = nowMs()
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
        link.subscribedAtMs = nowMs()
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
