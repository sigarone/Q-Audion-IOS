@preconcurrency import CoreBluetooth
import Foundation

/// CL-5.X — Concrete CoreBluetooth implementation of EarbudPairingGattProxy.
///
/// Implements earbud GATT operations:
///   c1  ATTEST_POP      : read 32 B SE PoP
///   c3  KEY_IMPORT       : fragment-write pkg (1668 B) + PoP-INPUTS frame (82 B), read status
///   c5  PAIR_BEGIN       : fragment-write 1632 B with 2-byte LE u16 offset header per frag
///   c6  PAIR_RESP        : write 1-byte chunk index, read 408 B × 4
///   c7  PAIR_FIN         : single 32-byte write
///   c8  FP_ADV_REQUEST   : Phase B — write ct_bind[32], read fp_adv[32]||key_epoch_le[8]
///
/// Connection flow:
///   1. Call connect(_:) with a CBPeripheral obtained from a CBCentralManager scan.
///   2. Characteristics are discovered automatically after GATT service discovery.
///   3. Once isConnected is true and all characteristics are set, invoke the proxy methods.
///
/// Thread safety: all CoreBluetooth callbacks arrive on the main queue (queue: nil in init).
/// @MainActor ensures all properties and continuations are accessed on the main actor.
@MainActor
public final class IOSEarbudGattProxy: NSObject {

    // MARK: - Error

    public enum GattError: Error, CustomStringConvertible {
        case notConnected
        case characteristicNotFound(String)
        case gattError(String)
        case unexpectedChunkSize(got: Int, expected: Int)

        public var description: String {
            switch self {
            case .notConnected:                     return "earbud_not_connected"
            case .characteristicNotFound(let u):    return "char_not_found:\(u)"
            case .gattError(let m):                 return "gatt:\(m)"
            case .unexpectedChunkSize(let g, let e): return "chunk_size:\(g)≠\(e)"
            }
        }
    }

    // MARK: - State

    private var central: CBCentralManager!
    private(set) var peripheral: CBPeripheral?

    // Characteristics (set after service/char discovery)
    private var attestPopChar: CBCharacteristic?   // c1
    private var keyImportChar: CBCharacteristic?   // c3
    private var pairBeginChar: CBCharacteristic?   // c5
    private var pairRespChar:  CBCharacteristic?   // c6
    private var pairFinChar:   CBCharacteristic?   // c7
    private var fpAdvChar:     CBCharacteristic?   // c8 (Phase B)

    // Active continuations — at most one write and one read outstanding at a time
    private var writeCont: CheckedContinuation<Void, Error>?
    private var readCont:  CheckedContinuation<Data, Error>?

    // MARK: - Init

    public override init() {
        super.init()
        // queue: nil → callbacks on main queue, matching @MainActor
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Connection helpers (for caller / app layer)

    /// Initiate a GATT connection. Service + characteristic discovery runs automatically.
    public func connect(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    /// Cancel the current GATT connection.
    public func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    // MARK: - EarbudKeyGattProxy

    public var isConnected: Bool { peripheral?.state == .connected }

    public func readAttestPop() async throws -> Data {
        let c = try require(attestPopChar, uuid: EarbudGattConstants.ATTEST_POP_UUID)
        return try await readChar(c)
    }

    public func startKeyImport(pkg: Data, popInputs: Data) async throws -> KeyImportOutcome {
        let c = try require(keyImportChar, uuid: EarbudGattConstants.KEY_IMPORT_UUID)

        // 1. Fragment-write pkg (1668 B) with 2-byte LE u16 offset header
        try await fragmentWrite(c, payload: pkg)

        // 2. Write PoP-INPUTS frame (82 B, first 2 bytes = 0xFFFF sentinel, written as-is)
        try await writeChar(c, data: popInputs)

        // 3. Read status (≥1 byte: [status][slot])
        let resp = try await readChar(c)
        guard resp.count >= 2 else {
            return resp.count == 1
                ? .ok(status: resp[0], slot: 0)
                : .err("empty_status_response")
        }
        return .ok(status: resp[0], slot: resp[1])
    }

    // MARK: - EarbudPairingGattProxy

    public func writePairBegin(_ payload: Data) async throws {
        let c = try require(pairBeginChar, uuid: EarbudGattConstants.PAIR_BEGIN_UUID)
        try await fragmentWrite(c, payload: payload)
    }

    public func readPairResp() async throws -> Data {
        let c = try require(pairRespChar, uuid: EarbudGattConstants.PAIR_RESP_UUID)
        var result = Data()
        result.reserveCapacity(EarbudGattConstants.EE_PAIR_MSG_LEN)
        for idx in 0..<EarbudGattConstants.EE_PAIR_RESP_NCHUNKS {
            try await writeChar(c, data: Data([UInt8(idx)]))
            let chunk = try await readChar(c)
            guard chunk.count == EarbudGattConstants.EE_PAIR_RESP_CHUNK else {
                throw GattError.unexpectedChunkSize(
                    got: chunk.count, expected: EarbudGattConstants.EE_PAIR_RESP_CHUNK)
            }
            result.append(chunk)
        }
        return result
    }

    public func writePairFin(_ confirm: Data) async throws {
        let c = try require(pairFinChar, uuid: EarbudGattConstants.PAIR_FIN_UUID)
        try await writeChar(c, data: confirm)
    }

    // MARK: - Phase B: c8 FP_ADV_REQUEST

    /// Write ct_bind[32] so the earbud computes fp_adv in-SE.
    /// Precondition: ctBind must be exactly 32 bytes.
    public func writeFpAdvSeed(_ ctBind: Data) async throws {
        precondition(ctBind.count == 32, "ct_bind must be 32 bytes")
        let c = try require(fpAdvChar, uuid: EarbudGattConstants.FP_ADV_UUID)
        try await writeChar(c, data: ctBind)
    }

    /// Read fp_adv[32] || key_epoch_le[8] from c8.
    /// Caller must have written ct_bind first via writeFpAdvSeed(_:).
    /// Returns (fpAdv: 32 bytes, epoch: little-endian UInt64).
    public func readFpAdv() async throws -> (fpAdv: Data, epoch: UInt64) {
        let c = try require(fpAdvChar, uuid: EarbudGattConstants.FP_ADV_UUID)
        let data = try await readChar(c)
        guard data.count >= 40 else {
            throw GattError.unexpectedChunkSize(got: data.count, expected: 40)
        }
        let fpAdv = Data(data.prefix(32))
        let epochSlice = data[32..<40]
        let epoch = epochSlice.withUnsafeBytes { ptr in
            ptr.load(as: UInt64.self).littleEndian
        }
        return (fpAdv, epoch)
    }

    // MARK: - Private helpers

    private func require(_ char: CBCharacteristic?, uuid: String) throws -> CBCharacteristic {
        guard let c = char else { throw GattError.characteristicNotFound(uuid) }
        return c
    }

    /// Write `payload` to `char` in fragments with a 2-byte LE u16 byte-offset header.
    /// Retries up to 6 times on GATT-busy errors with exponential backoff.
    private func fragmentWrite(_ char: CBCharacteristic, payload: Data) async throws {
        guard let p = peripheral else { throw GattError.notConnected }
        // maximumWriteValueLength returns mtu-3 (ATT header already subtracted)
        let maxWrite = p.maximumWriteValueLength(for: .withResponse)
        let dataPerFrag = max(1, maxWrite - EarbudGattConstants.KEYIMPORT_FRAG_HEADER)

        var offset = 0
        while offset < payload.count {
            let chunkLen = min(dataPerFrag, payload.count - offset)
            var frame = Data(count: 2 + chunkLen)
            frame[0] = UInt8(offset & 0xFF)
            frame[1] = UInt8((offset >> 8) & 0xFF)
            frame.replaceSubrange(2..<(2 + chunkLen),
                                  with: payload[offset..<(offset + chunkLen)])

            var retries = 0
            while true {
                do {
                    try await writeChar(char, data: frame)
                    break
                } catch GattError.gattError(let msg)
                    where msg.contains("busy") || msg.contains("congested") {
                    retries += 1
                    let backoffMs = 200 + retries * 300
                    try await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
                } catch where retries < 6 {
                    retries += 1
                    let backoffMs = 200 + retries * 300
                    try await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
                }
            }
            offset += chunkLen
        }
    }

    private func writeChar(_ char: CBCharacteristic, data: Data) async throws {
        guard let p = peripheral, p.state == .connected else { throw GattError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeCont = cont
            p.writeValue(data, for: char, type: .withResponse)
        }
    }

    private func readChar(_ char: CBCharacteristic) async throws -> Data {
        guard let p = peripheral, p.state == .connected else { throw GattError.notConnected }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            readCont = cont
            p.readValue(for: char)
        }
    }

    private func clearCharacteristics() {
        attestPopChar = nil
        keyImportChar = nil
        pairBeginChar = nil
        pairRespChar  = nil
        pairFinChar   = nil
        fpAdvChar     = nil
    }

    private func failPendingOps(with error: Error) {
        writeCont?.resume(throwing: error); writeCont = nil
        readCont?.resume(throwing: error);  readCont  = nil
    }
}

// MARK: - CBCentralManagerDelegate

extension IOSEarbudGattProxy: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            clearCharacteristics()
            failPendingOps(with: GattError.gattError("bluetooth_off"))
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        let svcUUID = CBUUID(string: EarbudGattConstants.SERVICE_UUID)
        peripheral.discoverServices([svcUUID])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failPendingOps(with: error ?? GattError.gattError("connect_failed"))
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        clearCharacteristics()
        failPendingOps(with: GattError.gattError(
            "disconnected:\(error?.localizedDescription ?? "nil")"))
    }
}

// MARK: - CBPeripheralDelegate

extension IOSEarbudGattProxy: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverServices error: Error?) {
        if let err = error {
            failPendingOps(with: err)
            return
        }
        guard let svc = peripheral.services?.first(where: {
            $0.uuid == CBUUID(string: EarbudGattConstants.SERVICE_UUID)
        }) else {
            failPendingOps(with: GattError.gattError("service_not_found"))
            return
        }
        let uuids = [
            EarbudGattConstants.ATTEST_POP_UUID,
            EarbudGattConstants.KEY_IMPORT_UUID,
            EarbudGattConstants.PAIR_BEGIN_UUID,
            EarbudGattConstants.PAIR_RESP_UUID,
            EarbudGattConstants.PAIR_FIN_UUID,
            EarbudGattConstants.FP_ADV_UUID,
        ].map { CBUUID(string: $0) }
        peripheral.discoverCharacteristics(uuids, for: svc)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let err = error {
            failPendingOps(with: err)
            return
        }
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case CBUUID(string: EarbudGattConstants.ATTEST_POP_UUID): attestPopChar = char
            case CBUUID(string: EarbudGattConstants.KEY_IMPORT_UUID): keyImportChar = char
            case CBUUID(string: EarbudGattConstants.PAIR_BEGIN_UUID): pairBeginChar = char
            case CBUUID(string: EarbudGattConstants.PAIR_RESP_UUID):  pairRespChar  = char
            case CBUUID(string: EarbudGattConstants.PAIR_FIN_UUID):   pairFinChar   = char
            case CBUUID(string: EarbudGattConstants.FP_ADV_UUID):     fpAdvChar     = char
            default: break
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let err = error {
            writeCont?.resume(throwing: GattError.gattError(err.localizedDescription))
        } else {
            writeCont?.resume()
        }
        writeCont = nil
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let err = error {
            readCont?.resume(throwing: GattError.gattError(err.localizedDescription))
        } else {
            readCont?.resume(returning: characteristic.value ?? Data())
        }
        readCont = nil
    }
}

// NOTE: `@preconcurrency` on the conformance clause (`extension X: @preconcurrency P`)
// is rejected by the iOS-simulator build's compiler ("attribute can only be applied
// to declarations, not types") — it broke every ios-simulator-tests run. Under the
// Swift 5 language mode (swift-tools 5.9) the main-actor-vs-nonisolated-protocol
// crossing it suppressed is only a warning, not an error, so plain conformance
// builds. CoreBluetooth conformances above rely on the `@preconcurrency import
// CoreBluetooth` at the top of this file instead.
extension IOSEarbudGattProxy: EarbudPairingGattProxy { }
