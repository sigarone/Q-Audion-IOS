import SwiftUI
import CoreBluetooth

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
        var heapFree: Int = 0
        var heapTotal: Int = 0
        var cpuPercent: Int = 0
        var cracenOps: Int = 0
        var pdmActive: Bool = false
        var tdmActive: Bool = false
        var axonState: String = "idle"
        var bleConnected: Bool = false
        var firmwareVersion: String = "—"
        var lastUpdated: Date = Date()
    }

    // MARK: - Private state

    private var central: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?

    // Q-Audion GATT service UUID — must match qaudion-firmware gatt_server.
    // Placeholder until firmware UUIDs are published in qaudion-firmware CLAUDE.md.
    private static let serviceUUID = CBUUID(string: "12345678-1234-5678-1234-56789ABCDEF0")
    private static let metricsCharUUID = CBUUID(string: "12345678-1234-5678-1234-56789ABCDEF1")

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
        if let p = connectedPeripheral {
            central?.cancelPeripheralConnection(p)
        }
        connectedPeripheral = nil
        connectedEarbud = nil
        connectionState = .disconnected
        metrics = nil
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
        Task { @MainActor in
            self.connectionState = .connected
            self.metrics = EarbudMetrics(
                heapFree: 0, heapTotal: 0,
                cpuPercent: 0, cracenOps: 0,
                pdmActive: false, tdmActive: false,
                axonState: "connesso", bleConnected: true,
                firmwareVersion: "—", lastUpdated: Date()
            )
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
        guard let data = characteristic.value,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        Task { @MainActor in
            var m = self.metrics ?? EarbudDiagViewModel.EarbudMetrics()
            m.heapFree    = json["heap_free"]   as? Int ?? m.heapFree
            m.heapTotal   = json["heap_total"]  as? Int ?? m.heapTotal
            m.cpuPercent  = json["cpu_pct"]     as? Int ?? m.cpuPercent
            m.cracenOps   = json["cracen_ops"]  as? Int ?? m.cracenOps
            m.pdmActive   = json["pdm"]         as? Bool ?? m.pdmActive
            m.tdmActive   = json["tdm"]         as? Bool ?? m.tdmActive
            m.axonState   = json["axon"]        as? String ?? m.axonState
            m.bleConnected = true
            m.firmwareVersion = json["fw"]      as? String ?? m.firmwareVersion
            m.lastUpdated = Date()
            self.metrics = m
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

    private func metricsSection(_ m: EarbudDiagViewModel.EarbudMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader("METRICHE LIVE")
            let heapPct: Double = m.heapTotal > 0
                ? Double(m.heapFree) / Double(m.heapTotal)
                : 0.0
            metricsCard(m, heapPct: heapPct)
            lastUpdatedFooter(m.lastUpdated)
        }
    }

    // Pre-build all metric strings outside @ViewBuilder to avoid String(Int)
    // overload-resolution timeouts (CLAUDE.md §13 v1.0.255+).
    private func heapLabel(_ m: EarbudDiagViewModel.EarbudMetrics) -> String {
        let free = String(describing: m.heapFree / 1024)
        let total = String(describing: m.heapTotal / 1024)
        return free + " / " + total + " KB"
    }
    private func cpuLabel(_ m: EarbudDiagViewModel.EarbudMetrics) -> String {
        String(describing: m.cpuPercent) + "%"
    }
    private func cracenLabel(_ m: EarbudDiagViewModel.EarbudMetrics) -> String {
        String(describing: m.cracenOps) + " ops"
    }
    private func axonLabel(_ m: EarbudDiagViewModel.EarbudMetrics) -> String {
        "AXON " + m.axonState
    }

    private func metricsCard(
        _ m: EarbudDiagViewModel.EarbudMetrics,
        heapPct: Double
    ) -> some View {
        let heapStr = heapLabel(m)
        let cpuStr = cpuLabel(m)
        let cracenStr = cracenLabel(m)
        let axonStr = axonLabel(m)
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

            // CPU + CRACEN row
            HStack(spacing: 0) {
                metricColumn("CPU", value: cpuStr)
                Spacer()
                metricColumn("CRACEN", value: cracenStr)
                Spacer()
                metricColumn("FW", value: m.firmwareVersion)
            }

            Divider().background(scheme.outline.opacity(0.4))

            // PDM / TDM / AXON row
            HStack(spacing: 16) {
                statusChip("PDM", active: m.pdmActive)
                statusChip("TDM", active: m.tdmActive)
                statusChip(axonStr, active: m.axonState != "idle")
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
