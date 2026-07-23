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
}
