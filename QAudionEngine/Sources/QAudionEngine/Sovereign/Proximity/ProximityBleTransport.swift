#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import Foundation

// Proximity pairing v1 — CoreBluetooth transport (spec §7).
//
// Displayer = GATT peripheral advertising ONLY the per-session service UUID
// (the 16 sessionId bytes; no local name). Scanner = central that scans
// filtered on that UUID and connects to the first match. No characteristic
// requires link-layer encryption, so iOS never shows a pairing dialog; every
// security property lives in the protocol above this layer. This file only
// moves whole protocol messages (`type ‖ body`), fragmenting and
// reassembling them with `ProximityFraming` / `ProximityReassembler`.
//
// Concurrency (see the transport comment in ProximityPairingTypes.swift and
// the trailing comment of IOSEarbudGattProxy.swift): no actor annotations.
// Both managers are created with `queue: nil`, so every CoreBluetooth
// callback arrives on the main thread, and every client call is made on the
// main thread too. Data paths are fully synchronous (no Task / async hop that
// could reorder fragments). Callbacks are never fired re-entrantly from inside
// a client call: a failure detected there is reported with
// `DispatchQueue.main.async`, guarded by a generation counter so nothing fires
// after `shutdown()` / `cancel()`.

public enum ProximityBleUUIDs {

    /// The GATT service UUID for a session: the 16 sessionId bytes read as a
    /// 128-bit UUID. Nil unless `sessionId` is exactly 16 bytes.
    public static func serviceUUID(sessionId: Data) -> CBUUID? {
        let bytes: Data = Data(sessionId)
        guard bytes.count == ProximityPairing.sessionIdBytes else { return nil }
        return CBUUID(data: bytes)
    }

    /// Scanner → displayer, write with response.
    public static let toDisplayerCharacteristic: CBUUID = CBUUID(string: ProximityPairing.toDisplayerCharacteristicUUID)

    /// Displayer → scanner, notify.
    public static let toScannerCharacteristic: CBUUID = CBUUID(string: ProximityPairing.toScannerCharacteristicUUID)
}

/// Largest ATT attribute value (Core Spec Vol 3 Part F §3.2.9).
private let proximityBleMaxAttributeValue: Int = 512

/// The `bluetoothUnavailable` reason for a manager state that will not become
/// usable without user action, nil otherwise.
private func proximityBleUnavailableReason(_ state: CBManagerState) -> String? {
    switch state {
    case .poweredOff: return "poweredOff"
    case .unauthorized: return "unauthorized"
    case .unsupported: return "unsupported"
    default: return nil
    }
}

// MARK: - Displayer (GATT peripheral)

public final class ProximityBleDisplayerTransport: NSObject, ProximityDisplayerTransport, CBPeripheralManagerDelegate {

    public var onIncomingLink: ((ProximityPairingLink) -> Void)?
    public var onUnavailable: ((ProximityPairingError) -> Void)?

    private enum ServiceState {
        case unpublished
        case adding
        case published
    }

    /// Created lazily by the first `startAdvertising`, so constructing the
    /// transport never triggers the Bluetooth permission prompt.
    private var manager: CBPeripheralManager?
    private var activeServiceUUID: CBUUID?
    private var serviceState: ServiceState = .unpublished
    private var wantsAdvertising: Bool = false
    private var toScannerCharacteristic: CBMutableCharacteristic?
    private var links: [UUID: ProximityBleDisplayerLink] = [:]
    /// Bumped only by `shutdown()`: deferred link callbacks captured under an
    /// older value are dropped, so nothing fires after `shutdown()`.
    private var silenceGeneration: Int = 0
    /// Bumped by `shutdown()` and by every `startAdvertising`: a deferred
    /// `onUnavailable` about a superseded request is dropped.
    private var requestGeneration: Int = 0

    public override init() {
        super.init()
    }

    deinit {
        if let m = manager {
            m.delegate = nil
            if m.state == .poweredOn {
                m.stopAdvertising()
                m.removeAllServices()
            }
        }
    }

    // MARK: ProximityDisplayerTransport

    public func startAdvertising(serviceId: Data) {
        // Replace semantics: the previous service (and every link bound to it) goes away.
        requestGeneration &+= 1
        failAllLinksDeferred(.transportFailed("service replaced"))
        if let m = manager, m.state == .poweredOn {
            m.stopAdvertising()
            m.removeAllServices()
        }
        serviceState = .unpublished
        toScannerCharacteristic = nil
        activeServiceUUID = nil
        wantsAdvertising = false

        guard let uuid = ProximityBleUUIDs.serviceUUID(sessionId: serviceId) else {
            reportUnavailableDeferred(.transportFailed("invalid service id"))
            return
        }
        activeServiceUUID = uuid
        wantsAdvertising = true

        guard let m = manager else {
            // The state callback that follows creation drives publishing.
            let options: [String: Any] = [CBPeripheralManagerOptionShowPowerAlertKey: true]
            manager = CBPeripheralManager(delegate: self, queue: nil, options: options)
            return
        }
        if m.state == .poweredOn {
            publishService(on: m, uuid: uuid)
        } else if let reason = proximityBleUnavailableReason(m.state) {
            // No state callback will come for a state that is already settled.
            reportUnavailableDeferred(.bluetoothUnavailable(reason))
        }
        // .unknown / .resetting: wait for peripheralManagerDidUpdateState.
    }

    /// Stops advertising but keeps the GATT service, so an established link keeps working.
    public func stopAdvertising() {
        wantsAdvertising = false
        if let m = manager, m.state == .poweredOn {
            m.stopAdvertising()
        }
    }

    public func shutdown() {
        silenceGeneration &+= 1
        requestGeneration &+= 1
        wantsAdvertising = false
        activeServiceUUID = nil
        serviceState = .unpublished
        toScannerCharacteristic = nil
        let snapshot: [ProximityBleDisplayerLink] = Array(links.values)
        links.removeAll()
        for link in snapshot {
            link.detach()
        }
        if let m = manager {
            m.delegate = nil
            if m.state == .poweredOn {
                m.stopAdvertising()
                m.removeAllServices()
            }
        }
        manager = nil
    }

    // MARK: Link plumbing (called by ProximityBleDisplayerLink)

    fileprivate func linkSend(_ link: ProximityBleDisplayerLink, _ message: Data) {
        guard !link.isClosed, links[link.central.identifier] === link else { return }
        let maxLength: Int = link.central.maximumUpdateValueLength
        let pieces: [Data]
        do {
            pieces = try ProximityFraming.fragments(of: message, maxValueLength: maxLength)
        } catch {
            failLinkDeferred(link, .protocolViolation("outbound message not frameable"))
            return
        }
        link.outbox.append(contentsOf: pieces)
        _ = pump(link)
    }

    // MARK: CBPeripheralManagerDelegate

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        let state: CBManagerState = peripheral.state
        if state == .poweredOn {
            if let uuid = activeServiceUUID, serviceState == .unpublished {
                publishService(on: peripheral, uuid: uuid)
            }
            return
        }
        if state == .unknown { return }

        // Any other state invalidates the published service and every connection.
        serviceState = .unpublished
        toScannerCharacteristic = nil
        let current: Int = silenceGeneration
        failAllLinksNow(.transportFailed("bluetooth state changed"))
        guard silenceGeneration == current else { return }
        if let reason = proximityBleUnavailableReason(state), activeServiceUUID != nil {
            onUnavailable?(.bluetoothUnavailable(reason))
        }
        // .resetting: the next state callback republishes (or reports) as needed.
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === manager, serviceState == .adding,
              let uuid = activeServiceUUID, service.uuid == uuid else { return }
        if error != nil {
            serviceState = .unpublished
            toScannerCharacteristic = nil
            onUnavailable?(.transportFailed("GATT service could not be published"))
            return
        }
        serviceState = .published
        if wantsAdvertising {
            let advertisement: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: [uuid]]
            peripheral.startAdvertising(advertisement)
        }
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral === manager, activeServiceUUID != nil, wantsAdvertising else { return }
        if error != nil {
            onUnavailable?(.transportFailed("advertising could not start"))
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didSubscribeTo characteristic: CBCharacteristic) {
        guard peripheral === manager, serviceState == .published,
              characteristic.uuid == ProximityBleUUIDs.toScannerCharacteristic else { return }
        let key: UUID = central.identifier
        if let existing = links[key], !existing.isClosed { return }
        let link = ProximityBleDisplayerLink(central: central, transport: self)
        links[key] = link
        peripheral.setDesiredConnectionLatency(.low, for: central)
        onIncomingLink?(link)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard peripheral === manager,
              characteristic.uuid == ProximityBleUUIDs.toScannerCharacteristic,
              let link = links.removeValue(forKey: central.identifier) else { return }
        failLinkNow(link, .transportFailed("unsubscribed"))
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        peripheral.respond(to: request, withResult: .readNotPermitted)
    }

    /// Responds exactly once, to `requests[0]` (CoreBluetooth contract). The
    /// whole batch is validated before any value is consumed.
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard peripheral === manager else {
            peripheral.respond(to: first, withResult: .unlikelyError)
            return
        }
        var result: CBATTError.Code = .success
        for request in requests {
            let code: CBATTError.Code = validateWrite(request)
            if code != .success {
                result = code
                break
            }
        }
        if result == .success {
            for request in requests {
                // The client may have closed this link (or shut down) while
                // handling an earlier message of the same batch.
                guard let link = liveLink(for: request.central) else { break }
                let value: Data = Data(request.value ?? Data())
                if !feed(link, value) {
                    result = .unlikelyError
                    break
                }
            }
        }
        peripheral.respond(to: first, withResult: result)
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        let snapshot: [ProximityBleDisplayerLink] = Array(links.values)
        for link in snapshot {
            if !pump(link) { return }
        }
    }

    // MARK: Private

    private func publishService(on m: CBPeripheralManager, uuid: CBUUID) {
        m.stopAdvertising()
        m.removeAllServices()
        let toDisplayer = CBMutableCharacteristic(type: ProximityBleUUIDs.toDisplayerCharacteristic,
                                                  properties: [.write],
                                                  value: nil,
                                                  permissions: [.writeable])
        let toScanner = CBMutableCharacteristic(type: ProximityBleUUIDs.toScannerCharacteristic,
                                                properties: [.notify],
                                                value: nil,
                                                permissions: [.readable])
        let service = CBMutableService(type: uuid, primary: true)
        service.characteristics = [toDisplayer, toScanner]
        toScannerCharacteristic = toScanner
        serviceState = .adding
        m.add(service)
    }

    private func validateWrite(_ request: CBATTRequest) -> CBATTError.Code {
        if request.characteristic.uuid != ProximityBleUUIDs.toDisplayerCharacteristic {
            return .requestNotSupported
        }
        if request.offset != 0 {
            return .invalidOffset
        }
        guard let value = request.value, !value.isEmpty, value.count <= proximityBleMaxAttributeValue else {
            return .invalidAttributeValueLength
        }
        if liveLink(for: request.central) == nil {
            return .unlikelyError
        }
        return .success
    }

    private func liveLink(for central: CBCentral) -> ProximityBleDisplayerLink? {
        guard let link = links[central.identifier], !link.isClosed else { return nil }
        return link
    }

    /// Returns false on a framing violation (the link is then already closed
    /// and its `onClosed` fired).
    private func feed(_ link: ProximityBleDisplayerLink, _ value: Data) -> Bool {
        let message: Data?
        do {
            message = try link.reassembler.append(value)
        } catch {
            let failure: ProximityPairingError = (error as? ProximityPairingError) ?? .protocolViolation("BLE framing")
            failLinkNow(link, failure)
            return false
        }
        if let whole = message, !link.isClosed {
            link.onMessage?(whole)
        }
        return true
    }

    /// Sends queued fragments in FIFO order. Returns false when the
    /// CoreBluetooth transmit queue is full (resumed by `isReady`).
    private func pump(_ link: ProximityBleDisplayerLink) -> Bool {
        guard let m = manager, let characteristic = toScannerCharacteristic else { return true }
        guard links[link.central.identifier] === link else { return true }
        while !link.isClosed, let next = link.outbox.first {
            let sent: Bool = m.updateValue(next, for: characteristic, onSubscribedCentrals: [link.central])
            if !sent { return false }
            link.outbox.removeFirst()
        }
        return true
    }

    private func failLinkNow(_ link: ProximityBleDisplayerLink, _ error: ProximityPairingError) {
        guard !link.isClosed else { return }
        link.markDead()
        link.fireClosed(error)
    }

    private func failLinkDeferred(_ link: ProximityBleDisplayerLink, _ error: ProximityPairingError) {
        guard !link.isClosed else { return }
        link.markDead()
        let captured: Int = silenceGeneration
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self, strongSelf.silenceGeneration == captured else { return }
            link.fireClosed(error)
        }
    }

    private func failAllLinksNow(_ error: ProximityPairingError) {
        let snapshot: [ProximityBleDisplayerLink] = Array(links.values)
        links.removeAll()
        let captured: Int = silenceGeneration
        for link in snapshot {
            if silenceGeneration != captured {
                // The client shut down from inside an onClosed: silence the rest.
                link.detach()
                continue
            }
            failLinkNow(link, error)
        }
    }

    /// Used from inside client calls: drops every link now, reports later
    /// (unless `shutdown()` runs first).
    private func failAllLinksDeferred(_ error: ProximityPairingError) {
        let snapshot: [ProximityBleDisplayerLink] = Array(links.values)
        links.removeAll()
        let pending: [ProximityBleDisplayerLink] = snapshot.filter { !$0.isClosed }
        for link in pending {
            link.markDead()
        }
        guard !pending.isEmpty else { return }
        let captured: Int = silenceGeneration
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self, strongSelf.silenceGeneration == captured else { return }
            for link in pending {
                link.fireClosed(error)
            }
        }
    }

    private func reportUnavailableDeferred(_ error: ProximityPairingError) {
        let captured: Int = requestGeneration
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self, strongSelf.requestGeneration == captured else { return }
            strongSelf.onUnavailable?(error)
        }
    }
}

/// One subscribed central. The peripheral role cannot disconnect a central,
/// so `close()` only marks the link dead: queued data is dropped and further
/// writes from that central are refused until it unsubscribes.
fileprivate final class ProximityBleDisplayerLink: ProximityPairingLink {

    let central: CBCentral
    weak var transport: ProximityBleDisplayerTransport?
    var onMessage: ((Data) -> Void)?
    var onClosed: ((ProximityPairingError?) -> Void)?
    private(set) var isClosed: Bool = false
    var reassembler: ProximityReassembler = ProximityReassembler(maxMessageBytes: ProximityPairing.maxMessageBytes)
    var outbox: [Data] = []

    init(central: CBCentral, transport: ProximityBleDisplayerTransport) {
        self.central = central
        self.transport = transport
    }

    func send(_ message: Data) {
        guard !isClosed else { return }
        guard let owner = transport else {
            markDead()
            DispatchQueue.main.async { [self] in
                self.fireClosed(.transportFailed("transport released"))
            }
            return
        }
        owner.linkSend(self, message)
    }

    func close() {
        onMessage = nil
        onClosed = nil
        markDead()
    }

    func markDead() {
        isClosed = true
        outbox.removeAll()
        reassembler.reset()
    }

    /// Silent close used by `shutdown()`.
    func detach() {
        close()
        transport = nil
    }

    /// Fires `onClosed` at most once; afterwards no callback can fire.
    func fireClosed(_ error: ProximityPairingError?) {
        let callback: ((ProximityPairingError?) -> Void)? = onClosed
        onClosed = nil
        onMessage = nil
        callback?(error)
    }
}

// MARK: - Scanner (GATT central)

public final class ProximityBleScannerTransport: NSObject, ProximityScannerTransport,
                                                 CBCentralManagerDelegate, CBPeripheralDelegate {

    private enum Phase {
        case idle
        case waitingForPower
        case scanning
        case connecting
        case discoveringServices
        case discoveringCharacteristics
        case subscribing
        case connected
    }

    /// Created lazily by the first `connect`, then reused.
    private var manager: CBCentralManager?
    private var phase: Phase = .idle
    private var serviceUUID: CBUUID?
    private var pendingCompletion: ((Result<ProximityPairingLink, ProximityPairingError>) -> Void)?
    private var timeoutItem: DispatchWorkItem?
    private var remotePeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var link: ProximityBleScannerLink?
    private var reassembler: ProximityReassembler = ProximityReassembler(maxMessageBytes: ProximityPairing.maxMessageBytes)
    private var outbox: [Data] = []
    private var writeInFlight: Bool = false
    /// Bumped by every teardown; stale timers compare against it.
    private var attempt: Int = 0
    /// Bumped by `cancel()`; deferred callbacks captured earlier are dropped.
    private var cancelGeneration: Int = 0

    public override init() {
        super.init()
    }

    deinit {
        timeoutItem?.cancel()
        if let m = manager {
            m.delegate = nil
            if m.state == .poweredOn {
                if m.isScanning { m.stopScan() }
                if let p = remotePeripheral { m.cancelPeripheralConnection(p) }
            }
        }
        remotePeripheral?.delegate = nil
    }

    // MARK: ProximityScannerTransport

    public func connect(serviceId: Data, timeout: TimeInterval,
                        completion: @escaping (Result<ProximityPairingLink, ProximityPairingError>) -> Void) {
        // A superseded attempt still gets its single completion.
        if let previous = pendingCompletion {
            pendingCompletion = nil
            deliverDeferred(previous, .failure(.cancelled))
        }
        dropLinkSilently()
        teardown()
        pendingCompletion = completion

        guard let uuid = ProximityBleUUIDs.serviceUUID(sessionId: serviceId) else {
            failPendingDeferred(.protocolViolation("invalid service id"))
            return
        }
        serviceUUID = uuid
        phase = .waitingForPower

        let delay: Double = (timeout.isFinite && timeout > 0) ? min(timeout, 3600) : ProximityPairing.scannerConnectTimeout
        let attemptId: Int = attempt
        let item = DispatchWorkItem { [weak self] in
            guard let strongSelf = self, strongSelf.attempt == attemptId else { return }
            strongSelf.failPending(.timeout("bluetooth discovery/connect"))
        }
        timeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)

        guard let m = manager else {
            let options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: true]
            manager = CBCentralManager(delegate: self, queue: nil, options: options)
            return
        }
        if m.state == .poweredOn {
            beginScan()
        } else if let reason = proximityBleUnavailableReason(m.state) {
            failPendingDeferred(.bluetoothUnavailable(reason))
        }
        // .unknown / .resetting: wait for centralManagerDidUpdateState.
    }

    public func cancel() {
        cancelGeneration &+= 1
        pendingCompletion = nil
        dropLinkSilently()
        teardown()
    }

    // MARK: Link plumbing (called by ProximityBleScannerLink)

    fileprivate func linkSend(_ sender: ProximityBleScannerLink, _ message: Data) {
        guard sender === link, !sender.isClosed, phase == .connected, let p = remotePeripheral else { return }
        // .withoutResponse length (ATT_MTU − 3) even though writes go WITH
        // response: the stack then never falls back to prepare/execute writes.
        let maxLength: Int = p.maximumWriteValueLength(for: .withoutResponse)
        let pieces: [Data]
        do {
            pieces = try ProximityFraming.fragments(of: message, maxValueLength: maxLength)
        } catch {
            failLinkDeferred(.protocolViolation("outbound message not frameable"))
            return
        }
        outbox.append(contentsOf: pieces)
        pumpWrites()
    }

    fileprivate func linkClose(_ sender: ProximityBleScannerLink) {
        guard sender === link else { return }
        link = nil
        teardown()
    }

    // MARK: CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager else { return }
        let state: CBManagerState = central.state
        if state == .poweredOn {
            if phase == .waitingForPower { beginScan() }
            return
        }
        if phase == .connected {
            if state != .unknown { failLink(.transportFailed("bluetooth state changed")) }
            return
        }
        guard pendingCompletion != nil else { return }
        if let reason = proximityBleUnavailableReason(state) {
            failPending(.bluetoothUnavailable(reason))
        } else if state == .resetting, phase != .waitingForPower {
            failPending(.transportFailed("bluetooth reset"))
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === manager, phase == .scanning else { return }
        central.stopScan()
        self.remotePeripheral = peripheral
        peripheral.delegate = self
        phase = .connecting
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === manager, peripheral === self.remotePeripheral, phase == .connecting,
              let uuid = serviceUUID else { return }
        phase = .discoveringServices
        peripheral.discoverServices([uuid])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === manager, peripheral === self.remotePeripheral else { return }
        fail(.transportFailed("connection failed"))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        guard central === manager, peripheral === self.remotePeripheral else { return }
        fail(.transportFailed("disconnected"))
    }

    // MARK: CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.remotePeripheral, phase == .discoveringServices, let uuid = serviceUUID else { return }
        if error != nil {
            failPending(.transportFailed("service discovery failed"))
            return
        }
        let matching: [CBService] = (peripheral.services ?? []).filter { $0.uuid == uuid }
        guard matching.count == 1, let service = matching.first else {
            failPending(.transportFailed("pairing service not found"))
            return
        }
        phase = .discoveringCharacteristics
        let wanted: [CBUUID] = [ProximityBleUUIDs.toDisplayerCharacteristic, ProximityBleUUIDs.toScannerCharacteristic]
        peripheral.discoverCharacteristics(wanted, for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard peripheral === self.remotePeripheral, phase == .discoveringCharacteristics,
              let uuid = serviceUUID, service.uuid == uuid else { return }
        if error != nil {
            failPending(.transportFailed("characteristic discovery failed"))
            return
        }
        let all: [CBCharacteristic] = service.characteristics ?? []
        let writes: [CBCharacteristic] = all.filter { $0.uuid == ProximityBleUUIDs.toDisplayerCharacteristic }
        let notifies: [CBCharacteristic] = all.filter { $0.uuid == ProximityBleUUIDs.toScannerCharacteristic }
        guard writes.count == 1, notifies.count == 1,
              let toDisplayer = writes.first, let toScanner = notifies.first else {
            failPending(.transportFailed("pairing characteristics not found"))
            return
        }
        guard toDisplayer.properties.contains(.write), toScanner.properties.contains(.notify) else {
            failPending(.protocolViolation("unexpected characteristic properties"))
            return
        }
        writeCharacteristic = toDisplayer
        notifyCharacteristic = toScanner
        phase = .subscribing
        peripheral.setNotifyValue(true, for: toScanner)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard peripheral === self.remotePeripheral, phase == .subscribing,
              characteristic.uuid == ProximityBleUUIDs.toScannerCharacteristic else { return }
        guard error == nil, characteristic.isNotifying else {
            failPending(.transportFailed("subscription failed"))
            return
        }
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
        timeoutItem?.cancel()
        timeoutItem = nil
        reassembler.reset()
        outbox.removeAll()
        writeInFlight = false
        let established = ProximityBleScannerLink(transport: self)
        link = established
        phase = .connected
        completion(.success(established))
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard peripheral === self.remotePeripheral, phase == .connected, writeInFlight,
              characteristic.uuid == ProximityBleUUIDs.toDisplayerCharacteristic else { return }
        writeInFlight = false
        if error != nil {
            failLink(.transportFailed("write failed"))
            return
        }
        pumpWrites()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard peripheral === self.remotePeripheral, phase == .connected,
              characteristic.uuid == ProximityBleUUIDs.toScannerCharacteristic,
              let current = link, !current.isClosed else { return }
        if error != nil {
            failLink(.transportFailed("notification failed"))
            return
        }
        let value: Data = Data(characteristic.value ?? Data())
        let message: Data?
        do {
            message = try reassembler.append(value)
        } catch {
            let failure: ProximityPairingError = (error as? ProximityPairingError) ?? .protocolViolation("BLE framing")
            failLink(failure)
            return
        }
        if let whole = message {
            current.onMessage?(whole)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === self.remotePeripheral, let uuid = serviceUUID, phase != .idle else { return }
        let lost: Bool = invalidatedServices.contains(where: { $0.uuid == uuid })
        if lost {
            fail(.transportFailed("pairing service removed"))
        }
    }

    // MARK: Private

    private func beginScan() {
        guard let m = manager, let uuid = serviceUUID else { return }
        phase = .scanning
        let options: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        m.scanForPeripherals(withServices: [uuid], options: options)
    }

    private func pumpWrites() {
        guard !writeInFlight, phase == .connected, !outbox.isEmpty,
              let p = remotePeripheral, let characteristic = writeCharacteristic else { return }
        let next: Data = outbox.removeFirst()
        writeInFlight = true
        p.writeValue(next, for: characteristic, type: .withResponse)
    }

    /// Releases the radio and every per-connection resource. Fires nothing.
    private func teardown() {
        attempt &+= 1
        timeoutItem?.cancel()
        timeoutItem = nil
        if let m = manager, m.state == .poweredOn {
            if m.isScanning { m.stopScan() }
            if let p = remotePeripheral { m.cancelPeripheralConnection(p) }
        }
        remotePeripheral?.delegate = nil
        remotePeripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        serviceUUID = nil
        reassembler.reset()
        outbox.removeAll()
        writeInFlight = false
        phase = .idle
    }

    private func dropLinkSilently() {
        if let current = link {
            current.detach()
        }
        link = nil
    }

    /// Delegate-context failure: to the link once connected, else to the pending completion.
    private func fail(_ error: ProximityPairingError) {
        if phase == .connected {
            failLink(error)
        } else {
            failPending(error)
        }
    }

    private func failPending(_ error: ProximityPairingError) {
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
        teardown()
        completion(.failure(error))
    }

    private func failPendingDeferred(_ error: ProximityPairingError) {
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
        teardown()
        deliverDeferred(completion, .failure(error))
    }

    private func deliverDeferred(_ completion: @escaping (Result<ProximityPairingLink, ProximityPairingError>) -> Void,
                                 _ result: Result<ProximityPairingLink, ProximityPairingError>) {
        let captured: Int = cancelGeneration
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self, strongSelf.cancelGeneration == captured else { return }
            completion(result)
        }
    }

    private func failLink(_ error: ProximityPairingError) {
        guard let current = link else { return }
        link = nil
        teardown()
        current.markDead()
        current.fireClosed(error)
    }

    private func failLinkDeferred(_ error: ProximityPairingError) {
        guard let current = link else { return }
        link = nil
        teardown()
        current.markDead()
        let captured: Int = cancelGeneration
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self, strongSelf.cancelGeneration == captured else { return }
            current.fireClosed(error)
        }
    }
}

/// The scanner's single link to the displayer. `close()` disconnects.
fileprivate final class ProximityBleScannerLink: ProximityPairingLink {

    weak var transport: ProximityBleScannerTransport?
    var onMessage: ((Data) -> Void)?
    var onClosed: ((ProximityPairingError?) -> Void)?
    private(set) var isClosed: Bool = false

    init(transport: ProximityBleScannerTransport) {
        self.transport = transport
    }

    func send(_ message: Data) {
        guard !isClosed else { return }
        guard let owner = transport else {
            markDead()
            DispatchQueue.main.async { [self] in
                self.fireClosed(.transportFailed("transport released"))
            }
            return
        }
        owner.linkSend(self, message)
    }

    func close() {
        onMessage = nil
        onClosed = nil
        guard !isClosed else { return }
        markDead()
        transport?.linkClose(self)
    }

    func markDead() {
        isClosed = true
    }

    /// Silent close used by `cancel()` / a superseding `connect()`.
    func detach() {
        onMessage = nil
        onClosed = nil
        isClosed = true
        transport = nil
    }

    /// Fires `onClosed` at most once; afterwards no callback can fire.
    func fireClosed(_ error: ProximityPairingError?) {
        let callback: ((ProximityPairingError?) -> Void)? = onClosed
        onClosed = nil
        onMessage = nil
        callback?(error)
    }
}

#endif
