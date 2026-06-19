import SwiftUI
import CoreBluetooth
import CryptoKit

// MARK: - EarbudDiagScreen
//
// W503: 1:1 port of Android `EarbudDiagScreen.kt` in
// feature/feature-settings/src/main/java/com/bcrypto/qaudion/feature/settings/ui/earbuddiag/.
//
// Shows live Q-Audion earbud metrics over BLE:
//   heap (free / total bytes), PDM/TDM status, CPU%, CRACEN AEAD ops,
//   Axon pipeline state, BLE connection state.
//
// The BLE service/characteristic UUIDs must match the earbud firmware
// (qaudion-firmware gatt_server / qaudion_service_uuid). Until the iOS
// BLE client is wired to the real firmware UUIDs the screen operates
// in "scan only" mode and surfaces whatever advertisement data is
// visible — same fallback state as the Android implementation before
// pairing.
//
// This file follows CLAUDE.md §16 (no AppState parameter type) and
// SWIFT6_PATTERNS §13 (all closures extracted to named methods).

// MARK: - BLE view-model

@MainActor
final class EarbudDiagViewModel: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var scanState: ScanState = .idle
    @Published var discoveredEarbuds: [DiscoveredEarbud] = []
    @Published var connectedEarbud: DiscoveredEarbud? = nil
    @Published var metrics: EarbudMetrics? = nil
    @Published var connectionState: ConnectionState = .disconnected
    @Published var blePermissionDenied: Bool = false

    // MARK: - Pairing state (FE-5 earbud-exclusive pairing)

    @Published var pairingStatus: PairingStatus = .idle
    /// Human-readable step label emitted by startAutoRelay(); nil when no relay is running.
    @Published var relayStatus: String? = nil

    enum PairingStatus: Equatable {
        case idle
        case inProgress
        case success(pairId: String)
        case failed(String)

        static func == (lhs: PairingStatus, rhs: PairingStatus) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.inProgress, .inProgress): return true
            case (.success(let a), .success(let b)): return a == b
            case (.failed(let a), .failed(let b)):   return a == b
            default: return false
            }
        }
    }

    // MARK: - Model types

    enum ScanState: Equatable {
        case idle, scanning, stopped
    }

    enum ConnectionState: Equatable {
        case disconnected, connecting, connected, error(String)
        static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected), (.connecting, .connecting),
                 (.connected, .connected): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    struct DiscoveredEarbud: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
        let peripheral: CBPeripheral
        static func == (lhs: DiscoveredEarbud, rhs: DiscoveredEarbud) -> Bool {
            lhs.id == rhs.id
        }
    }

    struct EarbudMetrics {
        var heapFreeKb: Int = 0
        var heapTotalKb: Int = 0      // heapUsedKb + heapFreeKb
        var cpuPercent: Int = 0
        var hsCount: Int = 0          // legacy handshake-count proxy for CRACEN PSA ops
        var aeadOpsTotal: UInt32? = nil  // V2 only (32-byte payload); nil on legacy firmware
        var pdmActive: Bool = false
        var tdmActive: Bool = false
        var axonOk: Bool = false
        var batteryPct: Int = 0
        var uptimeSec: Int = 0
        var firmwareVersion: String = "—"
        var lastUpdated: Date = Date()
    }

    // MARK: - Private state

    private var central: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?

    // FE-5: GATT proxy for earbud-exclusive pairing operations (c5/c6/c7/c8).
    // Created when a peripheral connects; torn down on disconnect.
    private var gattProxy: (any EarbudPairingGattProxy)? = nil
    private let fe5Exchange = Fe5ExchangeService()
    private var relayTask: Task<Void, Never>? = nil

    // W511: client-side CRACEN fps tracking (mirrors Android LaunchedEffect pattern).
    @Published var cracenFps: Int? = nil
    private var prevAeadOps: UInt32? = nil
    private var prevAeadOpsAt: TimeInterval = 0

    // Q-Audion GATT service and DIAG characteristic UUIDs — canonical values from
    // qaudion-firmware/nspe/src/transport/qaudion_gatt.c (QAUDION_SVC_UUID_VAL /
    // QAUDION_CH_DIAG_UUID_VAL, slot 0x90).
    // nonisolated(unsafe): these are constants (never mutated) accessed from
    // CBCentralManager/CBPeripheralDelegate callbacks which are nonisolated.
    // Swift 6 strict-concurrency requires explicit opt-in for @MainActor statics
    // referenced from nonisolated context.
    private nonisolated(unsafe) static let serviceUUID    = CBUUID(string: "f2c0aaaa-bcc0-4001-8000-000000000001")
    private nonisolated(unsafe) static let metricsCharUUID = CBUUID(string: "f2c0aaaa-bcc0-4001-8000-000000000090")

    // MARK: - Public API

    func startScan() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        }
        guard central?.state == .poweredOn else { return }
        discoveredEarbuds = []
        scanState = .scanning
        central?.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        // Auto-stop after 8 seconds — same as Android BLE scan window.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if scanState == .scanning { stopScan() }
        }
    }

    func stopScan() {
        central?.stopScan()
        scanState = .stopped
    }

    func connect(to earbud: DiscoveredEarbud) {
        connectedEarbud = earbud
        connectionState = .connecting
        connectedPeripheral = earbud.peripheral
        central?.connect(earbud.peripheral, options: nil)
    }

    func disconnect() {
        relayTask?.cancel()
        relayTask = nil
        relayStatus = nil
        if let p = connectedPeripheral {
            central?.cancelPeripheralConnection(p)
        }
        connectedPeripheral = nil
        connectedEarbud = nil
        connectionState = .disconnected
        metrics = nil
        gattProxy = nil
        pairingStatus = .idle
    }

    // MARK: - FE-5 Earbud Pairing

    /// Execute one GATT pairing exchange against the currently-connected earbud.
    ///
    /// Phase-1 diagnostic mode: both earbuds are owned by the same phone, so
    /// peer/own material fields are zero-filled placeholders and isConfirmed
    /// is { _ in true } (SAS gate bypassed). The firmware still exercises the
    /// full c5/c6/c7 exchange; pair_id is recorded in pairingStatus.
    ///
    /// Production note: for Phase-2 cross-user pairing, replace the isConfirmed
    /// closure with:
    ///   { SasVerificationStore.shared.isEarbudPairConfirmed(pairId: $0) }
    /// and supply real attestation material from the server in the six Data fields.
    func pairWithConnectedEarbud() async {
        guard connectedEarbud != nil else {
            pairingStatus = .failed("nessun auricolare connesso")
            return
        }
        guard let proxy = gattProxy else {
            pairingStatus = .failed("proxy GATT non disponibile")
            return
        }

        pairingStatus = .inProgress

        // Phase-1 placeholders: 32-byte pkSe / eid and 1568-byte material, all zeros.
        // Replace with real attestation data from the server for Phase-2.
        let zeroPkSe     = Data(count: 32)
        let zeroMaterial = Data(count: 1568)
        let zeroEid      = Data(count: 32)

        let relay = EarbudPairingRelay(gatt: proxy)
        let result = await relay.pairWithPeer(
            peerPkSe:     zeroPkSe,
            peerMaterial: zeroMaterial,
            peerEid:      zeroEid,
            ownPkSe:      zeroPkSe,
            ownMaterial:  zeroMaterial,
            ownEid:       zeroEid,
            // Phase-1 diagnostic: SAS gate bypassed.
            // Phase-2 production: { SasVerificationStore.shared.isEarbudPairConfirmed(pairId: $0) }
            isConfirmed: { _ in true }
        )

        switch result {
        case .success(let pairId, _):
            let hex = pairId.prefix(8).map { String(format: "%02x", $0) }.joined() + "…"
            pairingStatus = .success(pairId: hex)
        case .defer(let reason):
            pairingStatus = .failed(reason)
        }
    }

    // MARK: - FE-5 Auto-relay (two-phone cross-earbud pairing via server exchange)

    /// Two-stage auto relay:
    ///   1. Read connected earbud's pk_se/pk_pq/eid from c6 (pre-populated at boot).
    ///   2. Publish to server; poll for peer's data.
    ///   3. Role: if connEid > peerEid → RESPONDER phone (Stage 1 → publish ct_ee).
    ///            if connEid < peerEid → INITIATOR phone (wait for ct_ee → Stage 2).
    func startAutoRelay() {
        relayTask?.cancel()
        relayTask = Task { await self.runAutoRelay() }
    }

    private func runAutoRelay() async {
        guard let proxy = gattProxy else {
            relayStatus = "proxy GATT non disponibile"
            return
        }

        relayStatus = "Lettura chiavi auricolare connesso…"
        let pairRespRaw: Data
        do {
            pairRespRaw = try await proxy.readPairResp()
        } catch {
            relayStatus = "Errore lettura c6: \(error)"
            return
        }
        guard let conn = EarbudPairGatt.parsePairResp(pairRespRaw) else {
            relayStatus = "Parse PAIR_RESP fallito"
            return
        }
        let connPkSe = conn.pkSe
        let connMat  = conn.material  // pk_pq (pre-encap)
        let connEid  = conn.eid

        let connPkSeHex = connPkSe.map { String(format: "%02x", $0) }.joined()
        let connMatB64  = connMat.base64EncodedString()

        relayStatus = "Pubblicazione chiavi auricolare…"
        guard await fe5Exchange.publish(pkSeHex: connPkSeHex, materialB64: connMatB64) else {
            relayStatus = "Pubblicazione fallita"
            return
        }

        relayStatus = "In attesa del peer (120s)…"
        var peerData: Fe5ExchangeService.PeerData? = nil
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            peerData = await fe5Exchange.fetchPeer(myPkSeHex: connPkSeHex)
            if peerData != nil { break }
        }
        guard let peer = peerData,
              let peerPkSe = Self.dataFromHex(peer.pkSe),
              let peerMat  = Data(base64Encoded: peer.material) else {
            relayStatus = "Timeout: nessun peer trovato"
            return
        }
        let peerEid = Data(SHA256.hash(data: peerPkSe))

        let relay = EarbudPairingRelay(gatt: proxy)
        let weAreResponderPhone = Self.lexGreater(connEid, peerEid)

        if weAreResponderPhone {
            // Connected earbud is RESPONDER: send peer's pkPq → get ct_ee → publish
            relayStatus = "Stage 1: Pairing GATT (RESPONDER)…"
            pairingStatus = .inProgress
            let result = await relay.pairWithPeer(
                peerPkSe: connPkSe, peerMaterial: connMat, peerEid: connEid,
                ownPkSe: peerPkSe, ownMaterial: peerMat, ownEid: peerEid,
                isConfirmed: { _ in true }
            )
            switch result {
            case .success(let pairId, let ctEe):
                if let ct = ctEe {
                    _ = await fe5Exchange.publishCt(
                        pkSeHex: connPkSeHex, ctB64: ct.base64EncodedString())
                    let hex = pairId.prefix(8).map { String(format: "%02x", $0) }.joined() + "…"
                    pairingStatus = .success(pairId: hex)
                    relayStatus = "Completato (RESPONDER) · ct_ee pubblicato"
                } else {
                    pairingStatus = .failed("ct_ee assente (Stage 1)")
                    relayStatus = "Errore: ct_ee assente dopo Stage 1"
                }
            case .defer(let reason):
                pairingStatus = .failed(reason)
                relayStatus = "Pairing fallito: \(reason)"
            }
        } else {
            // Connected earbud is INITIATOR: wait for peer's ct_ee, then Stage 2
            relayStatus = "Attesa ct_ee dal RESPONDER (120s)…"
            var ctBase64: String? = nil
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                if let p = await fe5Exchange.fetchPeer(myPkSeHex: connPkSeHex),
                   let ct = p.ct, !ct.isEmpty {
                    ctBase64 = ct
                    break
                }
            }
            guard let ctB64 = ctBase64, let ctEe = Data(base64Encoded: ctB64) else {
                relayStatus = "Timeout: ct_ee non ricevuto"
                return
            }
            relayStatus = "Stage 2: Pairing GATT (INITIATOR)…"
            pairingStatus = .inProgress
            let result = await relay.pairWithPeer(
                peerPkSe: connPkSe, peerMaterial: connMat, peerEid: connEid,
                ownPkSe: peerPkSe, ownMaterial: ctEe, ownEid: peerEid,
                isConfirmed: { _ in true }
            )
            switch result {
            case .success(let pairId, _):
                let hex = pairId.prefix(8).map { String(format: "%02x", $0) }.joined() + "…"
                pairingStatus = .success(pairId: hex)
                relayStatus = "Completato (INITIATOR)"
            case .defer(let reason):
                pairingStatus = .failed(reason)
                relayStatus = "Pairing fallito: \(reason)"
            }
        }
    }

    // MARK: - Helpers

    private static func lexGreater(_ a: Data, _ b: Data) -> Bool {
        for i in 0..<min(a.count, b.count) {
            if a[i] != b[i] { return Int(a[i]) > Int(b[i]) }
        }
        return a.count > b.count
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var result = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}

// MARK: - CBCentralManagerDelegate

extension EarbudDiagViewModel: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .unauthorized {
                self.blePermissionDenied = true
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Q-Audion Earbud"
        // Filter: only show peripherals whose advertised name contains
        // "QAudion" or "Q-Audion" or "qaudion" (case-insensitive).
        let lcName = name.lowercased()
        guard lcName.contains("qaudion") || lcName.contains("q-audion") else { return }
        let earbud = DiscoveredEarbud(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            peripheral: peripheral
        )
        Task { @MainActor in
            if !self.discoveredEarbuds.contains(where: { $0.id == earbud.id }) {
                self.discoveredEarbuds.append(earbud)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        let identifier = peripheral.identifier
        Task { @MainActor in
            self.connectionState = .connected
            self.metrics = EarbudMetrics(
                heapFreeKb: 0, heapTotalKb: 0,
                cpuPercent: 0, hsCount: 0,
                pdmActive: false, tdmActive: false,
                axonOk: false, batteryPct: 0, uptimeSec: 0,
                firmwareVersion: "—", lastUpdated: Date()
            )
            AppState.rememberEarbudIdentifier(identifier)
            let proxy = IOSEarbudGattProxy()
            proxy.connect(peripheral)
            self.gattProxy = proxy
            self.pairingStatus = .idle
        }
        peripheral.delegate = self
        peripheral.discoverServices([EarbudDiagViewModel.serviceUUID])
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.connectionState = .disconnected
            self.connectedEarbud = nil
            self.metrics = nil
            self.gattProxy = nil
            self.pairingStatus = .idle
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let msg = error?.localizedDescription ?? "connessione fallita"
        Task { @MainActor in
            self.connectionState = .error(msg)
            self.connectedEarbud = nil
        }
    }
}

// MARK: - CBPeripheralDelegate

extension EarbudDiagViewModel: CBPeripheralDelegate {
    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard let services = peripheral.services else { return }
        for svc in services where svc.uuid == EarbudDiagViewModel.serviceUUID {
            peripheral.discoverCharacteristics(
                [EarbudDiagViewModel.metricsCharUUID],
                for: svc
            )
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let chars = service.characteristics else { return }
        for ch in chars where ch.uuid == EarbudDiagViewModel.metricsCharUUID {
            peripheral.setNotifyValue(true, for: ch)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        if characteristic.uuid == EarbudDiagViewModel.metricsCharUUID {
            parseDiagPayload(data)
        }
    }

    // MARK: - Binary DIAG parser
    //
    // Wire layout (little-endian packed, 28 or 32 bytes — matching Android EarbudDiag.kt):
    //   off  0  UInt32  heap_used_kb
    //   off  4  UInt32  heap_free_kb
    //   off  8  UInt8   cpu_load_pct
    //   off  9  UInt8   battery_pct
    //   off 10  UInt8   pdm_ok
    //   off 11  UInt8   tdm_ok
    //   off 12  Int32   hs_count
    //   off 16  UInt8   axon_ok
    //   off 17  UInt8   call_state
    //   off 18  UInt16  ble_interval_125us
    //   off 20  Float32 deepfake_score
    //   off 24  UInt32  uptime_sec
    //   off 28  UInt32  aead_ops_total  (V2 / 32-byte payload only)
    nonisolated private static func u32le(_ d: Data, _ off: Int) -> UInt32 {
        var v: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &v) { d.copyBytes(to: $0, from: off..<(off + 4)) }
        return UInt32(littleEndian: v)
    }
    nonisolated private static func u16le(_ d: Data, _ off: Int) -> UInt16 {
        var v: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &v) { d.copyBytes(to: $0, from: off..<(off + 2)) }
        return UInt16(littleEndian: v)
    }

    nonisolated private func parseDiagPayload(_ data: Data) {
        let sz = data.count
        guard sz == 28 || sz == 32 else { return }
        let heapUsed = Int(Self.u32le(data, 0))
        let heapFree = Int(Self.u32le(data, 4))
        let cpuPct   = Int(data[8])
        let batPct   = Int(data[9])
        let pdmOk    = data[10] != 0
        let tdmOk    = data[11] != 0
        let hsCount  = Int(Int32(bitPattern: Self.u32le(data, 12)))
        let axonOk   = data[16] != 0
        let uptimeSec = Int(Self.u32le(data, 24))
        let aeadOps: UInt32? = sz == 32 ? Self.u32le(data, 28) : nil
        Task { @MainActor in
            // Preserve existing firmwareVersion (set separately via PROTOVER char).
            let fwVer = self.metrics?.firmwareVersion ?? "—"
            // fps computation: unsigned delta with 2^32 wrap (mirrors Android unsignedDelta32)
            if let curr = aeadOps {
                let now = Date().timeIntervalSinceReferenceDate
                if let prev = self.prevAeadOps, self.prevAeadOpsAt > 0 {
                    let delta = curr &- prev
                    let dt = now - self.prevAeadOpsAt
                    self.cracenFps = dt > 0 ? Int((Double(delta) / dt).rounded()) : nil
                } else {
                    self.cracenFps = nil
                }
                self.prevAeadOps = curr
                self.prevAeadOpsAt = now
            } else {
                self.cracenFps = nil
            }
            self.metrics = EarbudMetrics(
                heapFreeKb: heapFree, heapTotalKb: heapUsed + heapFree,
                cpuPercent: cpuPct, hsCount: hsCount, aeadOpsTotal: aeadOps,
                pdmActive: pdmOk, tdmActive: tdmOk, axonOk: axonOk,
                batteryPct: batPct, uptimeSec: uptimeSec,
                firmwareVersion: fwVer, lastUpdated: Date()
            )
        }
    }
}

// MARK: - View

struct EarbudDiagScreen: View {
    @StateObject private var vm = EarbudDiagViewModel()
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType)   private var type

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    scanSection
                    if !vm.discoveredEarbuds.isEmpty {
                        deviceListSection
                    }
                    if let m = vm.metrics {
                        metricsSection(m)
                    } else if vm.connectionState == .connecting {
                        connectingSection
                    } else if vm.scanState != .scanning && vm.discoveredEarbuds.isEmpty {
                        emptyStateSection
                    }
                    if vm.connectionState == .connected {
                        pairingSection
                    }
                    Spacer().frame(height: 32)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Diagnostica auricolare")
        .onDisappear {
            vm.stopScan()
            vm.disconnect()
        }
    }

    // MARK: - Scan section

    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader("BLUETOOTH")
            HStack(spacing: 12) {
                Button(action: handleScanButton) {
                    HStack(spacing: 8) {
                        Image(systemName: vm.scanState == .scanning
                              ? "stop.circle.fill" : "antenna.radiowaves.left.and.right")
                            .font(.system(size: 15, weight: .semibold))
                        Text(vm.scanState == .scanning ? "Arresta scansione" : "Avvia scansione BLE")
                            .qaudionStyle(type.labelLarge)
                    }
                    .foregroundStyle(vm.scanState == .scanning ? extras.warning : scheme.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(vm.scanState == .scanning
                                  ? extras.warning.opacity(0.18)
                                  : scheme.primary.opacity(0.85))
                    )
                }
                .buttonStyle(.plain)

                if vm.connectedEarbud != nil {
                    Button(action: vm.disconnect) {
                        Text("Disconnetti")
                            .qaudionStyle(type.labelLarge)
                            .foregroundStyle(extras.riskHigh)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(extras.riskHigh.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if vm.blePermissionDenied {
                blePermissionHint
            }

            connectionStatePill
        }
    }

    private var connectionStatePill: some View {
        let label: String
        let color: Color
        switch vm.connectionState {
        case .disconnected:
            label = "Non connesso"
            color = scheme.onSurfaceVariant
        case .connecting:
            label = "Connessione in corso…"
            color = extras.warning
        case .connected:
            label = "Connesso · metriche live"
            color = extras.success
        case .error(let msg):
            label = "Errore: " + msg
            color = extras.riskHigh
        }
        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(color)
        }
        .padding(.top, 4)
    }

    // MARK: - Device list

    private var deviceListSection: some View {
        let header = "DISPOSITIVI RILEVATI (" + String(describing: vm.discoveredEarbuds.count) + ")"
        return VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(header)
            ForEach(vm.discoveredEarbuds) { earbud in
                earbudRow(earbud)
            }
        }
    }

    private func earbudRow(_ earbud: EarbudDiagViewModel.DiscoveredEarbud) -> some View {
        let isConnected = vm.connectedEarbud?.id == earbud.id
        return Button {
            if !isConnected { vm.connect(to: earbud) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "headphones")
                    .font(.system(size: 22))
                    .foregroundStyle(isConnected ? extras.success : scheme.onSurfaceVariant)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(earbud.name)
                        .qaudionStyle(type.bodyMedium)
                        .foregroundStyle(scheme.onSurface)
                    let rssiStr = String(describing: earbud.rssi) + " dBm"
                    Text(rssiStr)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                }
                Spacer()
                if isConnected {
                    Text("CONNESSO")
                        .qaudionStyle(type.labelSmall)
                        .tracking(0.8)
                        .foregroundStyle(extras.success)
                } else {
                    Text("Connetti")
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.primary)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 60)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.surfaceVariant.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Metrics

    private static func heapPercent(_ m: EarbudDiagViewModel.EarbudMetrics) -> Double {
        guard m.heapTotalKb > 0 else { return 0.0 }
        return Double(m.heapFreeKb) / Double(m.heapTotalKb)
    }

    private func metricsSection(_ m: EarbudDiagViewModel.EarbudMetrics) -> some View {
        let heapPct = Self.heapPercent(m)
        return VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader("METRICHE LIVE")
            metricsCard(m, heapPct: heapPct)
            lastUpdatedFooter(m.lastUpdated)
        }
    }

    // Pre-build all metric strings outside @ViewBuilder (CLAUDE.md §13 v1.0.255+).
    private func heapLabel(_ m: EarbudDiagViewModel.EarbudMetrics) -> String {
        // heapFreeKb / heapTotalKb already in KB — display directly.
        String(describing: m.heapFreeKb) + " / " + String(describing: m.heapTotalKb) + " KB"
    }
    private func cpuLabel(_ m: EarbudDiagViewModel.EarbudMetrics) -> String {
        String(describing: m.cpuPercent) + "%"
    }
    // W511: CRACEN label — new firmware shows "ops | fps", legacy shows "×hsCount".
    private func cracenLabel(_ m: EarbudDiagViewModel.EarbudMetrics) -> String {
        if let ops = m.aeadOpsTotal {
            let opsStr = String(describing: ops)
            let fpsStr = vm.cracenFps.map { String(describing: $0) } ?? "--"
            return opsStr + " ops | " + fpsStr + " fps"
        }
        return "×" + String(describing: m.hsCount)
    }
    private func uptimeLabel(_ m: EarbudDiagViewModel.EarbudMetrics) -> String {
        let h = m.uptimeSec / 3600
        let min = (m.uptimeSec % 3600) / 60
        let s = m.uptimeSec % 60
        return String(describing: h) + "h " + String(describing: min) + "m " + String(describing: s) + "s"
    }

    private func metricsCard(
        _ m: EarbudDiagViewModel.EarbudMetrics,
        heapPct: Double
    ) -> some View {
        let heapStr    = heapLabel(m)
        let cpuStr     = cpuLabel(m)
        let cracenStr  = cracenLabel(m)
        let uptimeStr  = uptimeLabel(m)
        let batStr     = String(describing: m.batteryPct) + "%"
        return VStack(alignment: .leading, spacing: 12) {
            // HEAP row
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    metricLabel("HEAP")
                    Spacer()
                    Text(heapStr)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurface)
                        .monospacedDigit()
                }
                ProgressView(value: heapPct)
                    .tint(heapPct > 0.4 ? extras.success : extras.warning)
            }

            Divider().background(scheme.outline.opacity(0.4))

            // CPU / CRACEN / BAT row
            HStack(spacing: 0) {
                metricColumn("CPU", value: cpuStr)
                Spacer()
                metricColumn("CRACEN", value: cracenStr)
                Spacer()
                metricColumn("BAT", value: batStr)
            }

            Divider().background(scheme.outline.opacity(0.4))

            // FW / UPTIME row
            HStack(spacing: 0) {
                metricColumn("FW", value: m.firmwareVersion)
                Spacer()
                metricColumn("UPTIME", value: uptimeStr)
            }

            Divider().background(scheme.outline.opacity(0.4))

            // PDM / TDM / AXON status chips
            HStack(spacing: 16) {
                statusChip("PDM", active: m.pdmActive)
                statusChip("TDM", active: m.tdmActive)
                statusChip("AXON", active: m.axonOk)
                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(extras.success.opacity(0.3), lineWidth: 1)
        )
    }

    private func metricLabel(_ label: String) -> some View {
        Text(label)
            .qaudionStyle(type.labelSmall)
            .tracking(1.0)
            .foregroundStyle(scheme.onSurfaceVariant)
    }

    private func metricColumn(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            metricLabel(label)
            Text(value)
                .qaudionStyle(type.titleSmall)
                .foregroundStyle(scheme.onSurface)
                .monospacedDigit()
        }
    }

    private func statusChip(_ label: String, active: Bool) -> some View {
        Text(label)
            .qaudionStyle(type.labelSmall)
            .tracking(0.6)
            .foregroundStyle(active ? extras.success : scheme.onSurfaceVariant)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(active ? extras.success.opacity(0.15) : scheme.surfaceVariant)
            )
            .overlay(
                Capsule()
                    .stroke((active ? extras.success : scheme.outline).opacity(0.5), lineWidth: 1)
            )
    }

    private func lastUpdatedFooter(_ date: Date) -> some View {
        let ts = date.formatted(date: .omitted, time: .standard)
        let line = "Ultimo aggiornamento: " + ts
        return Text(line)
            .qaudionStyle(type.labelSmall)
            .foregroundStyle(scheme.onSurfaceVariant)
            .padding(.horizontal, 4)
    }

    // MARK: - Pairing section (FE-5 earbud-exclusive pairing)

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader("PAIRING AURICOLARE (FE-5)")
            pairingCard
        }
    }

    private var pairingCard: some View {
        let isPairing = vm.pairingStatus == .inProgress
        return VStack(alignment: .leading, spacing: 12) {
            // Manual single-earbud pairing (Phase-1 diagnostic)
            Button {
                Task { await vm.pairWithConnectedEarbud() }
            } label: {
                HStack(spacing: 8) {
                    if isPairing {
                        ProgressView()
                            .tint(scheme.onPrimary)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Text(isPairing ? "Pairing in corso…" : "Avvia Pairing")
                        .qaudionStyle(type.labelLarge)
                }
                .foregroundStyle(scheme.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isPairing
                              ? extras.pqcAccent.opacity(0.6)
                              : extras.pqcAccent.opacity(0.85))
                )
            }
            .buttonStyle(.plain)
            .disabled(isPairing)

            // Auto-relay: two-phone cross-earbud pairing via server exchange (FE-5 Phase-2)
            Button {
                vm.startAutoRelay()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Auto-relay (cross-phone)")
                        .qaudionStyle(type.labelLarge)
                }
                .foregroundStyle(scheme.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(extras.success.opacity(isPairing ? 0.4 : 0.75))
                )
            }
            .buttonStyle(.plain)
            .disabled(isPairing)

            // Relay status banner (visible while auto-relay is running or just finished)
            if let status = vm.relayStatus {
                HStack(spacing: 8) {
                    if vm.pairingStatus == .inProgress {
                        ProgressView()
                            .tint(extras.pqcAccent)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(extras.pqcAccent)
                    }
                    Text(status)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(extras.pqcAccent)
                        .lineLimit(2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(extras.pqcAccent.opacity(0.08))
                )
            }

            pairingStatusRow
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(pairingBorderColor.opacity(0.35), lineWidth: 1)
        )
    }

    private var pairingBorderColor: Color {
        switch vm.pairingStatus {
        case .idle:       return scheme.outline
        case .inProgress: return extras.pqcAccent
        case .success:    return extras.success
        case .failed:     return extras.riskHigh
        }
    }

    private var pairingStatusRow: some View {
        let (icon, label, color) = pairingStatusContent
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(color)
                .lineLimit(2)
        }
        .padding(.top, 2)
    }

    private var pairingStatusContent: (icon: String, label: String, color: Color) {
        switch vm.pairingStatus {
        case .idle:
            return ("circle", "In attesa · premere Avvia Pairing per eseguire c5/c6/c7", scheme.onSurfaceVariant)
        case .inProgress:
            return ("arrow.triangle.2.circlepath", "Scambio GATT in corso (PAIR_BEGIN → PAIR_RESP → PAIR_FIN)…", extras.pqcAccent)
        case .success(let pairId):
            return ("checkmark.shield.fill", "Pairing completato · pair_id: " + pairId, extras.success)
        case .failed(let reason):
            return ("xmark.circle.fill", "Errore: " + reason, extras.riskHigh)
        }
    }

    // MARK: - Connecting placeholder

    private var connectingSection: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(extras.pqcAccent)
            Text("Connessione all'auricolare…")
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Empty state

    private var emptyStateSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "headphones")
                .font(.system(size: 48))
                .foregroundStyle(scheme.onSurfaceVariant.opacity(0.4))
            Text("Nessun auricolare Q-Audion rilevato")
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Text("Assicurati che l'auricolare sia acceso e in modalità pairing, poi avvia la scansione.")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - BLE permission hint

    private var blePermissionHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(extras.warning)
                .padding(.top, 1)
            Text("Accesso Bluetooth negato. Abilitalo in Impostazioni iOS → Privacy → Bluetooth.")
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(extras.warning)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(extras.warning.opacity(0.12))
        )
    }

    // MARK: - Action handler

    private func handleScanButton() {
        if vm.scanState == .scanning {
            vm.stopScan()
        } else {
            vm.startScan()
        }
    }
}

#Preview {
    NavigationStack {
        EarbudDiagScreen()
    }
    .qAudionTheme(dark: true)
}
