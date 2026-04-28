# Track A.3 — CallKit Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Integrate CallKit so iOS users see the OS-native incoming-call UI for Q-Audion calls (lock-screen full-screen UI + system call log), and so outgoing calls are routed through the system audio session correctly. Bridge to the existing `CallService` and the new `InCallViewModel` from F1.5.

**Architecture:** Single-direction abstraction. The engine knows about the protocol `CallKitManaging`; CallKit-specific code lives in iOS-only file behind `#if canImport(CallKit) && os(iOS)`. App layer wires `CallKitProvider` (the concrete iOS impl) into `CallService`. Tests run against a `MockCallKitProvider`.

**Tech Stack:** Swift 5.9, CallKit (`CXProvider`, `CXCallController`, `CXProviderConfiguration`), AVFoundation (`AVAudioSession`), XCTest. iOS 16+. No new SPM dependencies; CallKit is already linked per Phase 0.3.

**Predecessor:** [docs/superpowers/plans/2026-04-28-track-a-foundation.md](2026-04-28-track-a-foundation.md). Spec: §7 A.3.

---

## Reference paths

| What | Path |
|---|---|
| Existing `CallService` (App layer) | `QAudionApp/Services/CallService.swift` |
| Existing `CallView` (App layer) | `QAudionApp/Views/CallView.swift` |
| Engine `InCallViewModel` (from F1.5) | `QAudionEngine/Sources/QAudionEngine/UI/ViewModels/InCallViewModel.swift` |
| Engine call routing | `QAudionEngine/Sources/QAudionEngine/Registry/CallRouter.swift` |
| Android Telecom reference | `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-android-new\app\src\main\java\com\bcrypto\qaudion\call\QAudionConnectionService.kt` |
| CallKit framework already linked? | YES via `QAudionApp/project.yml` (commit `4e230ab`) |

## D-05 hygiene

NEVER stage USER-WT files (full list in A.2 plan §"Reference paths"). `QAudionCallIntegration.swift` is USER-WT — work only via its public protocol surface, do not modify.

## Iteration loop on Windows

CallKit only runs on physical iOS devices (and partly in iOS Simulator). User runs Codemagic to verify TestFlight. Mitigation:
- Define `CallKitManaging` protocol with full method surface.
- Implement `MockCallKitManaging` in test target. Unit-test all `CallService` integration paths against the mock.
- Integration with real `CXProvider` is in a single iOS-only file with minimal logic.

---

## Phase A — Protocol + mock

### Task A.1: Define CallKitManaging protocol

**Files:**
- Create: `QAudionEngine/Sources/QAudionEngine/Integration/CallKitManaging.swift`
- Create: `QAudionEngine/Tests/QAudionEngineTests/Integration/CallKitManagingTests.swift`

- [ ] **Step 1: Failing test for the protocol contract — implementer must respond to all 6 methods + emit no-op when iOS-not-available.**

```swift
import XCTest
@testable import QAudionEngine

final class CallKitManagingTests: XCTestCase {

    func test_mockReportsIncomingCall() async {
        let mock = MockCallKitManager()
        let id = UUID()
        await mock.reportIncomingCall(uuid: id, callerName: "Alice", hasVideo: false)
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].state, .ringing)
    }

    func test_mockEndCall() async {
        let mock = MockCallKitManager()
        let id = UUID()
        await mock.reportIncomingCall(uuid: id, callerName: "Alice", hasVideo: false)
        await mock.reportCallEnded(uuid: id, reason: .remoteEnded)
        XCTAssertEqual(mock.calls[0].state, .ended)
    }

    func test_mockStartOutgoingCall() async throws {
        let mock = MockCallKitManager()
        let id = try await mock.startOutgoingCall(handle: "+393331234567", hasVideo: false)
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].state, .dialing)
        XCTAssertEqual(mock.calls[0].uuid, id)
    }

    func test_mockSetCallConnected() async throws {
        let mock = MockCallKitManager()
        let id = try await mock.startOutgoingCall(handle: "+393331234567", hasVideo: false)
        await mock.reportCallConnected(uuid: id)
        XCTAssertEqual(mock.calls[0].state, .connected)
    }

    func test_mockMute() async throws {
        let mock = MockCallKitManager()
        let id = try await mock.startOutgoingCall(handle: "+393331234567", hasVideo: false)
        try await mock.setMuted(uuid: id, isMuted: true)
        XCTAssertTrue(mock.calls[0].isMuted)
    }

    func test_mockHold() async throws {
        let mock = MockCallKitManager()
        let id = try await mock.startOutgoingCall(handle: "+393331234567", hasVideo: false)
        try await mock.setOnHold(uuid: id, isOnHold: true)
        XCTAssertTrue(mock.calls[0].isOnHold)
    }
}
```

- [ ] **Step 2:** Run, expect FAIL — types don't exist yet.

- [ ] **Step 3: Implementation:**

```swift
import Foundation

/// Public protocol abstracting CallKit so the engine doesn't depend on
/// iOS-only frameworks at compile time. Concrete iOS implementation lives
/// in `Integration/CallKitProvider.swift` (iOS-only). Tests use
/// `MockCallKitManager`.
public protocol CallKitManaging: AnyObject, Sendable {

    /// Tell the OS we have an incoming call to display in lock-screen UI.
    func reportIncomingCall(uuid: UUID, callerName: String, hasVideo: Bool) async

    /// Notify the OS the user/peer ended the call.
    func reportCallEnded(uuid: UUID, reason: CallEndReason) async

    /// User initiated an outgoing call. Returns the assigned UUID.
    func startOutgoingCall(handle: String, hasVideo: Bool) async throws -> UUID

    /// Notify the OS the outgoing call connected (peer answered).
    func reportCallConnected(uuid: UUID) async

    /// Mute / unmute. Drives both the engine + system mic state.
    func setMuted(uuid: UUID, isMuted: Bool) async throws

    /// Hold / unhold.
    func setOnHold(uuid: UUID, isOnHold: Bool) async throws
}

public enum CallEndReason: Sendable {
    case userEnded         // local user pressed end
    case remoteEnded       // peer hung up
    case unanswered        // no answer / timeout
    case failed(String)    // hardware / network error
    case declined          // user pressed decline on incoming
}
```

```swift
// MockCallKitManager.swift (in Tests/Integration/)
@testable import QAudionEngine
import Foundation

final class MockCallKitManager: CallKitManaging {

    enum State { case ringing, dialing, connected, ended }

    struct CallRecord: Equatable {
        var uuid: UUID
        var handle: String
        var hasVideo: Bool
        var state: State
        var isMuted: Bool = false
        var isOnHold: Bool = false
    }

    private(set) var calls: [CallRecord] = []
    private let lock = NSLock()

    func reportIncomingCall(uuid: UUID, callerName: String, hasVideo: Bool) async {
        lock.lock(); defer { lock.unlock() }
        calls.append(CallRecord(uuid: uuid, handle: callerName, hasVideo: hasVideo, state: .ringing))
    }

    func reportCallEnded(uuid: UUID, reason: CallEndReason) async {
        lock.lock(); defer { lock.unlock() }
        if let idx = calls.firstIndex(where: { $0.uuid == uuid }) {
            calls[idx].state = .ended
        }
    }

    func startOutgoingCall(handle: String, hasVideo: Bool) async throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        calls.append(CallRecord(uuid: id, handle: handle, hasVideo: hasVideo, state: .dialing))
        return id
    }

    func reportCallConnected(uuid: UUID) async {
        lock.lock(); defer { lock.unlock() }
        if let idx = calls.firstIndex(where: { $0.uuid == uuid }) {
            calls[idx].state = .connected
        }
    }

    func setMuted(uuid: UUID, isMuted: Bool) async throws {
        lock.lock(); defer { lock.unlock() }
        guard let idx = calls.firstIndex(where: { $0.uuid == uuid }) else {
            throw NSError(domain: "MockCallKit", code: 404)
        }
        calls[idx].isMuted = isMuted
    }

    func setOnHold(uuid: UUID, isOnHold: Bool) async throws {
        lock.lock(); defer { lock.unlock() }
        guard let idx = calls.firstIndex(where: { $0.uuid == uuid }) else {
            throw NSError(domain: "MockCallKit", code: 404)
        }
        calls[idx].isOnHold = isOnHold
    }
}
```

Place `MockCallKitManager` under `QAudionEngine/Tests/QAudionEngineTests/Integration/MockCallKitManager.swift`.

- [ ] **Step 4:** Run tests. Expected: 6 PASS.

- [ ] **Step 5:** Commit `feat(callkit): A.3.A.1 CallKitManaging protocol + mock + 6 tests`.

---

## Phase B — Concrete CallKit provider (iOS-only)

### Task B.1: CallKitProvider implementation

**Files:**
- Create: `QAudionEngine/Sources/QAudionEngine/Integration/CallKitProvider.swift`

The single file gated by `#if canImport(CallKit) && os(iOS)`. Owns a `CXProvider` + `CXCallController`. Implements `CallKitManaging`.

- [ ] **Step 1:** Implementation:

```swift
import Foundation
#if canImport(CallKit) && os(iOS)
import CallKit
import AVFoundation

public final class CallKitProvider: NSObject, CallKitManaging, CXProviderDelegate {

    private let provider: CXProvider
    private let controller: CXCallController
    /// Caller hooks into these to react to system events (incoming call answered,
    /// outgoing call started, etc).
    public var onAnswerCall: ((UUID) async -> Void)?
    public var onEndCall: ((UUID) async -> Void)?
    public var onMutedChanged: ((UUID, Bool) async -> Void)?

    public override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = true
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.phoneNumber, .generic]
        cfg.iconTemplateImageData = nil  // App icon used as fallback
        cfg.ringtoneSound = nil          // System default
        self.provider = CXProvider(configuration: cfg)
        self.controller = CXCallController()
        super.init()
        self.provider.setDelegate(self, queue: nil)
    }

    // MARK: - CallKitManaging

    public func reportIncomingCall(uuid: UUID, callerName: String, hasVideo: Bool) async {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.hasVideo = hasVideo
        update.localizedCallerName = callerName
        do {
            try await provider.reportNewIncomingCall(with: uuid, update: update)
        } catch {
            // Server emitted incoming-call but iOS rejected it — likely
            // user has Do Not Disturb / Focus enabled. Silently drop.
        }
    }

    public func reportCallEnded(uuid: UUID, reason: CallEndReason) async {
        let cxReason: CXCallEndedReason
        switch reason {
        case .userEnded: cxReason = .remoteEnded // not used here, but symmetric
        case .remoteEnded: cxReason = .remoteEnded
        case .unanswered: cxReason = .unanswered
        case .declined: cxReason = .declinedElsewhere
        case .failed: cxReason = .failed
        }
        provider.reportCall(with: uuid, endedAt: Date(), reason: cxReason)
    }

    public func startOutgoingCall(handle: String, hasVideo: Bool) async throws -> UUID {
        let uuid = UUID()
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        action.isVideo = hasVideo
        let txn = CXTransaction(action: action)
        try await controller.request(txn)
        return uuid
    }

    public func reportCallConnected(uuid: UUID) async {
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    public func setMuted(uuid: UUID, isMuted: Bool) async throws {
        let action = CXSetMutedCallAction(call: uuid, muted: isMuted)
        try await controller.request(CXTransaction(action: action))
    }

    public func setOnHold(uuid: UUID, isOnHold: Bool) async throws {
        let action = CXSetHeldCallAction(call: uuid, onHold: isOnHold)
        try await controller.request(CXTransaction(action: action))
    }

    // MARK: - CXProviderDelegate

    public func providerDidReset(_ provider: CXProvider) {
        // System reset — drop all pending audio sessions.
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task {
            await onAnswerCall?(action.callUUID)
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task {
            await onEndCall?(action.callUUID)
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task {
            await onMutedChanged?(action.callUUID, action.isMuted)
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // System granted us the audio session. Engine should start mic capture now.
        try? audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        try? audioSession.setActive(true)
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // System took the audio session back (e.g. another call). Engine should pause.
    }
}
#endif
```

- [ ] **Step 2:** No unit test — runtime behavior is exercised by Phase D integration tests + manual smoke. Build verification only.

- [ ] **Step 3:** Commit `feat(callkit): A.3.B.1 CallKitProvider concrete iOS-only impl`.

---

## Phase C — App-level wiring

### Task C.1: Wire CallKitProvider into AppState

**Files:**
- Modify: `QAudionApp/AppState.swift`
- Modify: `QAudionApp/Services/CallService.swift` ⚠️ NOT USER-WT — verify before editing

- [ ] **Step 1:** Confirm `CallService.swift` is NOT in the USER-WT D-05 list. (It's in `QAudionApp/Services/`, separate from the engine `BCryptoCallingApiImpl`.) If it IS user-edited, mark BLOCKED.

- [ ] **Step 2:** Add to `AppState`:

```swift
final class AppState: ObservableObject {
    // ... existing state ...

    let callKit: CallKitManaging = {
        #if os(iOS) && canImport(CallKit)
        let p = CallKitProvider()
        p.onAnswerCall = { [weak self] uuid in
            await self?.callService.userAnsweredCall(uuid: uuid)
        }
        p.onEndCall = { [weak self] uuid in
            await self?.callService.userEndedCall(uuid: uuid)
        }
        p.onMutedChanged = { [weak self] uuid, muted in
            await self?.callService.userToggledMute(uuid: uuid, muted: muted)
        }
        return p
        #else
        return MockCallKitManager()  // for previews on macOS catalyst
        #endif
    }()
}
```

- [ ] **Step 3:** Modify `CallService` to call `callKit.reportIncomingCall(...)` when receiving a `call_offer` envelope, and `callKit.startOutgoingCall(...)` when user initiates outgoing.

- [ ] **Step 4:** Manual smoke test: install via TestFlight, place + receive a call. Document in `docs/progress/A3_CALLKIT_SMOKE.md`.

- [ ] **Step 5:** Commit.

---

## Phase D — Closeout

### Task D.1: STATUS.md + TASK_LOG.md

Mark A.3 complete. List 4-5 commits.

### Task D.2: Optional verification tag `v1.0.26-a3`

USER GATE.

---

## Self-review checklist

- [ ] **Spec coverage:** §7 A.3 (CallKit integration) — A.1 (protocol+mock), B.1 (concrete impl), C.1 (app wiring), C.1 Step 4 (manual smoke).
- [ ] **Iteration loop addressed:** mock-driven unit tests cover all 6 protocol methods; real CXProvider exercised on TestFlight only.
- [ ] **D-05 hygiene:** all changes under `QAudionEngine/Integration/` and `QAudionApp/Services/` (verify CallService not USER WT; if it is — BLOCK).
- [ ] **No dependency bumps.** CallKit framework already linked.
- [ ] **iOS-only gating:** `#if canImport(CallKit) && os(iOS)` around the concrete `CallKitProvider`.
