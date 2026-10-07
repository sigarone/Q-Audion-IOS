import XCTest
@testable import QAudionEngine

/// W-SIGNERBOOT — the sovereign identity is read-or-created as ONE serialised step.
///
/// Pure logic only: the CI simulator's test bundle has no Keychain entitlement
/// (`KeychainAvailability`), so the Keychain sits behind two closures here, exactly as in
/// production (`SovereignIdentityManager.ensureIdentity`).
final class SovereignIdentityBootstrapTests: XCTestCase {

    /// An in-memory stand-in for the one Keychain slot. Thread-safe, because the production
    /// callers are (the real Keychain is).
    private final class FakeSlot {
        private let lock = NSLock()
        private var stored = false
        private(set) var creates = 0
        private(set) var reads = 0

        func read() -> Bool { lock.lock(); defer { lock.unlock() }; reads += 1; return stored }
        func create() { lock.lock(); defer { lock.unlock() }; creates += 1; stored = true }
        func preload() { lock.lock(); stored = true; lock.unlock() }
    }

    func testPresentIdentityIsLeftAlone() {
        let slot = FakeSlot()
        slot.preload()
        let outcome = SovereignIdentityBootstrap.ensure(read: { slot.read() }, create: { slot.create() })
        XCTAssertEqual(outcome, .existing)
        XCTAssertEqual(slot.creates, 0, "an identity that is stored must never be regenerated")
    }

    func testAbsentIdentityIsCreatedOnce() {
        let slot = FakeSlot()
        let first = SovereignIdentityBootstrap.ensure(read: { slot.read() }, create: { slot.create() })
        let second = SovereignIdentityBootstrap.ensure(read: { slot.read() }, create: { slot.create() })
        XCTAssertEqual(first, .created)
        XCTAssertEqual(second, .existing)
        XCTAssertEqual(slot.creates, 1)
    }

    /// The cold-start case this exists for: a locked Keychain is "may exist", never "absent".
    func testLockedKeychainCreatesNothing() {
        var created = false
        let outcome = SovereignIdentityBootstrap.ensure(
            read: { throw KeyVaultError.deviceLocked },
            create: { created = true })
        XCTAssertEqual(outcome, .locked)
        XCTAssertFalse(created, "a locked read must never be answered by minting a new identity")
    }

    func testOtherReadFailureCreatesNothing() {
        var created = false
        let outcome = SovereignIdentityBootstrap.ensure(
            read: { throw KeyVaultError.loadFailed(-50) },
            create: { created = true })
        XCTAssertEqual(outcome, .failed)
        XCTAssertFalse(created, "a failing read must never be answered by writing over a key that may still be there")
    }

    func testFailedStoreIsReportedNotSwallowed() {
        let outcome = SovereignIdentityBootstrap.ensure(
            read: { false },
            create: { throw KeyVaultError.storeFailed(-34018) })
        XCTAssertEqual(outcome, .failed)
    }

    /// The launch bootstrap, the handshake and a key exchange can all arrive together; the
    /// check and the creation are one critical section, so exactly one identity is minted.
    func testRacingCallersMintExactlyOneIdentity() {
        let slot = FakeSlot()
        let outcomes = OutcomeBox()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            let outcome = SovereignIdentityBootstrap.ensure(read: { slot.read() }, create: { slot.create() })
            outcomes.add(outcome)
        }
        XCTAssertEqual(slot.creates, 1, "two racing callers must never create two identities")
        XCTAssertEqual(outcomes.count(.created), 1)
        XCTAssertEqual(outcomes.count(.existing), 63)
    }

    func testLogCodesAreDistinctNumbers() {
        let codes = [SovereignIdentityBootstrap.Outcome.existing, .created, .locked, .failed]
            .map(SovereignIdentityBootstrap.logCode)
        XCTAssertEqual(Set(codes).count, 4)
        XCTAssertEqual(codes, [0, 1, 2, 3])
    }

    private final class OutcomeBox {
        private let lock = NSLock()
        private var all: [SovereignIdentityBootstrap.Outcome] = []
        func add(_ o: SovereignIdentityBootstrap.Outcome) { lock.lock(); all.append(o); lock.unlock() }
        func count(_ o: SovereignIdentityBootstrap.Outcome) -> Int {
            lock.lock(); defer { lock.unlock() }
            return all.filter { $0 == o }.count
        }
    }
}
