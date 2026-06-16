import Foundation
import QAudionEngine

/// Canonical QAUDION earbud crypto GATT UUIDs (source of truth =
/// firmware/nspe/src/transport/qaudion_gatt.c). The contract (§3.0)
/// requires cross-checking the iOS-derived UUIDs against the
/// firmware-published canonical ones BEFORE relay — done here:
///
///   service base : f2c0aaaa-bcc0-4001-8000-0000000000XX
///   KEY_IMPORT   : slot 0xc3 (sovereign package relay + in-SE import)
///   ATTEST_POP   : slot 0xc1 (SE PoP read; write eph_pub||nonce then read)
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
/// BLOCKER (cross-subsystem, recorded): as of the committed firmware,
/// (1) there is no iOS CoreBluetooth client for the QAUDION crypto
///     service `f2c0aaaa…` (the only GATT client, QaP3GattManager, talks
///     to the QA-P3-BENCH diagnostic service `5a3e0001…`); and
/// (2) the firmware KEY_IMPORT char returns a 2-byte [status][slot], and
///     ATTEST_POP (0xc1) returns the device-ATTESTATION PoP
///     (nsc_attest_pop_respond over eph_pub||nonce), NOT the
///     qa-kms-pop-v1 SE PoP keyed on the sovereign wrap secret. The
///     firmware Phase-2 task to expose the KMS PoP over GATT is not yet
///     landed. The concrete CoreBluetooth client + the firmware GATT PoP
///     surface must land together before this relay can run on-device.
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
/// (qa-sovkey-wrap-v2, §3.3). The phone CANNOT decrypt it — it relays the
/// bytes over GATT KEY_IMPORT (char 0xc3) as `[frag_offset:u16 BE][payload]`
/// writes, then reads the 32-byte SE-computed qa-kms-pop-v1 PoP (§3.4) and
/// forwards it VERBATIM to /api/v1/kms/ack-pop. Because the earbud's wrap
/// secret (ss_pq||ss_x) never leaves the SE, the phone cannot forge it.
public final class EarbudKeyImportService {
    private let relay: SovereignEarbudGattRelay
    private let kmsClient: BCryptoKmsClient

    public init(relay: SovereignEarbudGattRelay, kmsClient: BCryptoKmsClient) {
        self.relay = relay
        self.kmsClient = kmsClient
    }

    public enum RelayError: Error {
        case badPackageLength(Int)
        case missingFields
        case importFailed(status: UInt8)
        case badPoP(Int)
    }

    /// Relay one sovereign PendingKey to the earbud and ack its PoP.
    /// `earbudDeviceId` is the EARBUD's device id (the sovereign recipient)
    /// the server keyed the PoP delivery on — NOT the phone's.
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
        guard let txn = entry.txnId, let epochStr = entry.keyEpoch,
              let epoch = UInt64(epochStr) else {
            throw RelayError.missingFields
        }
        // 1. Fragment + write each frame in order (offset-indexed reassembler).
        let frames = EarbudKeyImportFragmenter.fragment(pkg, mtuPayload: mtuPayload)
        for f in frames {
            try await relay.writeKeyImportFragment(f)
        }
        // 2. Confirm the in-SE import succeeded (firmware [status][slot]).
        let status = try await relay.readKeyImportStatus()
        let st = status.first ?? QaudionEarbudGatt.stErr
        guard st == QaudionEarbudGatt.stOK || st == QaudionEarbudGatt.stReplay else {
            throw RelayError.importFailed(status: st)
        }
        // 3. Read the SE qa-kms-pop-v1 MAC (32 bytes) and forward verbatim.
        let pop = try await relay.readSovereignPoP()
        guard pop.count == 32 else { throw RelayError.badPoP(pop.count) }
        let resp = try await kmsClient.ackPop(
            keyId: entry.keyId, deviceId: earbudDeviceId,
            epoch: epoch, txnId: txn, pop: pop)
        print("[EarbudKeyImport] key=\(entry.keyId.prefix(8))… st=0x\(String(st, radix: 16)) ackPop verified=\(resp.verified) commit=\(resp.commit) epoch=\(resp.epoch)")
        return resp
    }
}
