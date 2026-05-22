import SwiftUI

struct RadarMap3DScreen: View {
    @ObservedObject var gattManager: QaP3GattManager
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    
    // Drag gestures for 3D rotation
    @State private var baseYaw: Double = -45.0
    @State private var basePitch: Double = 25.0
    @GestureState private var dragOffset = CGSize.zero
    
    // Simulation mode toggle for testing on simulator
    @State private var isSimulating: Bool = false
    
    var body: some View {
        let yaw = baseYaw + Double(dragOffset.width) * 0.5
        let pitch = max(10.0, min(75.0, basePitch + Double(dragOffset.height) * 0.5))
        
        ZStack {
            scheme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top Custom Navigation Bar
                customTopBar
                
                // Connection/Simulation status indicator
                statusStrip
                
                // Main 3D Canvas
                ZStack(alignment: .topTrailing) {
                    canvasArea(yaw: yaw, pitch: pitch)
                    
                    // Floating view controls
                    HStack(spacing: 8) {
                        Button(action: {
                            baseYaw = -45.0
                            basePitch = 25.0
                        }) {
                            Image(systemName: "camera.filters")
                                .font(.body)
                            Text("Visuale default")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(scheme.surface.opacity(0.8))
                        .foregroundColor(scheme.primary)
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(scheme.primary.opacity(0.4), lineWidth: 1)
                        )
                        
                        Toggle("Simula", isOn: $isSimulating)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(scheme.onSurface)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(scheme.surface.opacity(0.8))
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(scheme.outline, lineWidth: 1)
                            )
                            .labelsHidden()
                            .overlay(
                                HStack {
                                    Text("Simula")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(scheme.onSurface)
                                        .padding(.leading, 8)
                                    Spacer()
                                }
                                .allowsHitTesting(false)
                            )
                            .frame(width: 90)
                    }
                    .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Bottom stats & breathing wave panel
                bottomPanel
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
    
    // MARK: - Navigation Bar
    
    private var customTopBar: some View {
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
            
            Text("Mappa 3D Radar")
                .font(.headline)
                .foregroundColor(scheme.onSurface)
            
            Spacer()
            
            // Spacer to balance back button
            Spacer().frame(width: 80)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }
    
    // MARK: - Status Strip
    
    private var statusStrip: some View {
        HStack {
            if isSimulating {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    Text("SIMULAZIONE ATTIVA (Dati Mock)")
                        .font(.caption2)
                        .monospaced()
                        .foregroundColor(.orange)
                }
            } else {
                switch gattManager.connState {
                case .ready(let p):
                    let name = p.name ?? "QA-P3-BENCH"
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(hex: 0x2FBF71))
                            .frame(width: 6, height: 6)
                        let statusText = "CONNESSO: \(name)"
                        Text(statusText)
                            .font(.caption2)
                            .monospaced()
                            .foregroundColor(Color(hex: 0x2FBF71))
                    }
                default:
                    HStack(spacing: 6) {
                        Circle()
                            .fill(scheme.error)
                            .frame(width: 6, height: 6)
                        Text("RADAR SCOLLEGATO (Nessun dato BLE)")
                            .font(.caption2)
                            .monospaced()
                            .foregroundColor(scheme.error)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(scheme.surfaceVariant.opacity(0.4))
    }
    
    // MARK: - 3D Canvas Area
    
    private func canvasArea(yaw: Double, pitch: Double) -> some View {
        TimelineView(.animation) { timeline in
            let date = timeline.date
            
            // Resolve radar & RF data sources (live or simulated)
            let radarData = getActiveRadarMap(date: date)
            let rfData = getActiveRfScan(date: date)
            
            Canvas { context, size in
                let width = size.width
                let height = size.height
                let centerPoint = CGPoint(x: width / 2.0, y: height * 0.62)
                let scale = Double(min(width, height)) / 370.0
                
                let yawRad = yaw * .pi / 180.0
                let pitchRad = pitch * .pi / 180.0
                
                // Colors
                let colGrid = Color(hex: 0x1E2530)
                let colText = scheme.onSurfaceVariant.opacity(0.8)
                
                // 1. Draw Back Wall Grid (at Z = 360)
                drawBackWallGrid(context: &context, yawRad: yawRad, pitchRad: pitchRad, center: centerPoint, scale: scale, color: colGrid)
                
                // 2. Draw RF Scan Activity spectrum wall
                drawRfSpectrumWall(context: &context, rfScan: rfData, yawRad: yawRad, pitchRad: pitchRad, center: centerPoint, scale: scale)
                
                // 3. Draw Ground Grid
                drawGroundGrid(context: &context, yawRad: yawRad, pitchRad: pitchRad, center: centerPoint, scale: scale, color: colGrid, textColor: colText)
                
                // 4. Draw Energy Columns (painter's algorithm: gate 8 to 0)
                drawEnergyColumns(context: &context, radarMap: radarData, yawRad: yawRad, pitchRad: pitchRad, center: centerPoint, scale: scale, date: date)
            }
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        baseYaw += Double(value.translation.width) * 0.5
                        basePitch = max(10.0, min(75.0, basePitch + Double(value.translation.height) * 0.5))
                    }
            )
        }
    }
    
    // MARK: - 3D Render Helpers
    
    private func project(x: Double, y: Double, z: Double, yawRad: Double, pitchRad: Double, center: CGPoint, scale: Double) -> CGPoint {
        // Rotate around Y axis (yaw), centering the grid's Z axis around 180.0
        let relativeZ = z - 180.0
        let xRot = x * cos(yawRad) - relativeZ * sin(yawRad)
        let zRot = x * sin(yawRad) + relativeZ * cos(yawRad)
        
        // Rotate around X axis (pitch)
        let yRot = y * cos(pitchRad) - zRot * sin(pitchRad)
        
        return CGPoint(
            x: center.x + CGFloat(xRot * scale),
            y: center.y - CGFloat(yRot * scale)
        )
    }
    
    private func drawBackWallGrid(context: inout GraphicsContext, yawRad: Double, pitchRad: Double, center: CGPoint, scale: Double, color: Color) {
        let wallZ = 360.0
        let wallHeight = 85.0
        let xMin = -65.0
        let xMax = 65.0
        
        // Horizontal lines on the wall
        for yStep in [0.0, 20.0, 40.0, 60.0, 80.0] {
            var path = Path()
            let p1 = project(x: xMin, y: yStep, z: wallZ, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
            let p2 = project(x: xMax, y: yStep, z: wallZ, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
            path.move(to: p1)
            path.addLine(to: p2)
            context.stroke(path, with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1.0))
        }
        
        // Vertical lines on the wall
        for xStep in [-65.0, -32.5, 0.0, 32.5, 65.0] {
            var path = Path()
            let pBottom = project(x: xStep, y: 0.0, z: wallZ, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
            let pTop = project(x: xStep, y: wallHeight, z: wallZ, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
            path.move(to: pBottom)
            path.addLine(to: pTop)
            context.stroke(path, with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1.0))
        }
    }
    
    private func drawRfSpectrumWall(context: inout GraphicsContext, rfScan: QaP3RfScan?, yawRad: Double, pitchRad: Double, center: CGPoint, scale: Double) {
        guard let scan = rfScan, scan.ready else { return }
        
        let bins = QaP3RfScan.bins
        let wallZ = 360.0
        let wallWidth = 130.0
        let binWidth = wallWidth / Double(bins)
        let leftBoundary = -wallWidth / 2.0
        
        let colSuspect = Color(hex: 0xE0524B) // Red
        let colNormal = scheme.primary.opacity(0.6) // Blue
        
        for b in 0..<bins {
            let energy = Double(scan.activity[b])
            guard energy > 0 else { continue }
            
            // Limit height to a max of 80 units
            let barHeight = min(80.0, energy * 0.8)
            let xStart = leftBoundary + Double(b) * binWidth
            let xEnd = xStart + binWidth
            
            let pBottomLeft = project(x: xStart, y: 0.0, z: wallZ, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
            let pBottomRight = project(x: xEnd, y: 0.0, z: wallZ, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
            let pTopRight = project(x: xEnd, y: barHeight, z: wallZ, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
            let pTopLeft = project(x: xStart, y: barHeight, z: wallZ, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
            
            var path = Path()
            path.move(to: pBottomLeft)
            path.addLine(to: pBottomRight)
            path.addLine(to: pTopRight)
            path.addLine(to: pTopLeft)
            path.closeSubpath()
            
            let color = scan.isSuspect(b) ? colSuspect : colNormal
            context.fill(path, with: .color(color.opacity(0.4)))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.0))
        }
    }
    
    private func drawGroundGrid(context: inout GraphicsContext, yawRad: Double, pitchRad: Double, center: CGPoint, scale: Double, color: Color, textColor: Color) {
        let xMin = -65.0
        let xMax = 65.0
        let zMax = 360.0
        let totalGates = QaP3RadarMap.gates
        let gateSpacing = zMax / Double(totalGates)
        
        // Transverse grid lines (at each gate threshold)
        for g in 0...totalGates {
            let z = Double(g) * gateSpacing
            let pLeft = project(x: xMin, y: 0.0, z: z, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
            let pRight = project(x: xMax, y: 0.0, z: z, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
            
            var path = Path()
            path.move(to: pLeft)
            path.addLine(to: pRight)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5))
            
            // Labels (draw distance label slightly left of grid)
            if g < totalGates {
                let pLabel = project(x: xMin - 15.0, y: 0.0, z: z + (gateSpacing / 2.0), yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
                let distanceMeters = (Double(g) * 0.75) + 0.375
                let distanceText = String(format: "%.2fm", distanceMeters)
                
                context.draw(
                    Text(distanceText).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(textColor),
                    at: pLabel
                )
            }
        }
        
        // Longitudinal grid lines
        for xStep in [xMin, -32.5, 0.0, 32.5, xMax] {
            let pFront = project(x: xStep, y: 0.0, z: 0.0, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
            let pBack = project(x: xStep, y: 0.0, z: zMax, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
            
            var path = Path()
            path.move(to: pFront)
            path.addLine(to: pBack)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5))
        }
    }
    
    private func drawEnergyColumns(context: inout GraphicsContext, radarMap: QaP3RadarMap?, yawRad: Double, pitchRad: Double, center: CGPoint, scale: Double, date: Date) {
        guard let map = radarMap, map.ready else { return }
        
        let gates = QaP3RadarMap.gates
        let zMax = 360.0
        let gateSpacing = zMax / Double(gates)
        
        let colStillBase = Color(hex: 0x2FBF71)   // Green (Life)
        let colStillStatic = Color(hex: 0xE0524B) // Red (Static)
        let colMove = Color(hex: 0xE0A53C)        // Amber (Motion)
        let colEmpty = Color(hex: 0x3A3F4B)       // Gray-blue
        
        // Painter's algorithm: draw from back to front (g = gates-1 down to 0)
        for g in stride(from: gates - 1, through: 0, by: -1) {
            let zCenter = (Double(g) * gateSpacing) + (gateSpacing / 2.0)
            
            // 1. Determine gate properties & classes
            let gateClass = g < map.gateClass.count ? map.gateClass[g] : .empty
            let stillEnergy = g < map.stillGate.count ? Double(map.stillGate[g]) : 0.0
            let moveEnergy = g < map.moveGate.count ? Double(map.moveGate[g]) : 0.0
            
            // 2. Select Colors
            let stillColor: Color = {
                switch gateClass {
                case .life: return colStillBase
                case .staticClass: return colStillStatic
                default: return stillEnergy > 0 ? colStillBase : colEmpty
                }
            }()
            
            // 3. Draw Still (Stationary/Life) Column on the Left (X = -28)
            if stillEnergy > 0 {
                let height = min(90.0, stillEnergy * 0.35)
                draw3DBox(
                    context: &context,
                    x: -28.0,
                    z: zCenter,
                    w: 12.0,
                    d: 12.0,
                    h: height,
                    color: stillColor,
                    opacity: 0.65,
                    yawRad: yawRad,
                    pitchRad: pitchRad,
                    center: center,
                    scale: scale
                )
                
                // Pulse ring for breath gate
                if map.breathGate == g && map.breathRpm > 0.0 {
                    let timeFactor = date.timeIntervalSince1970 * 4.5
                    let ringHeightFrac = (sin(timeFactor) + 1.0) / 2.0
                    let ringHeight = height * ringHeightFrac
                    drawPulseRing(
                        context: &context,
                        x: -28.0,
                        z: zCenter,
                        w: 16.0,
                        d: 16.0,
                        y: ringHeight,
                        color: colStillBase,
                        yawRad: yawRad,
                        pitchRad: pitchRad,
                        center: center,
                        scale: scale
                    )
                }
            }
            
            // 4. Draw Motion Column on the Right (X = 28)
            if moveEnergy > 0 {
                let height = min(90.0, moveEnergy * 0.35)
                draw3DBox(
                    context: &context,
                    x: 28.0,
                    z: zCenter,
                    w: 12.0,
                    d: 12.0,
                    h: height,
                    color: colMove,
                    opacity: 0.65,
                    yawRad: yawRad,
                    pitchRad: pitchRad,
                    center: center,
                    scale: scale
                )
            }
        }
    }
    
    private func draw3DBox(context: inout GraphicsContext, x: Double, z: Double, w: Double, d: Double, h: Double, color: Color, opacity: Double, yawRad: Double, pitchRad: Double, center: CGPoint, scale: Double) {
        let hw = w / 2.0
        let hd = d / 2.0
        
        // 8 Vertices
        let v0 = project(x: x - hw, y: 0.0, z: z - hd, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
        let v1 = project(x: x + hw, y: 0.0, z: z - hd, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
        let v2 = project(x: x + hw, y: 0.0, z: z + hd, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
        let v3 = project(x: x - hw, y: 0.0, z: z + hd, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
        
        let v4 = project(x: x - hw, y: h, z: z - hd, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
        let v5 = project(x: x + hw, y: h, z: z - hd, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
        let v6 = project(x: x + hw, y: h, z: z + hd, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
        let v7 = project(x: x - hw, y: h, z: z + hd, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
        
        // Draw sides paths
        var sidesPath = Path()
        
        // Face 1: Front
        sidesPath.move(to: v0)
        sidesPath.addLine(to: v1)
        sidesPath.addLine(to: v5)
        sidesPath.addLine(to: v4)
        sidesPath.closeSubpath()
        
        // Face 2: Right
        sidesPath.move(to: v1)
        sidesPath.addLine(to: v2)
        sidesPath.addLine(to: v6)
        sidesPath.addLine(to: v5)
        sidesPath.closeSubpath()
        
        // Face 3: Back
        sidesPath.move(to: v2)
        sidesPath.addLine(to: v3)
        sidesPath.addLine(to: v7)
        sidesPath.addLine(to: v6)
        sidesPath.closeSubpath()
        
        // Face 4: Left
        sidesPath.move(to: v3)
        sidesPath.addLine(to: v0)
        sidesPath.addLine(to: v4)
        sidesPath.addLine(to: v7)
        sidesPath.closeSubpath()
        
        // Fill sides with light transparency
        context.fill(sidesPath, with: .color(color.opacity(opacity * 0.35)))
        
        // Draw Top face path
        var topPath = Path()
        topPath.move(to: v4)
        topPath.addLine(to: v5)
        topPath.addLine(to: v6)
        topPath.addLine(to: v7)
        topPath.closeSubpath()
        
        // Fill top with higher visibility
        context.fill(topPath, with: .color(color.opacity(opacity * 0.75)))
        
        // Stroke everything with thin outline
        context.stroke(sidesPath, with: .color(color), style: StrokeStyle(lineWidth: 1.0))
        context.stroke(topPath, with: .color(color), style: StrokeStyle(lineWidth: 1.0))
    }
    
    private func drawPulseRing(context: inout GraphicsContext, x: Double, z: Double, w: Double, d: Double, y: Double, color: Color, yawRad: Double, pitchRad: Double, center: CGPoint, scale: Double) {
        let hw = w / 2.0
        let hd = d / 2.0
        
        let p0 = project(x: x - hw, y: y, z: z - hd, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
        let p1 = project(x: x + hw, y: y, z: z - hd, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
        let p2 = project(x: x + hw, y: y, z: z + hd, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
        let p3 = project(x: x - hw, y: y, z: z + hd, yawRad: yawRad, pitchRad: pitchRad, center: center, scale: scale)
        
        var ringPath = Path()
        ringPath.move(to: p0)
        ringPath.addLine(to: p1)
        ringPath.addLine(to: p2)
        ringPath.addLine(to: p3)
        ringPath.closeSubpath()
        
        context.stroke(ringPath, with: .color(color), style: StrokeStyle(lineWidth: 2.0, lineJoin: .round))
    }
    
    // MARK: - Mock Data Generators for Simulator
    
    private func getActiveRadarMap(date: Date) -> QaP3RadarMap? {
        if isSimulating {
            let time = date.timeIntervalSince1970
            
            // Simulated moving target location (oscillating between gate 1 and 8)
            let moveGateIndex = 1 + Int((sin(time * 0.3) + 1.0) * 3.5)
            
            var move = Array(repeating: 0, count: 9)
            if moveGateIndex >= 0 && moveGateIndex < 9 {
                move[moveGateIndex] = 180 + Int(40.0 * sin(time * 3.0))
                if moveGateIndex - 1 >= 0 { move[moveGateIndex - 1] = 60 }
                if moveGateIndex + 1 < 9 { move[moveGateIndex + 1] = 60 }
            }
            
            // Stationary breathing subject placed at gate 4
            let stillGateIndex = 4
            let respiratoryPhase = sin(time * (14.5 / 60.0) * 2.0 * .pi)
            let breathingEnergy = 130 + Int(35.0 * respiratoryPhase)
            
            var still = Array(repeating: 0, count: 9)
            still[stillGateIndex] = breathingEnergy
            still[2] = 25 // Static clutter at gate 2
            
            var cls = Array(repeating: QaGateClass.empty, count: 9)
            cls[stillGateIndex] = .life
            cls[2] = .staticClass
            if moveGateIndex != stillGateIndex {
                cls[moveGateIndex] = .motion
            }
            
            return QaP3RadarMap(
                version: 0x01,
                ready: true,
                presence: true,
                stationary: true,
                engMode: true,
                breathGate: stillGateIndex,
                breathRpm: 14.5,
                heartBpm: 72,
                detectDistanceCm: 320,
                moveGate: move,
                stillGate: still,
                gateClass: cls
            )
        } else {
            return gattManager.radarMap
        }
    }
    
    private func getActiveRfScan(date: Date) -> QaP3RfScan? {
        if isSimulating {
            let time = date.timeIntervalSince1970
            
            var activity = Array(repeating: 0, count: 16)
            for i in 0..<16 {
                // Background floor noise
                let noise = 8 + Int(4.0 * sin(time * 5.0 + Double(i)))
                activity[i] = noise
            }
            
            // Spike at bin 6 (representing 2.4 GHz interference candidate)
            let rawActivity6 = 78 + Int(12.0 * sin(time * 2.0))
            activity[6] = min(100, max(0, rawActivity6))
            
            // Small bump at bin 12
            activity[12] = 42 + Int(6.0 * cos(time))
            
            // Bin 6 designated as suspect
            let suspectMask = 1 << 6
            
            return QaP3RfScan(
                version: 0x01,
                ready: true,
                emitterCount: 2,
                strongestRssi: -45,
                activity: activity,
                suspectMask: suspectMask
            )
        } else {
            return gattManager.rfScan
        }
    }
    
    // MARK: - Bottom Details Dashboard
    
    private var bottomPanel: some View {
        VStack(spacing: 12) {
            Divider().background(scheme.outline)
            
            TimelineView(.animation) { timeline in
                let radarData = getActiveRadarMap(date: timeline.date)
                
                let ready = radarData?.ready ?? false
                let presence = radarData?.presence ?? false
                let stationary = radarData?.stationary ?? false
                let distance = radarData?.detectDistanceCm ?? 0
                let rpm = radarData?.breathRpm ?? 0.0
                let bpm = radarData?.heartBpm ?? 0
                
                VStack(spacing: 12) {
                    let distanceVal = ready && presence ? "\(distance) cm" : "---"
                    let rpmVal = ready && presence && stationary && rpm > 0.0 ? String(format: "%.1f RPM", rpm) : "---"
                    let bpmVal = ready && presence && stationary && bpm > 0 ? "\(bpm) BPM" : "---"
                    
                    // Numerical stats row
                    HStack(spacing: 24) {
                        metricItem(
                            label: "DISTANZA",
                            value: distanceVal,
                            icon: "lane",
                            iconColor: scheme.primary
                        )
                        
                        metricItem(
                            label: "RESPIRAZIONE",
                            value: rpmVal,
                            icon: "wind",
                            iconColor: Color(hex: 0x2FBF71)
                        )
                        
                        metricItem(
                            label: "BATTITO",
                            value: bpmVal,
                            icon: "heart.fill",
                            iconColor: scheme.error
                        )
                    }
                    .padding(.horizontal, 16)
                    
                    // Wave graphic container
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("RITMO RESPIRATORIO")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(scheme.onSurfaceVariant)
                            
                            Spacer()
                            
                            if ready && presence && stationary {
                                Text("SOGGETTO FERMO - LETTURA ATTIVA")
                                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Color(hex: 0x2FBF71))
                            } else if ready && presence {
                                Text("MOVIMENTO CORPO - FILTRO ATTIVO")
                                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                    .foregroundColor(Color(hex: 0xE0A53C))
                            } else {
                                Text("NESSUN SOGGETTO RILEVATO")
                                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                    .foregroundColor(scheme.onSurfaceVariant.opacity(0.6))
                            }
                        }
                        
                        AnimatedBreathingWave(
                            breathRpm: Float(rpm),
                            isPresence: ready && presence
                        )
                        .frame(height: 52)
                        .background(Color(hex: 0x0D1117))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(scheme.outline, lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 12)
        }
        .background(scheme.surface)
    }
    
    private func metricItem(label: String, value: String, icon: String, iconColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(scheme.onSurfaceVariant)
            
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundColor(iconColor)
                
                Text(value)
                    .font(.body)
                    .monospaced()
                    .fontWeight(.bold)
                    .foregroundColor(scheme.onSurface)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Animated Wave View

struct AnimatedBreathingWave: View {
    let breathRpm: Float
    let isPresence: Bool
    
    @Environment(\.qaudionScheme) private var scheme
    
    var body: some View {
        TimelineView(.animation) { timeline in
            let date = timeline.date
            let rpm = Double(breathRpm)
            
            // Map RPM to rotation speed. Fallback to a slow wave if presence but no rpm
            let speed: Double
            if isPresence {
                speed = rpm > 0 ? (rpm / 60.0) * 2.0 * .pi : 1.2
            } else {
                speed = 0.3
            }
            
            let phase = date.timeIntervalSince1970 * speed
            
            Canvas { context, size in
                let width = size.width
                let height = size.height
                let centerY = height / 2.0
                
                var path = Path()
                path.move(to: CGPoint(x: 0, y: centerY))
                
                // Amplitude is flat if no presence, small if moving, sinusoidal if breathing
                let amplitude: Double
                if isPresence {
                    amplitude = rpm > 0 ? 14.0 : 4.0
                } else {
                    amplitude = 0.5
                }
                
                let wavelength: Double = 60.0
                
                for x in stride(from: 0.0, through: Double(width), by: 2.0) {
                    let y = centerY + sin((x / wavelength) - phase) * amplitude
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                
                let strokeColor: Color
                if isPresence {
                    strokeColor = rpm > 0 ? Color(hex: 0x2FBF71) : Color(hex: 0xE0A53C)
                } else {
                    strokeColor = scheme.onSurfaceVariant.opacity(0.2)
                }
                
                context.stroke(
                    path,
                    with: .color(strokeColor),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
            }
        }
    }
}
