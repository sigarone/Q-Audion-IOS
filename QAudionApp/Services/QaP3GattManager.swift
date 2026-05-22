import Foundation
import CoreBluetooth

public enum QaP3ConnState: Equatable {
    case idle
    case scanning
    case connecting(CBPeripheral)
    case ready(CBPeripheral)
    case error(String)
}

public struct ScannedBoard: Identifiable, Equatable {
    public var id: UUID {
        return peripheral.identifier
    }
    public let peripheral: CBPeripheral
    public let displayName: String
    public let rssi: Int
    
    public var addressDisplay: String {
        return peripheral.identifier.uuidString
    }
    
    public static func == (lhs: ScannedBoard, rhs: ScannedBoard) -> Bool {
        return lhs.id == rhs.id && lhs.rssi == rhs.rssi
    }
}

@MainActor
public final class QaP3GattManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    @Published public var connState: QaP3ConnState = .idle
    @Published public var scanned: [ScannedBoard] = []
    @Published public var telemetry: QaP3Telemetry? = nil
    @Published public var logLines: [String] = []
    @Published public var radarMap: QaP3RadarMap? = nil
    @Published public var rfScan: QaP3RfScan? = nil
    @Published public var rfPower: QaP3RfPower? = nil
    
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var cmdCharacteristic: CBCharacteristic?
    
    public override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    public func startScan() {
        guard centralManager.state == .poweredOn else {
            connState = .error("Bluetooth non attivo o non pronto")
            return
        }
        scanned = []
        connState = .scanning
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }
    
    public func stopScan() {
        centralManager.stopScan()
        if case .scanning = connState {
            connState = .idle
        }
    }
    
    public func connect(board: ScannedBoard) {
        stopScan()
        let peripheral = board.peripheral
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connState = .connecting(peripheral)
        
        telemetry = nil
        logLines = []
        radarMap = nil
        rfScan = nil
        rfPower = nil
        
        centralManager.connect(peripheral, options: nil)
    }
    
    public func disconnect() {
        if let p = connectedPeripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        cleanup()
        connState = .idle
    }
    
    public func sendCommand(opcode: Int, arg: Int = 0) {
        guard let peripheral = connectedPeripheral,
              let cmdChar = cmdCharacteristic,
              case .ready = connState else { return }
        
        let data = QaP3Cmd.encode(opcode: opcode, arg: arg)
        peripheral.writeValue(data, for: cmdChar, type: .withResponse)
    }
    
    public func clearLog() {
        logLines = []
    }
    
    private func cleanup() {
        connectedPeripheral?.delegate = nil
        connectedPeripheral = nil
        cmdCharacteristic = nil
        telemetry = nil
        radarMap = nil
        rfScan = nil
        rfPower = nil
    }
    
    // MARK: - CBCentralManagerDelegate
    
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            break
        case .poweredOff:
            connState = .error("Bluetooth disattivato")
        case .unauthorized:
            connState = .error("Bluetooth non autorizzato")
        case .unsupported:
            connState = .error("Bluetooth non supportato su questo dispositivo")
        default:
            connState = .error("Stato Bluetooth non disponibile")
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.lowercased().contains(QaP3Gatt.deviceName.lowercased()) else { return }
        
        let board = ScannedBoard(peripheral: peripheral, displayName: name, rssi: RSSI.intValue)
        var cur = scanned
        if let idx = cur.firstIndex(where: { $0.id == board.id }) {
            cur[idx] = board
        } else {
            cur.append(board)
        }
        self.scanned = cur.sorted(by: { $0.rssi > $1.rssi })
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([QaP3Gatt.serviceUUID])
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let msg = error?.localizedDescription ?? "Connessione fallita"
        connState = .error(msg)
        cleanup()
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cleanup()
        if let error = error {
            connState = .error("Disconnesso: \(error.localizedDescription)")
        } else {
            connState = .idle
        }
    }
    
    // MARK: - CBPeripheralDelegate
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            connState = .error("Errore scoperta servizi: \(error.localizedDescription)")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        guard let services = peripheral.services else { return }
        for service in services {
            if service.uuid == QaP3Gatt.serviceUUID {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            connState = .error("Errore scoperta caratteristiche: \(error.localizedDescription)")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        var foundCmd: CBCharacteristic?
        
        for ch in characteristics {
            switch ch.uuid {
            case QaP3Gatt.chCmdUUID:
                foundCmd = ch
            case QaP3Gatt.chTlmUUID, QaP3Gatt.chLogUUID, QaP3Gatt.chRadarMapUUID, QaP3Gatt.chRfScanUUID, QaP3Gatt.chRfPwrUUID:
                peripheral.setNotifyValue(true, for: ch)
            default:
                break
            }
        }
        
        self.cmdCharacteristic = foundCmd
        self.connState = .ready(peripheral)
        self.sendCommand(opcode: QaP3Cmd.ping)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("GATT notify error: \(error.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else { return }
        
        switch characteristic.uuid {
        case QaP3Gatt.chTlmUUID:
            if let tlm = QaP3Telemetry.parse(data: data) {
                self.telemetry = tlm
            }
        case QaP3Gatt.chLogUUID:
            if let text = String(data: data, encoding: .utf8) {
                let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    var cur = self.logLines
                    if cur.count >= 500 {
                        cur.removeFirst(cur.count - 500 + 1)
                    }
                    cur.append(line)
                    self.logLines = cur
                }
            }
        case QaP3Gatt.chRadarMapUUID:
            if let map = QaP3RadarMap.parse(data: data) {
                self.radarMap = map
            }
        case QaP3Gatt.chRfScanUUID:
            if let scan = QaP3RfScan.parse(data: data) {
                self.rfScan = scan
            }
        case QaP3Gatt.chRfPwrUUID:
            if let power = QaP3RfPower.parse(data: data) {
                self.rfPower = power
            }
        default:
            break
        }
    }
}
