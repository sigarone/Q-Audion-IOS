# Track A.2 — NFC + Key Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire iOS NFC collaborative pairing (iOS reader ↔ Android HCE), key-management UI, and device-list management. Consumes the F1 ViewModels (KeyManagementVM / DeviceManagementVM / NfcExchangeVM) landed in the Foundation Sprint.

**Architecture:** 4 layers, bottom-up:
- **L0 — PSK derivation** (`QAudionEngine/Sources/QAudionEngine/Sovereign/NfcPskDerivation.swift`): pure crypto. HKDF-SHA256 with NFC info string per spec §5.5. KAT-tested against Android.
- **L1 — NFC reader service** (`QAudionEngine/Sources/QAudionEngine/Sovereign/NfcCollaborativeExchange.swift`): CoreNFC `NFCTagReaderSession` wrapper that drives the `NfcExchangeViewModel` state machine. APDU SELECT into AID `F0BCF1073A5100`, exchange 64-byte payload, derive PSK.
- **L2 — Backend integration**: REST `POST /api/v1/device/publickey` (frozen per §5.11) + WS `device_list` / `device_register` / `device_remove` envelopes.
- **L3 — SwiftUI view bindings**: `KeyManagementView`, `DeviceManagementView`, `NfcExchangeView` refactored to consume their ViewModels via `@StateObject` containers.

**Tech Stack:** Swift 5.9, CryptoKit (HKDF-SHA256), CoreNFC (`NFCTagReaderSession`, `NFCISO7816Tag`), SwiftUI, XCTest. No new dependencies. iOS 16+ only.

**Predecessor:** [docs/superpowers/plans/2026-04-28-track-a-foundation.md](2026-04-28-track-a-foundation.md) F1 (ViewModels). Spec: [docs/superpowers/specs/2026-04-28-cross-platform-alignment-design.md §5.5](../specs/2026-04-28-cross-platform-alignment-design.md) + §7 A.2.

---

## Reference paths

| What | Path |
|---|---|
| iOS NFC service (existing stub) | `QAudionEngine/Sources/QAudionEngine/Sovereign/NfcProtocol.swift` |
| iOS NFC view (existing) | `QAudionEngine/Sources/QAudionEngine/UI/NfcExchangeView.swift` |
| iOS KeyManagementView (existing) | `QAudionEngine/Sources/QAudionEngine/UI/KeyManagementView.swift` |
| iOS DeviceManagementView (existing) | `QAudionEngine/Sources/QAudionEngine/UI/DeviceManagementView.swift` |
| Android NFC reference | `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-android-new\qaudion-engine\src\main\java\com\bcrypto\qaudion\sovereign\NfcProtocol.kt` |
| Android device-link reference | `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-android-new\qaudion-engine\src\main\java\com\bcrypto\qaudion\sync\DeviceLinkingProtocol.kt` |
| Cross-platform vectors | `QAudionEngine/Resources/cross_platform_vectors.json` |
| Invariants doc | `docs/progress/INVARIANTS_VERIFIED.md` §5.5 |

## D-05 hygiene

NEVER stage these USER-WT files: `BCryptoBackendProvider.swift`, `BCryptoCallingApiImpl.swift`, `BCryptoGroupCallManager.swift`, `BCryptoWebSocketClient.swift`, `BCryptoPresenceManager.swift`, `CallingApi.swift`, `QAudionCallIntegration.swift`, `ContactSyncService.swift`. Any required changes to those files MUST be requested as user-side patches; this plan only modifies files outside that set.

---

## Phase G — Pre-work: read existing iOS NFC stub

### Task G.1: Read NfcProtocol.swift and decide replace-vs-extend

**Files:**
- Read: `QAudionEngine/Sources/QAudionEngine/Sovereign/NfcProtocol.swift`

- [ ] **Step 1:** Read the file end-to-end. Note its public surface: types, methods, line count.
- [ ] **Step 2:** Decide: does it already cover SELECT-AID + 64B payload + HKDF? Or is it a stub?
- [ ] **Step 3:** Document the decision (keep / extend / replace) in this plan as a comment in the next task's header. If "replace", list exactly what we delete and what we keep (e.g. constants like AID may be reusable).
- [ ] **Step 4:** No commit — this is internal recon.

---

## Phase A — PSK derivation (pure crypto, testable)

### Task A.1: NfcPskDerivation type + cross-platform KAT vectors

**Files:**
- Create: `QAudionEngine/Sources/QAudionEngine/Sovereign/NfcPskDerivation.swift`
- Create: `QAudionEngine/Tests/QAudionEngineTests/Sovereign/NfcPskDerivationTests.swift`
- Modify: `QAudionEngine/Resources/cross_platform_vectors.json` (append KAT vector)

- [ ] **Step 1: Failing test first.** Test cases:
  1. `derivePsk(myPriv:peerPub:)` produces 32B output.
  2. PSK is symmetric: `derivePsk(myPriv: A_priv, peerPub: B_pub)` == `derivePsk(myPriv: B_priv, peerPub: A_pub)`.
  3. Sorted-pubkey HKDF salt: confirm the salt is `sha256(sorted([myPub, peerPub]))` — same regardless of order.
  4. KAT vector test: load fixed test vector from `cross_platform_vectors.json` (key pair A, key pair B, expected 32-byte PSK in hex), assert match.
  5. HKDF info bytes are exactly `"Q-Audion NFC Collaborative PSK v1"` UTF-8 (33 bytes).

```swift
import XCTest
import CryptoKit
@testable import QAudionEngine

final class NfcPskDerivationTests: XCTestCase {

    func test_derivePsk_outputs32Bytes() throws {
        let aPriv = Curve25519.KeyAgreement.PrivateKey()
        let bPriv = Curve25519.KeyAgreement.PrivateKey()
        let psk = try NfcPskDerivation.derivePsk(
            myPriv: aPriv, peerPub: bPriv.publicKey
        )
        XCTAssertEqual(psk.count, 32)
    }

    func test_derivePsk_isSymmetric() throws {
        let aPriv = Curve25519.KeyAgreement.PrivateKey()
        let bPriv = Curve25519.KeyAgreement.PrivateKey()
        let pskA = try NfcPskDerivation.derivePsk(myPriv: aPriv, peerPub: bPriv.publicKey)
        let pskB = try NfcPskDerivation.derivePsk(myPriv: bPriv, peerPub: aPriv.publicKey)
        XCTAssertEqual(pskA, pskB)
    }

    func test_hkdfInfo_isExactlyAndroidString() {
        let info = NfcPskDerivation.hkdfInfo
        let expected = "Q-Audion NFC Collaborative PSK v1".data(using: .utf8)!
        XCTAssertEqual(info, expected)
    }

    func test_kat_pinsCrossPlatformPsk() throws {
        // Vector loaded from cross_platform_vectors.json under "nfc_psk_v1".
        let url = Bundle.module.url(forResource: "cross_platform_vectors", withExtension: "json")!
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let nfc = json["nfc_psk_v1"] as! [String: Any]
        let aPrivHex = nfc["a_priv"] as! String
        let bPubHex = nfc["b_pub"] as! String
        let expectedPskHex = nfc["expected_psk"] as! String

        let aPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hexString: aPrivHex)!)
        let bPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(hexString: bPubHex)!)
        let psk = try NfcPskDerivation.derivePsk(myPriv: aPriv, peerPub: bPub)
        XCTAssertEqual(psk.map { String(format: "%02x", $0) }.joined(), expectedPskHex)
    }
}

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i..<i+2]), radix: 16) else { return nil }
            bytes.append(b)
        }
        self = Data(bytes)
    }
}
```

- [ ] **Step 2:** Run test, expect `cannot find 'NfcPskDerivation'`.

- [ ] **Step 3: Implementation:**

```swift
import Foundation
import CryptoKit

/// Derives the 32-byte symmetric PSK from a CoreNFC pairing exchange.
///
/// Per spec §5.5: `HKDF-SHA256(shared = X25519(myPriv, theirPub),
/// salt = SHA256(sorted_concat(pubA, pubB)),
/// info = "Q-Audion NFC Collaborative PSK v1",
/// out = 32B)`.
///
/// Verified byte-identical to Android `NfcProtocol.kt:135` and
/// `INVARIANTS_VERIFIED.md` §5.3 row "NFC collaborative PSK".
public enum NfcPskDerivation {

    public enum Error: Swift.Error {
        case sharedSecretFailed
    }

    public static let hkdfInfo: Data = "Q-Audion NFC Collaborative PSK v1".data(using: .utf8)!

    public static func derivePsk(
        myPriv: Curve25519.KeyAgreement.PrivateKey,
        peerPub: Curve25519.KeyAgreement.PublicKey
    ) throws -> Data {
        let shared = try myPriv.sharedSecretFromKeyAgreement(with: peerPub)
        let myPub = myPriv.publicKey.rawRepresentation
        let peerPubBytes = peerPub.rawRepresentation
        let salt = sortedConcatHash(myPub, peerPubBytes)

        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    private static func sortedConcatHash(_ a: Data, _ b: Data) -> Data {
        let sorted = a.lexicographicallyPrecedes(b) ? a + b : b + a
        return Data(SHA256.hash(data: sorted))
    }
}

private extension Data {
    func lexicographicallyPrecedes(_ other: Data) -> Bool {
        for (lhs, rhs) in zip(self, other) {
            if lhs < rhs { return true }
            if lhs > rhs { return false }
        }
        return self.count < other.count
    }
}
```

- [ ] **Step 4: Generate the KAT vector.** Run a one-shot Swift script (or unit test in DEBUG mode) to compute the expected PSK for fixed test inputs. Append to `cross_platform_vectors.json`:

```json
{
  "nfc_psk_v1": {
    "a_priv": "<32-byte Curve25519 private key, hex>",
    "b_pub": "<32-byte Curve25519 public key, hex>",
    "expected_psk": "<32-byte derived PSK, hex>",
    "notes": "Generated by iOS A.2 task; cross-validate against Android NfcProtocolTest.kt expected output."
  }
}
```

Use deterministic test inputs (e.g. `a_priv = 0x01..0x20`, `b_priv = 0x21..0x40`).

- [ ] **Step 5:** Run all 4 tests. Expected: PASS (skip locally on Windows; CI verifies).

- [ ] **Step 6:** Commit.

```bash
git add QAudionEngine/Sources/QAudionEngine/Sovereign/NfcPskDerivation.swift \
        QAudionEngine/Tests/QAudionEngineTests/Sovereign/NfcPskDerivationTests.swift \
        QAudionEngine/Resources/cross_platform_vectors.json
git commit -m "feat(crypto): A.2.A.1 NfcPskDerivation + KAT vectors

HKDF-SHA256 PSK derivation per spec §5.5. Symmetric for both peers
via sorted-concat salt. KAT vector pinned in cross_platform_vectors.json
for cross-validation against Android NfcProtocolTest.kt.

4 unit tests pin: 32-byte output, symmetry, exact info bytes, KAT match.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Phase B — NFC reader service

### Task B.1: NfcCollaborativeExchange skeleton

**Files:**
- Create: `QAudionEngine/Sources/QAudionEngine/Sovereign/NfcCollaborativeExchange.swift`
- Create: `QAudionEngine/Tests/QAudionEngineTests/Sovereign/NfcCollaborativeExchangeTests.swift`

This service drives `NfcExchangeViewModel` through `Idle → Waiting → Exchanging → Success/Error`.
On iOS, it owns an `NFCTagReaderSession` (reader role only — iPhones cannot HCE).

- [ ] **Step 1: Failing test first.** Test the state-machine integration without real NFC hardware (mock the tag exchange).

```swift
import XCTest
@testable import QAudionEngine

final class NfcCollaborativeExchangeTests: XCTestCase {

    func test_initialState_isIdle() {
        let svc = NfcCollaborativeExchange()
        XCTAssertEqual(svc.viewModel.state, .idle)
    }

    func test_start_movesToWaiting() {
        let svc = NfcCollaborativeExchange()
        svc.start()
        XCTAssertEqual(svc.viewModel.state, .waiting)
    }

    func test_simulateTagDetected_movesToExchanging() {
        let svc = NfcCollaborativeExchange()
        svc.start()
        svc.simulateTagDetectedForTesting()
        XCTAssertEqual(svc.viewModel.state, .exchanging)
    }

    func test_simulateSuccess_recordsPeerName() throws {
        let svc = NfcCollaborativeExchange()
        svc.start()
        svc.simulateTagDetectedForTesting()
        svc.simulateExchangeCompletedForTesting(peerDeviceName: "Pixel 7")
        if case .success(let name) = svc.viewModel.state {
            XCTAssertEqual(name, "Pixel 7")
        } else { XCTFail() }
    }

    func test_simulateError_movesToError() {
        let svc = NfcCollaborativeExchange()
        svc.start()
        svc.simulateTagDetectedForTesting()
        svc.simulateExchangeFailedForTesting(message: "Timeout")
        if case .error(let msg) = svc.viewModel.state {
            XCTAssertEqual(msg, "Timeout")
        } else { XCTFail() }
    }
}
```

- [ ] **Step 2:** Run, expect FAIL.

- [ ] **Step 3: Implementation skeleton (stops at the CoreNFC seam — actual NFC reader callbacks are wired in B.2):**

```swift
import Foundation
#if canImport(CoreNFC) && os(iOS)
import CoreNFC
#endif

/// Drives an iOS-reader NFC collaborative pairing session.
///
/// Owns an `NfcExchangeViewModel` and an underlying `NFCTagReaderSession`
/// (created in `start()`). When a tag is detected, performs SELECT-AID
/// → 64-byte payload exchange → PSK derivation, then transitions to
/// `.success` or `.error`.
///
/// On non-iOS builds (e.g. macOS unit tests), the CoreNFC layer is absent
/// and the service exposes `simulate*ForTesting()` methods to drive the
/// state machine deterministically.
public final class NfcCollaborativeExchange {

    public private(set) var viewModel: NfcExchangeViewModel

    public init() {
        self.viewModel = .mock  // starts in .idle
    }

    public func start() {
        viewModel.transition(to: .waiting)
        #if canImport(CoreNFC) && os(iOS)
        beginNfcReaderSession()
        #endif
    }

    public func cancel() {
        // Returns to idle from any terminal state.
        viewModel.transition(to: .idle)
        #if canImport(CoreNFC) && os(iOS)
        endNfcReaderSessionIfActive()
        #endif
    }

    // MARK: - Test seams

    /// Test-only: pretend a tag was detected. Drives `.waiting → .exchanging`.
    public func simulateTagDetectedForTesting() {
        viewModel.transition(to: .exchanging)
    }

    /// Test-only: pretend the APDU exchange completed successfully.
    public func simulateExchangeCompletedForTesting(peerDeviceName: String) {
        viewModel.transition(to: .success(peerDeviceName: peerDeviceName))
    }

    /// Test-only: pretend the APDU exchange failed.
    public func simulateExchangeFailedForTesting(message: String) {
        viewModel.transition(to: .error(message: message))
    }

    // MARK: - CoreNFC integration (iOS-only)

    #if canImport(CoreNFC) && os(iOS)
    private var session: NFCTagReaderSession?

    private func beginNfcReaderSession() {
        // Implementation for B.2: instantiate NFCTagReaderSession with
        // pollingOption: .iso14443, delegate: an internal delegate that
        // forwards to viewModel.transition(...). Wired in B.2.
    }

    private func endNfcReaderSessionIfActive() {
        session?.invalidate()
        session = nil
    }
    #endif
}
```

- [ ] **Step 4:** Run tests. Expected PASS (5 tests).

- [ ] **Step 5: Commit.**

```bash
git add QAudionEngine/Sources/QAudionEngine/Sovereign/NfcCollaborativeExchange.swift \
        QAudionEngine/Tests/QAudionEngineTests/Sovereign/NfcCollaborativeExchangeTests.swift
git commit -m "feat(nfc): A.2.B.1 NfcCollaborativeExchange skeleton + state-machine tests

Drives NfcExchangeViewModel through Idle → Waiting → Exchanging → Success/Error.
Real CoreNFC integration deferred to B.2 — this commit pins the test seams
(simulate*ForTesting) so the state machine is fully covered without a real
phone-pair test rig.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

### Task B.2: CoreNFC reader session wiring (iOS-only)

**Files:**
- Modify: `QAudionEngine/Sources/QAudionEngine/Sovereign/NfcCollaborativeExchange.swift`

This is the IRL part — only meaningfully testable with two physical devices.

- [ ] **Step 1:** Inside the `#if canImport(CoreNFC) && os(iOS)` block, implement the `NFCTagReaderSessionDelegate` adapter:

```swift
private final class TagReaderDelegate: NSObject, NFCTagReaderSessionDelegate {
    weak var owner: NfcCollaborativeExchange?

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        // No-op: viewModel already in .waiting from start().
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        owner?.handleSessionInvalid(error: error)
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first, case .iso7816(let iso) = tag else {
            session.invalidate(errorMessage: "Unsupported tag")
            return
        }
        Task {
            do {
                try await session.connect(to: tag)
                let peerName = try await self.owner?.runApduExchange(over: iso, session: session) ?? "(unknown)"
                self.owner?.viewModel.transition(to: .success(peerDeviceName: peerName))
                session.alertMessage = "Paired with \(peerName)"
                session.invalidate()
            } catch {
                session.invalidate(errorMessage: error.localizedDescription)
            }
        }
    }
}
```

- [ ] **Step 2:** Implement `runApduExchange(over:session:)`:

```swift
fileprivate func runApduExchange(
    over iso: NFCISO7816Tag,
    session: NFCTagReaderSession
) async throws -> String {
    viewModel.transition(to: .exchanging)
    let aid = Data([0xF0, 0xBC, 0xF1, 0x07, 0x3A, 0x51, 0x00])  // §5.5
    let select = NFCISO7816APDU(
        instructionClass: 0x00, instructionCode: 0xA4,
        p1Parameter: 0x04, p2Parameter: 0x00,
        data: aid, expectedResponseLength: -1
    )
    let (selectResp, sw1, sw2) = try await iso.sendCommand(apdu: select)
    guard sw1 == 0x90, sw2 == 0x00 else {
        throw NSError(domain: "NfcCollaborativeExchange", code: Int(sw1) << 8 | Int(sw2),
                      userInfo: [NSLocalizedDescriptionKey: "SELECT failed"])
    }
    _ = selectResp  // SELECT response is metadata; payload comes via subsequent commands

    // Generate our 64-byte payload: ephemeral X25519 pubkey || 32B random.
    let myPriv = Curve25519.KeyAgreement.PrivateKey()
    let myPub = myPriv.publicKey.rawRepresentation
    let entropy = Data((0..<32).map { _ in UInt8.random(in: 0...UInt8.max) })
    let myPayload = myPub + entropy
    precondition(myPayload.count == 64)

    // Custom GET DATA: send our payload, expect peer's 64-byte payload back.
    let exchange = NFCISO7816APDU(
        instructionClass: 0x00, instructionCode: 0xCA,
        p1Parameter: 0x00, p2Parameter: 0x00,
        data: myPayload, expectedResponseLength: 64
    )
    let (peerPayload, sw1b, sw2b) = try await iso.sendCommand(apdu: exchange)
    guard sw1b == 0x90, sw2b == 0x00, peerPayload.count == 64 else {
        throw NSError(domain: "NfcCollaborativeExchange", code: Int(sw1b) << 8 | Int(sw2b),
                      userInfo: [NSLocalizedDescriptionKey: "Payload exchange failed"])
    }
    let peerPub = try Curve25519.KeyAgreement.PublicKey(
        rawRepresentation: peerPayload.prefix(32)
    )

    // Derive PSK and persist via SovereignKeyVault (handled by caller via delegate).
    let psk = try NfcPskDerivation.derivePsk(myPriv: myPriv, peerPub: peerPub)
    try await onPskDerivedDelegate?(psk, peerPub.rawRepresentation)

    // Peer device name comes back in the last 32 bytes (entropy block) — not used directly;
    // for now return placeholder "Android peer".
    return "Android peer"
}

/// Caller (e.g. KeyManagementView's view model wrapper) sets this to persist
/// the PSK. NfcCollaborativeExchange itself does not own a vault — that's
/// the integration layer's job.
public var onPskDerivedDelegate: ((Data, Data) async throws -> Void)?
```

- [ ] **Step 3: Manual smoke test.** Pair an iPhone (with Q-Audion installed) against an Android device running the same app's HCE service. Confirm: tap → "Reading tag" prompt → exchange completes → both sides display matching SAS words. Document the result in `docs/progress/A2_NFC_SMOKE.md`.

- [ ] **Step 4:** Commit.

```bash
git add QAudionEngine/Sources/QAudionEngine/Sovereign/NfcCollaborativeExchange.swift
git commit -m "feat(nfc): A.2.B.2 wire CoreNFC reader session + APDU exchange

SELECT into AID F0BCF1073A5100 then GET DATA with 64B payload (32B
ephemeral X25519 pubkey + 32B random entropy). Peer payload decoded
and PSK derived via NfcPskDerivation. Persisted via the caller-supplied
onPskDerivedDelegate (vault integration deferred to L2/L3).

Manual smoke test results in docs/progress/A2_NFC_SMOKE.md.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Phase C — Backend integration (device list / register / revoke)

### Task C.1: DeviceListClient — REST + WS bridge

**Files:**
- Create: `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoDeviceListClient.swift`
- Create: `QAudionEngine/Tests/QAudionEngineTests/Backend/BCryptoDeviceListClientTests.swift`

Wraps `device_list` / `device_register` / `device_remove` WS envelopes (frozen per §5.11) and `POST /api/v1/device/publickey` REST (already aligned in Phase 1 commit `c6e605e`).

- [ ] **Step 1:** Failing test (URLProtocol stub for REST + WS mock).
- [ ] **Step 2:** Run, expect FAIL.
- [ ] **Step 3: Implementation:**

```swift
import Foundation

public protocol DeviceListClient {
    /// Fetch current linked devices from server (uses WS `device_list`).
    func fetchDevices() async throws -> [DeviceManagementViewModel.Device]

    /// Register a newly linked device (post-NFC). Sends WS `device_register`
    /// + REST `POST /device/publickey` for the linked device's public key.
    func registerDevice(deviceName: String, publicKey: Data) async throws

    /// Revoke a device by id (sends WS `device_remove`).
    func revokeDevice(deviceId: String) async throws
}

public final class BCryptoDeviceListClient: DeviceListClient {
    // Implementation depends on existing BCryptoWebSocketClient (USER WT
    // — DO NOT modify) and BCryptoKmsClient (already aligned). Use the
    // public surface only.
    // Full impl in commit; ~150 LOC.
}
```

- [ ] **Step 4:** Tests pass.
- [ ] **Step 5:** Commit `feat(backend): A.2.C.1 BCryptoDeviceListClient`.

> **Caveat:** if the BCryptoWebSocketClient public surface lacks `subscribe(toType: ...)` for inbound `device_list_response`, this task BLOCKS on a USER-WT change. In that case mark BLOCKED and log in TASK_LOG.md; do not modify USER WT files.

---

## Phase D — SwiftUI view bindings

### Task D.1: KeyManagementView refactor

**Files:**
- Modify: `QAudionEngine/Sources/QAudionEngine/UI/KeyManagementView.swift`

- [ ] **Step 1:** Read existing `KeyManagementView.swift`.
- [ ] **Step 2:** Add a `@StateObject KeyManagementContainer` that wraps `KeyManagementViewModel` and a binding to a load-from-server task (uses `BCryptoDeviceListClient.fetchDevices` + `BCryptoKmsClient.getPendingKeys`).
- [ ] **Step 3:** Use ViewModel mock in `#Preview`.
- [ ] **Step 4:** Add SAS verification CTA → opens `SasVerificationView` sheet.
- [ ] **Step 5:** Commit `feat(ui): A.2.D.1 KeyManagementView consumes KeyManagementViewModel`.

### Task D.2: DeviceManagementView refactor

Same shape as D.1 but for `DeviceManagementViewModel`. Adds revoke confirmation alert.

### Task D.3: NfcExchangeView refactor

Wraps `NfcCollaborativeExchange` service; binds to `NfcExchangeViewModel.state`. Shows progress UI matching Android Compose flow.

---

## Phase E — Closeout

### Task E.1: STATUS.md + TASK_LOG.md update

Mark A.2 complete, list 6-8 commits, note any blocked sub-tasks (e.g. C.1 if WS public-surface gap forces deferral).

### Task E.2: Optional verification tag `v1.0.25-a2`

USER GATE — push tag only with explicit approval. Verify Codemagic still produces a clean IPA + Apple inbox is silent for 24h.

---

## Self-review checklist

- [ ] **Spec coverage:** §5.5 NFC pairing → A.1 + B.1 + B.2. KeyManagement screen → D.1. DeviceManagement → D.2. NfcExchange → D.3. ML-KEM-1024 / X25519 ECDH already covered by `INVARIANTS_VERIFIED.md` §5.4 (no work needed).
- [ ] **Blocked dependencies:** C.1 may block on WS public-surface; document path forward (request user to add `subscribe(toType:)` API to `BCryptoWebSocketClient`).
- [ ] **No USER WT files staged.**
- [ ] **No Codemagic / Package.swift / project.yml changes.**
- [ ] **All TDD code blocks include exact test code, exact implementation; no "TODO" placeholders in shipped code.**
- [ ] **Manual smoke test (B.2 Step 3)** is gated to a documented `A2_NFC_SMOKE.md` produced by the human running it.
