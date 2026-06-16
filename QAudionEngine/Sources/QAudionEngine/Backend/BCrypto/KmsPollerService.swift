import Foundation
import CryptoKit

/// Orchestrates the iOS-side KMS lifecycle: poll the server for
/// pending PSKs, decrypt each via `KmsTransport.decryptPackage`,
/// persist the recovered PSK to the iOS Keychain via
/// `SovereignKeyVault.storePsk`, then acknowledge so the server
/// flips status from `pending`/`delivered` to `acknowledged`.
///
/// Mirror of Android's `KmsPoller.kt` + `SovereignKeyKmsHandler.kt`
/// (cross-platform contract pinned in `WIRE_SPEC.md §2`).
///
/// ## Lifecycle
///
/// - `pollOnce()`: fetch /api/v1/kms/pending → decrypt → vault store →
///   acknowledge. Idempotent: a key that's already in the vault gets
///   its metadata refreshed but the bytes don't change. Each
///   per-key step is independently fault-tolerant — a single decrypt
///   failure does NOT abort the loop, and the server doesn't get
///   acknowledged for the failed key (per WIRE_SPEC §2.5: only
///   `acknowledged` and `revoked` are removed from the pending list).
/// - Should be called:
///   - At app launch (after WS auth) — sweeps any keys provisioned
///     while the app was offline.
///   - On every `kms_key_available` WS event — same sweep.
///
/// ## Device-key persistence (open gap)
///
/// This service expects the caller to supply the device's X25519 +
/// ML-KEM private keys. Long-term key persistence (so the keys
/// survive across app launches) is the responsibility of a separate
/// `DeviceKeyManager` (WIRE_SPEC §5 P1 follow-up). For now the
/// caller can pass freshly-generated keys for testing — those will
/// only decrypt packages encrypted within the same session.
public final class KmsPollerService {

    public struct DeviceKeys {
        public let x25519Priv: Data
        public let mlkemPub: Data?
        public let mlkemPriv: Data?

        public init(x25519Priv: Data, mlkemPub: Data?, mlkemPriv: Data?) {
            self.x25519Priv = x25519Priv
            self.mlkemPub = mlkemPub
            self.mlkemPriv = mlkemPriv
        }
    }

    public struct Stats {
        public var processed: Int = 0
        public var decryptFailed: Int = 0
        public var stored: Int = 0
        public var acknowledged: Int = 0
        public var ackFailed: Int = 0
    }

    private let kmsClient: BCryptoKmsClient
    private let vault: SovereignKeyVault

    public init(kmsClient: BCryptoKmsClient, vault: SovereignKeyVault) {
        self.kmsClient = kmsClient
        self.vault = vault
    }

    /// One-shot sweep. Returns aggregated stats so the caller can
    /// surface a per-poll diagnostic to the UI ("processed N keys").
    @discardableResult
    public func pollOnce(deviceKeys: DeviceKeys) async throws -> Stats {
        let pending = try await kmsClient.getPendingKeys()
        var stats = Stats()
        for entry in pending {
            stats.processed += 1
            do {
                try await processSingle(entry: entry, deviceKeys: deviceKeys, stats: &stats)
            } catch {
                stats.decryptFailed += 1
                print("[KmsPollerService] key=\(entry.keyId.prefix(8))… decrypt+store failed: \(error)")
            }
        }
        return stats
    }

    private func processSingle(
        entry: PendingKey,
        deviceKeys: DeviceKeys,
        stats: inout Stats
    ) async throws {
        // 1. Decode the encrypted_package bytes (server emits base64).
        guard let pkg = Data(base64Encoded: entry.encryptedPackage) else {
            throw KmsPollerError.malformedPackage
        }

        // 2. Decrypt via the 3-tier path. KmsTransport handles
        //    classical/binding-hybrid/legacy-KEM tier discrimination
        //    by package length (WIRE_SPEC §2.4).
        let psk = try KmsTransport.decryptPackage(
            pkg: pkg,
            x25519Priv: deviceKeys.x25519Priv,
            mlkemPub: deviceKeys.mlkemPub,
            mlkemPriv: deviceKeys.mlkemPriv
        )

        // 3. Compute the canonical fingerprint (full SHA-256 hex —
        //    WIRE_SPEC §3.3 — so this PSK can be advertised in the
        //    PqcHandshake OFFER and the responder's lex-sort
        //    intersection picks it cross-platform).
        let fingerprintHex = SHA256.hash(data: psk)
            .map { String(format: "%02x", $0) }
            .joined()

        // 4. Persist into the Keychain via SovereignKeyVault. The
        //    `name` is the server's keyId (UUID, stable across
        //    reboots; idempotent re-store updates the bytes).
        try vault.storePsk(name: entry.keyId, key: psk, fingerprint: fingerprintHex)
        stats.stored += 1

        // 5. Acknowledge — only after the bytes are durably stored.
        //    Per WIRE_SPEC §2.5: NOT ack'ing on a transient failure
        //    is intentional, so the server keeps re-emitting the
        //    same key on the next poll.
        do {
            try await kmsClient.acknowledgeKey(keyId: entry.keyId)
            stats.acknowledged += 1
        } catch {
            stats.ackFailed += 1
            print("[KmsPollerService] key=\(entry.keyId.prefix(8))… stored OK but acknowledge failed: \(error)")
        }
    }

    public enum KmsPollerError: Error {
        case malformedPackage
    }
}

/// Lightweight interval driver for the KMS sweep. Phase-0: replaces the
/// "poll only on WS event / app launch" gap with a steady cadence so a
/// dropped WS notification (background, flaky link) still gets keys
/// within `intervalSeconds`. Honors a server-supplied interval when the
/// caller passes one; defaults to 300s.
public actor KmsPeriodicPoller {
    private let intervalSeconds: Double
    private var task: Task<Void, Never>?

    public init(intervalSeconds: Double = 300) {
        // Floor guards against a zero/negative interval (busy-loop) while
        // staying below the test's fast 0.05s cadence. Production callers
        // pass the 300s default or a server-supplied `kms_poll_interval_sec`.
        self.intervalSeconds = max(0.01, intervalSeconds)
    }

    public func start(_ tick: @escaping @Sendable () async -> Void) {
        task?.cancel()
        let interval = intervalSeconds
        task = Task {
            while !Task.isCancelled {
                let ns = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { break }
                await tick()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
