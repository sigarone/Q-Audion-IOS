# Track A.5 — PushKit VoIP Scaffolding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Wire the iOS-side of VoIP push notifications: register for `.voIP` push token, receive `incoming_call` payload, hand off to CallKitProvider. **Delivery is server-blocked**: bcrypto-server lite does NOT emit APNs VoIP push (only FCM). This plan only ships scaffolding so the day the server team picks an option from spec §10.1, iOS is ready.

**Architecture:** Single iOS-only file `PushKitProvider.swift` wrapping `PKPushRegistry`. Bridges to `CallKitManaging` (A.3) so an incoming push immediately reports an incoming call to the OS. Token registration uses the existing `POST /api/v1/account/fcm-token` endpoint (frozen per §5.11) — iOS sends an APNs token under that field name; server-side documentation for mapping APNs tokens lives in the spec §10.1.

**Tech Stack:** Swift 5.9, PushKit (`PKPushRegistry`, `PKPushPayload`), already linked per Phase 0.3. iOS 16+ (PushKit available since iOS 8 but `.voIP` payload encryption changes happened in iOS 13+).

**Predecessor:** A.3 CallKit (`CallKitManaging` protocol). Spec: §7 A.5 + §5.7 (VoIP payload form) + §10.1 (server-team option α/β/γ/δ pending).

---

## Reference paths

| What | Path |
|---|---|
| PushKit framework | linked via `QAudionApp/project.yml` (commit `4e230ab`) |
| Existing AppState | `QAudionApp/AppState.swift` |
| Account API | `QAudionEngine/Sources/QAudionEngine/Backend/Protocols/AccountApi.swift` |
| BCrypto AccountApi impl | `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoAccountApiImpl.swift` (`registerPushToken`, frozen) |
| Spec §10.1 (server APNs gap) | `docs/superpowers/specs/2026-04-28-cross-platform-alignment-design.md` |

## D-05 hygiene

Standard list. `BCryptoAccountApiImpl.swift` is NOT in USER-WT but its registration of `registerPushToken` is already aligned (commit history). No need to modify.

---

## Phase A — PushKit registration

### Task A.1: PushKitProvider class

**Files:**
- Create: `QAudionEngine/Sources/QAudionEngine/Integration/PushKitProvider.swift`
- Create: `QAudionEngine/Tests/QAudionEngineTests/Integration/PushKitPayloadDecodingTests.swift`

The provider has 2 public responsibilities:
1. Register for `.voIP` token on launch, send to server via `AccountApi.registerPushToken`.
2. Receive incoming push payload, decode `{type, call_id, caller_id, caller_name, call_type}` (frozen §5.7), forward to `CallKitManaging.reportIncomingCall(...)`.

- [ ] **Step 1: Failing test for the payload decoder (this part runs on any platform, not just iOS):**

```swift
import XCTest
@testable import QAudionEngine

final class PushKitPayloadDecodingTests: XCTestCase {

    func test_decodesIncomingCallPayload() throws {
        let dict: [String: Any] = [
            "type": "incoming_call",
            "call_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
            "caller_id": "user-aabbccdd",
            "caller_name": "Alice",
            "call_type": "audio"
        ]
        let parsed = try PushKitProvider.parsePayload(dict)
        XCTAssertEqual(parsed.callId.uuidString.lowercased(), "f47ac10b-58cc-4372-a567-0e02b2c3d479")
        XCTAssertEqual(parsed.callerId, "user-aabbccdd")
        XCTAssertEqual(parsed.callerName, "Alice")
        XCTAssertEqual(parsed.hasVideo, false)
    }

    func test_decodesVideoCall() throws {
        let dict: [String: Any] = [
            "type": "incoming_call",
            "call_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
            "caller_id": "user-x",
            "caller_name": "Bob",
            "call_type": "video"
        ]
        let parsed = try PushKitProvider.parsePayload(dict)
        XCTAssertTrue(parsed.hasVideo)
    }

    func test_rejectsWrongType() throws {
        let dict: [String: Any] = ["type": "regular_message"]
        XCTAssertThrowsError(try PushKitProvider.parsePayload(dict))
    }

    func test_rejectsMissingCallId() throws {
        let dict: [String: Any] = [
            "type": "incoming_call",
            "caller_id": "user-x",
            "caller_name": "Bob",
            "call_type": "audio"
        ]
        XCTAssertThrowsError(try PushKitProvider.parsePayload(dict))
    }

    func test_rejectsBadUUID() throws {
        let dict: [String: Any] = [
            "type": "incoming_call",
            "call_id": "not-a-uuid",
            "caller_id": "user-x",
            "caller_name": "Bob",
            "call_type": "audio"
        ]
        XCTAssertThrowsError(try PushKitProvider.parsePayload(dict))
    }
}
```

- [ ] **Step 2:** Run, expect FAIL.

- [ ] **Step 3: Implementation:**

```swift
import Foundation
#if canImport(PushKit) && os(iOS)
import PushKit
#endif

public final class PushKitProvider {

    /// Decoded form of the §5.7 VoIP payload. Public so unit tests can use it.
    public struct ParsedPayload: Equatable {
        public let callId: UUID
        public let callerId: String
        public let callerName: String
        public let hasVideo: Bool
    }

    public enum DecodeError: Error {
        case wrongType(String)
        case missingField(String)
        case badUUID(String)
    }

    /// Stateless payload parser. Pure function, testable on any platform.
    public static func parsePayload(_ dict: [String: Any]) throws -> ParsedPayload {
        guard let type = dict["type"] as? String, type == "incoming_call" else {
            throw DecodeError.wrongType(dict["type"] as? String ?? "<absent>")
        }
        guard let callIdStr = dict["call_id"] as? String else {
            throw DecodeError.missingField("call_id")
        }
        guard let callId = UUID(uuidString: callIdStr) else {
            throw DecodeError.badUUID(callIdStr)
        }
        guard let callerId = dict["caller_id"] as? String else {
            throw DecodeError.missingField("caller_id")
        }
        guard let callerName = dict["caller_name"] as? String else {
            throw DecodeError.missingField("caller_name")
        }
        let callTypeStr = (dict["call_type"] as? String) ?? "audio"
        let hasVideo = (callTypeStr == "video")
        return ParsedPayload(
            callId: callId,
            callerId: callerId,
            callerName: callerName,
            hasVideo: hasVideo
        )
    }

    // MARK: - PushKit-only behaviors (iOS-only)

    #if canImport(PushKit) && os(iOS)
    public typealias TokenHandler = (Data) async -> Void
    public typealias IncomingHandler = (ParsedPayload) async -> Void

    private let registry: PKPushRegistry
    private let onTokenUpdate: TokenHandler
    private let onIncomingCall: IncomingHandler

    private final class Delegate: NSObject, PKPushRegistryDelegate {
        weak var owner: PushKitProvider?
        func pushRegistry(_ registry: PKPushRegistry,
                          didUpdate pushCredentials: PKPushCredentials,
                          for type: PKPushType) {
            guard type == .voIP else { return }
            Task { await self.owner?.onTokenUpdate(pushCredentials.token) }
        }
        func pushRegistry(_ registry: PKPushRegistry,
                          didReceiveIncomingPushWith payload: PKPushPayload,
                          for type: PKPushType,
                          completion: @escaping () -> Void) {
            guard type == .voIP else { completion(); return }
            do {
                let parsed = try PushKitProvider.parsePayload(payload.dictionaryPayload as! [String: Any])
                Task {
                    await self.owner?.onIncomingCall(parsed)
                    completion()
                }
            } catch {
                completion()
            }
        }
    }

    private let delegate = Delegate()

    public init(onTokenUpdate: @escaping TokenHandler,
                onIncomingCall: @escaping IncomingHandler) {
        self.onTokenUpdate = onTokenUpdate
        self.onIncomingCall = onIncomingCall
        self.registry = PKPushRegistry(queue: .main)
        delegate.owner = self
        registry.delegate = delegate
        registry.desiredPushTypes = [.voIP]
    }
    #endif
}
```

- [ ] **Step 4:** Run tests. 5 PASS.

- [ ] **Step 5:** Commit `feat(push): A.5.A.1 PushKitProvider + payload decoder + 5 tests`.

---

## Phase B — App-level wiring

### Task B.1: Wire PushKitProvider in AppState

**Files:**
- Modify: `QAudionApp/AppState.swift`

- [ ] **Step 1:** Inside `AppState.init`, instantiate `PushKitProvider` (iOS-only):

```swift
#if canImport(PushKit) && os(iOS)
self.pushKit = PushKitProvider(
    onTokenUpdate: { [weak self] token in
        let hex = token.map { String(format: "%02hhx", $0) }.joined()
        try? await self?.accountApi.registerPushToken(hex, platform: "ios-apns")
    },
    onIncomingCall: { [weak self] payload in
        await self?.callKit.reportIncomingCall(
            uuid: payload.callId,
            callerName: payload.callerName,
            hasVideo: payload.hasVideo
        )
        // Wake the engine so when the user answers, it's ready.
        await self?.callService.prepareForIncomingCall(
            callId: payload.callId,
            callerId: payload.callerId
        )
    }
)
#endif
```

> **Server contract note:** The iOS variant calls `registerPushToken(<apns hex>, platform: "ios-apns")`. Server-side (option α from §10.1) must route `platform == "ios-apns"` to the APNs HTTP/2 emitter. Until server picks an option, this token is stored but no pushes flow.

- [ ] **Step 2:** Add a "VoIP push pending" line to Settings → About → Diagnostics (consume from `getServerHealth` health check; if server `version` response indicates `apns_voip_supported: false`, surface text "VoIP push pending server upgrade").

- [ ] **Step 3:** Commit.

---

## Phase C — Closeout

### Task C.1: STATUS + TASK_LOG; optional `v1.0.28-a5` tag (USER GATE).

---

## Self-review checklist

- [ ] **Spec coverage:** §7 A.5 — A.1 (provider+payload+tests), B.1 (AppState wiring + Settings note).
- [ ] **§5.7 payload form** parsed exactly: `type`, `call_id`, `caller_id`, `caller_name`, `call_type` ∈ {audio,video}.
- [ ] **Server gap acknowledged:** Settings surfaces "VoIP push pending server upgrade" until §10.1 resolved.
- [ ] **D-05 hygiene:** `BCryptoAccountApiImpl.registerPushToken` is already aligned, no edits.
- [ ] **No new dependencies.**
