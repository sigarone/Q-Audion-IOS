// QAUDION_EARBUD -- the earbud hardware stack (BLE GATT client for the Q-Audion earbud).
//
// This file lives in the APP target and is compiled only when the QAUDION_EARBUD
// compilation condition is set (QAudionApp/project-earbud.yml, or ios-testflight.yml
// dispatched with earbud=true). The default build -- every tag push -- does not
// contain it: no class, no GATT UUID, no CoreBluetooth earbud client. It used to be
// part of the QAudionEngine package, which cannot see an app compilation condition,
// so the class (an NSObject subclass, which the linker keeps) and the UUID strings
// could not be compiled out there; hardware lab builds only, kept out of store
// builds. The protocols it implements (EarbudKeyGattProxy,
// EarbudPairingGattProxy) and the hardware-independent relay logic (EarbudAckPopRelay,
// EarbudPairingRelay, the frozen sizes in EarbudGattConstants) stay in the engine.
//
// To re-enable it, see QAudionApp/project-earbud.yml and "Earbud (hardware) support"
// in CLAUDE.md: generate the project from project-earbud.yml, or dispatch
// ios-testflight.yml with earbud=true.
#if QAUDION_EARBUD
@preconcurrency import CoreBluetooth
import Foundation
import QAudionEngine

// GATT UUIDs of the earbud firmware (qaudion_gatt.c). They live here, next to the only
// code that uses them, and not in the engine's EarbudGattConstants, so that a build
// without QAUDION_EARBUD carries none of them. The frozen sizes stay in the engine
// (EarbudAckPopRelay and EarbudPairGatt use them). UPPER_SNAKE_CASE mirrors the
// firmware / Android constant names byte for byte.
//
// ONE source for every earbud UUID in the app: this extension. The sovereign relay
// (EarbudKeyImportService / CoreBluetoothSovereignRelay) and the diagnostics screen
// read the same constants, so no copy can drift (a service UUID with the last byte 0x00
// names no firmware service).
// swiftlint:disable identifier_name
extension EarbudGattConstants {
    /// Primary earbud service (QAUDION_SVC_UUID_VAL)
    static let SERVICE_UUID      = "f2c0aaaa-bcc0-4001-8000-000000000001"
    /// DIAG characteristic (0x90) -- READ only (BT_GATT_CHRC_READ, READ_ENCRYPT): the earbud never
    /// notifies it, so the phone polls it with a read (Android: every 2 s)
    static let DIAG_UUID         = "f2c0aaaa-bcc0-4001-8000-000000000090"
    /// KEY_IMPORT characteristic (c3) -- sovereign + hw_only relay
    static let KEY_IMPORT_UUID   = "f2c0aaaa-bcc0-4001-8000-0000000000c3"
    /// ATTEST_POP characteristic (c1) -- 32-byte SE PoP after import
    static let ATTEST_POP_UUID   = "f2c0aaaa-bcc0-4001-8000-0000000000c1"
    /// ATTEST_PQ characteristic (c2) -- not used by this client (firmware and WIRE_SPEC call it ATTEST_PQ)
    static let ATTEST_UUID       = "f2c0aaaa-bcc0-4001-8000-0000000000c2"
    /// PAIR_BEGIN (c5) -- initiator writes 1632B fragmented
    static let PAIR_BEGIN_UUID   = "f2c0aaaa-bcc0-4001-8000-0000000000c5"
    /// PAIR_RESP (c6) -- reads 4 x 408B chunks
    static let PAIR_RESP_UUID    = "f2c0aaaa-bcc0-4001-8000-0000000000c6"
    /// PAIR_FIN (c7) -- writes 32B confirm hash
    static let PAIR_FIN_UUID     = "f2c0aaaa-bcc0-4001-8000-0000000000c7"
    /// FP_ADV_REQUEST (c8) -- Phase B fp_adv GATT char
    ///   WRITE 32B = ct_bind (phone writes this, earbud computes fp_adv in-SE)
    ///   READ  40B = fp_adv[32] || key_epoch_le[8] (little-endian UInt64)
    static let FP_ADV_UUID       = "f2c0aaaa-bcc0-4001-8000-0000000000c8"
}
// swiftlint:enable identifier_name

/// CL-5.X — Concrete CoreBluetooth implementation of EarbudPairingGattProxy.
///
/// Implements earbud GATT operations:
///   c1  ATTEST_POP      : read 32 B SE PoP
///   c3  KEY_IMPORT       : write the PoP-INPUTS frame (82 B) FIRST, then the package (1668 B) as
///                          [offset u16 BIG-endian][data] fragments, then read [status][slot]
///   c5  PAIR_BEGIN       : fragment-write 1632 B with a 2-byte LITTLE-endian u16 offset header per frag
///   c6  PAIR_RESP        : write 1-byte chunk index, read 408 B × 4
///   c7  PAIR_FIN         : single 32-byte write
///   c8  FP_ADV_REQUEST   : Phase B — write ct_bind[32], read fp_adv[32]||key_epoch_le[8]
///   0x90 DIAG            : read (polled; the characteristic has no notify)
///
/// ONE instance serves the whole app (AppState.earbudGattProxy: the KMS sweep and the diagnostics screen
/// share it). It owns the only CBCentralManager that connects to the earbud, and every public operation
/// runs inside `opGate`, so a DIAG poll, a KMS key import and a pairing never overlap on the single
/// pending write / read continuation.
///
/// Connection flow:
///   1. `ensureConnected(identifier:timeout:)` with the CoreBluetooth identifier of the earbud: the id
///      of a scan result (the diagnostics screen), or the remembered one (the KMS sweep). It returns when
///      the earbud service and its characteristics have been discovered, so `isConnected` is true only
///      when an operation can run (not as soon as the link is up, before discovery).
///   2. Invoke the proxy methods.
///
/// Write size: every write must fit ONE ATT PDU (ATT_MTU - 3). The firmware refuses an ATT write with a
/// non-zero offset, which is what CoreBluetooth sends for the second part of a long write, so the frames
/// are sized from `maximumWriteValueLength(for: .withoutResponse)`; the `.withResponse` figure is the 512
/// that CoreBluetooth reports for a long write, not what the link carries in one PDU.
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
        /// A frame that cannot be split (the 82 B PoP-INPUTS frame) does not fit one ATT write of this link.
        case writeBudgetTooSmall(have: Int, need: Int)
        case badInput(String)

        public var description: String {
            switch self {
            case .notConnected:                     return "earbud_not_connected"
            case .characteristicNotFound(let u):    return "char_not_found:\(u)"
            case .gattError(let m):                 return "gatt:\(m)"
            case .unexpectedChunkSize(let g, let e): return "chunk_size:\(g)≠\(e)"
            case .writeBudgetTooSmall(let h, let n): return "write_budget:\(h)<\(n)"
            case .badInput(let m):                  return "bad_input:\(m)"
            }
        }
    }

    // MARK: - State

    private var central: CBCentralManager!
    // nonisolated(unsafe): read by the `nonisolated` isConnected getter and the
    // nonisolated CB delegate witnesses below. Every access happens on the main
    // thread (CBCentralManager is created with queue: nil, and all @MainActor
    // ops run on main), so this is single-threaded at runtime — the same house
    // pattern already shipping in VideoCallPipeline / ScreenShareController.
    private(set) nonisolated(unsafe) var peripheral: CBPeripheral?

    // Characteristics (set after service/char discovery)
    // nonisolated(unsafe): assigned in the nonisolated didDiscoverCharacteristicsFor
    // / clearCharacteristics witnesses, read from the @MainActor async ops — all
    // on the main thread (queue: nil delegate delivery).
    private nonisolated(unsafe) var attestPopChar: CBCharacteristic?   // c1
    private nonisolated(unsafe) var keyImportChar: CBCharacteristic?   // c3
    private nonisolated(unsafe) var pairBeginChar: CBCharacteristic?   // c5
    private nonisolated(unsafe) var pairRespChar: CBCharacteristic?   // c6
    private nonisolated(unsafe) var pairFinChar: CBCharacteristic?   // c7
    private nonisolated(unsafe) var fpAdvChar: CBCharacteristic?   // c8 (Phase B)
    private nonisolated(unsafe) var diagChar: CBCharacteristic?   // 0x90 (read only)

    /// True once the earbud service and its characteristics have been discovered on the live link.
    private nonisolated(unsafe) var linkReady = false
    /// Why the last connect / discovery attempt failed; nil while it has not.
    private nonisolated(unsafe) var linkError: String?

    // Active continuations — at most one write and one read outstanding at a time
    // nonisolated(unsafe): set on the main actor in writeChar/readChar, resumed in
    // the nonisolated didWrite/didUpdate witnesses + failPendingOps — all on the
    // main thread, so ordering is byte-identical to the @MainActor original.
    private nonisolated(unsafe) var writeCont: CheckedContinuation<Void, Error>?
    private nonisolated(unsafe) var readCont: CheckedContinuation<Data, Error>?

    /// Identifies the operation whose timer is running, so a stale timer never fails a later operation.
    private var opSeq: UInt64 = 0

    /// One public operation at a time (see the class comment).
    private let opGate = EarbudSerialGate()

    /// A write or read that gets no answer in this long drops the link: a late answer would otherwise
    /// be taken for the next operation's, and a hung operation would hold `opGate` for ever.
    private static let opTimeoutNS: UInt64 = 45 * 1_000_000_000
    private static let maxWriteRetries = 6
    /// See `reconnect(to:timeout:)`.
    private static let reconnectCooldown: TimeInterval = 60
    private var lastReconnectFailureAt: Date?

    // MARK: - Init

    public override init() {
        super.init()
        // queue: nil → callbacks on main queue, matching @MainActor
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Connection helpers (for caller / app layer)

    /// Connects to the earbud with this CoreBluetooth identifier and returns when its service and
    /// characteristics are discovered (`isConnected` is then true). Already connected to it: returns at once.
    ///
    /// The identifier is the `CBPeripheral.identifier` of a scan result, or the one the app remembered
    /// (`AppState.rememberEarbudIdentifier`): CoreBluetooth resolves it with `retrievePeripherals`, so a
    /// peripheral that another central of this app discovered can be connected here.
    ///
    /// When the earbud is not in range the connection request stays pending in the system; after
    /// `timeout` this call throws but the request is NOT withdrawn, so the link comes up by itself when the
    /// earbud appears and a later call finds it ready. `disconnect()` withdraws it.
    public func ensureConnected(identifier: UUID, timeout: TimeInterval = 15) async throws {
        if isConnected, peripheral?.identifier == identifier { return }
        let deadline = Date().addingTimeInterval(timeout)
        try await waitForPoweredOn(deadline: deadline)
        guard let p = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            throw GattError.gattError("peripheral_not_found")
        }
        if let old = peripheral, old.identifier != p.identifier {
            // another earbud was linked: leave it, this call is for the new one. The operation that was
            // running on the old link fails now: its disconnect callback arrives after `peripheral` is the
            // new earbud and is ignored (`isCurrent`), so nothing else would end it before the op timeout.
            central.cancelPeripheralConnection(old)
            clearCharacteristics()
            failPendingOps(with: GattError.notConnected)
        }
        peripheral = p
        p.delegate = self
        linkError = nil
        switch p.state {
        case .connected:
            if !linkReady { p.discoverServices([CBUUID(string: EarbudGattConstants.SERVICE_UUID)]) }
        case .disconnected:
            central.connect(p, options: nil)
        default:
            break   // connecting / disconnecting: the delegate carries on, this call waits
        }
        while !(p.state == .connected && linkReady) {
            if let why = linkError { throw GattError.gattError(why) }
            if Date() >= deadline { throw GattError.gattError("connect_timeout") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The KMS sweep's way to the earbud: connects to `identifier` (the remembered earbud) with a bounded
    /// wait, and does nothing when there is none or the link is already up. A failure only means the key
    /// stays pending for the next sweep, so it is logged and not thrown.
    ///
    /// After a failed attempt the next one waits `reconnectCooldown`: a sweep with several hw_only keys
    /// pays the wait for an absent earbud once, not once per key. The connection request itself stays
    /// pending in the system (see `ensureConnected`), so an earbud that comes into range is linked anyway.
    public func reconnect(to identifier: UUID?, timeout: TimeInterval) async {
        if isConnected { return }
        guard let identifier = identifier else {
            RTLog.info("earbud", "reconnect skipped no remembered earbud")
            return
        }
        if let failedAt = lastReconnectFailureAt,
           Date().timeIntervalSince(failedAt) < Self.reconnectCooldown {
            return
        }
        do {
            try await ensureConnected(identifier: identifier, timeout: timeout)
            lastReconnectFailureAt = nil
        } catch {
            lastReconnectFailureAt = Date()
            let why: String = String(describing: error)
            RTLog.info("earbud", "reconnect failed why=\(why)")
        }
    }

    /// Cancel the current GATT connection (and withdraw a pending connection request).
    public func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        clearCharacteristics()
        failPendingOps(with: GattError.notConnected)
    }

    private func waitForPoweredOn(deadline: Date) async throws {
        while true {
            switch central.state {
            case .poweredOn:
                return
            case .poweredOff:
                throw GattError.gattError("bluetooth_off")
            case .unauthorized:
                throw GattError.gattError("bluetooth_unauthorized")
            case .unsupported:
                throw GattError.gattError("bluetooth_unsupported")
            default:
                break   // unknown / resetting: wait for the state update
            }
            if Date() >= deadline { throw GattError.gattError("bluetooth_not_ready") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - EarbudKeyGattProxy

    // nonisolated: `isConnected` is the ONLY synchronous requirement of
    // EarbudKeyGattProxy/EarbudPairingGattProxy — a @MainActor sync witness of a
    // nonisolated sync requirement is exactly what fired the "conformance
    // crosses into main actor-isolated code" warning on the conformance line;
    // the async requirements are witnessed by @MainActor async methods, which
    // hop safely and do NOT cross. Reads `peripheral` (nonisolated(unsafe));
    // `.state` returns a Sendable enum. Keeping this nonisolated (instead of
    // @MainActor-ing the protocols) leaves the non-@MainActor relay callers
    // (EarbudAckPopRelay/EarbudPairingRelay `guard gatt.isConnected`) intact.
    //
    // True only when the link is up AND the service is discovered: an operation can run.
    public nonisolated var isConnected: Bool { peripheral?.state == .connected && linkReady }

    public func readAttestPop() async throws -> Data {
        try await opGate.run { try await self.readAttestPopLocked() }
    }

    private func readAttestPopLocked() async throws -> Data {
        let c = try require(attestPopChar, uuid: EarbudGattConstants.ATTEST_POP_UUID)
        return try await readChar(c)
    }

    public func startKeyImport(pkg: Data, popInputs: Data) async throws -> KeyImportOutcome {
        guard pkg.count == EarbudGattConstants.KEYIMPORT_PKG_LEN else {
            throw GattError.badInput("package_size:\(pkg.count)")
        }
        guard popInputs.count == EarbudGattConstants.KEYIMPORT_POP_FRAME_LEN else {
            throw GattError.badInput("pop_inputs_size:\(popInputs.count)")
        }
        return try await opGate.run { try await self.startKeyImportLocked(pkg: pkg, popInputs: popInputs) }
    }

    /// The ATT writes are decided by `EarbudKeyImportFragmenter.writeFrames` (engine, unit-tested against a
    /// model of the firmware's `key_import_write`): the PoP-INPUTS frame first, then the package as
    /// big-endian-offset fragments. The firmware imports and computes the PoP on the LAST fragment and
    /// wipes the staged PoP inputs right after, so the inputs written after the package never counted.
    private func startKeyImportLocked(pkg: Data, popInputs: Data) async throws -> KeyImportOutcome {
        let c = try require(keyImportChar, uuid: EarbudGattConstants.KEY_IMPORT_UUID)
        let budget = try writeBudget()
        guard let frames = EarbudKeyImportFragmenter.writeFrames(
            pkg: pkg, popInputs: popInputs, maxWriteLength: budget) else {
            throw GattError.writeBudgetTooSmall(have: budget, need: popInputs.count)
        }
        for frame in frames {
            try await writeWithRetry(c, data: frame)
        }

        // Read status (≥1 byte: [status][slot])
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
        try await opGate.run { try await self.writePairBeginLocked(payload) }
    }

    /// c5 is little-endian (the firmware's `pair_begin_write`), c3 big-endian: `EarbudPairGatt.pairBeginFrames`.
    private func writePairBeginLocked(_ payload: Data) async throws {
        let c = try require(pairBeginChar, uuid: EarbudGattConstants.PAIR_BEGIN_UUID)
        let budget = try writeBudget()
        guard let frames = EarbudPairGatt.pairBeginFrames(payload, maxWriteLength: budget) else {
            throw GattError.badInput("pair_begin_frames")
        }
        for frame in frames {
            try await writeWithRetry(c, data: frame)
        }
    }

    public func readPairResp() async throws -> Data {
        try await opGate.run { try await self.readPairRespLocked() }
    }

    private func readPairRespLocked() async throws -> Data {
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
        try await opGate.run { try await self.writePairFinLocked(confirm) }
    }

    private func writePairFinLocked(_ confirm: Data) async throws {
        let c = try require(pairFinChar, uuid: EarbudGattConstants.PAIR_FIN_UUID)
        try await writeChar(c, data: confirm)
    }

    // MARK: - Phase B: c8 FP_ADV_REQUEST

    /// Write ct_bind[32] so the earbud computes fp_adv in-SE.
    /// Precondition: ctBind must be exactly 32 bytes.
    public func writeFpAdvSeed(_ ctBind: Data) async throws {
        precondition(ctBind.count == 32, "ct_bind must be 32 bytes")
        try await opGate.run { try await self.writeFpAdvSeedLocked(ctBind) }
    }

    private func writeFpAdvSeedLocked(_ ctBind: Data) async throws {
        let c = try require(fpAdvChar, uuid: EarbudGattConstants.FP_ADV_UUID)
        try await writeChar(c, data: ctBind)
    }

    /// Read fp_adv[32] || key_epoch_le[8] from c8.
    /// Caller must have written ct_bind first via writeFpAdvSeed(_:).
    /// Returns (fpAdv: 32 bytes, epoch: little-endian UInt64).
    public func readFpAdv() async throws -> (fpAdv: Data, epoch: UInt64) {
        try await opGate.run { try await self.readFpAdvLocked() }
    }

    private func readFpAdvLocked() async throws -> (fpAdv: Data, epoch: UInt64) {
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

    // MARK: - DIAG (0x90)

    /// One read of the DIAG characteristic: the 28 / 32 B metrics packet. DIAG is READ only in the
    /// firmware (it declares BT_GATT_CHRC_READ, no notify and no CCC descriptor), so a subscription
    /// never delivers anything: the diagnostics screen calls this every 2 s, as Android does.
    public func readDiag() async throws -> Data {
        try await opGate.run { try await self.readDiagLocked() }
    }

    private func readDiagLocked() async throws -> Data {
        let c = try require(diagChar, uuid: EarbudGattConstants.DIAG_UUID)
        return try await readChar(c)
    }

    // MARK: - Private helpers

    private func require(_ char: CBCharacteristic?, uuid: String) throws -> CBCharacteristic {
        guard let c = char else { throw GattError.characteristicNotFound(uuid) }
        return c
    }

    /// The most one ATT write can carry on this link: ATT_MTU - 3. See the class comment.
    private func writeBudget() throws -> Int {
        guard let p = peripheral, p.state == .connected else { throw GattError.notConnected }
        return p.maximumWriteValueLength(for: .withoutResponse)
    }

    /// One frame, written with response. A transient failure is retried (a frame at the same offset is
    /// absorbed by the firmware's reassembler); a lost link is not.
    private func writeWithRetry(_ char: CBCharacteristic, data: Data) async throws {
        var retries = 0
        while true {
            do {
                try await writeChar(char, data: data)
                return
            } catch GattError.notConnected {
                throw GattError.notConnected
            } catch GattError.gattError(let msg) where msg.hasPrefix("disconnected") || msg == "timeout" {
                throw GattError.gattError(msg)
            } catch where retries < Self.maxWriteRetries {
                retries += 1
                let backoffMs = 200 + retries * 300
                try await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
            }
        }
    }

    private func writeChar(_ char: CBCharacteristic, data: Data) async throws {
        guard let p = peripheral, p.state == .connected else { throw GattError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeCont = cont
            p.writeValue(data, for: char, type: .withResponse)
            armOpTimeout()
        }
    }

    private func readChar(_ char: CBCharacteristic) async throws -> Data {
        guard let p = peripheral, p.state == .connected else { throw GattError.notConnected }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            readCont = cont
            p.readValue(for: char)
            armOpTimeout()
        }
    }

    private func armOpTimeout() {
        opSeq &+= 1
        let seq = opSeq
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: IOSEarbudGattProxy.opTimeoutNS)
            self?.expireOp(seq)
        }
    }

    /// The timer of operation `seq` ran out. Only the operation that is still pending is failed, and the
    /// link is dropped with it: the earbud may still answer, and that answer must not land on the next op.
    private func expireOp(_ seq: UInt64) {
        guard seq == opSeq, writeCont != nil || readCont != nil else { return }
        RTLog.warn("earbud", "gatt op timeout")
        failPendingOps(with: GattError.gattError("timeout"))
        disconnect()
    }

    /// True when a CoreBluetooth callback about `p` concerns the link this client follows now.
    ///
    /// After `ensureConnected` switched from earbud A to earbud B, CoreBluetooth still reports A's end
    /// (`didDisconnectPeripheral`, `didFailToConnect`) and may deliver A's late discovery or read / write
    /// results. Acting on them would clear B's characteristics and ready flag, set B's `linkError`, or
    /// resume B's pending write / read with A's answer. The rule is `EarbudLinkIdentity` (engine, unit-tested).
    private nonisolated func isCurrent(_ p: CBPeripheral) -> Bool {
        EarbudLinkIdentity.concernsCurrentLink(callback: p.identifier, current: peripheral?.identifier)
    }

    // nonisolated: called synchronously from the nonisolated CB delegate
    // witnesses (didDisconnect / didUpdateState); touches only the
    // nonisolated(unsafe) characteristic slots — always on the main thread.
    private nonisolated func clearCharacteristics() {
        attestPopChar = nil
        keyImportChar = nil
        pairBeginChar = nil
        pairRespChar  = nil
        pairFinChar   = nil
        fpAdvChar     = nil
        diagChar      = nil
        linkReady     = false
    }

    // nonisolated: called synchronously from every nonisolated delegate witness
    // on error/teardown; resumes the nonisolated(unsafe) continuations inline
    // (no reordering) — always on the main thread.
    private nonisolated func failPendingOps(with error: Error) {
        writeCont?.resume(throwing: error); writeCont = nil
        readCont?.resume(throwing: error);  readCont  = nil
    }
}

// MARK: - CBCentralManagerDelegate

extension IOSEarbudGattProxy: CBCentralManagerDelegate {

    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            clearCharacteristics()
            failPendingOps(with: GattError.gattError("bluetooth_off"))
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager,
                                           didConnect peripheral: CBPeripheral) {
        guard isCurrent(peripheral) else { return }
        peripheral.delegate = self
        let svcUUID = CBUUID(string: EarbudGattConstants.SERVICE_UUID)
        peripheral.discoverServices([svcUUID])
    }

    public nonisolated func centralManager(_ central: CBCentralManager,
                                           didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard isCurrent(peripheral) else { return }
        linkError = error?.localizedDescription ?? "connect_failed"
        failPendingOps(with: error ?? GattError.gattError("connect_failed"))
    }

    public nonisolated func centralManager(_ central: CBCentralManager,
                                           didDisconnectPeripheral peripheral: CBPeripheral,
                                           error: Error?) {
        guard isCurrent(peripheral) else { return }
        clearCharacteristics()
        failPendingOps(with: GattError.gattError(
            "disconnected:\(error?.localizedDescription ?? "nil")"))
    }
}

// MARK: - CBPeripheralDelegate

extension IOSEarbudGattProxy: CBPeripheralDelegate {

    public nonisolated func peripheral(_ peripheral: CBPeripheral,
                                       didDiscoverServices error: Error?) {
        guard isCurrent(peripheral) else { return }
        if let err = error {
            linkError = err.localizedDescription
            failPendingOps(with: err)
            return
        }
        guard let svc = peripheral.services?.first(where: {
            $0.uuid == CBUUID(string: EarbudGattConstants.SERVICE_UUID)
        }) else {
            linkError = "service_not_found"
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
            EarbudGattConstants.DIAG_UUID,
        ].map { CBUUID(string: $0) }
        peripheral.discoverCharacteristics(uuids, for: svc)
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral,
                                       didDiscoverCharacteristicsFor service: CBService,
                                       error: Error?) {
        guard isCurrent(peripheral) else { return }
        if let err = error {
            linkError = err.localizedDescription
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
            case CBUUID(string: EarbudGattConstants.DIAG_UUID):       diagChar      = char
            default: break
            }
        }
        // The link is usable once the KMS characteristics (c3 KEY_IMPORT, c1 ATTEST_POP) are there; the
        // others are looked up when used and name the missing one (characteristicNotFound).
        if keyImportChar != nil, attestPopChar != nil {
            linkError = nil
            linkReady = true
        } else {
            linkError = "service_incomplete"
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral,
                                       didWriteValueFor characteristic: CBCharacteristic,
                                       error: Error?) {
        guard isCurrent(peripheral) else { return }
        if let err = error {
            writeCont?.resume(throwing: GattError.gattError(err.localizedDescription))
        } else {
            writeCont?.resume()
        }
        writeCont = nil
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral,
                                       didUpdateValueFor characteristic: CBCharacteristic,
                                       error: Error?) {
        guard isCurrent(peripheral) else { return }
        if let err = error {
            readCont?.resume(throwing: GattError.gattError(err.localizedDescription))
        } else {
            readCont?.resume(returning: characteristic.value ?? Data())
        }
        readCont = nil
    }
}

// Swift 6 conformance fix (2026-07-12): the three "conformance crosses into main
// actor-isolated code" warnings are resolved by making every protocol witness
// that a nonisolated protocol requires SYNCHRONOUSLY — the CB delegate methods
// and `isConnected` — `nonisolated`, with the state they touch declared
// `nonisolated(unsafe)` (safe because CBCentralManager is created with
// queue: nil → all delegate callbacks land on the main thread, the same thread
// every @MainActor member runs on; single-threaded at runtime). The async
// EarbudKeyGattProxy/EarbudPairingGattProxy requirements are witnessed by
// @MainActor async methods, which satisfy nonisolated async requirements via a
// safe hop and never "cross". (History: `extension X: @preconcurrency P` was
// rejected by the ios-simulator build; MainActor.assumeIsolated needs iOS 17,
// target is 16 — this witness-level approach needs neither.)
extension IOSEarbudGattProxy: EarbudPairingGattProxy { }

#endif // QAUDION_EARBUD
