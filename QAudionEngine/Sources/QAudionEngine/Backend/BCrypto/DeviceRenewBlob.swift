import Foundation

/// Pure functions for the Phase 2 device-bound silent re-auth blobs.
///
/// Mirror of:
///   - Go server : `bcrypto-server/internal/auth/blob.go`
///   - Android   : `core-data/auth/DeviceRenewBlob.kt`
///   - Desktop   : `src/main/transport/DeviceRenewBlob.ts`
///
/// Domain-tag prefixes are uppercase + hyphenated to be prefix-disjoint
/// from every existing Ed25519 signing site. The disjointness invariant
/// is enforced by `DeviceRenewBlobTests`. Adding a sixth use of the
/// device key REQUIRES extending the disjointness test on every client
/// AND server.
///
/// 2026-05-06 session-renewal Phase 2.
public enum DeviceRenewBlob {

    public static let domainTagDeviceRenew  = "QAUDION-DEVICE-RENEW-v1"
    public static let domainTagDeviceRevoke = "QAUDION-REVOKE-v1"

    /// Single-use server-issued nonce length (32 bytes raw → 64 hex chars).
    public static let nonceLenBytes = 32

    /// Layout: `tag || 0x00 || serverID || 0x00 || deviceID || 0x00 || nonce(32) || 0x00 || epochMs(BE u64)`.
    public static func buildRenew(
        serverId: String,
        deviceId: String,
        nonce: Data,
        epochMs: UInt64
    ) -> Data {
        return buildBlob(domainTag: domainTagDeviceRenew,
                         idA: serverId, idB: deviceId,
                         nonce: nonce, epochMs: epochMs)
    }

    /// Layout: `tag || 0x00 || requestingDeviceID || 0x00 || targetDeviceID || 0x00 || nonce(32) || 0x00 || epochMs(BE u64)`.
    /// serverID intentionally NOT in the revoke blob — bearer access-token already pins the request.
    public static func buildRevoke(
        requestingDeviceId: String,
        targetDeviceId: String,
        nonce: Data,
        epochMs: UInt64
    ) -> Data {
        return buildBlob(domainTag: domainTagDeviceRevoke,
                         idA: requestingDeviceId, idB: targetDeviceId,
                         nonce: nonce, epochMs: epochMs)
    }

    private static func buildBlob(domainTag: String, idA: String, idB: String,
                                  nonce: Data, epochMs: UInt64) -> Data {
        precondition(nonce.count == nonceLenBytes,
                     "nonce must be \(nonceLenBytes) bytes, got \(nonce.count)")
        var out = Data()
        out.reserveCapacity(domainTag.utf8.count + 1 + idA.utf8.count + 1 +
                            idB.utf8.count + 1 + nonce.count + 1 + 8)
        out.append(contentsOf: domainTag.utf8)
        out.append(0x00)
        out.append(contentsOf: idA.utf8)
        out.append(0x00)
        out.append(contentsOf: idB.utf8)
        out.append(0x00)
        out.append(nonce)
        out.append(0x00)
        // Big-endian u64
        var be = epochMs.bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        return out
    }

    /// lowercase-hex encode (matches the Go server's `encoding/hex`).
    public static func hexEncode(_ data: Data) -> String {
        var s = ""
        s.reserveCapacity(data.count * 2)
        for b in data {
            s += String(format: "%02x", b)
        }
        return s
    }

    public static func hexDecode(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }
}
