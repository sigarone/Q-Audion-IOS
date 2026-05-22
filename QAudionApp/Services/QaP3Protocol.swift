import Foundation
import CoreBluetooth

public struct QaP3Gatt {
    public static let deviceName = "QA-P3-BENCH"
    
    public static let serviceUUID = CBUUID(string: "5a3e0001-7c9e-4b1a-9f3d-1c2b3a4d5e6f")
    public static let chCmdUUID  = CBUUID(string: "5a3e0002-7c9e-4b1a-9f3d-1c2b3a4d5e6f")
    public static let chTlmUUID  = CBUUID(string: "5a3e0003-7c9e-4b1a-9f3d-1c2b3a4d5e6f")
    public static let chLogUUID  = CBUUID(string: "5a3e0004-7c9e-4b1a-9f3d-1c2b3a4d5e6f")
    public static let chRadarMapUUID = CBUUID(string: "5a3e0005-7c9e-4b1a-9f3d-1c2b3a4d5e6f")
    public static let chRfScanUUID = CBUUID(string: "5a3e0006-7c9e-4b1a-9f3d-1c2b3a4d5e6f")
    public static let chRfPwrUUID = CBUUID(string: "5a3e0007-7c9e-4b1a-9f3d-1c2b3a4d5e6f")
    
    public static let cccUUID = CBUUID(string: "00002902-0000-1000-8000-00805f9b34fb")
    
    public static let tlmPktSize = 20
    public static let tlmPktSizeV2 = 26
    public static let tlmVersion = 0x02
}

public struct QaP3Cmd {
    public static let arm            = 0x01
    public static let disarm         = 0x02
    public static let setMode        = 0x03
    public static let subsysEnable   = 0x10
    public static let subsysDisable  = 0x11
    public static let setUsDuty      = 0x20
    public static let setIrDuty      = 0x21
    public static let setLogLevel    = 0x30
    public static let clearFaults    = 0x40
    public static let maskOn         = 0x50
    public static let maskOff        = 0x51
    public static let setMaskLevel   = 0x52
    public static let duressClear    = 0x53
    public static let ping           = 0x7F
    
    public static func encode(opcode: Int, arg: Int = 0) -> Data {
        return Data([UInt8(opcode & 0xFF), UInt8(arg & 0xFF)])
    }
}

public struct QaP3Subsys {
    public static let ultrasonic = 1 << 0
    public static let ir         = 1 << 1
    public static let audio      = 1 << 2
    public static let all        = ultrasonic | ir | audio
}

public struct QaP3Fault {
    public static let refMic = 1 << 0
    public static let imu     = 1 << 1
    public static let tamper  = 1 << 2
}

public enum QaGateClass: Int, CaseIterable, Codable {
    case empty = 0
    case motion = 1
    case life = 2
    case staticClass = 3
    
    public static func from(_ code: Int) -> QaGateClass {
        return QaGateClass(rawValue: code) ?? .empty
    }
}

public enum QaP3Mode: Int, CaseIterable, Codable {
    case idle = 0
    case proximity = 1
    case room = 2
    case professional = 3
    case conference = 4
    
    public var label: String {
        switch self {
        case .idle: return "IDLE"
        case .proximity: return "PROXIMITY"
        case .room: return "ROOM"
        case .professional: return "PROFESSIONAL"
        case .conference: return "CONFERENCE"
        }
    }
    
    public static func from(_ code: Int) -> QaP3Mode {
        return QaP3Mode(rawValue: code) ?? .idle
    }
}

fileprivate func readU8(_ data: Data, _ index: Int) -> Int {
    guard index < data.count else { return 0 }
    return Int(data[index])
}

fileprivate func readU16(_ data: Data, _ index: Int) -> Int {
    guard index + 1 < data.count else { return 0 }
    return Int(data[index]) | (Int(data[index + 1]) << 8)
}

fileprivate func readI16(_ data: Data, _ index: Int) -> Int {
    guard index + 1 < data.count else { return 0 }
    let val = UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
    return Int(Int16(bitPattern: val))
}

fileprivate func readI8(_ data: Data, _ index: Int) -> Int {
    guard index < data.count else { return 0 }
    return Int(Int8(bitPattern: data[index]))
}

fileprivate func readU32(_ data: Data, _ index: Int) -> Int64 {
    guard index + 3 < data.count else { return 0 }
    let val = UInt32(data[index]) |
              (UInt32(data[index + 1]) << 8) |
              (UInt32(data[index + 2]) << 16) |
              (UInt32(data[index + 3]) << 24)
    return Int64(val)
}

public struct QaP3Telemetry: Equatable {
    public let version: Int
    public let mode: QaP3Mode
    public let armed: Bool
    public let faultFlags: Int
    public let splDb: Float
    public let usDutyPct: Int
    public let usGainPct: Int
    public let usEnabled: Bool
    public let irDutyPct: Int
    public let irEnabled: Bool
    public let subsysMask: Int
    public let audioActive: Bool
    public let threadsHealth: Int
    public let uptimeSec: Int64
    public let logLevel: Int
    
    // v2: P6 radar respiration
    public let radarReady: Bool
    public let radarPresence: Bool
    public let radarStationary: Bool
    public let radarBreathRpm: Float
    public let radarDistanceCm: Int
    
    // v3: P8 counter-espionage
    public let cspMaskEnabled: Bool
    public let cspDuress: Bool
    public let cspRiskLevel: Int
    public let cspMaskLevel: Int
    
    public var faultRefMic: Bool { (faultFlags & QaP3Fault.refMic) != 0 }
    public var faultImu: Bool { (faultFlags & QaP3Fault.imu) != 0 }
    public var faultTamper: Bool { (faultFlags & QaP3Fault.tamper) != 0 }
    public var anyFault: Bool { faultFlags != 0 }
    
    public var ultrasonicAllowed: Bool { (subsysMask & QaP3Subsys.ultrasonic) != 0 }
    public var irAllowed: Bool { (subsysMask & QaP3Subsys.ir) != 0 }
    public var audioAllowed: Bool { (subsysMask & QaP3Subsys.audio) != 0 }
    
    public var safetyThreadUp: Bool { (threadsHealth & 0x01) != 0 }
    public var emissionThreadUp: Bool { (threadsHealth & 0x02) != 0 }
    public var audioThreadUp: Bool { (threadsHealth & 0x04) != 0 }
    
    public static func parse(data: Data) -> QaP3Telemetry? {
        guard data.count >= QaP3Gatt.tlmPktSize else { return nil }
        
        let version = readU8(data, 0)
        let mode = QaP3Mode.from(readU8(data, 1))
        let armed = readU8(data, 2) != 0
        let faultFlags = readU8(data, 3)
        let splDb = Float(readU16(data, 4)) / 10.0
        let usDutyPct = readU8(data, 6)
        let usGainPct = readU8(data, 7)
        let usEnabled = readU8(data, 8) != 0
        let irDutyPct = readU8(data, 9)
        let irEnabled = readU8(data, 10) != 0
        let subsysMask = readU8(data, 11)
        let audioActive = readU8(data, 12) != 0
        let threadsHealth = readU8(data, 13)
        let uptimeSec = readU32(data, 14)
        let logLevel = readU8(data, 18)
        
        let hasRadar = data.count >= QaP3Gatt.tlmPktSizeV2
        let radarStatus = hasRadar ? readU8(data, 24) : 0
        let csp = readU8(data, 19)
        let cspRisk = (csp >> 1) & 0x03
        
        return QaP3Telemetry(
            version: version,
            mode: mode,
            armed: armed,
            faultFlags: faultFlags,
            splDb: splDb,
            usDutyPct: usDutyPct,
            usGainPct: usGainPct,
            usEnabled: usEnabled,
            irDutyPct: irDutyPct,
            irEnabled: irEnabled,
            subsysMask: subsysMask,
            audioActive: audioActive,
            threadsHealth: threadsHealth,
            uptimeSec: uptimeSec,
            logLevel: logLevel,
            radarReady: (radarStatus & 0x01) != 0,
            radarPresence: (radarStatus & 0x02) != 0,
            radarStationary: (radarStatus & 0x04) != 0,
            radarBreathRpm: hasRadar ? Float(readU16(data, 20)) / 10.0 : 0.0,
            radarDistanceCm: hasRadar ? readU16(data, 22) : 0,
            cspMaskEnabled: (csp & 0x01) != 0,
            cspDuress: (csp & 0x08) != 0,
            cspRiskLevel: cspRisk,
            cspMaskLevel: hasRadar ? readU8(data, 25) : 0
        )
    }
}

public struct QaP3RadarMap: Equatable {
    public static let gates = 9
    public static let gateCm = 75
    public static let pktSize = 35
    
    public let version: Int
    public let ready: Bool
    public let presence: Bool
    public let stationary: Bool
    public let engMode: Bool
    public let breathGate: Int
    public let breathRpm: Float
    public let heartBpm: Int
    public let detectDistanceCm: Int
    public let moveGate: [Int]
    public let stillGate: [Int]
    public let gateClass: [QaGateClass]
    
    public func gateRangeCm(g: Int) -> Int {
        return g * Self.gateCm
    }
    
    public static func parse(data: Data) -> QaP3RadarMap? {
        guard data.count >= pktSize else { return nil }
        
        let version = readU8(data, 0)
        let flags = readU8(data, 1)
        let bg = readU8(data, 2)
        
        var move = [Int]()
        for i in 0..<gates {
            move.append(readU8(data, 8 + i))
        }
        
        var still = [Int]()
        for i in 0..<gates {
            still.append(readU8(data, 17 + i))
        }
        
        var cls = [QaGateClass]()
        for i in 0..<gates {
            cls.append(QaGateClass.from(readU8(data, 26 + i)))
        }
        
        return QaP3RadarMap(
            version: version,
            ready: (flags & 0x01) != 0,
            presence: (flags & 0x02) != 0,
            stationary: (flags & 0x04) != 0,
            engMode: (flags & 0x08) != 0,
            breathGate: bg == 0xFF ? -1 : Int(bg),
            breathRpm: Float(readU16(data, 4)) / 10.0,
            heartBpm: readU8(data, 3),
            detectDistanceCm: readU16(data, 6),
            moveGate: move,
            stillGate: still,
            gateClass: cls
        )
    }
}

public struct QaP3RfScan: Equatable {
    public static let bins = 16
    public static let pktSize = 22
    
    public let version: Int
    public let ready: Bool
    public let emitterCount: Int
    public let strongestRssi: Int?
    public let activity: [Int]
    public let suspectMask: Int
    
    public func isSuspect(_ b: Int) -> Bool {
        return (suspectMask & (1 << b)) != 0
    }
    
    public var suspectCount: Int {
        var count = 0
        for b in 0..<Self.bins {
            if isSuspect(b) {
                count += 1
            }
        }
        return count
    }
    
    public static func parse(data: Data) -> QaP3RfScan? {
        guard data.count >= pktSize else { return nil }
        
        let version = readU8(data, 0)
        let ready = (readU8(data, 1) & 0x01) != 0
        let emitterCount = readU8(data, 2)
        let rssiRaw = readI8(data, 3)
        
        var act = [Int]()
        for i in 0..<bins {
            act.append(readU8(data, 4 + i))
        }
        
        let suspectMask = readU16(data, 20)
        
        return QaP3RfScan(
            version: version,
            ready: ready,
            emitterCount: emitterCount,
            strongestRssi: rssiRaw == -128 ? nil : rssiRaw,
            activity: act,
            suspectMask: suspectMask
        )
    }
}

public struct QaP3RfPower: Equatable {
    public static let pktSize = 8
    
    public let version: Int
    public let ready: Bool
    public let burst: Bool
    public let sustained: Bool
    public let dbm: Int
    public let peakDbm: Int
    public let floorDbm: Int
    
    public var alert: Bool {
        return ready && (sustained || burst)
    }
    
    public static func parse(data: Data) -> QaP3RfPower? {
        guard data.count >= pktSize else { return nil }
        
        let version = readU8(data, 0)
        let f = readU8(data, 1)
        let dbm = readI16(data, 2)
        let peakDbm = readI16(data, 4)
        let floorDbm = readI16(data, 6)
        
        return QaP3RfPower(
            version: version,
            ready: (f & 0x01) != 0,
            burst: (f & 0x02) != 0,
            sustained: (f & 0x04) != 0,
            dbm: dbm,
            peakDbm: peakDbm,
            floorDbm: floorDbm
        )
    }
}
