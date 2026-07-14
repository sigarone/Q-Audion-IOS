import Foundation

/// W399 — persisted local registry of joined groups.
///
/// Closes the "GroupChatScreen.makeInfoState() uses stub members"
/// gap (#3 in PARITY_AUDIT_HONEST). Each entry tracks the group's
/// membership + admin set + bootstrap state so the UI and the
/// GroupChatService no longer rely on hardcoded data.
///
/// **Storage:** UserDefaults JSON for now. Same trade-off as the
/// existing `PendingGroupInviteStore` — adequate for the local
/// roster (no secret material, just userIds and names). Future
/// hardening: migrate to Keychain so a hostile process can't
/// enumerate the user's group list.
///
/// **Concurrency:** all access lives on @MainActor — the file is
/// designed around AppState ownership, not multi-threaded vault use.
@MainActor
public final class GroupRegistry: ObservableObject {

    public static let shared = GroupRegistry()

    public struct Entry: Codable, Equatable, Identifiable {
        public let id: String                // groupId hex (matches GroupChatService)
        public var name: String
        public var members: [String]         // userId list
        public var admins: [String]          // subset of members
        public let joinedAt: Date
        public var bootstrapped: Bool        // true once GroupChatService.session was created
        /// Fase 1A keystone — the SERVER-canonical membership epoch
        /// (`group_epoch` from `group_membership_changed` / the REST
        /// `membershipResponse`). This is the version counter the server
        /// bumps on EVERY membership op (add included) — distinct from the
        /// crypto sender-key epoch (which bumps only on remove/leave, §7.2).
        /// Used for the "epoch N" UI subtitle and as the `e_proposed` base
        /// for the signed membership envelope. The crypto epoch lives in
        /// the GroupSession vault snapshot (which GroupChatService probe-
        /// loads because the two counters diverge after any add). Persisted
        /// here so a real remove-member epoch bump survives an app restart
        /// (before Fase 1A, GroupChatService hardcoded epoch 1 → the bump
        /// was silently lost → cross-platform decrypt broke on remove).
        public var epoch: UInt32

        public init(id: String, name: String, members: [String],
                    admins: [String], joinedAt: Date = Date(),
                    bootstrapped: Bool = false, epoch: UInt32 = 1) {
            self.id = id
            self.name = name
            self.members = members
            self.admins = admins
            self.joinedAt = joinedAt
            self.bootstrapped = bootstrapped
            self.epoch = epoch
        }

        // Custom Decodable so pre-Fase-1A persisted entries (no `epoch`
        // key) decode cleanly to the default epoch 1 instead of throwing.
        // (Swift's synthesized init(from:) ignores property default values
        // for absent keys, so we must decode-if-present explicitly.)
        enum CodingKeys: String, CodingKey {
            case id, name, members, admins, joinedAt, bootstrapped, epoch
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.name = try c.decode(String.self, forKey: .name)
            self.members = try c.decode([String].self, forKey: .members)
            self.admins = try c.decode([String].self, forKey: .admins)
            self.joinedAt = try c.decode(Date.self, forKey: .joinedAt)
            self.bootstrapped = try c.decodeIfPresent(Bool.self, forKey: .bootstrapped) ?? false
            self.epoch = try c.decodeIfPresent(UInt32.self, forKey: .epoch) ?? 1
        }
    }

    @Published public private(set) var entries: [Entry] = []

    private static let storageKey = "qaudion.groups.registry.v1"

    private init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    // MARK: - Public API

    public func entry(for groupId: String) -> Entry? {
        return entries.first(where: { $0.id == groupId })
    }

    public func upsert(_ entry: Entry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        persist()
    }

    public func remove(groupId: String) {
        entries.removeAll(where: { $0.id == groupId })
        persist()
    }

    public func markBootstrapped(groupId: String) {
        guard let idx = entries.firstIndex(where: { $0.id == groupId }) else { return }
        entries[idx].bootstrapped = true
        persist()
    }

    public func addMember(groupId: String, userId: String) {
        guard let idx = entries.firstIndex(where: { $0.id == groupId }) else { return }
        if !entries[idx].members.contains(userId) {
            entries[idx].members.append(userId)
            persist()
        }
    }

    public func removeMember(groupId: String, userId: String) {
        guard let idx = entries.firstIndex(where: { $0.id == groupId }) else { return }
        entries[idx].members.removeAll(where: { $0 == userId })
        entries[idx].admins.removeAll(where: { $0 == userId })
        persist()
    }

    public func setAdmin(groupId: String, userId: String, isAdmin: Bool) {
        guard let idx = entries.firstIndex(where: { $0.id == groupId }) else { return }
        if isAdmin {
            if !entries[idx].admins.contains(userId) {
                entries[idx].admins.append(userId)
            }
        } else {
            entries[idx].admins.removeAll(where: { $0 == userId })
        }
        persist()
    }

    public func renameGroup(groupId: String, newName: String) {
        guard let idx = entries.firstIndex(where: { $0.id == groupId }) else { return }
        entries[idx].name = newName
        persist()
    }

    /// Fase 1A — record the server-canonical membership epoch. Monotonic:
    /// a stale event (lower epoch) never rolls the persisted value back
    /// (replay/downgrade defense; the server epoch only ever increases).
    public func setEpoch(groupId: String, epoch: UInt32) {
        guard let idx = entries.firstIndex(where: { $0.id == groupId }) else { return }
        guard epoch > entries[idx].epoch else { return }
        entries[idx].epoch = epoch
        persist()
    }
}
