import Foundation

/// The order of the pre-shared keys this app holds, which is the order of the caller's advert
/// (docs/security/CALL_KEY_PRIORITY.md, the same document and the same conformance table
/// `call-key-priority-cases.tsv` as the Android app), including the two-step replacement of an in-person key
/// (section 4a: `storeAsReplacement`, then `finalize`).
///
/// One pure type: it has no Keychain, no clock and no randomness. The real key list (Key management: arrows,
/// imports, deliveries, pairings, deletions) and the advert (OFFER, ACCEPT advert, re-key) both use it, and
/// `CallKeyPriorityTests` runs every row of the shared table through it.
public struct CallKeyPriority: Equatable, Sendable {

    /// Section 1 of the document: H is a KMS key of class hw_only, K any other KMS key, O every other key.
    public enum Group: String, Equatable, Sendable {
        case hwOnly = "H"
        case kms = "K"
        case other = "O"
    }

    /// A key the list is built from: its stable id (the vault account name), its group and when it arrived.
    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let group: Group
        public let createdAt: Date?
        /// The device the key belongs to (section 4a), nil for a key that belongs to no device: it is then its own.
        public let device: String?

        public init(id: String, group: Group, createdAt: Date? = nil, device: String? = nil) {
            self.id = id
            self.group = group
            self.createdAt = createdAt
            self.device = device
        }
    }

    /// One place of the list. `placedByHand` is the mark of section 2: set when the user moves the key with an
    /// arrow (even when the move changed nothing), cleared only when the key is deleted.
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let group: Group
        public var placedByHand: Bool
        /// The device of section 4a: the in-person keys of one device share it; any other key is its own device.
        public var device: String
        /// The store sequence number: a key stored later has a higher one. Compared only between keys of one device,
        /// by `finalize`. 0 for a key stored before the number existed, which therefore counts as stored first.
        public var seq: Int

        public init(id: String, group: Group, placedByHand: Bool = false, device: String? = nil, seq: Int = 0) {
            self.id = id
            self.group = group
            self.placedByHand = placedByHand
            self.device = device ?? id
            self.seq = seq
        }
    }

    /// Where a key stands in a two-step replacement (section 4a).
    public enum Pending: Equatable, Sendable {
        case none
        /// Stored as the replacement of an earlier key of the device and not finalized yet.
        case waiting
        /// An earlier key of the device that a newer one replaces; still live.
        case retiring
    }

    /// Index 0 is the highest priority: the first fingerprint of the caller's advert.
    public private(set) var entries: [Entry]

    public init() {
        self.entries = []
    }

    public var ids: [String] {
        entries.map { $0.id }
    }

    public func contains(_ id: String) -> Bool {
        entries.contains(where: { $0.id == id })
    }

    /// Zero-based place of the key, nil when it is not in the list.
    public func position(of id: String) -> Int? {
        entries.firstIndex(where: { $0.id == id })
    }

    public func isPlacedByHand(_ id: String) -> Bool {
        entries.first(where: { $0.id == id })?.placedByHand ?? false
    }

    /// The group of a key from where it came from and its class: a hw_only key is H wherever it came from, any
    /// other KMS key is K, everything else (NFC tap, in-person pairing, anything else) is O.
    public static func group(origin: PskOrigin, keyClass: SovereignKeyVault.KeyClass) -> Group {
        if keyClass == .hwOnly { return .hwOnly }
        if origin == .kms { return .kms }
        return .other
    }

    // MARK: - A new key (section 3)

    /// Puts a new key in its place. A key already in the list stays where it is.
    ///
    /// - O: at the end.
    /// - H: right above the highest-ranked H or K key; with none, above the first key not placed by hand (at the
    ///   end when every key is placed by hand).
    /// - K: right above the highest-ranked K key; with none, right below the lowest-ranked H key; with no H key
    ///   either, above the first key not placed by hand (at the end when every key is placed by hand).
    public mutating func add(id: String, group: Group, device: String? = nil) {
        guard !contains(id) else { return }
        let entry = Entry(id: id, group: group, device: device, seq: nextSeq())
        let index: Int
        switch group {
        case .other:
            index = entries.count
        case .hwOnly:
            let highestHwOrKms = entries.firstIndex(where: { $0.group == .hwOnly || $0.group == .kms })
            index = highestHwOrKms ?? firstNotPlacedIndex()
        case .kms:
            if let highestKms = entries.firstIndex(where: { $0.group == .kms }) {
                index = highestKms
            } else if let lowestHw = entries.lastIndex(where: { $0.group == .hwOnly }) {
                index = lowestHw + 1
            } else {
                index = firstNotPlacedIndex()
            }
        }
        entries.insert(entry, at: index)
    }

    private func firstNotPlacedIndex() -> Int {
        entries.firstIndex(where: { !$0.placedByHand }) ?? entries.count
    }

    private func nextSeq() -> Int {
        (entries.map { $0.seq }.max() ?? 0) + 1
    }

    // MARK: - Pairing again with the same device (section 4a)

    /// Store: `id`, from a new confirmed pairing with `device` by the same method, takes the place and the "placed by
    /// hand" mark of the highest-ranked key of that device; that key moves directly below it, without the mark, and
    /// is now retiring. Nothing is deleted. A device with no other key gets the new key as in section 3 (an in-person
    /// key goes to the end). A key already in the list (it arrived before this call) is moved to its place.
    public mutating func storeAsReplacement(id: String, device: String) {
        if let existing = position(of: id) {
            entries.remove(at: existing)
        }
        guard let oldIndex = entries.firstIndex(where: { $0.device == device }) else {
            add(id: id, group: .other, device: device)
            return
        }
        let carriedMark = entries[oldIndex].placedByHand
        entries[oldIndex].placedByHand = false
        entries.insert(Entry(id: id, group: .other, placedByHand: carriedMark, device: device, seq: nextSeq()),
                       at: oldIndex)
    }

    /// Finalize: deletes every key of the device of `id` that was stored before it, and never one stored after it.
    /// Finalizing twice changes nothing.
    /// - Returns: the ids removed from the list, which the caller deletes from the vault.
    @discardableResult
    public mutating func finalize(_ id: String) -> [String] {
        guard let target = entries.first(where: { $0.id == id }) else { return [] }
        let removed = entries.filter { $0.device == target.device && $0.id != id && $0.seq < target.seq }.map { $0.id }
        entries.removeAll(where: { removed.contains($0.id) })
        return removed
    }

    public func pending(_ id: String) -> Pending {
        guard let entry = entries.first(where: { $0.id == id }) else { return .none }
        let siblings = entries.filter { $0.device == entry.device && $0.id != id }
        if siblings.contains(where: { $0.seq > entry.seq }) { return .retiring }
        if siblings.contains(where: { $0.seq < entry.seq }) { return .waiting }
        return .none
    }

    /// Whether some key waits for its confirmation.
    public var hasWaitingKey: Bool {
        entries.contains(where: { pending($0.id) == .waiting })
    }

    /// The device an in-person key belongs to, from its vault account name: `nfc-<16 hex of the peer's identity key>`
    /// or `prox-<16 hex>`, with or without the `-<8 hex of the key's fingerprint>` that tells two keys of one device
    /// apart. Nil for any other name (the key is then its own device). The method is part of the device, so the same
    /// phone paired by the other method is another device.
    public static func inPersonDevice(ofAccount name: String) -> String? {
        for prefix in ["nfc-", "prox-"] where name.hasPrefix(prefix) {
            let parts = name.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 1 || parts.count == 2,
                  isLowerHex(parts[0], count: 16),
                  parts.count == 1 || isLowerHex(parts[1], count: 8) else { return nil }
            return prefix + String(parts[0])
        }
        return nil
    }

    /// The vault account name of a stored in-person key: its device and the first 8 hex characters of the key's
    /// fingerprint. A fresh pairing has a fresh key, so it gets a name of its own and the earlier key stays.
    public static func inPersonAccountName(device: String, keyFingerprint: String) -> String {
        device + "-" + String(keyFingerprint.lowercased().prefix(8))
    }

    private static func isLowerHex(_ text: Substring, count: Int) -> Bool {
        text.count == count && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    // MARK: - Moves and deletions (section 4)

    /// A deleted key leaves the list and loses its mark.
    public mutating func remove(_ id: String) {
        entries.removeAll(where: { $0.id == id })
    }

    /// Swaps the key with the one above it. The key is marked as placed by hand even when it is already first and
    /// nothing moves; only the moved key is marked, not the neighbour it swapped with.
    /// - Returns: whether the order changed.
    @discardableResult
    public mutating func moveUp(_ id: String) -> Bool {
        guard let index = position(of: id) else { return false }
        entries[index].placedByHand = true
        guard index > 0 else { return false }
        entries.swapAt(index, index - 1)
        return true
    }

    /// Swaps the key with the one below it; see `moveUp` for the mark.
    /// - Returns: whether the order changed.
    @discardableResult
    public mutating func moveDown(_ id: String) -> Bool {
        guard let index = position(of: id) else { return false }
        entries[index].placedByHand = true
        guard index < entries.count - 1 else { return false }
        entries.swapAt(index, index + 1)
        return true
    }

    // MARK: - First run (section 5) and rebuilding from what is stored

    /// The list built from keys the app already holds, with nothing stored yet: H, then K, then O; inside H and
    /// inside K the newest first, inside O the oldest first. A key with no creation date comes after the dated
    /// ones of its group, then by id, so the result never depends on the order the keys are listed in. No key
    /// starts placed by hand.
    public static func firstRun(_ candidates: [Candidate]) -> CallKeyPriority {
        var list = CallKeyPriority()
        let sorted = uniqueById(candidates).sorted(by: { (lhs: Candidate, rhs: Candidate) -> Bool in
            if lhs.group != rhs.group { return rank(lhs.group) < rank(rhs.group) }
            let newestFirst = lhs.group != .other
            switch (lhs.createdAt, rhs.createdAt) {
            case let (l?, r?) where l != r: return newestFirst ? l > r : l < r
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.id < rhs.id
            }
        })
        let arrival = uniqueById(candidates).sorted(by: { (lhs: Candidate, rhs: Candidate) -> Bool in
            arrivesBefore(lhs, rhs)
        })
        var seqById: [String: Int] = [:]
        for (index, candidate) in arrival.enumerated() { seqById[candidate.id] = index + 1 }
        list.entries = sorted.map { Entry(id: $0.id, group: $0.group, device: $0.device, seq: seqById[$0.id] ?? 0) }
        return list
    }

    /// What is stored for a list: the order and the marks. The groups are not stored, they come from the keys.
    public struct Stored: Codable, Equatable, Sendable {
        public struct Key: Codable, Equatable, Sendable {
            public let id: String
            public let placed: Bool
            /// The store sequence number of the key (section 4a); 0 when none was stored.
            public let seq: Int

            public init(id: String, placed: Bool, seq: Int = 0) {
                self.id = id
                self.placed = placed
                self.seq = seq
            }

            private enum CodingKeys: String, CodingKey {
                case id, placed, seq
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                placed = try container.decode(Bool.self, forKey: .placed)
                seq = try container.decodeIfPresent(Int.self, forKey: .seq) ?? 0
            }
        }

        public let version: Int
        public let keys: [Key]

        public init(version: Int = Stored.currentVersion, keys: [Key]) {
            self.version = version
            self.keys = keys
        }

        public static let currentVersion = 1

        public func encoded() -> Data? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try? encoder.encode(self)
        }

        /// Nil for anything that is not a stored list of this version.
        public static func decode(_ data: Data) -> Stored? {
            guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
                  stored.version == currentVersion else { return nil }
            return stored
        }
    }

    public var stored: Stored {
        Stored(keys: entries.map { Stored.Key(id: $0.id, placed: $0.placedByHand, seq: $0.seq) })
    }

    /// The list for the keys held now, given what was stored before.
    ///
    /// A stored key that is no longer held leaves the list and loses its mark, as a deletion does. A key held and
    /// not stored is a new key: each goes through the rule of section 3, the oldest first (a key with no creation
    /// date counts as the oldest), which gives the same list as if the keys had been added one by one when they
    /// arrived. When nothing survives, the list is built as on the first run.
    ///
    /// Pure: it persists nothing; `CallKeyPriorityStore` does.
    public static func reconciled(stored: Stored?, candidates: [Candidate]) -> CallKeyPriority {
        let held = uniqueById(candidates)
        var byId: [String: Candidate] = [:]
        for candidate in held { byId[candidate.id] = candidate }

        var list = CallKeyPriority()
        if let stored {
            for key in stored.keys {
                guard let candidate = byId[key.id], !list.contains(key.id) else { continue }
                list.entries.append(Entry(id: key.id, group: candidate.group, placedByHand: key.placed,
                                          device: candidate.device, seq: key.seq))
            }
        }
        if list.entries.isEmpty {
            return firstRun(held)
        }
        let arrivals = held.filter { !list.contains($0.id) }.sorted(by: { (lhs: Candidate, rhs: Candidate) -> Bool in
            arrivesBefore(lhs, rhs)
        })
        for candidate in arrivals {
            // A key of a device the list already holds is the store of section 4a: it replaces that device's
            // highest-ranked key in place and the earlier keys wait for the finalize.
            if candidate.group == .other, let device = candidate.device,
               list.entries.contains(where: { $0.device == device }) {
                list.storeAsReplacement(id: candidate.id, device: device)
            } else {
                list.add(id: candidate.id, group: candidate.group, device: candidate.device)
            }
        }
        return list
    }

    /// Arrival order: oldest first, a key with no creation date counts as the oldest, ties by id.
    private static func arrivesBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (l?, r?) where l != r: return l < r
        case (nil, .some): return true
        case (.some, nil): return false
        default: return lhs.id < rhs.id
        }
    }

    private static func rank(_ group: Group) -> Int {
        switch group {
        case .hwOnly: return 0
        case .kms: return 1
        case .other: return 2
        }
    }

    private static func uniqueById(_ candidates: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        var result: [Candidate] = []
        for candidate in candidates where seen.insert(candidate.id).inserted {
            result.append(candidate)
        }
        return result
    }
}
