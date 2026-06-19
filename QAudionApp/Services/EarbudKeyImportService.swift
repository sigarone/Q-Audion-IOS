import Foundation
import QAudionEngine

/// Canonical QAUDION earbud crypto GATT UUIDs (source of truth =
/// firmware/nspe/src/transport/qaudion_gatt.c). The contract (§3.0)
/// requires cross-checking the iOS-derived UUIDs against the
/// firmware-published canonical ones BEFORE relay — done here:
///
///   service base : f2c0aaaa-bcc0-4001-8000-0000000000XX
///   KEY_IMPORT   : slot 0xc3 (write PoP-inputs + package fragments; read [status][slot])
///   ATTEST_POP   : slot 0xc1 (read the 32-byte qa-kms-pop-v1 SE PoP after import)
///
/// NOTE: the plan-draft UUIDs (5a3e00c3 / 5a3e00c4) were derived from the
/// QA-P3-BENCH *diagnostic* service base and are REJECTED — that is a
/// different service. ATTEST_POP is 0xc1, not 0xc4.
public enum QaudionEarbudGatt {
    public static let serviceUUID    = "f2c0aaaa-bcc0-4001-8000-000000000000"
    public static let keyImportUUID  = "f2c0aaaa-bcc0-4001-8000-0000000000c3"
    public static let attestPopUUID  = "f2c0aaaa-bcc0-4001-8000-0000000000c1"
    /// Sovereign package fixed size (§3.3, == firmware KEYIMPORT_PKG_LEN).
    public static let sovereignPackageBytes = 1668
    /// KEY_IMPORT status bytes (firmware key_import_read [status][slot]).
    public static let stOK: UInt8      = 0x00
    public static let stErr: UInt8     = 0x01
    public static let stAuthFail: UInt8 = 0x02
    public static let stReplay: UInt8  = 0x03
}

/// Transport abstraction for the sovereign relay so the orchestrator is
/// decoupled from CoreBluetooth and unit-testable. A concrete
/// implementation drives a CBPeripheral against the canonical QAUDION
/// crypto service (NOT the QA-P3-BENCH diagnostic manager).
///
/// RESOLVED (was a 2-part blocker): firmware commit 3677d2a landed the
/// qa-kms-pop-v1 SE PoP over GATT, so this relay can now run on-device.
/// (1) The concrete CoreBluetooth client is `CoreBluetoothSovereignRelay`
///     (drives the f2c0aaaa… service; the QA-P3-BENCH QaP3GattManager talks
///     to a DIFFERENT diagnostic service 5a3e0001… and is reused only for
///     its CB + async/await PATTERNS, not its UUIDs).
/// (2) ATTEST_POP (0xc1) now returns the qa-kms-pop-v1 SE PoP — NOT the
///     device-attestation MAC — once a PoP-INPUTS frame (step 1 below) has
///     been written before the package fragments. Firmware
///     key_import_write stages the inputs (0xFFFF sentinel) and, on the
///     final-fragment import, loads `nsc_get_last_kms_pop()` into the
///     ATTEST_POP read buffer. Reading 0xc1 WITHOUT writing the PoP-INPUTS
///     frame first yields an invalid/empty PoP — that is why
///     `relay()` writes the inputs frame before any fragment.
///
/// Both chars are ENCRYPT-permissioned
/// (BT_GATT_PERM_READ_ENCRYPT|WRITE_ENCRYPT), so the relay requires a
/// bonded/encrypted link.
public protocol SovereignEarbudGattRelay {
    /// Write one KEY_IMPORT fragment ([offset:u16 BE][payload]) with
    /// response and await the GATT write confirmation.
    func writeKeyImportFragment(_ frame: Data) async throws
    /// Read the import result status (firmware [status][slot], 2 bytes).
    func readKeyImportStatus() async throws -> Data
    /// Read the 32-byte SE-computed qa-kms-pop-v1 MAC after the import.
    func readSovereignPoP() async throws -> Data
}

/// Sovereign earbud-relay for KMS Rotation v2 (§5 iOS, Phase-2).
///
/// The server seals the 1668-byte sovereign package to the earbud's SE
/// (qa-sovkey-wrap-v2, §3.3). The phone CANNOT decrypt it — it:
///   1. WRITEs the §3.4 PoP-INPUTS frame to KEY_IMPORT (0xc3) so the SE
///      computes the qa-kms-pop-v1 PoP during the import,
///   2. WRITEs the 1668-byte package as `[frag_offset:u16 BE][payload]`
///      fragments to 0xc3,
///   3. READs the import status [status][slot] from 0xc3, and
///   4. READs the 32-byte SE-computed qa-kms-pop-v1 PoP from ATTEST_POP
///      (0xc1) and forwards it VERBATIM to /api/v1/kms/ack-pop.
/// Because the earbud's wrap secret (ss_pq||ss_x) never leaves the SE, the
/// phone cannot forge the PoP.
public final class EarbudKeyImportService {
    private let relay: SovereignEarbudGattRelay
    private let kmsClient: BCryptoKmsClient
    /// Provisioned 32-byte server_id (SHA-256("qa-kms-server-id-v1|" ||
    /// KMS.ServerIdentity), §3.0). The SAME constant used for the phone-held
    /// PoP — defaults to `CryptoConstants.kmsServerId()` so the relay and the
    /// poller never diverge. Injectable for tests/KAT.
    private let serverId: Data

    public init(
        relay: SovereignEarbudGattRelay, kmsClient: BCryptoKmsClient,
        serverId: Data = CryptoConstants.kmsServerId()
    ) {
        self.relay = relay
        self.kmsClient = kmsClient
        self.serverId = serverId
    }

    public enum RelayError: Error {
        case badPackageLength(Int)
        case missingFields
        case importFailed(status: UInt8)
        case badPoP(Int)
    }

    /// Relay one sovereign PendingKey to the earbud and ack its PoP.
    ///
    /// `earbudDeviceId` is the value the phone sends as `device_id` in the
    /// `/kms/ack-pop` request — the ROW-LOOKUP key. The server matches it by
    /// STRING EQUALITY against the row it persisted (`row.DeviceID ==
    /// req.DeviceID`, server cmd/bcrypto-lite/main.go handleKMSAckPoP). This
    /// is SEPARATE from the `device_id = earbud_id[:16]` the PoP BYTES are
    /// bound to INTERNALLY on both firmware (sovkey_import.c:268 devid16 =
    /// earbud_id[:16], G2) and server (precomputed ExpectedPoP) — the phone
    /// neither computes nor sends those 16 bytes. Callers therefore pass the
    /// server-authoritative `entry.deviceId` from `/kms/pending` (§3.0:
    /// "device_id == the id registered at /device/publickey"), falling back to
    /// `entry.earbudId` only when the server omits `device_id`. See
    /// `AppState.runKmsSweep` for the resolution at the call site.
    @discardableResult
    public func relay(
        entry: PendingKey, earbudDeviceId: String, mtuPayload: Int = 180
    ) async throws -> BCryptoKmsClient.AckPopResponse {
        guard let pkg = Data(base64Encoded: entry.encryptedPackage) else {
            throw RelayError.missingFields
        }
        guard pkg.count == QaudionEarbudGatt.sovereignPackageBytes else {
            throw RelayError.badPackageLength(pkg.count)
        }
        // §3.4 PoP-INPUTS need txn_id, key_id (UUIDs), server_nonce (16B),
        // and the epoch (for the ack-pop request, decimal-string on the wire).
        guard let txnStr = entry.txnId, let txn = UUID(uuidString: txnStr),
              let keyId = UUID(uuidString: entry.keyId),
              let epochStr = entry.keyEpoch, let epoch = UInt64(epochStr),
              let nonceB64 = entry.serverNonce,
              let serverNonce = Data(base64Encoded: nonceB64),
              serverNonce.count == 16 else {
            throw RelayError.missingFields
        }
        // 1. MANDATORY first write: the 82-byte PoP-INPUTS frame (0xFFFF
        //    sentinel). Without it the SE imports K but computes NO PoP and
        //    the 0xc1 read is invalid. server_id is the provisioned constant
        //    (§3.0); device_id is NOT carried here — the SE binds the PoP to
        //    earbud_id[:16] internally.
        let popInputs = EarbudKeyImportFragmenter.popInputsFrame(
            txnId: txn, keyId: keyId, serverId: serverId, serverNonce: serverNonce)
        try await relay.writeKeyImportFragment(popInputs)
        // 2. Fragment + write each package frame in order (offset-indexed
        //    reassembler). frag_offset=0 resets the SE buffer.
        let frames = EarbudKeyImportFragmenter.fragment(pkg, mtuPayload: mtuPayload)
        for f in frames {
            try await relay.writeKeyImportFragment(f)
        }
        // 3. Confirm the in-SE import succeeded (firmware [status][slot]).
        let status = try await relay.readKeyImportStatus()
        let st = status.first ?? QaudionEarbudGatt.stErr
        guard st == QaudionEarbudGatt.stOK || st == QaudionEarbudGatt.stReplay else {
            throw RelayError.importFailed(status: st)
        }
        // 4. Read the SE qa-kms-pop-v1 MAC (32 bytes) from ATTEST_POP (0xc1)
        //    and forward verbatim to /kms/ack-pop.
        let pop = try await relay.readSovereignPoP()
        guard pop.count == 32 else { throw RelayError.badPoP(pop.count) }
        let resp = try await kmsClient.ackPop(
            keyId: entry.keyId, deviceId: earbudDeviceId,
            epoch: epoch, txnId: txnStr, pop: pop)
        print("[EarbudKeyImport] key=\(entry.keyId.prefix(8))… st=0x\(String(st, radix: 16)) ackPop verified=\(resp.verified) commit=\(resp.commit) epoch=\(resp.epoch)")
        return resp
    }
}
