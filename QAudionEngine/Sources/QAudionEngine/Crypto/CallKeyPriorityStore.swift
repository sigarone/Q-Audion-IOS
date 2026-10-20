import Foundation

/// What the backing store holds for the order of the call keys.
public enum CallKeyPriorityStoredRead: Equatable {
    /// Nothing was ever stored.
    case absent
    case found(Data)
    /// There may be something, but it cannot be read now (Keychain locked, access refused): nothing is written
    /// over it.
    case unreadable
}

/// Where the order and the "placed by hand" marks live.
///
/// `CallKeyPriorityStore` calls `write` while it holds its lock, on whatever thread asked, the main thread
/// included. A write must therefore finish by itself: it must not post a notification that a block observer on
/// another queue answers, nor wait for any other thread.
public protocol CallKeyPriorityBacking {
    func read() -> CallKeyPriorityStoredRead
    func write(_ data: Data) -> Bool
}

/// The order and the marks as one entry of the key vault, under the same service as the keys, so it is wiped by
/// `clearAll` with them. It is metadata, not a secret, so it does not take the user-presence access control the keys
/// take when biometric key protection is on: it is written `AfterFirstUnlockThisDeviceOnly` with no access control
/// (`SovereignKeyVault.EntryProtection`) and `migratePskProtection` leaves it in that class. Reading it therefore
/// never prompts, on the main thread or while a call is being set up. The name starts with `__`, so the entry is
/// device-internal bookkeeping: never a call key, never advertised, never listed, and its writes are not announced on
/// `.sovereignVaultDidChange` (`SovereignKeyVault.announcesChange(ofAccount:)`), which keeps the write inside the
/// store's lock free of observers.
struct VaultCallKeyPriorityBacking: CallKeyPriorityBacking {
    static let accountName = "__callkeyprio.v1"
    static let fingerprintLabel = "call-key-order"

    let vault: SovereignKeyVault

    func read() -> CallKeyPriorityStoredRead {
        do {
            guard let data = try vault.loadPsk(name: Self.accountName), !data.isEmpty else { return .absent }
            return .found(data)
        } catch {
            return .unreadable
        }
    }

    func write(_ data: Data) -> Bool {
        do {
            try vault.storePsk(name: Self.accountName, key: data, fingerprint: Self.fingerprintLabel)
            return true
        } catch {
            return false
        }
    }
}

/// What a finalize did (section 4a).
public struct CallKeyPriorityFinalize: Equatable, Sendable {
    /// The keys deleted from the vault: the keys of the device stored before the finalized one.
    public let deleted: [String]
    /// `false` when the finalize could not be carried out: the stored list cannot be read now (the sequence of the
    /// keys is unknown, so nothing is deleted), or a key could not be deleted. Nothing is lost by retrying.
    public let complete: Bool
}

/// The list after an arrow press, and whether the new order is stored.
public struct CallKeyPriorityMove: Equatable, Sendable {
    /// The list as it is stored: the moved one when `saved`, the one before the press otherwise.
    public let list: CallKeyPriority
    /// `false` when the new order could not be stored (the Keychain refused the write, or the stored list cannot be
    /// read now and nothing is written over it). The stored order is then unchanged.
    public let saved: Bool
}

/// Keeps `CallKeyPriority` across launches and applies the moves of the user.
///
/// The list is keyed by the account name of each key in the vault (a KMS key id, `nfc-…`, `prox-…`). Every
/// reader goes through `current()`: it drops what the vault no longer holds, puts a key the vault holds and the
/// list does not know through the rule of the document (an in-person key of a device already held is stored as
/// the replacement of that device's key, section 4a), and writes only when something changed. A failed read
/// never overwrites what is stored. `finalize` is the only deletion the store makes.
public final class CallKeyPriorityStore {

    private static let lock = NSLock()

    private let backing: CallKeyPriorityBacking
    private let candidateSource: () -> [CallKeyPriority.Candidate]
    private let deleteKey: (String) -> Bool

    /// - Parameter deleteKey: removes a key from the vault; true when it is gone. Called by `finalize` only, and never
    ///   while the store holds its lock.
    public init(backing: CallKeyPriorityBacking,
                candidates: @escaping () -> [CallKeyPriority.Candidate],
                deleteKey: @escaping (String) -> Bool = { _ in false }) {
        self.backing = backing
        self.candidateSource = candidates
        self.deleteKey = deleteKey
    }

    /// The store over the real vault.
    public static func live(vault: SovereignKeyVault = SovereignKeyVault()) -> CallKeyPriorityStore {
        CallKeyPriorityStore(
            backing: VaultCallKeyPriorityBacking(vault: vault),
            candidates: { CallKeyPriorityStore.vaultCandidates(vault: vault) },
            deleteKey: { name in
                do {
                    try vault.deletePsk(name: name)
                    return true
                } catch {
                    return false
                }
            })
    }

    /// The keys that take part in calls, as the call path sees them: every vault entry except device keys,
    /// call-derived keys and identity-key entries (`PskAdvertising.isEligibleMatchCandidate`). Reads names,
    /// origins, classes and dates only, never key material.
    public static func vaultCandidates(vault: SovereignKeyVault) -> [CallKeyPriority.Candidate] {
        vault.listPskEntries().compactMap { entry -> CallKeyPriority.Candidate? in
            let origin = vault.origin(name: entry.name)
            guard PskAdvertising.isEligibleMatchCandidate(origin: origin) else { return nil }
            let group = CallKeyPriority.group(origin: origin, keyClass: vault.getKeyClass(name: entry.name))
            // A key with no bound identity (stored before the identity was kept) belongs to no device: never replaced.
            let device = group == .other && (origin == .nfc || origin == .proximity)
                && vault.nfcPeerIdentityKey(name: entry.name) != nil
                ? CallKeyPriority.inPersonDevice(ofAccount: entry.name) : nil
            return CallKeyPriority.Candidate(id: entry.name, group: group, createdAt: entry.createdAt, device: device)
        }
    }

    // MARK: - Reading

    /// The list for the keys the vault holds now. Persists the rebuilt list when it differs from the stored one.
    @discardableResult
    public func current() -> CallKeyPriority {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let loaded = load()
        let list = CallKeyPriority.reconciled(stored: loaded.stored, candidates: candidateSource())
        if loaded.writable {
            persistIfChanged(list, previous: loaded.stored)
        }
        return list
    }

    /// Call after a key was stored or deleted, so the list takes the new key by the rule (or drops the deleted
    /// one and its mark) at that moment.
    public func syncWithVault() {
        current()
    }

    // MARK: - Finalizing (section 4a)

    /// Finalize: `id` is known to be held by the other phone, so every key of its device stored before it is deleted
    /// from the vault and leaves the list. A key of the device stored after it stays. Nothing else deletes.
    ///
    /// The caller decides that the evidence is there (`InPersonKeyFinalize` for a call). Deleting happens outside the
    /// store's lock: a vault delete announces itself on `.sovereignVaultDidChange`.
    @discardableResult
    public func finalize(_ id: String) -> CallKeyPriorityFinalize {
        let toDelete: [String]
        do {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            let loaded = load()
            // Without the stored sequence numbers the order of storing is unknown: delete nothing.
            guard loaded.writable else { return CallKeyPriorityFinalize(deleted: [], complete: false) }
            var list = CallKeyPriority.reconciled(stored: loaded.stored, candidates: candidateSource())
            toDelete = list.finalize(id)
        }
        var deleted: [String] = []
        for name in toDelete where deleteKey(name) {
            deleted.append(name)
        }
        if !toDelete.isEmpty { syncWithVault() }
        return CallKeyPriorityFinalize(deleted: deleted, complete: deleted.count == toDelete.count)
    }

    // MARK: - Moving

    /// Swaps the key with the one above it and marks it as placed by hand. Returns the list as it is stored, and
    /// whether the move was stored.
    @discardableResult
    public func moveUp(_ id: String) -> CallKeyPriorityMove {
        move(id, up: true)
    }

    /// Swaps the key with the one below it and marks it as placed by hand. Returns the list as it is stored, and
    /// whether the move was stored.
    @discardableResult
    public func moveDown(_ id: String) -> CallKeyPriorityMove {
        move(id, up: false)
    }

    private func move(_ id: String, up: Bool) -> CallKeyPriorityMove {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let loaded = load()
        let before = CallKeyPriority.reconciled(stored: loaded.stored, candidates: candidateSource())
        // The stored list cannot be read now: a move written over it would lose the order and the marks.
        guard loaded.writable else { return CallKeyPriorityMove(list: before, saved: false) }
        var list = before
        if up {
            list.moveUp(id)
        } else {
            list.moveDown(id)
        }
        let saved = persistIfChanged(list, previous: loaded.stored)
        return CallKeyPriorityMove(list: saved ? list : before, saved: saved)
    }

    // MARK: - Storage

    private func load() -> (stored: CallKeyPriority.Stored?, writable: Bool) {
        switch backing.read() {
        case .absent:
            return (nil, true)
        case .unreadable:
            return (nil, false)
        case .found(let data):
            // A stored list that cannot be understood is rebuilt as on the first run.
            return (CallKeyPriority.Stored.decode(data), true)
        }
    }

    /// - Returns: `true` when the stored list is the given one afterwards: nothing needed writing, or the write
    ///   succeeded.
    @discardableResult
    private func persistIfChanged(_ list: CallKeyPriority, previous: CallKeyPriority.Stored?) -> Bool {
        let now = list.stored
        if let previous {
            if previous == now { return true }
        } else if list.entries.isEmpty {
            return true
        }
        guard let data = now.encoded() else { return false }
        return backing.write(data)
    }

    // MARK: - Display

    /// The first 64 bits of a key's fingerprint as `xxxx.xxxx.xxxx.xxxx`, the way the Android app shows it. The
    /// vault label of a call key is the full lowercase hex SHA-256 of the key; anything else is shown as it is,
    /// and a missing label as a dash.
    public static func shortFingerprint(label: String?) -> String {
        guard let label, !label.isEmpty else { return "—" }
        let lower = label.lowercased()
        let hexDigits = Set("0123456789abcdef")
        guard lower.count == 64, lower.allSatisfy({ hexDigits.contains($0) }) else { return label }
        let head = Array(lower.prefix(16))
        var groups: [String] = []
        var start = 0
        while start < head.count {
            groups.append(String(head[start..<(start + 4)]))
            start += 4
        }
        return groups.joined(separator: ".")
    }
}

/// Vault entries written by the key-rotation code that Key management no longer has: a rotated ephemeral public key
/// (`rotated_ephemeral.<seconds>`). Nothing reads them any more and the call path never used them.
///
/// The public keys of contacts scanned through the former identity QR (`peer.<userId>`) are left where they are:
/// they are not call keys (the vault classifies them as identity keys and every call-key reader skips them), and
/// this cleanup is limited to what the former rotation wrote.
public enum LegacyIdentityKeyEntries {

    /// The names among `names` to delete: the family above, and only when the vault classifies the entry as an
    /// identity key.
    public static func namesToRemove(from names: [String], origin: (String) -> PskOrigin) -> [String] {
        names.filter { name -> Bool in
            guard name.hasPrefix("rotated_ephemeral.") else { return false }
            return origin(name) == .identityKey
        }
    }

    /// Deletes them from the vault.
    /// - Returns: `true` when every one of them is gone.
    @discardableResult
    public static func removeAll(from vault: SovereignKeyVault) -> Bool {
        var allRemoved = true
        for name in namesToRemove(from: vault.listPskNames(), origin: { vault.origin(name: $0) }) {
            do {
                try vault.deletePsk(name: name)
            } catch {
                allRemoved = false
            }
        }
        return allRemoved
    }
}
