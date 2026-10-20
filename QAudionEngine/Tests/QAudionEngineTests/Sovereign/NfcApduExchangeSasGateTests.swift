import XCTest
@testable import QAudionEngine

/// W-NFCSAS — pins `NfcApduExchange.NfcSasConfirmGate`, the post-derivation
/// confirm barrier `runPhase14cExchange` awaits between deriving the raw PSK
/// and ever calling `onPskDerived` (the only point that persists anything —
/// see `NfcExchangeView.persistPsk`, which writes to `SovereignKeyVault`).
///
/// This is the closest thing to an end-to-end proof this ship can offer that
/// the real ceremony "requires passing through SAS-confirm before success":
/// `NfcApduExchange`'s actual NFC I/O cannot run in CI/simulator (CoreNFC
/// needs real hardware + a real tag — the same constraint
/// `NfcCollaborativePskKatTests` already documents for the PSK derivation
/// itself), so the gate is extracted as a plain, hardware-free async
/// primitive and tested in isolation. Reading `runPhase14cExchange`'s actual
/// source confirms the sequencing: `state = .sasConfirm(...)` is set, then
/// `await gate.awaitConfirmation()` is awaited, and `onPskDerived` is called
/// ONLY after that returns `true` -- there is no path from "PSK derived" to
/// "onPskDerived called" that skips the gate.
final class NfcApduExchangeSasGateTests: XCTestCase {

    func test_confirm_resolvesAwaitConfirmationToTrue() async {
        let gate = NfcApduExchange.NfcSasConfirmGate()
        Task {
            // Give awaitConfirmation() a moment to start suspending before
            // resolving it, so this exercises the real suspend/resume path
            // rather than a same-thread race.
            try? await Task.sleep(nanoseconds: 1_000_000)
            gate.confirm()
        }
        let result = await gate.awaitConfirmation()
        XCTAssertTrue(result, "confirm() must resolve awaitConfirmation() to true")
    }

    func test_reject_resolvesAwaitConfirmationToFalse() async {
        let gate = NfcApduExchange.NfcSasConfirmGate()
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000)
            gate.reject()
        }
        let result = await gate.awaitConfirmation()
        XCTAssertFalse(result, "reject() must resolve awaitConfirmation() to false, never true")
    }

    /// A second confirm()/reject() after the continuation already resumed
    /// must be a safe no-op (the continuation reference is cleared after
    /// the first resume) -- this is what makes `confirmSas()`/`rejectSas()`
    /// safe to call from the UI even if the user double-taps a button.
    func test_secondCallAfterResolution_isNoOp() async {
        let gate = NfcApduExchange.NfcSasConfirmGate()
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000)
            gate.confirm()
            gate.confirm()  // double-tap guard
            gate.reject()   // even a contradicting second call must not crash
        }
        let result = await gate.awaitConfirmation()
        XCTAssertTrue(result, "the FIRST resolution wins; later calls are no-ops")
    }

    // MARK: - Pairing the same phone again (docs/security/CALL_KEY_PRIORITY.md section 4a)

    /// Stands in for `SovereignKeyVault`, which needs the Keychain: name -> key material, written the way the vault
    /// writes a name that is already there (the entry is replaced).
    private final class FakeVault {
        private(set) var keys: [String: Data]
        private(set) var writes = 0

        init(keys: [String: Data]) {
            self.keys = keys
        }

        func store(name: String, key: Data) {
            keys[name] = key
            writes += 1
        }
    }

    private static let phoneName = "nfc-0707070707070707"
    private static let phoneIdentity = Data(repeating: 0x07, count: 32)
    private static let earlierKey = Data(repeating: 0x01, count: 32)
    private static let newKey = Data(repeating: 0x02, count: 32)

    /// Runs the last step of a tap: the user decides after a moment (`confirm` or reject), and the handler stores
    /// the key the way `NfcExchangeView` does. Returns the error the step threw, if any.
    private func handOver(confirm: Bool, to vault: FakeVault) async -> Error? {
        let gate = NfcApduExchange.NfcSasConfirmGate()
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000)
            if confirm {
                gate.confirm()
            } else {
                gate.reject()
            }
        }
        do {
            try await NfcApduExchange.handOverIfConfirmed(
                gate: gate, psk: Self.newKey, peerIdentityPub: Self.phoneIdentity,
                to: { (psk: Data, peerIdentity: Data) in
                    XCTAssertEqual(peerIdentity, Self.phoneIdentity)
                    vault.store(name: Self.phoneName, key: psk)
                })
            return nil
        } catch {
            return error
        }
    }

    private func isSasRejected(_ error: Error?) -> Bool {
        guard let exchangeError = error as? NfcApduExchange.ExchangeError, case .sasRejected = exchangeError else {
            return false
        }
        return true
    }

    func test_confirmedTap_replacesTheEarlierKeyOfTheSamePhoneUnderTheSameName() async {
        let vault = FakeVault(keys: [Self.phoneName: Self.earlierKey])
        let error = await handOver(confirm: true, to: vault)
        XCTAssertNil(error)
        XCTAssertEqual(vault.keys, [Self.phoneName: Self.newKey])
        XCTAssertEqual(vault.writes, 1)
    }

    /// `cancel()` (the user leaves the screen, or the session ends) rejects the same gate, so a cancelled tap takes
    /// this path too.
    func test_unconfirmedTap_leavesTheEarlierKeyUntouched() async {
        let vault = FakeVault(keys: [Self.phoneName: Self.earlierKey])
        let error = await handOver(confirm: false, to: vault)
        XCTAssertTrue(isSasRejected(error), "a rejected SAS must end the tap with sasRejected, got \(String(describing: error))")
        XCTAssertEqual(vault.keys, [Self.phoneName: Self.earlierKey])
        XCTAssertEqual(vault.writes, 0, "nothing may be written for a tap that was not confirmed")
    }

    func test_confirmedTap_withoutAHandler_isNotAnError() async throws {
        let gate = NfcApduExchange.NfcSasConfirmGate()
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000)
            gate.confirm()
        }
        try await NfcApduExchange.handOverIfConfirmed(
            gate: gate, psk: Self.newKey, peerIdentityPub: Self.phoneIdentity, to: nil)
    }
}
