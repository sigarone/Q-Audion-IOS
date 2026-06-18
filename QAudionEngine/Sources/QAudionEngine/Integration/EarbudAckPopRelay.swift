import CryptoKit
import Foundation

/// CL-5.8 — KMS handler for `key_class == "hw_only"` deliveries.
///
/// Relays the encrypted package BLIND to the earbud via KEY_IMPORT (c3),
/// builds the 82-byte PoP-INPUTS frame (FLAG-2 applies), then reads the
/// 32-byte SE PoP from ATTEST_POP (c1). The caller POSTs to /kms/earbud-ack-pop.
///
/// ─── FLAG-2 (FROZEN 2026-06-18) ──────────────────────────────────────────────
/// In the PoP-INPUTS frame, offset +16 MUST be uuid16(txn_id), NOT uuid16(key_id).
/// The earbud SE binds the PoP to the txn_id; key_id makes the PoP unverifiable.
/// ─────────────────────────────────────────────────────────────────────────────
public final class EarbudAckPopRelay {

    private let gatt: EarbudKeyGattProxy

    public init(gatt: EarbudKeyGattProxy) { self.gatt = gatt }

    // MARK: - Public

    public enum HandleResult {
        case popVerified(popB64: String)
        case `defer`(reason: String)
        case success
    }

    public func handle(key: PendingKey) async -> HandleResult {
        guard key.keyClass == "hw_only" else {
            return .defer(reason: "not_hw_only")
        }
        guard let earbudId = key.earbudId, !earbudId.isEmpty else {
            return .defer(reason: "missing_earbud_id")
        }
        guard let pkgB64 = key.encryptedPackage.nilIfEmpty,
              let pkg = Data(base64Encoded: pkgB64),
              pkg.count == EarbudGattConstants.KEYIMPORT_PKG_LEN else {
            return .defer(reason: pkg_issue(key))
        }
        guard let popInputs = buildPopInputsFrame(key: key) else {
            return .defer(reason: "bad_pop_inputs")
        }
        guard gatt.isConnected else {
            return .defer(reason: "earbud_not_connected")
        }
        do {
            let outcome = try await gatt.startKeyImport(pkg: pkg, popInputs: popInputs)
            switch outcome {
            case .ok(let status, _):
                if status == EarbudGattConstants.KEYIMPORT_ST_OK {
                    return await readPopOrDefer(key: key)
                } else if status == EarbudGattConstants.KEYIMPORT_ST_REPLAY {
                    return .success
                } else {
                    return .defer(reason: String(format: "earbud_status_0x%02x", status))
                }
            case .err(let msg):
                return .defer(reason: "relay_error:\(msg)")
            }
        } catch {
            return .defer(reason: "relay_exception:\(error)")
        }
    }

    // MARK: - Internal (visible for tests)

    /// Build the 82-byte PoP-INPUTS frame for a hw_only key.
    ///
    /// Layout (FLAG-2 applies):
    ///   [0xFF,0xFF] || txn_id(16) || txn_id(16) [FLAG-2] || server_id(32) || server_nonce(16)
    func buildPopInputsFrame(key: PendingKey) -> Data? {
        guard let txnIdStr = key.txnId, !txnIdStr.isEmpty else { return nil }
        guard let txn16 = try? KmsTransport.uuid16(txnIdStr) else { return nil }
        let serverId = KmsServerIdentity.serverIdBytes
        guard serverId.count == 32 else { return nil }
        guard let nonceB64 = key.serverNonce,
              let nonce16 = Data(base64Encoded: nonceB64),
              nonce16.count == 16 else { return nil }

        var frame = Data(count: EarbudGattConstants.KEYIMPORT_POP_FRAME_LEN)
        // Sentinel [0xFF, 0xFF]
        frame[0] = 0xFF
        frame[1] = 0xFF
        let h = EarbudGattConstants.KEYIMPORT_FRAG_HEADER // 2
        // +0  txn_id(16)
        frame.replaceSubrange(h..<(h+16), with: txn16)
        // +16 FLAG-2: key_id slot = txn_id (NOT key_id)
        frame.replaceSubrange((h+16)..<(h+32), with: txn16)
        // +32 server_id(32)
        frame.replaceSubrange((h+32)..<(h+64), with: serverId)
        // +64 server_nonce(16)
        frame.replaceSubrange((h+64)..<(h+80), with: nonce16)
        return frame
    }

    // MARK: - Private

    private func readPopOrDefer(key: PendingKey) async -> HandleResult {
        do {
            let pop = try await gatt.readAttestPop()
            guard pop.count == EarbudGattConstants.KEYIMPORT_POP_LEN else {
                return .defer(reason: "bad_pop_size:\(pop.count)")
            }
            return .popVerified(popB64: pop.base64EncodedString())
        } catch {
            return .defer(reason: "pop_read_error:\(error)")
        }
    }

    private func pkg_issue(_ key: PendingKey) -> String {
        if key.encryptedPackage.isEmpty { return "empty_package" }
        if Data(base64Encoded: key.encryptedPackage) == nil { return "invalid_base64" }
        return "bad_package_size"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
