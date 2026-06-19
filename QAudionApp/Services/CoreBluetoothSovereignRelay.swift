import Foundation
import CoreBluetooth
import QAudionEngine

/// Concrete `SovereignEarbudGattRelay` driving a real CBCentralManager /
/// CBPeripheral against the canonical QAUDION crypto service
/// `f2c0aaaa-bcc0-4001-8000-000000000000` (NOT the QA-P3-BENCH diagnostic
/// service `5a3e0001…` — that is QaP3GattManager). The crypto service is the
/// same family `EarbudDiagViewModel` already talks to (metrics char 0x90);
/// here we drive KEY_IMPORT (0xc3) + ATTEST_POP (0xc1) for the KMS-v2
/// sovereign relay (lockstep §5 iOS, Phase-2).
///
/// ## Sub-protocol (firmware commit 3677d2a, qaudion_gatt.c)
///   - writeKeyImportFragment → Write-With-Response to 0xc3, await
///     `didWriteValueFor` (the firmware needs ordered, acked writes: each
///     package fragment must extend the contiguous prefix).
///   - readKeyImportStatus    → read 0xc3 → [status:u8][slot:u8].
///   - readSovereignPoP       → read 0xc1 → 32-byte qa-kms-pop-v1 SE PoP.
///
/// ## Encrypted link requirement
/// Both 0xc3 and 0xc1 are `BT_GATT_PERM_READ_ENCRYPT|WRITE_ENCRYPT`, so the
/// first write/read triggers iOS pairing if the peripheral is not already
/// bonded. CoreBluetooth performs the pairing transparently and retries the
/// ATT op once the link is encrypted; a user who declines pairing surfaces as
/// an insufficient-authentication/encryption ATT error on the awaited op,
/// which propagates as `RelayBleError.gatt`.
///
/// ## Concurrency
/// Mirrors the proven Swift-6 pattern in this codebase (EarbudDiagViewModel /
/// QaP3GattManager): the class is `@MainActor`, the CBCentralManager is built
/// with `queue: nil` so every delegate callback lands on the MAIN queue, and
/// the delegate conformances are `@preconcurrency` so the main-actor methods
/// satisfy the `nonisolated` protocol requirements (runtime-correct: the
/// inserted main-actor check always passes). Operations are SERIALIZED — one
/// outstanding continuation at a time, which matches the strictly-sequential
/// relay() driver (PoP-inputs → fragments → status read → PoP read).
@MainActor
public final class CoreBluetoothSovereignRelay: NSObject, SovereignEarbudGattRelay,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {

    // Canonical crypto-service UUIDs (= QAudionEarbudGatt string constants).
    private static let serviceCBUUID    = CBUUID(string: QaudionEarbudGatt.serviceUUID)
    private static let keyImportCBUUID  = CBUUID(string: QaudionEarbudGatt.keyImportUUID)
    private static let attestPopCBUUID  = CBUUID(string: QaudionEarbudGatt.attestPopUUID)

    public enum RelayBleError: Error, Equatable {
        case bluetoothUnavailable(String)
        case peripheralNotFound          // could not resolve the target peripheral
        case connectFailed(String)
        case serviceNotFound
        case characteristicNotFound(String)
        case notReady                    // op requested before discovery completed
        case gatt(String)                // an ATT error on a write/read
        case disconnected                // link dropped mid-op
        case timeout
    }

    private let central: CBCentralManager
    private var peripheral: CBPeripheral?
    private var keyImportChar: CBCharacteristic?
    private var attestPopChar: CBCharacteristic?

    /// The target peripheral's CoreBluetooth identifier (NOT the BLE MAC —
    /// iOS hides the MAC; this is the per-host stable identifier from a prior
    /// scan/connect). Resolved via `retrievePeripherals(withIdentifiers:)`.
    private let targetIdentifier: UUID

    // Single-flight continuations (serialized usage; the relay() driver never
    // overlaps GATT ops). Each is fulfilled exactly once by the matching
    // delegate callback or an error/disconnect path.
    private var poweredOnCont: CheckedContinuation<Void, Error>?
    private var connectCont: CheckedContinuation<Void, Error>?
    private var discoverCont: CheckedContinuation<Void, Error>?
    private var writeCont: CheckedContinuation<Void, Error>?
    private var readCont: CheckedContinuation<Data, Error>?
    private var readingCharUUID: CBUUID?

    /// `identifier` is the target earbud peripheral's CoreBluetooth UUID. The
    /// caller obtains it from a prior scan (e.g. EarbudDiagViewModel's
    /// `DiscoveredEarbud.id` == `peripheral.identifier`) or from a bonded
    /// peripheral known to the system.
    public init(identifier: UUID) {
        self.targetIdentifier = identifier
        self.central = CBCentralManager(delegate: nil, queue: nil)
        super.init()
        self.central.delegate = self
    }

    // MARK: - Connection lifecycle

    /// Connect, discover the crypto service + KEY_IMPORT/ATTEST_POP chars, and
    /// leave the link ready for writes/reads. Idempotent: a second call when
    /// already ready returns immediately. MUST be awaited before the first
    /// `writeKeyImportFragment`.
    public func prepare() async throws {
        if keyImportChar != nil, attestPopChar != nil,
           peripheral?.state == .connected {
            return
        }
        try await waitForPoweredOn()
        guard let p = central.retrievePeripherals(withIdentifiers: [targetIdentifier]).first else {
            throw RelayBleError.peripheralNotFound
        }
        peripheral = p
        p.delegate = self
        try await connect(p)
        try await discover(p)
    }

    private func waitForPoweredOn() async throws {
        switch central.state {
        case .poweredOn:
            return
        case .poweredOff:
            throw RelayBleError.bluetoothUnavailable("Bluetooth is powered off")
        case .unauthorized:
            throw RelayBleError.bluetoothUnavailable("Bluetooth not authorized")
        case .unsupported:
            throw RelayBleError.bluetoothUnavailable("Bluetooth not supported")
        default:
            // .resetting / .unknown — wait for centralManagerDidUpdateState.
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.poweredOnCont = c
            }
        }
    }

    private func connect(_ p: CBPeripheral) async throws {
        if p.state == .connected { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.connectCont = c
            central.connect(p, options: nil)
        }
    }

    private func discover(_ p: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.discoverCont = c
            p.discoverServices([Self.serviceCBUUID])
        }
    }

    /// Cancel the connection. Safe to call multiple times.
    public func close() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    /// The negotiated ATT MTU minus the 3-byte ATT write header — the max
    /// payload per Write-With-Response. The relay() caller uses this to size
    /// package fragments. Falls back to 20 (MTU 23 default) before discovery.
    public var maxWritePayload: Int {
        guard let p = peripheral else { return 20 }
        let mtu = p.maximumWriteValueLength(for: .withResponse)
        // maximumWriteValueLength already accounts for the ATT header; but our
        // KEY_IMPORT frame format is [frag_offset:2][payload], so the payload
        // budget is mtu - 2. Clamp to >=1.
        return max(1, mtu - 2)
    }

    // MARK: - SovereignEarbudGattRelay

    public func writeKeyImportFragment(_ frame: Data) async throws {
        guard let p = peripheral, let ch = keyImportChar, p.state == .connected else {
            throw RelayBleError.notReady
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.writeCont = c
            // Write-With-Response: the firmware requires acked, ordered writes
            // (each fragment extends the contiguous prefix). didWriteValueFor
            // resolves this continuation.
            p.writeValue(frame, for: ch, type: .withResponse)
        }
    }

    public func readKeyImportStatus() async throws -> Data {
        try await read(from: keyImportChar, uuid: Self.keyImportCBUUID)
    }

    public func readSovereignPoP() async throws -> Data {
        try await read(from: attestPopChar, uuid: Self.attestPopCBUUID)
    }

    private func read(from ch: CBCharacteristic?, uuid: CBUUID) async throws -> Data {
        guard let p = peripheral, let ch = ch, p.state == .connected else {
            throw RelayBleError.notReady
        }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            self.readCont = c
            self.readingCharUUID = uuid
            p.readValue(for: ch)
        }
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let c = poweredOnCont else { return }
        poweredOnCont = nil
        switch central.state {
        case .poweredOn:
            c.resume()
        case .poweredOff:
            c.resume(throwing: RelayBleError.bluetoothUnavailable("Bluetooth is powered off"))
        case .unauthorized:
            c.resume(throwing: RelayBleError.bluetoothUnavailable("Bluetooth not authorized"))
        case .unsupported:
            c.resume(throwing: RelayBleError.bluetoothUnavailable("Bluetooth not supported"))
        default:
            // Still transitioning — re-arm by reinstating the continuation.
            poweredOnCont = c
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectCont?.resume()
        connectCont = nil
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let msg = error?.localizedDescription ?? "connect failed"
        connectCont?.resume(throwing: RelayBleError.connectFailed(msg))
        connectCont = nil
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Fail any in-flight op so the awaiting relay() does not hang.
        failAllInflight(RelayBleError.disconnected)
        keyImportChar = nil
        attestPopChar = nil
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            finishDiscover(throwing: RelayBleError.gatt(error.localizedDescription))
            return
        }
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceCBUUID }) else {
            finishDiscover(throwing: RelayBleError.serviceNotFound)
            return
        }
        peripheral.discoverCharacteristics(
            [Self.keyImportCBUUID, Self.attestPopCBUUID], for: svc)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            finishDiscover(throwing: RelayBleError.gatt(error.localizedDescription))
            return
        }
        for ch in service.characteristics ?? [] {
            if ch.uuid == Self.keyImportCBUUID { keyImportChar = ch }
            if ch.uuid == Self.attestPopCBUUID { attestPopChar = ch }
        }
        guard keyImportChar != nil else {
            finishDiscover(throwing: RelayBleError.characteristicNotFound("KEY_IMPORT 0xc3"))
            return
        }
        guard attestPopChar != nil else {
            finishDiscover(throwing: RelayBleError.characteristicNotFound("ATTEST_POP 0xc1"))
            return
        }
        finishDiscover(throwing: nil)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let c = writeCont else { return }
        writeCont = nil
        if let error = error {
            c.resume(throwing: RelayBleError.gatt(error.localizedDescription))
        } else {
            c.resume()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Only resolve a pending READ for the characteristic we asked for.
        guard let c = readCont, characteristic.uuid == readingCharUUID else { return }
        readCont = nil
        readingCharUUID = nil
        if let error = error {
            c.resume(throwing: RelayBleError.gatt(error.localizedDescription))
        } else {
            c.resume(returning: characteristic.value ?? Data())
        }
    }

    // MARK: - Helpers

    private func finishDiscover(throwing error: Error?) {
        guard let c = discoverCont else { return }
        discoverCont = nil
        if let error = error { c.resume(throwing: error) } else { c.resume() }
    }

    private func failAllInflight(_ error: Error) {
        poweredOnCont?.resume(throwing: error);  poweredOnCont = nil
        connectCont?.resume(throwing: error);    connectCont = nil
        discoverCont?.resume(throwing: error);   discoverCont = nil
        writeCont?.resume(throwing: error);      writeCont = nil
        readCont?.resume(throwing: error);       readCont = nil
        readingCharUUID = nil
    }
}
