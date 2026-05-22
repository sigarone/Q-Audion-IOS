import SwiftUI
import CoreBluetooth

struct P3ControlScreen: View {
    @StateObject private var gattManager = QaP3GattManager()
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    
    @State private var usDutyOverride: Float = 40.0
    @State private var irDutyOverride: Float = 40.0
    @State private var maskLevelOverride: Float = 50.0
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Custom Top Bar
                HStack {
                    Button(action: {
                        dismiss()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Indietro")
                        }
                        .foregroundColor(scheme.primary)
                    }
                    
                    Spacer()
                    
                    Text("P3 Simboard Control")
                        .font(.headline)
                        .foregroundColor(scheme.onSurface)
                    
                    Spacer()
                    
                    if case .ready = gattManager.connState {
                        Button(action: {
                            gattManager.disconnect()
                        }) {
                            Text("Disconnetti")
                                .foregroundColor(scheme.error)
                        }
                    } else {
                        Spacer().frame(width: 80)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 56)
                
                ScrollView {
                    VStack(spacing: 16) {
                        connectionSection
                        
                        if case .ready = gattManager.connState {
                            statusSection
                            modeControlSection
                            subsystemSection
                            radarSection
                            rfScanSection
                            counterSpySection
                            telemetrySection
                            debugSection
                            logConsoleSection
                        }
                        
                        Spacer().frame(height: 24)
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear {
            gattManager.stopScan()
            gattManager.disconnect()
        }
    }
    
    // MARK: - Subviews
    
    private var connectionSection: some View {
        SectionCard(title: "Connessione") {
            let (statusText, statusColor) = connectionStatusDetails
            
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.body)
                    .foregroundColor(statusColor)
                Spacer()
            }
            
            Spacer().frame(height: 12)
            
            let isConnected: Bool = {
                if case .ready = gattManager.connState { return true }
                return false
            }()
            
            if !isConnected {
                HStack(spacing: 8) {
                    Button(action: {
                        gattManager.startScan()
                    }) {
                        Text("Scansiona QA-P3-BENCH")
                            .font(.body)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(gattManager.connState == .scanning ? Color.gray.opacity(0.3) : scheme.primary)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                    .disabled(gattManager.connState == .scanning)
                    
                    if gattManager.connState == .scanning {
                        Button(action: {
                            gattManager.stopScan()
                        }) {
                            Text("Stop")
                                .font(.body)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .border(scheme.outline, width: 1)
                                .foregroundColor(scheme.onSurface)
                                .cornerRadius(4)
                        }
                    }
                }
                
                if !gattManager.scanned.isEmpty {
                    Spacer().frame(height: 12)
                    VStack(spacing: 0) {
                        ForEach(gattManager.scanned) { board in
                            Button(action: {
                                gattManager.connect(board: board)
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(board.displayName)
                                            .font(.body)
                                            .fontWeight(.semibold)
                                            .foregroundColor(scheme.onSurface)
                                        Text(board.addressDisplay)
                                            .font(.caption)
                                            .monospaced()
                                            .foregroundColor(scheme.onSurfaceVariant)
                                    }
                                    Spacer()
                                    let rssiLabel = "\(board.rssi) dBm"
                                    Text(rssiLabel)
                                        .font(.caption)
                                        .monospaced()
                                        .foregroundColor(scheme.onSurface)
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 4)
                            }
                            Divider().background(scheme.outline)
                        }
                    }
                } else if gattManager.connState == .scanning {
                    Spacer().frame(height: 16)
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
        }
    }
    
    private var connectionStatusDetails: (String, Color) {
        switch gattManager.connState {
        case .idle:
            return ("Disconnesso", scheme.onSurfaceVariant)
        case .scanning:
            return ("Scansione…", scheme.primary)
        case .connecting(let p):
            let name = p.name ?? p.identifier.uuidString
            let truncate = String(name.prefix(12))
            let connLabel = "Connessione a \(truncate)…"
            return (connLabel, scheme.primary)
        case .ready(let p):
            let name = p.name ?? p.identifier.uuidString
            let readyLabel = "Connesso: \(name)"
            return (readyLabel, Color(hex: 0x2FBF71))
        case .error(let msg):
            let errLabel = "Errore: \(msg)"
            return (errLabel, scheme.error)
        }
    }
    
    private var statusSection: some View {
        SectionCard(title: "Stato") {
            if let tlm = gattManager.telemetry {
                KeyValRow(k: "Modalità", v: tlm.mode.label, isAccent: tlm.mode != .idle)
                KeyValRow(k: "Armato", v: tlm.armed ? "SÌ" : "NO", isAccent: tlm.armed)
                KeyValRow(k: "Uptime", v: formatUptime(tlm.uptimeSec))
                
                let threadStatus = buildThreadStatusString(tlm: tlm)
                KeyValRow(k: "Thread", v: threadStatus)
                
                if tlm.anyFault {
                    Spacer().frame(height: 8)
                    let faultStr = buildFaultString(tlm: tlm)
                    let faultLabel = "FAULT: \(faultStr)"
                    Text(faultLabel)
                        .font(.body)
                        .fontWeight(.bold)
                        .foregroundColor(scheme.error)
                }
            } else {
                Text("In attesa della prima telemetria…")
                    .font(.caption)
                    .foregroundColor(scheme.onSurfaceVariant)
            }
        }
    }
    
    private var modeControlSection: some View {
        SectionCard(title: "Modalità & ARM") {
            HStack(spacing: 8) {
                Button(action: {
                    gattManager.sendCommand(opcode: QaP3Cmd.arm)
                }) {
                    Text("ARM")
                        .font(.body)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background((gattManager.telemetry?.armed ?? false) ? Color.gray.opacity(0.3) : scheme.primary)
                        .foregroundColor(.white)
                        .cornerRadius(4)
                }
                .disabled(gattManager.telemetry?.armed ?? false)
                
                Button(action: {
                    gattManager.sendCommand(opcode: QaP3Cmd.disarm)
                }) {
                    Text("DISARM")
                        .font(.body)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(scheme.error)
                        .foregroundColor(.white)
                        .cornerRadius(4)
                }
            }
            
            Spacer().frame(height: 12)
            Text("Forza modalità")
                .font(.caption)
                .foregroundColor(scheme.onSurfaceVariant)
            
            Spacer().frame(height: 8)
            
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    modeChip(mode: .idle)
                    modeChip(mode: .proximity)
                }
                HStack(spacing: 8) {
                    modeChip(mode: .room)
                    modeChip(mode: .professional)
                }
                HStack(spacing: 8) {
                    modeChip(mode: .conference)
                    Spacer()
                }
            }
        }
    }
    
    private var subsystemSection: some View {
        SectionCard(title: "Sottosistemi (gating granulare)") {
            if let tlm = gattManager.telemetry {
                let usSubText = usSubsystemStatusText(tlm: tlm)
                ToggleRow(
                    title: "Ultrasuoni (P1)",
                    subtitle: usSubText,
                    isOn: Binding(
                        get: { tlm.ultrasonicAllowed },
                        set: { on in
                            gattManager.sendCommand(opcode: on ? QaP3Cmd.subsysEnable : QaP3Cmd.subsysDisable, arg: QaP3Subsys.ultrasonic)
                        }
                    )
                )
                
                Divider().background(scheme.outline)
                
                let irSubText = irSubsystemStatusText(tlm: tlm)
                ToggleRow(
                    title: "Infrarossi (P2)",
                    subtitle: irSubText,
                    isOn: Binding(
                        get: { tlm.irAllowed },
                        set: { on in
                            gattManager.sendCommand(opcode: on ? QaP3Cmd.subsysEnable : QaP3Cmd.subsysDisable, arg: QaP3Subsys.ir)
                        }
                    )
                )
                
                Divider().background(scheme.outline)
                
                let audioSubText = tlm.audioActive ? "ACTIVE" : "idle"
                ToggleRow(
                    title: "Audio / speakerphone (P4)",
                    subtitle: audioSubText,
                    isOn: Binding(
                        get: { tlm.audioAllowed },
                        set: { on in
                            gattManager.sendCommand(opcode: on ? QaP3Cmd.subsysEnable : QaP3Cmd.subsysDisable, arg: QaP3Subsys.audio)
                        }
                    )
                )
            }
        }
    }
    
    private var radarSection: some View {
        SectionCard(title: "Radar respiro (P6)") {
            if let tlm = gattManager.telemetry {
                if !tlm.radarReady {
                    Text("Radar non rilevato — modulo P6 opzionale assente o non pronto")
                        .font(.body)
                        .foregroundColor(scheme.onSurfaceVariant)
                } else {
                    let rpm = tlm.radarBreathRpm
                    let rpmStr = rpm > 0.0 ? String(format: "%.1f", rpm) : "--"
                    
                    HStack(alignment: .lastTextBaseline) {
                        Text(rpmStr)
                            .font(.largeTitle)
                            .monospaced()
                            .fontWeight(.bold)
                            .foregroundColor(rpm > 0.0 ? scheme.primary : scheme.onSurfaceVariant)
                        Text("respiri/min")
                            .font(.caption)
                            .foregroundColor(scheme.onSurfaceVariant)
                            .padding(.bottom, 4)
                        Spacer()
                    }
                    
                    Spacer().frame(height: 8)
                    
                    KeyValRow(k: "Presenza", v: tlm.radarPresence ? "RILEVATA" : "assente", isAccent: tlm.radarPresence)
                    KeyValRow(k: "Soggetto", v: tlm.radarStationary ? "fermo (respiro valido)" : "in movimento / nessuno")
                    
                    let distText = "\(tlm.radarDistanceCm) cm"
                    KeyValRow(k: "Distanza", v: distText)
                    
                    if tlm.radarPresence && !tlm.radarStationary {
                        Spacer().frame(height: 6)
                        Text("Stima respiro disponibile solo con soggetto fermo")
                            .font(.caption)
                            .foregroundColor(scheme.onSurfaceVariant)
                    }
                    
                    Spacer().frame(height: 12)
                    
                    NavigationLink(destination: RadarMap3DScreen(gattManager: gattManager)) {
                        Text("Apri mappa 3D radar")
                            .font(.body)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(scheme.primary)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    private var rfScanSection: some View {
        SectionCard(title: "RF counter-surveillance (P7 + P9)") {
            if let rfp = gattManager.rfPower, rfp.ready {
                let colLifeLocal = Color(hex: 0x2FBF71)
                HStack(spacing: 8) {
                    Circle()
                        .fill(rfp.alert ? scheme.error : colLifeLocal)
                        .frame(width: 8, height: 8)
                    Text("Broadband RF (AD8318): ")
                        .font(.body)
                        .foregroundColor(scheme.onSurface)
                    
                    let powerStatusText: String = {
                        if rfp.sustained && rfp.burst { return "SORGENTE ATTIVA + BURST" }
                        if rfp.sustained { return "trasmettitore fisso" }
                        if rfp.burst { return "burst rilevato" }
                        return "pulito"
                    }()
                    
                    Text(powerStatusText)
                        .font(.body)
                        .fontWeight(.bold)
                        .foregroundColor(rfp.alert ? scheme.error : colLifeLocal)
                }
                
                let pwrValueText = "\(rfp.dbm) / \(rfp.peakDbm) / \(rfp.floorDbm) dBm"
                KeyValRow(k: "Potenza / picco / floor", v: pwrValueText)
                Spacer().frame(height: 10)
            } else {
                Text("Broadband RF (AD8318): non collegato (modulo P9 assente)")
                    .font(.caption)
                    .foregroundColor(scheme.onSurfaceVariant)
                Spacer().frame(height: 10)
            }
            
            if let rf = gattManager.rfScan, rf.ready {
                let colLifeLocal = Color(hex: 0x2FBF71)
                let suspects = rf.suspectCount
                let suspectsStr = String(describing: suspects)
                HStack(alignment: .lastTextBaseline) {
                    Text(suspectsStr)
                        .font(.largeTitle)
                        .monospaced()
                        .fontWeight(.bold)
                        .foregroundColor(suspects > 0 ? scheme.error : colLifeLocal)
                    Text("sorgenti sospette")
                        .font(.caption)
                        .foregroundColor(scheme.onSurfaceVariant)
                        .padding(.bottom, 4)
                    Spacer()
                }
                
                Spacer().frame(height: 8)
                KeyValRow(k: "Emettitori 2.4 GHz", v: String(describing: rf.emitterCount))
                
                let maxRssiVal = rf.strongestRssi ?? -127
                let strongestRssiText = rf.strongestRssi != nil ? "\(rf.strongestRssi!) dBm" : "—"
                KeyValRow(k: "Più forte", v: strongestRssiText, isAccent: maxRssiVal > -55)
                
                Spacer().frame(height: 8)
                
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<rf.bins, id: \.self) { b in
                        let energy = Double(rf.activity[b]) / 100.0
                        let heightFraction = max(0.02, min(1.0, energy))
                        let isSuspect = rf.isSuspect(b)
                        
                        GeometryReader { geo in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(isSuspect ? scheme.error : scheme.primary.opacity(0.55))
                                    .frame(height: geo.size.height * CGFloat(heightFraction))
                            }
                        }
                        .frame(height: 40)
                    }
                }
                
                Spacer().frame(height: 6)
                Text("Rilevatore di attività/energia 2.4 GHz (non analizzatore di spettro): segnala emettitori vicini/forti come candidati da ispezionare, non identificazioni certe.")
                    .font(.caption)
                    .foregroundColor(scheme.onSurfaceVariant)
            } else {
                Text("Scanner 2.4 GHz non attivo (richiede stack BLE up)")
                    .font(.caption)
                    .foregroundColor(scheme.onSurfaceVariant)
            }
        }
    }
    
    private var counterSpySection: some View {
        SectionCard(title: "Controspionaggio (P8)") {
            if let tlm = gattManager.telemetry {
                let colLifeLocal = Color(hex: 0x2FBF71)
                let (riskLabel, riskColor): (String, Color) = {
                    switch tlm.cspRiskLevel {
                    case 3: return ("ALTO", scheme.error)
                    case 2: return ("ELEVATO", Color(hex: 0xE0A53C))
                    case 1: return ("BASSO", Color(hex: 0xE0C53C))
                    default: return ("nessuno", colLifeLocal)
                    }
                }()
                
                HStack(spacing: 8) {
                    Circle()
                        .fill(riskColor)
                        .frame(width: 8, height: 8)
                    Text("Rischio intercettazione: ")
                        .font(.body)
                        .foregroundColor(scheme.onSurface)
                    Text(riskLabel)
                        .font(.body)
                        .fontWeight(.bold)
                        .foregroundColor(riskColor)
                    Spacer()
                }
                
                Spacer().frame(height: 12)
                
                if tlm.cspDuress {
                    Text("⚠ DURESS ATTIVO — secure-wipe richiesto")
                        .font(.body)
                        .fontWeight(.bold)
                        .foregroundColor(scheme.error)
                    Spacer().frame(height: 6)
                    Button(action: {
                        gattManager.sendCommand(opcode: QaP3Cmd.duressClear)
                    }) {
                        Text("Azzera duress")
                            .font(.body)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(scheme.primary)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                } else {
                    KeyValRow(k: "Duress (gesto IMU)", v: "armato")
                    Text("Scuoti il dispositivo 3 volte per attivare il duress")
                        .font(.caption)
                        .foregroundColor(scheme.onSurfaceVariant)
                }
                
                Spacer().frame(height: 12)
                
                let maskSubtitle = maskSubtitleText(tlm: tlm)
                
                ToggleRow(
                    title: "Mascheramento superficie",
                    subtitle: maskSubtitle,
                    isOn: Binding(
                        get: { tlm.cspMaskEnabled },
                        set: { on in
                            gattManager.sendCommand(opcode: on ? QaP3Cmd.maskOn : QaP3Cmd.maskOff)
                        }
                    )
                )
                
                if tlm.cspMaskEnabled {
                    Spacer().frame(height: 8)
                    let maskLvlVal = Int(maskLevelOverride)
                    let maskLvlOverrideText = "Livello mask \(maskLvlVal)%"
                    Text(maskLvlOverrideText)
                        .font(.caption)
                        .foregroundColor(scheme.onSurface)
                    Slider(value: $maskLevelOverride, in: 0...100, step: 5)
                    Button(action: {
                        gattManager.sendCommand(opcode: QaP3Cmd.setMaskLevel, arg: Int(maskLevelOverride))
                    }) {
                        Text("Applica livello")
                            .font(.body)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(scheme.primary)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                }
            }
        }
    }
    
    private var telemetrySection: some View {
        SectionCard(title: "Telemetria") {
            if let tlm = gattManager.telemetry {
                let splFrac = max(0.0, min(1.0, Double(tlm.splDb) / 130.0))
                let splText = String(format: "SPL %.1f dBSPL", tlm.splDb)
                
                Text(splText)
                    .font(.body)
                    .monospaced()
                    .foregroundColor(scheme.onSurface)
                
                Spacer().frame(height: 4)
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(scheme.surfaceVariant)
                            .frame(height: 10)
                        
                        RoundedRectangle(cornerRadius: 5)
                            .fill(tlm.splDb >= 110.0 ? scheme.error : Color(hex: 0x2E7D32))
                            .frame(width: geo.size.width * CGFloat(splFrac), height: 10)
                    }
                }
                .frame(height: 10)
                
                Spacer().frame(height: 12)
                
                let usTlmValue = "duty=\(tlm.usDutyPct)% gain=\(tlm.usGainPct)% \(tlm.usEnabled ? "ON" : "OFF")"
                KeyValRow(k: "Ultrasuoni", v: usTlmValue)
                
                let irTlmValue = "duty=\(tlm.irDutyPct)% \(tlm.irEnabled ? "ON" : "OFF")"
                KeyValRow(k: "Infrarossi", v: irTlmValue)
                
                KeyValRow(k: "Audio", v: tlm.audioActive ? "ACTIVE" : "idle")
                KeyValRow(k: "Log level", v: String(describing: tlm.logLevel))
                
                let maskHex = String(format: "0x%02X", tlm.subsysMask)
                KeyValRow(k: "Subsys mask", v: maskHex)
            }
        }
    }
    
    private var debugSection: some View {
        SectionCard(title: "Debug & override") {
            VStack(alignment: .leading, spacing: 12) {
                let usOverrideVal = Int(usDutyOverride)
                let usOverrideText = "Override duty ultrasuoni \(usOverrideVal)%"
                Text(usOverrideText)
                    .font(.caption)
                    .foregroundColor(scheme.onSurface)
                Slider(value: $usDutyOverride, in: 0...100, step: 5)
                HStack(spacing: 8) {
                    Button(action: {
                        gattManager.sendCommand(opcode: QaP3Cmd.setUsDuty, arg: Int(usDutyOverride))
                    }) {
                        Text("Applica")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(scheme.primary)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                    Button(action: {
                        gattManager.sendCommand(opcode: QaP3Cmd.setUsDuty, arg: 0xFF)
                    }) {
                        Text("Default firmware")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .border(scheme.outline, width: 1)
                            .foregroundColor(scheme.onSurface)
                            .cornerRadius(4)
                    }
                }
                
                Divider().background(scheme.outline)
                
                let irOverrideVal = Int(irDutyOverride)
                let irOverrideText = "Override duty IR \(irOverrideVal)%"
                Text(irOverrideText)
                    .font(.caption)
                    .foregroundColor(scheme.onSurface)
                Slider(value: $irDutyOverride, in: 0...100, step: 5)
                HStack(spacing: 8) {
                    Button(action: {
                        gattManager.sendCommand(opcode: QaP3Cmd.setIrDuty, arg: Int(irDutyOverride))
                    }) {
                        Text("Applica")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(scheme.primary)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                    Button(action: {
                        gattManager.sendCommand(opcode: QaP3Cmd.setIrDuty, arg: 0xFF)
                    }) {
                        Text("Default firmware")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .border(scheme.outline, width: 1)
                            .foregroundColor(scheme.onSurface)
                            .cornerRadius(4)
                    }
                }
                
                Divider().background(scheme.outline)
                
                Text("Log level Zephyr")
                    .font(.caption)
                    .foregroundColor(scheme.onSurface)
                
                HStack(spacing: 4) {
                    logLevelButton(label: "OFF", level: 0)
                    logLevelButton(label: "ERR", level: 1)
                    logLevelButton(label: "WRN", level: 2)
                    logLevelButton(label: "INF", level: 3)
                    logLevelButton(label: "DBG", level: 4)
                }
                
                Divider().background(scheme.outline)
                
                HStack(spacing: 8) {
                    Button(action: {
                        gattManager.sendCommand(opcode: QaP3Cmd.clearFaults)
                    }) {
                        Text("Clear faults")
                            .font(.body)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(scheme.primary)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                    
                    Button(action: {
                        gattManager.sendCommand(opcode: QaP3Cmd.ping)
                    }) {
                        Text("Ping / refresh")
                            .font(.body)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .border(scheme.outline, width: 1)
                            .foregroundColor(scheme.onSurface)
                            .cornerRadius(4)
                    }
                }
            }
        }
    }
    
    private var logConsoleSection: some View {
        SectionCard(title: "Console log (LOG characteristic)") {
            let logCountText = "\(gattManager.logLines.count) righe"
            HStack {
                Text(logCountText)
                    .font(.caption)
                    .foregroundColor(scheme.onSurfaceVariant)
                Spacer()
                Button(action: {
                    gattManager.clearLog()
                }) {
                    Text("Pulisci")
                        .font(.caption)
                        .foregroundColor(scheme.primary)
                }
            }
            
            Spacer().frame(height: 8)
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(gattManager.logLines.reversed(), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(hex: 0xC9D1D9))
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .frame(height: 260)
            .padding(8)
            .background(Color(hex: 0x0D1117))
            .cornerRadius(4)
        }
    }
    
    private func modeChip(mode: QaP3Mode) -> some View {
        let isSelected = gattManager.telemetry?.mode == mode
        return Button(action: {
            gattManager.sendCommand(opcode: QaP3Cmd.setMode, arg: mode.rawValue)
        }) {
            HStack {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption)
                }
                Text(mode.label)
                    .font(.body)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? scheme.primaryContainer : scheme.surfaceVariant)
            .foregroundColor(isSelected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant)
            .border(isSelected ? scheme.primary : Color.clear, width: 1)
            .cornerRadius(4)
        }
    }
    
    private func logLevelButton(label: String, level: Int) -> some View {
        Button(action: {
            gattManager.sendCommand(opcode: QaP3Cmd.setLogLevel, arg: level)
        }) {
            Text(label)
                .font(.caption2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .border(scheme.outline, width: 1)
                .foregroundColor(scheme.onSurface)
                .cornerRadius(4)
        }
    }
    
    private func buildThreadStatusString(tlm: QaP3Telemetry) -> String {
        var s = ""
        s += tlm.safetyThreadUp ? "safety✓ " : "safety✗ "
        s += tlm.emissionThreadUp ? "emission✓ " : "emission✗ "
        s += tlm.audioThreadUp ? "audio✓" : "audio✗"
        return s
    }
    
    private func buildFaultString(tlm: QaP3Telemetry) -> String {
        var parts = [String]()
        if tlm.faultRefMic { parts.append("REF-MIC") }
        if tlm.faultImu { parts.append("IMU") }
        if tlm.faultTamper { parts.append("TAMPER") }
        return parts.joined(separator: " ")
    }
    
    private func usSubsystemStatusText(tlm: QaP3Telemetry) -> String {
        let duty = tlm.usDutyPct.description
        let gain = tlm.usGainPct.description
        let state = tlm.usEnabled ? "EMITTING" : "off"
        return "duty \(duty)% gain \(gain)% \(state)"
    }
    
    private func irSubsystemStatusText(tlm: QaP3Telemetry) -> String {
        let duty = tlm.irDutyPct.description
        let state = tlm.irEnabled ? "EMITTING" : "off"
        return "duty \(duty)% \(state)"
    }
    
    private func maskSubtitleText(tlm: QaP3Telemetry) -> String {
        let base = "anti micro a contatto / laser — usa l'esciter P4"
        if tlm.cspMaskEnabled {
            let level = tlm.cspMaskLevel.description
            return "\(base)  (ATTIVO \(level)%)"
        } else {
            return base
        }
    }
    
    private func formatUptime(_ sec: Int64) -> String {
        let h = sec / 3600
        let m = (sec % 3600) / 60
        let s = sec % 60
        if h > 0 {
            return "\(h)h \(m)m \(s)s"
        } else if m > 0 {
            return "\(m)m \(s)s"
        } else {
            return "\(s)s"
        }
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let content: Content
    
    @Environment(\.qaudionScheme) private var scheme
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(scheme.onSurface)
            
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(scheme.surface)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(scheme.primary.opacity(0.4), lineWidth: 1)
        )
    }
}

struct KeyValRow: View {
    let k: String
    let v: String
    var isAccent: Bool = false
    
    @Environment(\.qaudionScheme) private var scheme
    
    var body: some View {
        HStack {
            Text(k)
                .font(.caption)
                .foregroundColor(scheme.onSurfaceVariant)
            Spacer()
            Text(v)
                .font(.body)
                .monospaced()
                .fontWeight(isAccent ? .bold : .regular)
                .foregroundColor(isAccent ? scheme.primary : scheme.onSurface)
        }
        .padding(.vertical, 3)
    }
}

struct ToggleRow: View {
    let title: String
    let subtitle: String
    var isOn: Binding<Bool>
    
    @Environment(\.qaudionScheme) private var scheme
    
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(scheme.onSurface)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .monospaced()
                        .foregroundColor(scheme.onSurfaceVariant)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.vertical, 6)
    }
}
