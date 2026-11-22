import Foundation
import CryptoKit

/// The answer of `MessageRatchet.boundPeerPrintsChecked(peerId:)`.
public enum BoundResult: Equatable, Sendable {
    /// Every live session is bound; the set is never empty.
    case known(Set<String>)
    /// No session, or a session without a believable binding: an honest "cannot tell". Safe to cache until the peer's bindings change.
    case unknown
    /// A row could not be read. Callers treat it as unknown and never cache it.
    case failed
}

/// Which peer key each 1:1 CHAT / CONTROL ratchet session was authenticated against, kept in the SAME vault as the session, so the
/// contact shield can tell whether a session still speaks to a key that was verified.
///
/// One record per slot (`<epoch>-rec`), written in ONE commit and holding, for the current and for the retained previous session of
/// that slot: the hash of the session's source material (the `-src` / `-prev-src` row written next to the session), the
/// safety-number fingerprint of the peer key, and two liveness numbers. A record is believed only if its tags equal the source hashes
/// found next to the sessions now; a missing record, or one that belongs to another session, makes the whole answer unknown. The write
/// order of every change is: delete the record, write the sessions, write the record.
///
/// Liveness of the previous session uses a persisted, strictly increasing counter and never the clock: `curFirstSeq` is taken from the
/// counter at the first successful decrypt of the current session (once per install, no write per message) and `prevLastSeq` whenever
/// the previous session decrypts. The previous session counts while `curFirstSeq == 0` or `prevLastSeq >= curFirstSeq`. It is never
/// deleted for this.
///
/// Nothing here holds key bytes (a fingerprint and hashes only) and the only line it writes is the closed-vocabulary
/// `SESSION-BIND write_failed slot=cur|prev|rec`, without ids. Every read error is "unknown", never "absent".
final class SessionBindingStore {

    // MARK: - Slots and rows

    /// CHAT, the reserved v5 CHAT row and CONTROL: every channel a peer key can be bound to.
    static let epochs: [String] = [
        MessageRatchet.v4RoutingEpoch, MessageRatchet.v5ChatRoutingEpoch, MessageRatchet.v5ControlRoutingEpoch,
    ]

    static func recId(_ epoch: String) -> String { epoch + "-rec" }
    static func srcId(_ epoch: String) -> String { MessageRatchet.sourceEpochId(epoch) }
    static func prevSrcId(_ epoch: String) -> String { epoch + "-prev-src" }
    static func prevId(_ epoch: String) -> String { MessageRatchet.previousEpochId(epoch) }

    private let vault: RatchetVault

    init(vault: RatchetVault) {
        self.vault = vault
    }

    // MARK: - Record

    /// One slot's record. An empty tag or print means "none" (a legacy or absent session).
    struct Record: Equatable {
        var counter: UInt64
        var curTag: Data
        var curPrint: String
        var prevTag: Data
        var prevPrint: String
        var curFirstSeq: UInt64
        var prevLastSeq: UInt64

        func encode() -> Data {
            var out = Data([1])
            Self.putU64(&out, counter)
            Self.putBlob(&out, curTag)
            Self.putBlob(&out, Data(curPrint.utf8))
            Self.putBlob(&out, prevTag)
            Self.putBlob(&out, Data(prevPrint.utf8))
            Self.putU64(&out, curFirstSeq)
            Self.putU64(&out, prevLastSeq)
            return out
        }

        static func decode(_ data: Data) -> Record? {
            let bytes = [UInt8](data)
            var at = 0
            func u8() -> UInt8? {
                guard at < bytes.count else { return nil }
                defer { at += 1 }
                return bytes[at]
            }
            func u64() -> UInt64? {
                guard at + 8 <= bytes.count else { return nil }
                var v: UInt64 = 0
                for i in 0..<8 { v = (v << 8) | UInt64(bytes[at + i]) }
                at += 8
                return v
            }
            func blob() -> Data? {
                guard at + 2 <= bytes.count else { return nil }
                let n = Int(bytes[at]) << 8 | Int(bytes[at + 1])
                at += 2
                guard at + n <= bytes.count else { return nil }
                defer { at += n }
                return Data(bytes[at..<(at + n)])
            }
            guard u8() == 1, let counter = u64(),
                  let curTag = blob(), let curPrintData = blob(), let curPrint = String(data: curPrintData, encoding: .utf8),
                  let prevTag = blob(), let prevPrintData = blob(), let prevPrint = String(data: prevPrintData, encoding: .utf8),
                  let curFirst = u64(), let prevLast = u64(), at == bytes.count else { return nil }
            return Record(counter: counter, curTag: curTag, curPrint: curPrint, prevTag: prevTag, prevPrint: prevPrint,
                          curFirstSeq: curFirst, prevLastSeq: prevLast)
        }

        private static func putU64(_ out: inout Data, _ v: UInt64) {
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((v >> UInt64(shift)) & 0xFF)) }
        }

        private static func putBlob(_ out: inout Data, _ b: Data) {
            let n = min(b.count, 0xFFFF)
            out.append(UInt8(n >> 8))
            out.append(UInt8(n & 0xFF))
            out.append(b.prefix(n))
        }
    }

    /// What a change started from: the slot's record as it was (nil if none or unreadable) and the source hash of the current session.
    struct Before {
        let record: Record?
        let curSrc: Data?
    }

    // MARK: - Changes (called under the ratchet's per-instance lock)

    /// First step of every change: read what is there, then DELETE the record, so a crash from here on reads as unknown.
    func begin(_ epoch: String, _ peerId: String) -> Before {
        let old = readRecord(epoch, peerId)
        let curSrc: Data? = (try? vault.loadV4Checked(epochId: Self.srcId(epoch), peerId: peerId)) ?? nil
        do {
            try vault.deleteV4Checked(epochId: Self.recId(epoch), peerId: peerId)
        } catch {
            logWriteFailed("rec")
            // The tags cannot be relied on to disown a stale record that is still there: the slot is unknown, in memory and on disk
            // (a tombstone over the record, or no record), until a record write to the same slot succeeds at an install or replace.
            markUnknownPersistently(epoch, peerId, base: old)
        }
        changed(peerId) // cached answers are void from here until the record is back
        return Before(record: old, curSrc: curSrc)
    }

    /// Writes an auxiliary row next to a session (`-src`, `-prev-src`). Never throws: a binding write must not fail an install. A
    /// failure leaves the slot without a believable binding (its record tag cannot match a missing row), which reads as unknown.
    func putAux(_ rowId: String, _ peerId: String, _ blob: Data) {
        do { try vault.saveV4(epochId: rowId, peerId: peerId, blob: blob) } catch { logWriteFailed("rec") }
    }

    func deleteAux(_ rowId: String, _ peerId: String) {
        do { try vault.deleteV4Checked(epochId: rowId, peerId: peerId) } catch { logWriteFailed("rec") }
    }

    /// Last step of an install over (or without) a current session that does NOT touch the previous one: the new session, hashed
    /// `curTag`, is bound to `print`; liveness restarts. A nil `print` leaves the session unbound (unknown).
    func commitInstall(_ epoch: String, _ peerId: String, before: Before, curTag: Data, print: String?) {
        let old = before.record
        write(epoch, peerId,
              Record(counter: old?.counter ?? 0, curTag: curTag, curPrint: print ?? "",
                     prevTag: old?.prevTag ?? Data(), prevPrint: old?.prevPrint ?? "",
                     curFirstSeq: 0, prevLastSeq: 0),
              slot: "rec", rearms: true)
    }

    /// Last step of a REPLACE: the old current session (hashed `before.curSrc`) is now the previous one and keeps its fingerprint when
    /// the old record is believable; when there was no current session the previous one is left exactly as it was.
    func commitReplace(_ epoch: String, _ peerId: String, before: Before, hadPrevious: Bool, curTag: Data, print: String?) {
        let old = before.record
        let prevTag: Data
        let prevPrint: String
        if hadPrevious {
            let oldTag = before.curSrc ?? Data()
            prevTag = oldTag
            if let old, !oldTag.isEmpty, old.curTag == oldTag { prevPrint = old.curPrint } else { prevPrint = "" }
        } else {
            prevTag = old?.prevTag ?? Data()
            prevPrint = old?.prevPrint ?? ""
        }
        write(epoch, peerId,
              Record(counter: old?.counter ?? 0, curTag: curTag, curPrint: print ?? "",
                     prevTag: prevTag, prevPrint: prevPrint, curFirstSeq: 0, prevLastSeq: 0),
              slot: "rec", rearms: true)
    }

    /// The current session was dropped: its binding goes, the previous one keeps its own and its liveness.
    func commitDrop(_ epoch: String, _ peerId: String, before: Before) {
        guard let old = before.record else {
            // Nothing believable to carry over: whatever row remains is not trusted.
            markUnknownPersistently(epoch, peerId, base: nil)
            return
        }
        // A drop is not an install or a replace: it never clears an unknown mark.
        let ok = write(epoch, peerId,
                       Record(counter: old.counter, curTag: Data(), curPrint: "", prevTag: old.prevTag, prevPrint: old.prevPrint,
                              curFirstSeq: 0, prevLastSeq: old.prevLastSeq),
                       slot: "rec", rearms: false)
        if !ok { markUnknownPersistently(epoch, peerId, base: old) }
    }

    /// The delete of the current session did not happen: the session is still there, with no record. The slot is unknown.
    func dropFailed(_ epoch: String, _ peerId: String, before: Before) {
        logWriteFailed("cur")
        markUnknownPersistently(epoch, peerId, base: before.record)
    }

    /// A repeat install from the same material: bind the session now if its slot has no believable record for it.
    func bindIfUnbound(_ epoch: String, _ peerId: String, curTag: Data, print: String?) {
        guard let print, !print.isEmpty else { return }
        let old = readRecord(epoch, peerId)
        if let old, old.curTag == curTag, !old.curPrint.isEmpty { return }
        // The previous session (if any) was installed before this record existed: its binding is unknown, which is what an empty
        // `prevPrint` means. Its liveness numbers are kept as they were.
        write(epoch, peerId,
              Record(counter: old?.counter ?? 0, curTag: curTag, curPrint: print,
                     prevTag: old?.prevTag ?? Data(), prevPrint: old?.prevPrint ?? "",
                     curFirstSeq: old?.curFirstSeq ?? 0, prevLastSeq: old?.prevLastSeq ?? 0),
              slot: "rec", rearms: false)
    }

    // MARK: - Liveness notes (never throw, never fail a decrypt)

    /// The current session of `epoch` opened a frame: the first one of an install is recorded, the rest cost a memo lookup and no I/O.
    func noteCurrentDecrypt(_ epoch: String, _ peerId: String) {
        if State.shared.isNoted(epoch: epoch, peer: peerId) { return }
        guard let old = readRecord(epoch, peerId) else {
            // No believable record: nothing to note for this session. Any record write voids this memo.
            State.shared.setNoted(epoch: epoch, peer: peerId)
            return
        }
        if old.curFirstSeq != 0 {
            State.shared.setNoted(epoch: epoch, peer: peerId)
            return
        }
        let seq = old.counter &+ 1
        var next = old
        next.counter = seq
        next.curFirstSeq = seq
        // A failed write is the safe direction: the first decrypt stays unrecorded, so the previous session keeps counting as live.
        // It is retried on the next frame.
        if write(epoch, peerId, next, slot: "cur", rearms: false) {
            State.shared.setNoted(epoch: epoch, peer: peerId) // after write(): its change voided the memo of this peer
        }
    }

    /// The retained previous session of `epoch` opened a frame.
    func notePrevDecrypt(_ epoch: String, _ peerId: String) {
        let old: Record
        do {
            guard let found = try readRecordChecked(epoch, peerId) else { return }
            old = found
        } catch {
            // The previous session just decrypted but the record that says whether it is live could not be read: it might look dead.
            logWriteFailed("prev")
            markUnknownPersistently(epoch, peerId, base: nil)
            return
        }
        let seq = old.counter &+ 1
        var next = old
        next.counter = seq
        next.prevLastSeq = seq
        if !write(epoch, peerId, next, slot: "prev", rearms: false) {
            // It could not be recorded either: the slot is unknown, in memory and on disk, until a record write to the same slot
            // succeeds at an install or replace.
            markUnknownPersistently(epoch, peerId, base: old)
        }
    }

    // MARK: - Answer

    /// The fingerprints the peer's live sessions are bound to. Unknown when ANY existing slot has no record, a record whose tag is not
    /// the session's source hash, a live session without a fingerprint, or a slot marked unknown in memory; an empty set (no session at
    /// all) is unknown too: the filter needs a non-empty, fully known binding. `.failed` when a row cannot be read.
    func check(_ peerId: String) -> BoundResult {
        if Self.epochs.contains(where: { State.shared.isUnknown(epoch: $0, peer: peerId) }) { return .unknown }
        do {
            if let prints = try compute(peerId) { return .known(prints) }
            return .unknown
        } catch {
            return .failed
        }
    }

    private func compute(_ peerId: String) throws -> Set<String>? {
        var out = Set<String>()
        for e in Self.epochs {
            let curExists = try vault.hasV4Checked(epochId: e, peerId: peerId)
            let prevExists = try vault.hasV4Checked(epochId: Self.prevId(e), peerId: peerId)
            if !curExists && !prevExists { continue }
            guard let recData = try readExisting(Self.recId(e), peerId), let r = Record.decode(recData) else { return nil }
            if curExists {
                guard let tag = try readExisting(Self.srcId(e), peerId) else { return nil }
                if r.curPrint.isEmpty || r.curTag != tag { return nil }
                out.insert(r.curPrint)
            }
            if prevExists && (r.curFirstSeq == 0 || r.prevLastSeq >= r.curFirstSeq) {
                guard let tag = try readExisting(Self.prevSrcId(e), peerId) else { return nil }
                if r.prevPrint.isEmpty || r.prevTag != tag { return nil }
                out.insert(r.prevPrint)
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Rows

    /// Writes the slot's record in one commit. NEVER throws: a binding or liveness write must not fail a decrypt or a session
    /// install. Returns whether it was stored. `rearms`: a success clears the in-memory "unknown" mark of THIS slot.
    @discardableResult
    private func write(_ epoch: String, _ peerId: String, _ r: Record, slot: String, rearms: Bool) -> Bool {
        do {
            try vault.saveV4(epochId: Self.recId(epoch), peerId: peerId, blob: r.encode())
            if rearms { State.shared.clearUnknown(epoch: epoch, peer: peerId) }
            changed(peerId)
            return true
        } catch {
            logWriteFailed(slot)
            changed(peerId)
            return false
        }
    }

    /// The slot is unknown from now on, also after a restart: a tombstone (a record with no print, which reads as unknown) is written
    /// over the record; when that fails too the record is deleted. Only a record write to the same slot at an install or replace
    /// clears the in-memory mark, and that write replaces the tombstone.
    private func markUnknownPersistently(_ epoch: String, _ peerId: String, base: Record?) {
        State.shared.markUnknown(epoch: epoch, peer: peerId)
        let tomb = Record(counter: base?.counter ?? 0, curTag: Data(), curPrint: "", prevTag: Data(), prevPrint: "",
                          curFirstSeq: 0, prevLastSeq: 0)
        do {
            try vault.saveV4(epochId: Self.recId(epoch), peerId: peerId, blob: tomb.encode())
        } catch {
            logWriteFailed("rec")
            do { try vault.deleteV4Checked(epochId: Self.recId(epoch), peerId: peerId) } catch { logWriteFailed("rec") }
        }
        changed(peerId)
    }

    /// The record, nil only when none exists; a read error or a record that cannot be decoded throws.
    private func readRecordChecked(_ epoch: String, _ peerId: String) throws -> Record? {
        guard let data = try vault.loadV4Checked(epochId: Self.recId(epoch), peerId: peerId) else { return nil }
        guard let record = Record.decode(data) else { throw VaultError.readFailed(0) }
        return record
    }

    /// The record as written, or nil when absent or unreadable (both are "not believable").
    private func readRecord(_ epoch: String, _ peerId: String) -> Record? {
        guard let data = (try? vault.loadV4Checked(epochId: Self.recId(epoch), peerId: peerId)) ?? nil else { return nil }
        return Record.decode(data)
    }

    /// A row that EXISTS must be readable: an existing row that cannot be read is an error (unknown), not an absent one.
    private func readExisting(_ rowId: String, _ peerId: String) throws -> Data? {
        guard try vault.hasV4Checked(epochId: rowId, peerId: peerId) else { return nil }
        guard let data = try vault.loadV4Checked(epochId: rowId, peerId: peerId) else { throw VaultError.readFailed(0) }
        return data
    }

    /// One closed-vocabulary line per failure, no ids; it goes through the engine's existing log sink for call-tag lines.
    private func logWriteFailed(_ slot: String) {
        CapsBindLog.line("SESSION-BIND write_failed slot=\(slot)")
    }

    private func changed(_ peerId: String) {
        State.shared.bump(peer: peerId)
        NotificationCenter.default.post(name: MessageRatchet.bindingDidChangeNotification, object: nil, userInfo: ["peerId": peerId])
    }

    /// The SHA-256 of a session blob: the tag a record carries for it.
    static func tag(of blob: Data) -> Data { Data(SHA256.hash(data: blob)) }

    // MARK: - Process-wide state

    /// Shared by every engine instance (they come and go; the vault is shared): the per-peer change counter, the slots that are
    /// unknown for now, and the memo of "already noted" first decrypts.
    final class State: @unchecked Sendable {
        static let shared = State()
        private let lock = NSLock()
        private var versions: [String: UInt64] = [:]
        private var unknown: Set<String> = []
        private var generationValue: UInt64 = 0
        private var noted: [String: Set<String>] = [:] // peer -> epochs whose first decrypt (or lack of record) is already handled

        private func slot(_ epoch: String, _ peer: String) -> String { epoch + "|" + peer }

        func bump(peer: String) {
            lock.lock()
            versions[peer, default: 0] &+= 1
            noted.removeValue(forKey: peer) // a change of this peer's sessions voids "already noted"
            lock.unlock()
        }

        func version(of peer: String) -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            return versions[peer] ?? 0
        }

        func markUnknown(epoch: String, peer: String) {
            lock.lock(); unknown.insert(slot(epoch, peer)); lock.unlock()
        }

        func clearUnknown(epoch: String, peer: String) {
            lock.lock(); unknown.remove(slot(epoch, peer)); lock.unlock()
        }

        func isUnknown(epoch: String, peer: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return unknown.contains(slot(epoch, peer))
        }

        func isNoted(epoch: String, peer: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return noted[peer]?.contains(epoch) ?? false
        }

        func setNoted(epoch: String, peer: String) {
            lock.lock(); noted[peer, default: []].insert(epoch); lock.unlock()
        }

        /// The vault was wiped (logout, remote wipe): nothing remembered about any peer is valid. Every known peer's version moves (a
        /// cached answer must not match again) and those peers are returned so the caller can announce each.
        func resetAll() -> [String] {
            lock.lock()
            let peers = Array(versions.keys)
            for p in peers { versions[p, default: 0] &+= 1 }
            unknown.removeAll()
            noted.removeAll()
            generationValue &+= 1
            lock.unlock()
            return peers
        }

        /// Moves when the whole vault was wiped.
        func generation() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            return generationValue
        }
    }
}
