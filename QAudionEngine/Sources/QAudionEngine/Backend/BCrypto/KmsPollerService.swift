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
    private let earbudRelay: EarbudAckPopRelay?

    public init(kmsClient: BCryptoKmsClient, vault: SovereignKeyVault, earbudRelay: EarbudAckPopRelay? = nil) {
        self.kmsClient = kmsClient
        self.vault = vault
        self.earbudRelay = earbudRelay
    }

    /// One-shot sweep. Returns aggregated stats so the caller can
    /// surface a per-poll diagnostic to the UI ("processed N keys").
    ///
    /// When `v2Context` is supplied, v2 phone-held entries are decrypted
    /// with the AAD-bound path and committed staged→active on a verified
    /// PoP (§3.5). v2 sovereign (earbud) entries are NOT handled here —
    /// the poller surfaces them to the app layer (`EarbudKeyImportService`)
    /// which owns the GATT relay (the phone cannot decrypt them).
    @discardableResult
    public func pollOnce(
        deviceKeys: DeviceKeys,
        v2Context: V2Context? = nil
    ) async throws -> Stats {
        let pending = try await kmsClient.getPendingKeys()
        var stats = Stats()
        for entry in pending {
            stats.processed += 1
            do {
                switch Self.route(for: entry) {
                case .v1Legacy:
                    try await processSingle(entry: entry, deviceKeys: deviceKeys, stats: &stats)
                case .v2PhoneHeld:
                    guard let ctx = v2Context else { throw KmsPollerError.missingV2Context }
                    try await processV2PhoneHeld(
                        entry: entry, deviceKeys: deviceKeys,
                        context: ctx, stats: &stats)
                case .v2Sovereign:
                    // Deferred to EarbudKeyImportService (app layer owns BLE).
                    print("[KmsPollerService] sovereign entry key=\(entry.keyId.prefix(8))… deferred to earbud relay")
                }
            } catch {
                stats.decryptFailed += 1
                print("[KmsPollerService] key=\(entry.keyId.prefix(8))… process failed: \(error)")
            }
        }
        return stats
    }

    // MARK: - v2 routing + lifecycle (§3.5/§6)

    public enum Route: Equatable { case v1Legacy, v2PhoneHeld, v2Sovereign }

    /// §6 routing: legacy devices/keys → v1; v2 sovereign earbud keys →
    /// GATT relay; v2 phone-held keys → AAD-bound decrypt + PoP.
    public static func route(for entry: PendingKey) -> Route {
        if entry.protoVersion < 2 { return .v1Legacy }
        if entry.keyType == "sovereign" { return .v2Sovereign }
        return .v2PhoneHeld
    }

    /// §3.5 anti-rollback: reject an epoch that is not strictly greater
    /// than the device's last committed (active) epoch for the slot.
    public static func shouldRejectEpoch(incoming: UInt64, active: UInt64?) -> Bool {
        guard let active = active else { return false }
        return incoming <= active
    }

    /// v2 identity context: the user/device UUIDs + the provisioned
    /// 32-byte server_id (SHA-256 of the pinned KMS identity, §3.0/§3.4).
    /// Per the §3.0 freeze, user/device ids are server-authoritative and
    /// delivered in the /kms/pending entry — these caller-supplied values
    /// are only a fallback when the entry omits them (legacy server).
    public struct V2Context {
        public let userId: UUID
        public let deviceId: UUID
        public let serverId: Data    // 32B SHA-256 of pinned KMS identity
        public init(userId: UUID, deviceId: UUID, serverId: Data) {
            self.userId = userId; self.deviceId = deviceId; self.serverId = serverId
        }
    }

    /// App-side active-epoch store (per slot_id). Honest limitation
    /// (§7): defeatable by a fully compromised OS — the earbud NVS
    /// counter is the strong anchor. Stored in the vault as a decimal
    /// string under "__kms.active_epoch.<slot_id>".
    private func activeEpoch(slotId: String) -> UInt64? {
        guard let d = try? vault.loadPsk(name: "__kms.active_epoch.\(slotId)"),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return UInt64(s)
    }
    private func commitActiveEpoch(slotId: String, epoch: UInt64) {
        let d = Data(String(epoch).utf8)
        try? vault.storePsk(name: "__kms.active_epoch.\(slotId)", key: d, fingerprint: "kms-epoch")
    }

    /// v2 phone-held (§3.2/§3.4/§3.5): AAD-bound decrypt → stage PSK →
    /// derive PoP over the per-delivery wrap secret → POST /kms/ack-pop →
    /// commit STAGED→ACTIVE on {commit:true}. user/device ids come from
    /// the entry (server-authoritative) with a context fallback.
    func processV2PhoneHeld(
        entry: PendingKey, deviceKeys: DeviceKeys,
        context: V2Context, stats: inout Stats
    ) async throws {
        // Server-authoritative identity from the entry (§3.0), else the
        // caller's context (legacy server that omits the fields).
        let userId = entry.userId.flatMap { UUID(uuidString: $0) } ?? context.userId
        let deviceId = entry.deviceId.flatMap { UUID(uuidString: $0) } ?? context.deviceId
        guard let slotId = entry.slotId, let epochStr = entry.keyEpoch,
              let epoch = UInt64(epochStr), let txnStr = entry.txnId,
              let txn = UUID(uuidString: txnStr),
              let keyId = UUID(uuidString: entry.keyId),
              let kc = KmsTransport.KeyClassV2(wire: entry.keyClass),
              let nonceB64 = entry.serverNonce,
              let serverNonce = Data(base64Encoded: nonceB64), serverNonce.count == 16,
              let pkg = Data(base64Encoded: entry.encryptedPackage) else {
            throw KmsPollerError.malformedPackage
        }
        if Self.shouldRejectEpoch(incoming: epoch, active: activeEpoch(slotId: slotId)) {
            print("[KmsPollerService] epoch reject key=\(entry.keyId.prefix(8))… epoch=\(epoch)")
            return
        }
        let out = try KmsTransport.decryptPackageV2(
            pkg: pkg, x25519Priv: deviceKeys.x25519Priv,
            mlkemPriv: deviceKeys.mlkemPriv, mlkemPub: deviceKeys.mlkemPub,
            keyId: keyId, userId: userId, deviceId: deviceId,
            keyEpoch: epoch, txnId: txn, keyClass: kc)
        var psk = out.psk
        var wrap = out.wrapSecret
        // Stage: persist PSK under keyId (idempotent).
        let fp = SHA256.hash(data: psk).map { String(format: "%02x", $0) }.joined()
        // D1 (Phase-1): persist the server-declared key_class alongside the PSK
        // so the per-call negotiation (D2) and the require-hw-only policy (D4)
        // can tell a hw_only contact key from a plain shared one. `kc` is the
        // §3.2 KeyClassV2 already validated above; map it onto the vault class.
        let vaultClass: SovereignKeyVault.KeyClass
        switch kc {
        case .hwOnly: vaultClass = .hwOnly
        case .swOnly: vaultClass = .swOnly
        case .shared: vaultClass = .shared
        }
        try vault.storePsk(name: entry.keyId, key: psk, fingerprint: fp, keyClass: vaultClass)
        stats.stored += 1
        // PoP over the per-delivery wrap secret (NOT over K).
        let pop = KmsPoPV1.compute(
            wrapSecret: wrap, deviceId: deviceId, serverId: context.serverId,
            txnId: txn, keyId: keyId, keyEpoch: epoch, serverNonce: serverNonce)
        CryptoConstants.zeroize(&wrap); CryptoConstants.zeroize(&psk)
        let resp = try await kmsClient.ackPop(
            keyId: entry.keyId, deviceId: deviceId.uuidString.lowercased(),
            epoch: epoch, txnId: txnStr, pop: pop)
        if resp.verified {
            stats.acknowledged += 1
        } else {
            stats.ackFailed += 1
        }
        // Commit STAGED→ACTIVE on the server's commit verdict. epoch is a
        // decimal STRING on the wire (§3.0); parse it, fall back to the
        // request epoch if the server echoes an unparseable value.
        if resp.commit {
            commitActiveEpoch(slotId: slotId, epoch: UInt64(resp.epoch) ?? epoch)
        }
    }

    private func processSingle(
        entry: PendingKey,
        deviceKeys: DeviceKeys,
        stats: inout Stats
    ) async throws {
        // hw_only: relay blind to earbud — phone cannot decrypt K''-wrapped package.
        if entry.keyClass == "hw_only" {
            guard let relay = earbudRelay else {
                print("[KmsPollerService] hw_only key=\(entry.keyId.prefix(8))… no earbudRelay — skip")
                return
            }
            let result = await relay.handle(key: entry)
            switch result {
            case .popVerified(let popB64):
                // POST /kms/earbud-ack-pop — FLAG-2: txnId, not keyId
                guard let txnId = entry.txnId, let earbudId = entry.earbudId else {
                    print("[KmsPollerService] hw_only key missing txnId/earbudId for ack-pop")
                    return
                }
                let epoch = entry.keyEpoch ?? 0
                do {
                    try await kmsClient.ackPopEarbud(txnId: txnId, earbudId: earbudId, epoch: epoch, popB64: popB64)
                    stats.acknowledged += 1
                } catch {
                    stats.ackFailed += 1
                    print("[KmsPollerService] hw_only ack-pop failed: \(error)")
                }
            case .success:
                stats.acknowledged += 1
            case .defer(let reason):
                print("[KmsPollerService] hw_only key=\(entry.keyId.prefix(8))… deferred: \(reason)")
            }
            return
        }

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
        case missingV2Context
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
