import XCTest
@testable import QAudionEngine

/// W-GRPDEL (2026-08-02) — the vault half of "delete a group chat".
///
/// `GroupSessionVault` had `save` and `load` and nothing else: snapshots were
/// written per `(groupId, groupEpoch, selfId)` and **never removed**, by
/// design (`AppState.applyRemovalRekey` documents relying on that: the
/// descending epoch probe in `GroupChatService.loadFromVault` walks over old
/// snapshots). That is fine while the user is in the group and wrong the
/// moment they delete it — the sender-key material for a group they left
/// would otherwise sit in the Keychain forever.
///
/// Two properties are fenced here, and the second is the one that matters:
///
///   1. Purging a group makes every epoch of that group's snapshot
///      unloadable, not just the newest one.
///   2. Purging a group touches **no other group** and no other identity.
///      Deleting one chat must never cost the user the ability to decrypt a
///      different group they are still in.
final class GroupSessionVaultPurgeTests: XCTestCase {

    private let selfId = "user-self"
    private let otherId = "user-other"

    private func gid(_ byte: UInt8) -> Data {
        return Data(repeating: byte, count: 16)
    }

    /// A snapshot the vault can round-trip. Built through the engine rather
    /// than by hand so the test stays honest if `GroupState` grows fields.
    private func makeState(groupIdBytes: Data, epoch: UInt32, selfId: String) throws -> GroupState {
        let session = GroupSession(vault: nil)
        let state = try session.create(
            groupIdBytes: groupIdBytes,
            groupEpoch: epoch,
            members: [selfId, "peer-1"],
            admins: [selfId],
            selfId: selfId,
            selfSeed: nil)
        return state
    }

    func testPurgeRemovesEveryEpochOfTheTargetGroup() throws {
        let vault = InMemoryGroupSessionVault()
        let target = gid(0xA1)
        for epoch in UInt32(1)...UInt32(3) {
            vault.save(try makeState(groupIdBytes: target, epoch: epoch, selfId: selfId))
        }
        XCTAssertNotNil(vault.load(groupIdBytes: target, groupEpoch: 1, selfId: selfId))
        XCTAssertNotNil(vault.load(groupIdBytes: target, groupEpoch: 3, selfId: selfId))

        vault.purge(groupIdBytes: target, selfId: selfId)

        for epoch in UInt32(1)...UInt32(3) {
            XCTAssertNil(
                vault.load(groupIdBytes: target, groupEpoch: epoch, selfId: selfId),
                "epoch \(epoch) survived the purge — the descending vault probe would resurrect it")
        }
    }

    /// THE regression guard. A purge that over-reaches is a far worse bug
    /// than the one it fixes: the user deletes one group and silently loses
    /// the ability to read another.
    func testPurgeLeavesEveryOtherGroupIntact() throws {
        let vault = InMemoryGroupSessionVault()
        let deleted = gid(0xA1)
        let kept = gid(0xB2)
        vault.save(try makeState(groupIdBytes: deleted, epoch: 1, selfId: selfId))
        vault.save(try makeState(groupIdBytes: kept, epoch: 1, selfId: selfId))
        vault.save(try makeState(groupIdBytes: kept, epoch: 2, selfId: selfId))

        vault.purge(groupIdBytes: deleted, selfId: selfId)

        XCTAssertNil(vault.load(groupIdBytes: deleted, groupEpoch: 1, selfId: selfId))
        XCTAssertNotNil(vault.load(groupIdBytes: kept, groupEpoch: 1, selfId: selfId))
        XCTAssertNotNil(vault.load(groupIdBytes: kept, groupEpoch: 2, selfId: selfId))
    }

    /// Vault items are keyed by identity as well as group. A purge run for
    /// one account must not reach into another account's snapshot of the
    /// same group (multi-account/reinstall leftovers do exist on these
    /// devices).
    func testPurgeIsScopedToTheIdentityThatRanIt() throws {
        let vault = InMemoryGroupSessionVault()
        let group = gid(0xC3)
        vault.save(try makeState(groupIdBytes: group, epoch: 1, selfId: selfId))
        vault.save(try makeState(groupIdBytes: group, epoch: 1, selfId: otherId))

        vault.purge(groupIdBytes: group, selfId: selfId)

        XCTAssertNil(vault.load(groupIdBytes: group, groupEpoch: 1, selfId: selfId))
        XCTAssertNotNil(vault.load(groupIdBytes: group, groupEpoch: 1, selfId: otherId))
    }

    /// Deleting a group you never had crypto state for is a normal case (a
    /// bootstrap that never completed, a group known only from a roster).
    /// It must be a silent no-op, not a crash.
    func testPurgingAnUnknownGroupIsANoOp() {
        let vault = InMemoryGroupSessionVault()
        vault.purge(groupIdBytes: gid(0xD4), selfId: selfId)
        XCTAssertNil(vault.load(groupIdBytes: gid(0xD4), groupEpoch: 1, selfId: selfId))
    }

    /// Re-running a delete (the user taps twice, or a retry lands) must not
    /// behave differently the second time.
    func testPurgeIsIdempotent() throws {
        let vault = InMemoryGroupSessionVault()
        let group = gid(0xE5)
        vault.save(try makeState(groupIdBytes: group, epoch: 1, selfId: selfId))
        vault.purge(groupIdBytes: group, selfId: selfId)
        vault.purge(groupIdBytes: group, selfId: selfId)
        XCTAssertNil(vault.load(groupIdBytes: group, groupEpoch: 1, selfId: selfId))
    }
}
