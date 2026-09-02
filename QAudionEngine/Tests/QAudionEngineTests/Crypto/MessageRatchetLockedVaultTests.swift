import XCTest
@testable import QAudionEngine

/// W-KCAFTERUNLOCK (2026-09-01) — `MessageRatchet.ensureSession` must not
/// derive-and-persist a fresh chain over a snapshot it merely could not
/// decrypt yet.
///
/// Before this change `ensureSession` read through `RatchetVault.load`, which
/// the Keychain vault answered with `nil` for BOTH "nothing stored" and
/// "-25308, device locked"; the bootstrap branch then ran with whatever
/// `pskRoot` it was handed. Now it reads through `loadChecked` and a locked
/// vault throws `VaultError.deviceLocked`, so nothing is derived and nothing
/// is written. Pure — a hand-rolled vault stands in for the locked Keychain,
/// so this runs on the CI simulator.
final class MessageRatchetLockedVaultTests: XCTestCase {

    /// The shape `KeychainRatchetVault` reports for -25308: the plain `load`
    /// still answers nil (legacy contract), `loadChecked` throws.
    private final class LockedVault: RatchetVault, @unchecked Sendable {
        private let lock = NSLock()
        private var saves = 0
        var saveCount: Int {
            lock.lock(); defer { lock.unlock() }
            return saves
        }
        func load(epochId: String, peerId: String) -> RatchetSnapshot? { nil }
        func loadChecked(epochId: String, peerId: String) throws -> RatchetSnapshot? {
            throw VaultError.deviceLocked
        }
        func save(epochId: String, peerId: String, snapshot: RatchetSnapshot) throws {
            lock.lock(); saves += 1; lock.unlock()
        }
        func delete(epochId: String, peerId: String) {}
    }

    private let psk = Data(repeating: 0x42, count: 32)

    // THE BUG: a locked vault must surface as transient, with NO fresh chain persisted.
    func testEnsureSessionThrowsDeviceLockedAndPersistsNothing() {
        let vault = LockedVault()
        let ratchet = MessageRatchet(vault: vault)
        XCTAssertThrowsError(
            try ratchet.ensureSession(epochId: "epoch-1", selfId: "alice", peerId: "bob", pskRoot: psk)
        ) { error in
            XCTAssertEqual(error as? VaultError, VaultError.deviceLocked)
        }
        XCTAssertEqual(vault.saveCount, 0, "a locked vault must never receive a freshly derived chain")
    }

    /// The protocol default forwards `loadChecked` to `load`, so a vault that
    /// cannot be locked (in-memory, test doubles) keeps bootstrapping on nil
    /// exactly as before — the happy path is untouched.
    func testDefaultLoadCheckedForwardsToLoadAndBootstrapsAsBefore() throws {
        let vault = InMemoryRatchetVault()
        let ratchet = MessageRatchet(vault: vault)
        XCTAssertNil(try vault.loadChecked(epochId: "epoch-1", peerId: "bob"))
        _ = try ratchet.ensureSession(epochId: "epoch-1", selfId: "alice", peerId: "bob", pskRoot: psk)
        XCTAssertNotNil(try vault.loadChecked(epochId: "epoch-1", peerId: "bob"))
        XCTAssertEqual(vault.count, 1)
    }

    /// `deviceLocked` and `persistFailed` are distinct outcomes: a caller may
    /// retry the former after unlock and must treat the latter as fatal.
    func testDeviceLockedIsNotAPersistFailure() {
        XCTAssertNotEqual(VaultError.deviceLocked, VaultError.persistFailed(-25308))
    }
}
