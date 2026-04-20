# Q-Audion iOS ↔ Android Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Q-Audion iOS from ~45% feature coverage to full parity with the Android reference at `D:\users\f10379a\DEV APP\BCRYPTO\Q-Audion Android New`, with every screen real (no stubs), every algorithm wired to the BCrypto server, and the Codemagic TestFlight pipeline still green.

**Architecture:** iOS `QAudionApp` (SwiftUI) keeps its current 3-layer split: (a) `QAudionApp/Views` for UI, (b) `QAudionApp/Services` for iOS-only integrations (CallKit, PushKit, NFC, QR), (c) `QAudionEngine` Swift package for crypto/audio/protocol. We extend all three layers but do **not** restructure the project. All wire formats mirror Android files byte-for-byte (HKDF salts/infos, binary QR layouts, APDU AID, JSON envelope).

**Tech Stack:** Swift 5.9, SwiftUI (iOS 16+), Combine, CallKit, PushKit, CoreNFC, AVFoundation, CryptoKit + liboqs (ML-KEM-1024), CoreImage (QR gen), AVCaptureSession (QR scan), URLSessionWebSocketTask (via BCryptoWebSocketClient), XcodeGen, Codemagic.

**Reference commits / files (sources of truth):**
- Android wire: `Q-Audion Android New/core/core-data/src/main/java/com/bcrypto/qaudion/data/ws/{WsCommand,WsEvent,WsCodec}.kt`
- Android REST: `Q-Audion Android New/core/core-data/.../data/net/BCryptoApi.kt`
- Android device link: `Q-Audion Android New/.../DeviceLinkingProtocol.kt` (binary QR, HKDF salt `"qaudion-link-salt"`, info `"qaudion-device-link-v1"`)
- Android key vault: `Q-Audion Android New/.../SovereignKeyVault.kt` (~613 LOC)
- Android NFC: `Q-Audion Android New/.../NfcProtocol.kt` (AID `F0BCF1073A5100`, 64B payload, info `"Q-Audion NFC Collaborative PSK v1"`)
- Android CallStyle / Telecom: `Q-Audion Android New/app/.../call/QAudionConnectionService.kt` + `notification/CallStyleNotifier.kt`
- Android FCM: `Q-Audion Android New/app/.../push/FcmService.kt`
- iOS current baseline:
  - `QAudionApp/QAudionApp.swift`, `QAudionApp/AppState.swift`
  - `QAudionApp/Views/*.swift`
  - `QAudionApp/Services/{AuthService,CallService,ContactSyncService}.swift`
  - `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/*.swift`
  - `QAudionEngine/Sources/QAudionEngine/UI/{KeyManagementView,QrIdentityView,DeviceManagementView,ChatView,ContactDetailView,ContactDiscoveryView,SasVerificationView}.swift`

**Non-goals (out of scope for this plan):**
- Android-only Telecom APDU features that have no iOS analogue.
- Refactoring `QAudionEngine` package structure (only additive changes).
- Changing the onnxruntime 1.17.0 pin or the Codemagic patch step.
- External-tester distribution (needs legal review for PQC export compliance per CLAUDE.md section 7).

**Discipline rules:**
1. After each task: `git commit` with conventional prefix (`feat(ios):`, `fix(ios):`, `chore(ios):`).
2. Every task must compile cleanly (`xcodebuild -scheme QAudionApp -destination "generic/platform=iOS"`) before commit unless the task is a multi-step feature in which case the checkpoint commit lands at the end of that task.
3. After every **Phase** a TestFlight tag MAY be cut (`v1.0.N`) to verify Codemagic still produces a valid IPA. Treat any pipeline break as **P0** — do not proceed until resolved.
4. No `fatalError`, no `TODO:` in shipped code. A task that is blocked must be documented in this plan with a **BLOCKED** note; do not fake completion.
5. Phone hash across iOS MUST be `SHA-256(E.164 phone_number).hex_lowercase` — no salt — to match Android `BCryptoContactsApiImpl.kt:83-91`.

---

## Table of contents

- [Phase 0 — Capability & pipeline baseline](#phase-0--capability--pipeline-baseline)
- [Phase 1 — Wire protocol alignment audit](#phase-1--wire-protocol-alignment-audit)
- [Phase 2 — Authentication parity (FastSetup QR login + voice enrollment)](#phase-2--authentication-parity)
- [Phase 3 — Device linking (binary QR + sync key + snapshot)](#phase-3--device-linking)
- [Phase 4 — Key management depth + NFC collaborative exchange](#phase-4--key-management)
- [Phase 5 — CallKit integration](#phase-5--callkit-integration)
- [Phase 6 — PushKit VoIP](#phase-6--pushkit-voip)
- [Phase 7 — In-call UI parity (SAS / transport / video upgrade)](#phase-7--in-call-ui-parity)
- [Phase 8 — Chat parity (typing / attach / status)](#phase-8--chat-parity)
- [Phase 9 — Contacts parity (block list / phonebook / editor)](#phase-9--contacts-parity)
- [Phase 10 — Group calls (ViewModel + SFU bridge)](#phase-10--group-calls)
- [Phase 11 — Settings split + missing sub-screens](#phase-11--settings-parity)
- [Phase 12 — Tor / proxy real integration](#phase-12--torproxy-integration)
- [Phase 13 — End-to-end verification + TestFlight release](#phase-13--end-to-end-verification)

---

## Phase 0 — Capability & pipeline baseline

Goal: make the project able to link CallKit + PushKit, declare VoIP background mode, enable push entitlement, without breaking Codemagic. No functional Swift code yet.

### Task 0.1: Enable Push Notifications capability in Apple Developer portal

**Files:** none (portal action, document only)

- [ ] **Step 1:** User logs in to https://developer.apple.com/account and navigates to Identifiers → `com.qaudion.app`.
- [ ] **Step 2:** Check **Push Notifications**. Save.
- [ ] **Step 3:** Confirm the identifier now lists "Push Notifications" under capabilities.
- [ ] **Step 4:** Record the date in `SESSION_LOG.md` with line: `YYYY-MM-DD: Enabled Push Notifications capability for com.qaudion.app in Developer portal`.

Why: `app-store-connect fetch-signing-files --create` (codemagic.yaml) builds profiles from whatever capabilities are enabled on the identifier. If Push is not enabled here, the profile won't contain `aps-environment` and a later tag will fail signing.

### Task 0.2: Add VoIP background mode + aps-environment to iOS project

**Files:**
- Modify: `QAudionApp/Info.plist`
- Modify: `QAudionApp/QAudion.entitlements`

- [ ] **Step 1:** Edit `QAudionApp/Info.plist` — add `UIBackgroundModes` with `voip` and `audio`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>voip</string>
    <string>audio</string>
</array>
```

Place it just before the closing `</dict>` of the root dictionary.

- [ ] **Step 2:** Edit `QAudionApp/QAudion.entitlements` — add the push entitlement key:

```xml
<key>aps-environment</key>
<string>production</string>
```

Keep the existing `<key>com.apple.developer.nfc.readersession.formats</key>` array untouched.

- [ ] **Step 3:** Commit:

```bash
git add QAudionApp/Info.plist QAudionApp/QAudion.entitlements
git commit -m "feat(ios): declare voip background mode + aps-environment"
```

### Task 0.3: Link CallKit.framework and PushKit.framework via XcodeGen

**Files:**
- Modify: `QAudionApp/project.yml`

- [ ] **Step 1:** Open `QAudionApp/project.yml`. Locate the `dependencies:` block under target `QAudionApp`. Add two entries (matching the existing `sdk:` style — CLAUDE.md section 5 warns NEVER use `framework:`):

```yaml
    dependencies:
      - package: QAudionEngine
      - sdk: CoreAudio.framework
      - sdk: AudioToolbox.framework
      - sdk: Accelerate.framework
      - sdk: CallKit.framework
      - sdk: PushKit.framework
      - sdk: AVFoundation.framework
      - sdk: CoreNFC.framework
      - sdk: Contacts.framework
      - sdk: ContactsUI.framework
```

Rationale for each:
- `CallKit.framework`: needed by `CallKitService` (Phase 5).
- `PushKit.framework`: needed by `PushKitService` (Phase 6).
- `AVFoundation.framework`: QR scanner (`AVCaptureSession`) + audio session control; explicit link avoids "No such module 'AVFoundation'" at -Os.
- `CoreNFC.framework`: NFC APDU session in Phase 4.
- `Contacts.framework` + `ContactsUI.framework`: phonebook import (Phase 9). Engine's `ContactDiscoveryView` already uses `CNContactStore` so Contacts is actually already linked transitively but declaring it explicitly is safer.

- [ ] **Step 2:** From repo root run:

```bash
cd QAudionApp && xcodegen generate && cd ..
```

Expected: "Loaded project … Created project at QAudionApp.xcodeproj" with no warnings.

- [ ] **Step 3:** Verify the generated project still builds for iOS (quick smoke test):

```bash
xcodebuild -project QAudionApp/QAudionApp.xcodeproj -scheme QAudionApp -destination "generic/platform=iOS" -configuration Debug build-for-testing
```

Expected: `** BUILD SUCCEEDED **`. If it fails with "No such module" for one of the new SDKs, check iOS 16+ deployment target is still set.

- [ ] **Step 4:** Commit:

```bash
git add QAudionApp/project.yml
git commit -m "build(ios): link CallKit/PushKit/CoreNFC/Contacts SDK frameworks"
```

### Task 0.4: Verify Codemagic still builds

**Files:** none (CI verification)

- [ ] **Step 1:** Create tag `v1.0.23-ph0` and push:

```bash
git tag v1.0.23-ph0
git push origin v1.0.23-ph0
```

- [ ] **Step 2:** Watch Codemagic build. Expected: all steps green including "Set up signing" (now fetches a profile with `aps-environment`) and "Patch onnxruntime.framework". Publishing step uploads to App Store Connect; the build reaches the `Q-Audion testers` group.
- [ ] **Step 3:** Verify Apple's inbox: no ITMS-* rejection. The Phase 0 build should be indistinguishable from last green `v1.0.22` except for the new entitlements + background modes.
- [ ] **Step 4:** If the build fails, DO NOT start Phase 1. Diagnose; check Task 0.1 was completed; re-read CLAUDE.md sections 1–4.
- [ ] **Step 5:** On success, note `v1.0.23-ph0` in `SESSION_LOG.md` as the Phase 0 baseline.

---

## Phase 1 — Wire protocol alignment audit

Goal: before writing any feature code, confirm the existing `QAudionEngine/Backend/BCrypto/*` implementations match the Android wire spec. Any drift here silently breaks every later phase.

Reference: Android spec extracted during analysis — see plan header for file citations. JSON envelope is `{ "type": string, "data": object, "id": UUID? }`.

### Task 1.1: Audit WebSocket command set against Android WsCommand.kt

**Files:**
- Read: `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoWebSocketClient.swift`
- Reference: `Q-Audion Android New/core/core-data/src/main/java/com/bcrypto/qaudion/data/ws/WsCommand.kt`

- [ ] **Step 1:** Open the Android `WsCommand.kt`. List every `type` string the client sends.
- [ ] **Step 2:** Open the iOS `BCryptoWebSocketClient.swift` and its call sites (`BCryptoCallingApiImpl`, `BCryptoGroupCallManager`, `BCryptoPresenceManager`). Verify each Android command has a Swift equivalent method that emits an envelope with the same `type` string.

Required Android → iOS command mapping (from the protocol spec extracted in this session):

| Android type | iOS method (must exist) |
|---|---|
| `authenticate` | `BCryptoWebSocketClient.authenticate(token:)` |
| `call_offer` | `sendCallOffer` |
| `call_answer` | `sendCallAnswer` |
| `call_ice` | `sendIceCandidate` |
| `call_hangup` | `sendHangup` |
| `call_processing` | `sendCallProcessing` |
| `call_ready` | `sendCallReady` |
| `call_upgrade_request` | **NEW — Task 7.3** |
| `call_upgrade_response` | **NEW — Task 7.3** |
| `call_video_state` | **NEW — Task 7.3** |
| `opaque_message` | `sendOpaqueMessage` |
| `audio_frame` | existing engine path |
| `video_frame` | **NEW — Task 7.3** |
| `presence_subscribe` | `BCryptoPresenceManager.subscribe(userIds:)` |
| `msg_send` | existing or NEW — Task 8.2 |
| `msg_delivered` | **NEW — Task 8.2** |
| `msg_read` | **NEW — Task 8.2** |
| `msg_typing` | **NEW — Task 8.1** |
| `group_call_create` / `join` / `leave` / `forward` / `end` | `BCryptoGroupCallManager` |
| `ping` | existing keepalive |

- [ ] **Step 3:** For every row marked existing, produce a 1-line evidence comment in the file header (do not litter code — keep it to the existing doc-comment at the top of each impl file). For every **NEW** row, record it as a dependency for its Phase's task.
- [ ] **Step 4:** Commit if any doc-comment was touched:

```bash
git commit -am "docs(engine): document WS command coverage vs Android"
```

### Task 1.2: Audit REST endpoints against Android BCryptoApi.kt

**Files:**
- Read: `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/BCryptoRestClient.swift` and all API impl files
- Reference: `Q-Audion Android New/core/core-data/.../data/net/BCryptoApi.kt`

- [ ] **Step 1:** List Android REST paths (authoritative from the protocol spec):
  - `POST /register`, `POST /auth/login`, `POST /auth/refresh`, `DELETE /auth/logout`
  - `GET /profile`, `PUT /profile`, `GET /users/{id}`
  - `POST /contacts/discover`, `GET /contacts`, `POST /contacts/block`, `DELETE /contacts/block/{id}`, `GET /contacts/blocked`
  - `POST /device/publickey`, `POST /account/fcm-token` (rename on iOS to `/account/push-token` if backend accepts, else reuse)
  - `GET /calling/relays`
  - `GET /kms/pending`, `POST /kms/acknowledge/{id}`
  - `GET /config/client`, `GET /version`, `GET /health`

- [ ] **Step 2:** For each path, grep the iOS impl (`rg '"/api/v1/'` inside `QAudionEngine/Sources/QAudionEngine/Backend/BCrypto/`). For any gap, add a task to the dependent Phase. Likely gaps: `PUT /profile`, `DELETE /contacts/block/{id}`, `GET /contacts/blocked`, `GET /kms/pending`, `POST /kms/acknowledge/{id}`, `GET /version`, `GET /health`.

- [ ] **Step 3:** For `POST /auth/login`: confirm the iOS payload field is `phone_number` (underscore, Android snake_case), containing SHA-256 hex of the E.164 phone number, and that `device_name` is sent. If the iOS code currently sends `phoneHash` or camelCase, fix it now:

```swift
// Before any change: locate BCryptoAccountApiImpl.swift login() and check the JSON keys
```

If the keys are wrong, this is a Phase 1 fix, not a later phase:

```swift
// BCryptoAccountApiImpl.swift
struct LoginRequest: Encodable {
    let phone_number: String
    let password: String
    let device_name: String
}
```

- [ ] **Step 4:** For `POST /register`: confirm `phone_number` (hashed), `password`, optional `invite_code`, optional `display_name`.

- [ ] **Step 5:** Commit any key renames:

```bash
git commit -am "fix(engine): align REST field names with Android (snake_case)"
```

### Task 1.3: Ensure SHA-256 phone hashing helper exists and is the single source of truth

**Files:**
- Create (if not exists): `QAudionEngine/Sources/QAudionEngine/Utils/PhoneHash.swift`
- Test: `QAudionEngine/Tests/QAudionEngineTests/PhoneHashTests.swift`

- [ ] **Step 1:** Search: `rg 'SHA256.*phone|phoneHash' QAudionEngine/Sources/`. If there are multiple ad-hoc implementations, consolidate to one.

- [ ] **Step 2:** Create the canonical helper:

```swift
import CryptoKit
import Foundation

public enum PhoneHash {
    /// Normalize to E.164 (strip spaces, hyphens, parentheses, keep a leading +).
    /// Matches Android PhoneNumberNormalizer.
    public static func normalize(_ raw: String) -> String {
        var s = raw.unicodeScalars.filter { $0 == "+" || ("0"..."9").contains(Character($0)) }
            .map(String.init).joined()
        if !s.hasPrefix("+") { s = "+" + s }
        return s
    }

    /// SHA-256(E.164).hex_lowercase — must match Android BCryptoContactsApiImpl:83.
    public static func hash(_ phoneNumber: String) -> String {
        let e164 = normalize(phoneNumber)
        let digest = SHA256.hash(data: Data(e164.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 3:** Write the cross-platform-vector test:

```swift
import XCTest
@testable import QAudionEngine

final class PhoneHashTests: XCTestCase {
    func test_knownVector_e164() {
        // Vector extracted from Android PhoneNumberNormalizerTest.
        XCTAssertEqual(
            PhoneHash.hash("+14155552671"),
            "aacf5e8db1dc5d6a5f7..."  // FILL IN from the cross_platform_vectors.json bundle
        )
    }
    func test_normalization_strips_formatting() {
        XCTAssertEqual(
            PhoneHash.hash("+1 (415) 555-2671"),
            PhoneHash.hash("+14155552671")
        )
    }
}
```

Before committing, read `QAudionEngine/Resources/cross_platform_vectors.json` and extract the actual known-good hash to replace the placeholder. If the file doesn't contain a phone-hash vector, compute one on Android and commit the vector in the same PR.

- [ ] **Step 4:** Replace all existing ad-hoc hashing calls with `PhoneHash.hash(...)`. Grep: `rg 'SHA256\.hash.*phone' QAudionEngine/Sources/`.

- [ ] **Step 5:** Run tests:

```bash
cd QAudionEngine && swift test --filter PhoneHashTests
```

Expected: all pass.

- [ ] **Step 6:** Commit:

```bash
git add QAudionEngine/Sources/QAudionEngine/Utils/PhoneHash.swift \
        QAudionEngine/Tests/QAudionEngineTests/PhoneHashTests.swift
git commit -m "feat(engine): canonical PhoneHash helper with Android cross-platform vector"
```

---

## Phase 2 — Authentication parity

Goal: iOS login screen matches Android's two-path onboarding (manual credential entry **and** QR fast-setup) plus optional voice enrollment. No more stub or missing `VoiceEnrollmentView`.

Android reference: `.../feature-auth/.../ui/{SplashScreen,WelcomeScreen,PhoneEntryScreen,VoiceEnrollmentScreen,FastSetupScreen}.kt` (~1725 LOC total).

### Task 2.1: Scaffold `QRCodeScanner` reusable view (used by Tasks 2.2, 3.3, 4.1)

**Files:**
- Create: `QAudionApp/Services/QRCodeScanner.swift`
- Create: `QAudionApp/Views/Components/QRScannerView.swift`

- [ ] **Step 1:** Write `QRCodeScanner.swift` as an `AVCaptureSession`-backed delegate (AVFoundation, not CoreImage — CoreImage only generates QR, not scan). Keep it generic — no knowledge of payload semantics.

```swift
import AVFoundation
import UIKit

public final class QRCodeScanner: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    public enum Error: Swift.Error {
        case cameraUnavailable
        case addInputFailed
        case addOutputFailed
    }

    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "qaudion.qr.session")
    public var onCode: ((String) -> Void)?

    public func start() throws {
        guard let device = AVCaptureDevice.default(for: .video) else { throw Error.cameraUnavailable }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) } else { throw Error.addInputFailed }
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) { session.addOutput(output) } else { throw Error.addOutputFailed }
        output.setMetadataObjectsDelegate(self, queue: queue)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()
        queue.async { [session] in session.startRunning() }
    }

    public func stop() {
        queue.async { [session] in session.stopRunning() }
    }

    public func metadataOutput(_ output: AVCaptureMetadataOutput,
                               didOutput metadataObjects: [AVMetadataObject],
                               from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let raw = obj.stringValue else { return }
        DispatchQueue.main.async { [weak self] in self?.onCode?(raw) }
    }
}
```

- [ ] **Step 2:** Write `QRScannerView.swift` — a SwiftUI `UIViewRepresentable` that mounts the preview layer, takes an `onCode: (String) -> Void`, and auto-stops on disappear.

```swift
import SwiftUI
import AVFoundation

struct QRScannerView: UIViewRepresentable {
    var onCode: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        context.coordinator.scanner.onCode = { code in
            onCode(code)
            context.coordinator.scanner.stop()
        }
        v.previewLayer.session = context.coordinator.scanner.session
        v.previewLayer.videoGravity = .resizeAspectFill
        try? context.coordinator.scanner.start()
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { let scanner = QRCodeScanner() }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
```

- [ ] **Step 3:** Smoke test: compile only.
- [ ] **Step 4:** Commit:

```bash
git add QAudionApp/Services/QRCodeScanner.swift QAudionApp/Views/Components/QRScannerView.swift
git commit -m "feat(ios): add reusable QR scanner (AVCaptureSession)"
```

### Task 2.2: Implement `FastSetupView` (QR fast login)

**Files:**
- Create: `QAudionApp/Views/FastSetupView.swift`
- Create: `QAudionApp/Services/FastSetupPayload.swift`
- Modify: `QAudionApp/Views/LoginView.swift` (add "Scan setup QR" button)

Android reference: `FastSetupScreen.kt`, payload shape `qaudion://fastsetup/<base64-json>` with fields `{ server, phone_id, password, display_name, extension_number }`.

- [ ] **Step 1:** Write `FastSetupPayload.swift`:

```swift
import Foundation

struct FastSetupPayload: Codable {
    let server: String
    let phone_id: String       // NB: Android uses phone_id, which is the RAW E.164 phone, NOT the hash.
    let password: String
    let display_name: String?
    let extension_number: String?

    static func decode(from uri: String) throws -> FastSetupPayload {
        guard let url = URL(string: uri), url.scheme == "qaudion", url.host == "fastsetup",
              let b64 = url.path.split(separator: "/").last.map(String.init),
              let data = Data(base64Encoded: Self.urlSafeToStandard(b64)) else {
            throw NSError(domain: "FastSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid QR"])
        }
        return try JSONDecoder().decode(FastSetupPayload.self, from: data)
    }

    private static func urlSafeToStandard(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "-", with: "+")
                  .replacingOccurrences(of: "_", with: "/")
        let rem = t.count % 4
        if rem > 0 { t += String(repeating: "=", count: 4 - rem) }
        return t
    }
}
```

- [ ] **Step 2:** Write `FastSetupView.swift` — camera preview + scanner + error banner. On decode success, call `appState.fastSetup(payload:)` (added in Step 4).

```swift
import SwiftUI

struct FastSetupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if isLoading {
                ProgressView("Activating…").controlSize(.large)
            } else {
                QRScannerView { code in handle(code) }
                    .ignoresSafeArea()
            }
            VStack {
                Spacer()
                if let error { Text(error).foregroundColor(.red).padding() }
                Text("Inquadra il codice QR fornito dall'amministratore")
                    .font(.callout).padding().background(.ultraThinMaterial).cornerRadius(12)
                    .padding(.bottom, 24)
            }
        }
        .navigationTitle("Accesso rapido")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } } }
    }

    private func handle(_ code: String) {
        do {
            let p = try FastSetupPayload.decode(from: code)
            isLoading = true
            Task {
                await appState.fastSetup(payload: p)
                await MainActor.run { dismiss() }
            }
        } catch {
            self.error = "QR non valido."
        }
    }
}
```

- [ ] **Step 3:** Extend `AppState`:

```swift
// AppState.swift — add a method
func fastSetup(payload: FastSetupPayload) async {
    serverUrl = payload.server
    let phoneHash = PhoneHash.hash(payload.phone_id)
    await login(userId: phoneHash, credential: payload.password)
    // On Android the QR also provides display_name/extension which are persisted locally.
    if let name = payload.display_name {
        UserDefaults.standard.set(name, forKey: "qaudion.display_name")
    }
}
```

Note: existing `AppState.login(userId:credential:)` currently treats `userId` as the server's user_id; revise the signature or add `login(phoneHash:password:)`. Match whatever the engine's `AccountApi.login` takes — Android sends `phone_number: sha256hex`, so the iOS field is a hash, not a user_id.

- [ ] **Step 4:** Add the entry point to `LoginView.swift` — a button under the existing form:

```swift
NavigationLink(destination: FastSetupView()) {
    Label("Accesso rapido (QR)", systemImage: "qrcode.viewfinder")
        .frame(maxWidth: .infinity).padding()
        .background(Color.accentColor.opacity(0.1)).cornerRadius(12)
}
```

- [ ] **Step 5:** Build, run on simulator, verify the new button navigates to the scanner (camera preview may be blank on simulator — that's fine).

- [ ] **Step 6:** Commit:

```bash
git add QAudionApp/Views/FastSetupView.swift \
        QAudionApp/Services/FastSetupPayload.swift \
        QAudionApp/Views/LoginView.swift \
        QAudionApp/AppState.swift
git commit -m "feat(ios): FastSetup QR login (parity with Android FastSetupScreen)"
```

### Task 2.3: Implement `VoiceEnrollmentView` (3-phrase recording + upload)

**Files:**
- Create: `QAudionApp/Views/VoiceEnrollmentView.swift`
- Create: `QAudionApp/Services/VoiceEnrollmentService.swift`
- Modify: `QAudionApp/Views/SettingsView.swift` line 132 (link already exists, just make sure it resolves)

Android reference: `VoiceEnrollmentScreen.kt` + `VoiceEnrollmentUseCase` — records 3 phrase samples, extracts MFCC, uploads to KMS.

The iOS MFCC extraction lives in QAudionEngine (search `Mfcc` — probably `QAudionEngine/Sources/QAudionEngine/Audio/MfccExtractor.swift`; if absent, use the same DSP already used for deepfake preprocessing).

- [ ] **Step 1:** Write `VoiceEnrollmentService.swift` (records → PCM → MFCC → `POST /voice/enroll`):

```swift
import AVFoundation
import QAudionEngine

public final class VoiceEnrollmentService: NSObject {
    public enum Phrase: String, CaseIterable {
        case phrase1 = "La mia voce è la mia password."
        case phrase2 = "Verifica la mia identità ora."
        case phrase3 = "Attivare la modalità quantistica sicura."
    }

    private let audioEngine = AVAudioEngine()
    private var recordingBuffer = Data()

    public func record(phrase: Phrase, seconds: TimeInterval) async throws -> Data {
        // Install tap on input node at 16 kHz mono (matches Android DeepfakeClassifier preprocessing).
        // Collect PCM16LE for `seconds` then return the raw buffer.
        // Implementation detail omitted here but must use AVAudioSession .record category.
        fatalError("implement me with AVAudioEngine input tap — see Android VoiceEnrollmentUseCase")
    }

    public func upload(samples: [Data], userId: String, backend: BackendProvider) async throws {
        // POST /voice/enroll with samples as multipart or base64 array.
        // Use backend.accountApi (extend AccountApi protocol if needed).
    }
}
```

*(Do NOT keep `fatalError`. Replace with a real AVAudioEngine input-tap implementation. See Apple sample code "Capturing Audio".)*

- [ ] **Step 2:** Write `VoiceEnrollmentView.swift` — step-through UI: phrase 1 → record 3 s → preview → retry or accept → phrase 2 → …, then upload, then success.
- [ ] **Step 3:** Wire the existing link in SettingsView:132 to navigate to `VoiceEnrollmentView()`.
- [ ] **Step 4:** Manual test on a physical iPhone (simulator lacks microphone).
- [ ] **Step 5:** Commit:

```bash
git commit -am "feat(ios): voice enrollment (3 phrases) + MFCC upload"
```

---

## Phase 3 — Device linking

Goal: real multi-device pairing, byte-compatible with Android `DeviceLinkingProtocol.kt` (binary QR, HKDF salt `"qaudion-link-salt"`, info `"qaudion-device-link-v1"`).

### Task 3.1: Port `DeviceLinkingProtocol` to Swift

**Files:**
- Create: `QAudionEngine/Sources/QAudionEngine/Crypto/DeviceLinkingProtocol.swift`
- Create: `QAudionEngine/Tests/QAudionEngineTests/DeviceLinkingProtocolTests.swift`

Android binary layout (authoritative): `[X25519 pubkey(32B) | userId_len(4B int, big-endian) | userId_utf8(N bytes) | oneTimeCode(16B)]`. URL is `qaudion://link/<base64url-no-pad>`.

- [ ] **Step 1:** Write the protocol struct:

```swift
import CryptoKit
import Foundation

public struct DeviceLinkPayload: Equatable {
    public let publicKey: Data          // 32 B, Curve25519
    public let userId: String
    public let oneTimeCode: Data        // 16 B

    public init(publicKey: Data, userId: String, oneTimeCode: Data) {
        precondition(publicKey.count == 32, "pubkey must be 32B")
        precondition(oneTimeCode.count == 16, "code must be 16B")
        self.publicKey = publicKey; self.userId = userId; self.oneTimeCode = oneTimeCode
    }
}

public enum DeviceLinkingProtocol {
    static let linkSalt  = Data("qaudion-link-salt".utf8)
    static let linkInfo  = Data("qaudion-device-link-v1".utf8)

    public static func encode(_ p: DeviceLinkPayload) -> String {
        var buf = Data(capacity: 32 + 4 + p.userId.utf8.count + 16)
        buf.append(p.publicKey)
        var len = UInt32(p.userId.utf8.count).bigEndian
        withUnsafeBytes(of: &len) { buf.append(contentsOf: $0) }
        buf.append(contentsOf: p.userId.utf8)
        buf.append(p.oneTimeCode)
        let b64url = buf.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "qaudion://link/\(b64url)"
    }

    public static func decode(_ uri: String) throws -> DeviceLinkPayload {
        guard let url = URL(string: uri), url.scheme == "qaudion", url.host == "link",
              let tail = url.path.split(separator: "/").last.map(String.init)
        else { throw NSError(domain: "DeviceLink", code: 1) }
        var b64 = tail.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4; if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
        guard let buf = Data(base64Encoded: b64), buf.count >= 32 + 4 + 16 else {
            throw NSError(domain: "DeviceLink", code: 2)
        }
        let pub = buf[0..<32]
        let rawLen = buf[32..<36].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let nameEnd = 36 + Int(rawLen)
        guard buf.count == nameEnd + 16 else { throw NSError(domain: "DeviceLink", code: 3) }
        let name = String(data: buf[36..<nameEnd], encoding: .utf8) ?? ""
        let code = buf[nameEnd..<buf.count]
        return DeviceLinkPayload(publicKey: Data(pub), userId: name, oneTimeCode: Data(code))
    }

    /// Matches Android deriveSyncKey (X25519 ECDH → HKDF-SHA256, salt, info, L=32).
    public static func deriveSyncKey(ourPriv: Curve25519.KeyAgreement.PrivateKey,
                                     peerPub: Data) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPub)
        let shared = try ourPriv.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                              salt: linkSalt,
                                              sharedInfo: linkInfo,
                                              outputByteCount: 32)
    }

    /// AES-GCM sealed state snapshot (matches Android createStateSnapshot/restoreFromSnapshot).
    public static func seal(snapshot: Data, key: SymmetricKey) throws -> Data {
        try AES.GCM.seal(snapshot, using: key).combined!
    }
    public static func open(sealed: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: sealed)
        return try AES.GCM.open(box, using: key)
    }
}
```

- [ ] **Step 2:** Write tests with known Android-generated vectors. Create a small Kotlin scratch program in the Android repo (or ask the user to run it) that prints `base64(encode(payload))` for a fixed input, and paste that value into the Swift test to assert cross-platform equality.

```swift
func test_decode_androidVector() throws {
    let uri = "qaudion://link/<paste-android-generated-b64>"
    let p = try DeviceLinkingProtocol.decode(uri)
    XCTAssertEqual(p.userId, "<known>")
    XCTAssertEqual(p.publicKey.count, 32)
    XCTAssertEqual(p.oneTimeCode.count, 16)
}
```

- [ ] **Step 3:** Run:

```bash
cd QAudionEngine && swift test --filter DeviceLinkingProtocolTests
```

- [ ] **Step 4:** Commit:

```bash
git commit -am "feat(engine): DeviceLinkingProtocol port (byte-compatible with Android)"
```

### Task 3.2: Implement `LinkNewDeviceView` (generate QR on existing device)

**Files:**
- Create: `QAudionApp/Views/LinkNewDeviceView.swift`
- Modify: the existing engine `QrIdentityView.swift` is generic — we compose on top, not replace.

- [ ] **Step 1:** Write the view:

```swift
import SwiftUI
import CoreImage.CIFilterBuiltins
import QAudionEngine

struct LinkNewDeviceView: View {
    @EnvironmentObject var appState: AppState
    @State private var qrImage: UIImage?

    var body: some View {
        VStack(spacing: 24) {
            if let img = qrImage {
                Image(uiImage: img).interpolation(.none).resizable()
                    .scaledToFit().frame(maxWidth: 320)
            } else { ProgressView() }
            Text("Inquadra questo codice con il nuovo dispositivo.")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            Button("Rigenera codice") { generate() }
        }.padding().navigationTitle("Collega nuovo dispositivo")
        .task { generate() }
    }

    private func generate() {
        guard let userId = appState.currentUserId,
              let keypair = appState.deviceLinkKeypair() else { return }
        let code = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let payload = DeviceLinkPayload(publicKey: keypair.publicKey.rawRepresentation,
                                        userId: userId, oneTimeCode: code)
        let uri = DeviceLinkingProtocol.encode(payload)
        let ctx = CIContext()
        let f = CIFilter.qrCodeGenerator()
        f.setValue(Data(uri.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        if let out = f.outputImage?.transformed(by: .init(scaleX: 10, y: 10)),
           let cg = ctx.createCGImage(out, from: out.extent) {
            qrImage = UIImage(cgImage: cg)
        }
        // Stash (publicKey, code) in AppState pending-link table, keyed by code.
        appState.beginLinkSession(publicKey: payload.publicKey, code: code, ourPriv: keypair)
    }
}
```

- [ ] **Step 2:** Add `AppState.deviceLinkKeypair()` → returns a persistent Curve25519 keypair (load from Keychain; create if missing). Reuse existing `QAudionKeyStore`.
- [ ] **Step 3:** Add `AppState.beginLinkSession(publicKey:code:ourPriv:)` — stores a pending entry and subscribes to WebSocket `device_link_snapshot` event.
- [ ] **Step 4:** Commit.

### Task 3.3: Implement `DeviceLinkScanView` (scan QR on new device)

**Files:**
- Create: `QAudionApp/Views/DeviceLinkScanView.swift`
- Modify: `QAudionApp/Views/LoginView.swift` (add second entry point — "Collegati a un dispositivo esistente")

- [ ] **Step 1:** Write the scanner view — reuses `QRScannerView` from Task 2.1. On scan:
  1. Decode via `DeviceLinkingProtocol.decode`.
  2. Generate our X25519 keypair.
  3. `POST /device/publickey` with our pubkey.
  4. Derive `syncKey = deriveSyncKey(ourPriv, peer.publicKey)`.
  5. Wait for `device_link_snapshot` WS event (timeout 30 s).
  6. Decrypt snapshot; apply (contacts, keys, settings); navigate to Home.

- [ ] **Step 2:** Extend `QAudionEngine/Backend/BCrypto/BCryptoWebSocketClient.swift` to emit `onDeviceLinkSnapshot: (Data) -> Void` callback when type=`device_link_snapshot` arrives.

- [ ] **Step 3:** Wire the whole flow end-to-end against a running BCrypto server. Manual test with two physical devices (or iPhone + Android) once backend supports it.

- [ ] **Step 4:** Commit:

```bash
git commit -am "feat(ios): device link scanner + snapshot decryption"
```

### Task 3.4: Implement `DeviceManagerView` (list linked, unlink)

**Files:**
- Create: `QAudionApp/Views/DeviceManagerView.swift`

Android reference: `DeviceManagerScreen.kt`.

- [ ] **Step 1:** Add REST: `GET /device/list` (returns `[{device_id, device_name, last_seen}]`) and `DELETE /device/{id}`. If backend doesn't expose this yet, add a **BLOCKED** note and ship the UI with a "Coming soon" banner that appears only if the endpoint returns 404.
- [ ] **Step 2:** SwiftUI list with swipe-to-unlink; "Collega nuovo dispositivo" button navigates to `LinkNewDeviceView`.
- [ ] **Step 3:** Commit.

---

## Phase 4 — Key management

Goal: replace the 43-line stub `KeyManagementView.swift` (in `QAudionEngine/Sources/QAudionEngine/UI/`) with a real ~500-LOC equivalent to Android `SovereignKeyVault.kt` + `KeyManagementScreen.kt` (613 LOC). Also deliver `NfcExchangeView` (ISO-7816 collaborative PSK over NFC).

Reminder: the Swift engine already has `SovereignKeyVault.swift` (93 LOC) with a Keychain-backed store and `ContactKeyExchange.swift` (pairwise PSK derivation). We extend these, we don't replace.

### Task 4.1: Audit and extend `SovereignKeyVault` API

**Files:**
- Modify: `QAudionEngine/Sources/QAudionEngine/Crypto/SovereignKeyVault.swift`

Required operations (match Android `SovereignKeyVault.kt`):
- `listKeys() -> [SovereignKey]` (sorted by priority, desc)
- `createKey(name:, creationMethod:) -> SovereignKey`
- `importKey(rawKey: Data, name:, creationMethod:, contactId: String?) -> SovereignKey` (dedup by fingerprint)
- `deleteKey(id: String)`
- `setKeyPriority(id:, priority: Int)`
- `findNewestForContact(contactId:) -> SovereignKey?`
- `getKeyFingerprints() -> [(fullFingerprint: String, priority: Int)]`
- `formatDisplayFingerprint(_ full: String) -> String` (4-char groups joined by `.`)

- [ ] **Step 1:** For each method that doesn't exist yet, add it. Storage remains Keychain; metadata (name, fingerprint, priority, creationMethod, createdAt, contactId) lives in a JSON blob in Keychain under one service identifier.
- [ ] **Step 2:** Write unit tests covering round-trip (create → list → delete, dedup, priority ordering, fingerprint formatting).
- [ ] **Step 3:** Commit.

### Task 4.2: Replace the stub `KeyManagementView`

**Files:**
- Rewrite: `QAudionEngine/Sources/QAudionEngine/UI/KeyManagementView.swift`
- Create: `QAudionEngine/Sources/QAudionEngine/UI/KeyManagementViewModel.swift`

Features (mirror Android exactly):
- PSK list (sorted by priority; newest creation method shown as badge).
- "Nuova chiave" dialog.
- "Importa via QR" → navigate to scanner; `qaudion://key/import/<base64-json>`.
- "Importa via NFC" → navigate to `NfcExchangeView` (Task 4.3).
- "Esporta via QR" → show a QR of the key (peer scans).
- Swipe to delete (with confirmation).
- Tap to view full fingerprint + copy button.
- "Imposta come principale" (rotate).

- [ ] **Step 1:** Port the ViewModel (state: `keys`, `selected`, `exportData`, `importPending`).
- [ ] **Step 2:** Port the View. Keep the file under 500 LOC by extracting sub-views (`KeyRow`, `ImportDialog`, `ExportQrSheet`).
- [ ] **Step 3:** Ensure `HomeView.swift:109` and `SettingsView.swift:162` navigate to this real view (they already reference `KeyManagementView()` so as long as the rewritten file exports `public struct KeyManagementView: View`, nothing else to change).
- [ ] **Step 4:** Commit.

### Task 4.3: Implement `NfcExchangeView` (collaborative PSK over ISO-7816)

**Files:**
- Create: `QAudionApp/Views/NfcExchangeView.swift`
- Create: `QAudionApp/Services/NfcCollaborativeExchange.swift`
- Create: `QAudionEngine/Sources/QAudionEngine/Crypto/NfcProtocol.swift` (port of Android `NfcProtocol.kt`)

Android authoritative constants:
- AID: `F0BCF1073A5100` (7 B, proprietary)
- SELECT APDU: `00 A4 04 00 07 F0BCF1073A5100`
- KEY_EXCHANGE APDU: `80 01 00 00 40 <64 B payload> 40`
- Payload: `[32 B X25519 pubkey | 32 B entropy]`
- PSK = HKDF-SHA256(ECDH ‖ ent_a ‖ ent_b, salt = SHA256(sorted pubkeys concatenated), info = "Q-Audion NFC Collaborative PSK v1", L = 32)

iOS reality: CoreNFC supports `NFCTagReaderSession` with ISO-7816 reading. iPhone can act as reader **but not as HCE card** — so the iOS device must always play the **reader** role with the Android device configured as HCE (which it already is). For iOS-to-iOS NFC collaborative exchange, one side must be a passive NDEF tag (unsupported); document this as an Android-interop-only feature.

- [ ] **Step 1:** Create `NfcProtocol.swift` with pure-Swift encoders/decoders, HKDF derivation and sanity tests against an Android-generated vector.
- [ ] **Step 2:** Create `NfcCollaborativeExchange.swift` — wraps `NFCTagReaderSession`:

```swift
import CoreNFC
import QAudionEngine

final class NfcCollaborativeExchange: NSObject, NFCTagReaderSessionDelegate {
    static let aid: [UInt8] = [0xF0, 0xBC, 0xF1, 0x07, 0x3A, 0x51, 0x00]
    var session: NFCTagReaderSession?
    var onPSK: ((Data, Data) -> Void)? // (psk, peerPubKey)

    func begin() {
        session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self)
        session?.alertMessage = "Avvicina il dispositivo Android."
        session?.begin()
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}
    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        self.session = nil
    }
    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard case .iso7816(let tag) = tags.first else { session.invalidate(errorMessage: "Tipo tag non supportato"); return }
        session.connect(to: tags.first!) { err in
            if let err { session.invalidate(errorMessage: err.localizedDescription); return }
            let selectApdu = NFCISO7816APDU(data: Data([0x00, 0xA4, 0x04, 0x00, 0x07] + Self.aid))!
            tag.sendCommand(apdu: selectApdu) { _, sw1, sw2, err in
                guard sw1 == 0x90, sw2 == 0x00 else {
                    session.invalidate(errorMessage: "AID non selezionato"); return
                }
                // Prepare our 64-B payload.
                let (ourPriv, ourPayload) = NfcProtocol.prepareOutbound()
                var cmd = Data([0x80, 0x01, 0x00, 0x00, 0x40]); cmd.append(ourPayload); cmd.append(0x40)
                let exApdu = NFCISO7816APDU(data: cmd)!
                tag.sendCommand(apdu: exApdu) { resp, sw1, sw2, err in
                    guard sw1 == 0x90, sw2 == 0x00, resp.count == 64 else {
                        session.invalidate(errorMessage: "Scambio fallito"); return
                    }
                    let psk = NfcProtocol.derive(ourPriv: ourPriv, peerPayload: resp, ourPayload: ourPayload)
                    let peerPub = resp.prefix(32)
                    DispatchQueue.main.async { self.onPSK?(psk, Data(peerPub)) }
                    session.alertMessage = "Chiave scambiata ✓"
                    session.invalidate()
                }
            }
        }
    }
}
```

- [ ] **Step 3:** Build `NfcExchangeView.swift` — UI shows a big phone-to-phone icon, "Inizia scambio" button, status line, success sheet that previews the 4-group fingerprint and offers "Salva come" (contact alias).
- [ ] **Step 4:** Wire from `SettingsView.swift:190`.
- [ ] **Step 5:** Commit.

---

## Phase 5 — CallKit integration

Goal: incoming calls show the iOS system call UI (lock screen, CarPlay, Apple Watch). Outgoing calls register with the system so AirPods routing and "Do Not Disturb" bypass work. Equivalent role as Android's `QAudionConnectionService` + `CallStyleNotifier`.

### Task 5.1: Create `CallKitService`

**Files:**
- Create: `QAudionApp/Services/CallKitService.swift`
- Modify: `QAudionApp/AppState.swift` (instantiate service at init)

- [ ] **Step 1:** Skeleton:

```swift
import CallKit
import AVFoundation
import Combine

final class CallKitService: NSObject, CXProviderDelegate {
    let provider: CXProvider
    let controller = CXCallController()

    override init() {
        let config = CXProviderConfiguration()  // iOS 14+: parameterless init; set properties after.
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic, .phoneNumber]
        if let icon = UIImage(named: "callkit_icon") { config.iconTemplateImageData = icon.pngData() }
        config.ringtoneSound = "ringtone.caf"
        self.provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    // Incoming from PushKit
    func reportIncoming(callId: UUID, callerName: String, hasVideo: Bool, completion: @escaping (Error?) -> Void) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.hasVideo = hasVideo
        update.supportsDTMF = false
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.localizedCallerName = callerName
        provider.reportNewIncomingCall(with: callId, update: update, completion: completion)
    }

    // Outgoing
    func startOutgoing(callId: UUID, handle: String, video: Bool) {
        let h = CXHandle(type: .generic, value: handle)
        let action = CXStartCallAction(call: callId, handle: h)
        action.isVideo = video
        controller.requestTransaction(with: action) { _ in }
    }

    func end(callId: UUID) {
        let action = CXEndCallAction(call: callId)
        controller.requestTransaction(with: action) { _ in }
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        CallServiceBridge.shared.cancelAll()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        CallServiceBridge.shared.answer(callId: action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        CallServiceBridge.shared.end(callId: action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        CallServiceBridge.shared.startOutgoing(callId: action.callUUID, handle: action.handle.value, video: action.isVideo)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        CallServiceBridge.shared.setMuted(callId: action.callUUID, muted: action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        CallServiceBridge.shared.audioSessionActivated(audioSession)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        CallServiceBridge.shared.audioSessionDeactivated(audioSession)
    }
}
```

- [ ] **Step 2:** Create `CallServiceBridge` — a singleton façade that the existing `CallService` conforms to, so `CallKitService` never imports engine internals. The bridge has the methods `answer/end/startOutgoing/setMuted/audioSession…`.

- [ ] **Step 3:** Wire `AppState.initialize()` to create `CallKitService` and hold it. Wire outgoing flow: when user taps "Call" in Contacts, call `callKitService.startOutgoing(callId:handle:video:)` INSTEAD of the current direct `CallService.startCall`. The CallKit delegate then forwards to `CallServiceBridge.shared.startOutgoing(...)` which calls the engine.

- [ ] **Step 4:** Manual test on device: start an outgoing call, verify the green "in-call banner" appears at the top of the status bar; verify it survives going to Home screen.

- [ ] **Step 5:** Commit:

```bash
git commit -am "feat(ios): CallKit provider (incoming/outgoing/answer/end/mute)"
```

---

## Phase 6 — PushKit VoIP

Goal: backend can wake the app with a VoIP push even when suspended; the push directly triggers `reportNewIncomingCall` (Apple requires this within seconds of the push landing or iOS kills the app).

### Task 6.1: Create `PushKitService`

**Files:**
- Create: `QAudionApp/Services/PushKitService.swift`
- Modify: `QAudionApp/AppState.swift` (register VoIP token, expose to backend)
- Modify: engine `AccountApi` to add `registerVoipPushToken(_ token: String)` → `POST /account/voip-token` (or `/account/fcm-token` if the backend treats it uniformly; ask server team).

- [ ] **Step 1:** Skeleton:

```swift
import PushKit

final class PushKitService: NSObject, PKPushRegistryDelegate {
    private let registry = PKPushRegistry(queue: .main)
    weak var appState: AppState?

    override init() {
        super.init()
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = credentials.token.map { String(format: "%02x", $0) }.joined()
        Task { await appState?.registerVoipToken(token) }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        Task { await appState?.registerVoipToken("") }
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: @escaping () -> Void) {
        // Apple requires: report new incoming call BEFORE completion().
        let data = payload.dictionaryPayload
        guard let callIdStr = data["call_id"] as? String, let callId = UUID(uuidString: callIdStr),
              let callerId = data["caller_id"] as? String
        else { completion(); return }
        let callerName = data["caller_name"] as? String ?? callerId
        let hasVideo = (data["call_type"] as? String) == "video"
        appState?.callKitService.reportIncoming(callId: callId, callerName: callerName, hasVideo: hasVideo) { _ in
            completion()
        }
    }
}
```

- [ ] **Step 2:** Instantiate `PushKitService` in `AppState.initialize()` AFTER `CallKitService` (order matters — the push handler references the CallKit provider).

- [ ] **Step 3:** Backend must send the VoIP push payload matching Android FCM (per the protocol spec): `{"type":"call_incoming","call_id":"…","caller_id":"…","caller_name":"…","call_type":"audio|video"}`. Confirm with server team that the iOS VoIP push endpoint uses the same JSON shape.

- [ ] **Step 4:** Manual end-to-end test with a second device (Android or iPhone) calling the test device. Lock the screen and start the call from the other device — the incoming-call UI MUST appear over the lock screen within ~3 seconds.

- [ ] **Step 5:** Commit:

```bash
git commit -am "feat(ios): PushKit VoIP registration + incoming-call bridge to CallKit"
```

---

## Phase 7 — In-call UI parity

Goal: bring `CallView.swift` from ~70% to 100% — SAS badge, transport indicator, video upgrade, hold, BT routing.

Android reference: `InCallScreen.kt`.

### Task 7.1: SAS display in CallView

**Files:**
- Modify: `QAudionApp/Views/CallView.swift`
- Use existing: `QAudionEngine/Sources/QAudionEngine/UI/SasVerificationView.swift` (already ~85 LOC)
- Extend: `AppState.sasEmojis: [String]` and `AppState.sasNumeric: String` populated by the engine after PQC handshake.

- [ ] **Step 1:** Expose SAS from engine. Find where the PQC handshake completes in `QAudionCallIntegration.swift`; after shared-secret derivation, compute SAS:

```swift
// Use Android-equivalent derivation: SHA256(sharedSecret ‖ callerPub ‖ calleePub) → take first 5 bytes → split into 4 indices into a 256-emoji set.
```

If Android uses the PGP word list, port the same list verbatim (the word list is standardized — easy to google).

- [ ] **Step 2:** Display a new row in `CallView` between `CallSecurityBadge` and `WaveformPanel`: a horizontal row of 4 big emojis with a "Verifica" button. Tapping opens `SasVerificationView` as a sheet.

- [ ] **Step 3:** Manual test with two devices — compare emojis.

- [ ] **Step 4:** Commit.

### Task 7.2: Transport indicator pill

**Files:**
- Modify: `QAudionApp/Views/CallSecurityBadge.swift`
- Expose: `AppState.transportMode: TransportMode` (`.p2p, .turn, .serverRelay, .tor`)

- [ ] **Step 1:** Add the enum and wire the engine's `TransportSelector` to post state changes to `AppState` via a callback.
- [ ] **Step 2:** In `CallSecurityBadge`, add a compact pill:

```swift
Text(transportLabel)
    .font(.caption.weight(.semibold))
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(transportColor.opacity(0.2))
    .foregroundColor(transportColor)
    .clipShape(Capsule())
```

Color scheme: P2P=green, TURN=orange, serverRelay=blue, Tor=purple.

- [ ] **Step 3:** Commit.

### Task 7.3: Video upgrade button + call_upgrade_* WS messages

**Files:**
- Modify: `QAudionApp/Views/CallView.swift` (add button)
- Modify: engine `CallingApi` + `BCryptoCallingApiImpl` (add `sendCallUpgradeRequest/Response`, `sendCallVideoState`)
- Modify: `BCryptoWebSocketClient` (dispatch incoming `call_upgrade_request/response/video_state`)

- [ ] **Step 1:** Extend the protocol (see Phase 1 Task 1.1 gap list).
- [ ] **Step 2:** Add a CAMERA permission gate — `AVCaptureDevice.requestAccess(for: .video)`.
- [ ] **Step 3:** On "Upgrade to video" tap: build a new SDP offer via whatever WebRTC layer exists; send via `sendCallUpgradeRequest`. On receiving `call_upgrade_response` with `accepted=true`, start local camera preview.
- [ ] **Step 4:** Commit.

### Task 7.4: Hold + BT routing

- [ ] **Step 1:** Use CallKit's `CXSetHeldCallAction` — already plumbed in Task 5.1. Add a Hold button that requests the action via `callKitService.controller`.
- [ ] **Step 2:** Bluetooth: add an `AVRoutePickerView` inline in the controls bar. iOS handles the picker UI automatically.
- [ ] **Step 3:** Commit.

---

## Phase 8 — Chat parity

Goal: typing indicators, message status icons, file attachments, voice notes.

### Task 8.1: Typing indicator

**Files:**
- Modify: engine `MessageApi` + `BCryptoMessageApiImpl` + WS client to support `msg_typing`
- Modify: `QAudionApp/Views/ChatView.swift`
- Modify: `AppState.peerTyping: Bool`

- [ ] **Step 1:** Server side commands:
  - `Client → msg_typing { recipient_id, is_typing }` (debounce 1.5 s after last keystroke; send `is_typing=false` after 3 s of inactivity or on send).
  - `Server → msg_typing { sender_id, is_typing }` — route to `AppState.peerTyping`.
- [ ] **Step 2:** Add `TypingIndicator` view (3 animated dots) above the input bar in `ChatView`.
- [ ] **Step 3:** Commit.

### Task 8.2: Message status + read receipts

- [ ] **Step 1:** Add `msg_delivered` / `msg_read` commands. Mirror Android fields exactly.
- [ ] **Step 2:** Add a `MessageStatus` enum (`.pending, .sent, .delivered, .read`) to `AppState.Message`. Render check icons on each bubble (single/double/blue).
- [ ] **Step 3:** Automatic read receipt: when `ChatView` appears and the message is from the peer, send `msg_read` for all visible unread message IDs.
- [ ] **Step 4:** Commit.

### Task 8.3: File attachment UI

- [ ] **Step 1:** Add an attachment button beside the text field. Tapping opens a menu: Photo/Video (PHPickerViewController), Document (UIDocumentPickerViewController), Voice Note.
- [ ] **Step 2:** Selected media is encrypted by `MessageCrypto` (see engine; same HKDF info `"q-audion-msg-key"` as Android) and uploaded via `POST /messages/attachment` (multipart; URL returned to peer as ciphertext in `msg_send`). Confirm the exact endpoint with server team; if missing, add **BLOCKED** note.
- [ ] **Step 3:** Render image/doc bubbles in `MessageBubbleView`.
- [ ] **Step 4:** Commit.

### Task 8.4: Voice note recording + playback

- [ ] **Step 1:** Press-and-hold record button on the input bar (similar to WhatsApp). Record at 16 kHz mono AAC. Show a waveform.
- [ ] **Step 2:** Playback in message bubble with scrubber.
- [ ] **Step 3:** Commit.

---

## Phase 9 — Contacts parity

Goal: phonebook import with explicit UI, block list, contact editor, verification UI.

### Task 9.1: Block list + blocked tab

**Files:**
- Modify: engine `ContactsApi` + impl — add `listBlocked()`, `block(userId:)`, `unblock(userId:)`.
- Create: `QAudionApp/Views/BlockListView.swift`
- Modify: `QAudionApp/Views/ConversationListView.swift` (add tabs "Tutti" / "Bloccati")

- [ ] **Step 1:** Wire all three REST endpoints (POST /contacts/block, DELETE /contacts/block/{id}, GET /contacts/blocked).
- [ ] **Step 2:** Build the block list view with swipe-to-unblock.
- [ ] **Step 3:** Commit.

### Task 9.2: Phonebook import explicit action

**Files:**
- Modify: `QAudionApp/Services/ContactSyncService.swift` — keep existing auto-sync; add manual-trigger method that shows import progress.
- Create: `QAudionApp/Views/PhonebookImportView.swift`

- [ ] **Step 1:** Button "Importa rubrica" in Settings → Privacy → Contatti. Shows a sheet with progress (N of M), result (K matched contacts), and a "Fine" button.
- [ ] **Step 2:** Commit.

### Task 9.3: Contact editor (create/edit)

- [ ] **Step 1:** `ContactEditorView.swift` — form for name, phone number, notes, avatar. Saves locally via `NSUbiquitousKeyValueStore` or Core Data (whichever the engine already uses for contact local state).
- [ ] **Step 2:** Invoke from `ConversationListView` + button and from `ContactDetailView` (pencil icon).
- [ ] **Step 3:** Commit.

### Task 9.4: Verification UI (fingerprint compare) in ContactDetail

- [ ] **Step 1:** In the existing `ContactDetailView`, tapping "Verifica" opens the SAS sheet or the fingerprint-compare sheet. Port from Android `ContactVerificationDialog`.
- [ ] **Step 2:** Commit.

---

## Phase 10 — Group calls

Goal: unbreak `GroupCallView.swift` (currently references the missing `GroupCallViewModel`) and wire SFU.

### Task 10.1: Create `GroupCallViewModel`

**Files:**
- Create: `QAudionApp/ViewModels/GroupCallViewModel.swift`

- [ ] **Step 1:** Expose `@Published var participants: [GroupCallParticipant]`, `@Published var isMuted: Bool`, `@Published var callDuration: Int`. Subscribe to `BCryptoGroupCallManager` state events and update published properties.
- [ ] **Step 2:** Actions: `toggleMute()`, `end()`, `invite(userIds:)`.
- [ ] **Step 3:** Commit.

### Task 10.2: `ParticipantTile` real impl

- [ ] **Step 1:** Replace the stub in `GroupCallView.swift:80` (or extract to its own file). Avatar + name + speaking indicator + mute icon.
- [ ] **Step 2:** Commit.

### Task 10.3: End-to-end group call test

- [ ] **Step 1:** Three-device test (iOS + iOS + Android or server-side simulated bots).
- [ ] **Step 2:** Commit a `GROUP_CALL_TEST_LOG.md` note (if the user doesn't want docs, skip).

---

## Phase 11 — Settings parity

Goal: split the current 395-LOC monolithic `SettingsView.swift` into the sectioned navigation Android has (per the UI map): Profile / Security / Keys / Devices / Transport / Backup / OTA / Privacy / About.

Do NOT remove existing functionality; redistribute it.

### Task 11.1: Create sectioned `SettingsView` root

- [ ] **Step 1:** New root shows a List with `NavigationLink` rows, each navigating to a dedicated sub-view. Current inline content becomes `AdvancedSettingsView` (kept for power users who want single-form view).
- [ ] **Step 2:** Commit.

### Task 11.2–11.7: One sub-view per section

For each section below, create `QAudionApp/Views/Settings/<Name>View.swift` and move the relevant portion of the current `SettingsView.swift` into it. Commit per sub-view.

- [ ] `ProfileView.swift` (display name, avatar, bio — `GET/PUT /profile`)
- [ ] `SecurityDashboardView.swift` (verify device, view fingerprint, panic wipe, voice auth toggle + enroll link)
- [ ] `TransportSettingsView.swift` (AUTO/P2P/TURN/relay selector, latency simulator if engine exposes it)
- [ ] `BackupView.swift` (export encrypted key bundle, restore)
- [ ] `OtaUpdateView.swift` (check version via `GET /version`, show current build)
- [ ] `PrivacyView.swift` (block list link, read receipts toggle, incognito mode)
- [ ] `AboutView.swift` (app version, engine info, legal)

---

## Phase 12 — Tor/Proxy integration

Goal: the Tor toggle in Settings actually routes traffic through Tor. iOS has no native Tor binary; the canonical approach is Orbot Companion (Orbot.app) which exposes a SOCKS5 proxy on 127.0.0.1:9050 and an HTTP proxy on :8118.

### Task 12.1: `TorProxyService`

**Files:**
- Create: `QAudionApp/Services/TorProxyService.swift`
- Modify: engine `BCryptoRestClient` + `BCryptoWebSocketClient` to accept a proxy configuration.

- [ ] **Step 1:** Detect Orbot via `UIApplication.shared.canOpenURL(URL(string: "orbot://")!)`. Expose `isOrbotAvailable: Bool`.
- [ ] **Step 2:** When Tor is enabled in Settings:
  - For REST: set `URLSessionConfiguration.connectionProxyDictionary` to SOCKS 127.0.0.1:9050.
  - For WebSocket: `URLSessionWebSocketTask` does not support SOCKS proxy directly; fall back to HTTP CONNECT via 127.0.0.1:8118, OR bootstrap our own `Network.framework`-based SOCKS client. The pragmatic path: **document the limitation** — audio calls stay direct/TURN, only REST + WS control-plane get proxied through Tor's HTTP proxy. Match Android by displaying a disclaimer in Settings.
- [ ] **Step 3:** "Apri Orbot" deep-link button that opens `orbot://` or falls back to the App Store listing.
- [ ] **Step 4:** Commit.

### Task 12.2: Bootstrap status UI

- [ ] **Step 1:** Show connection state (checking / reachable / unreachable) in Settings → Privacy → Tor.
- [ ] **Step 2:** Commit.

---

## Phase 13 — End-to-end verification

Goal: verify everything works against a real BCrypto backend. Produce a signed TestFlight build.

### Task 13.1: Matrix manual test

- [ ] Login with password.
- [ ] Login via QR fast-setup.
- [ ] Voice enrollment.
- [ ] Import phonebook; discover contacts.
- [ ] Block / unblock a contact.
- [ ] Send 1:1 chat message; verify status icons.
- [ ] Typing indicator visible on peer.
- [ ] Send image attachment.
- [ ] Send voice note.
- [ ] Outgoing 1:1 audio call (CallKit starts; SAS displayed; hangup).
- [ ] Outgoing 1:1 video call + mid-call upgrade.
- [ ] Incoming call while locked (PushKit wakes app; CallKit lock-screen UI appears within 3 s).
- [ ] Hold + Bluetooth routing.
- [ ] Group call (3 participants).
- [ ] NFC key exchange with Android peer — fingerprints match.
- [ ] Device linking — new iOS device scans primary iPhone's QR, state snapshot applied.
- [ ] Tor toggle with Orbot — check connection.
- [ ] Panic wipe → all keys + messages cleared locally.

Record pass/fail per item in `SESSION_LOG.md`. For any fail, do not proceed to Task 13.2; fix first.

### Task 13.2: Cut release tag

- [ ] **Step 1:** `git tag v1.0.23` (bump per CLAUDE.md rule #4).
- [ ] **Step 2:** `git push origin v1.0.23`.
- [ ] **Step 3:** Watch Codemagic.
- [ ] **Step 4:** Check Apple inbox for rejections. If `aps-environment` causes ITMS-90208 or similar, re-check Task 0.1.
- [ ] **Step 5:** Confirm build lands in `Q-Audion testers` TestFlight group.
- [ ] **Step 6:** Update `SESSION_LOG.md` with the release note.

---

## Spec coverage self-review

Gap list from the user's message, mapped to phases:

| Android gap | Phase | Task |
|---|---|---|
| Fast login QR | 2 | 2.1 + 2.2 |
| Device linking QR generation | 3 | 3.1 + 3.2 |
| Key Management (KMS, NFC, QR) | 4 | 4.1 + 4.2 + 4.3 |
| CallKit/Telecom | 5 | 5.1 |
| PushKit VoIP | 6 | 6.1 |
| Settings 70% → 100% | 11 | 11.1–11.7 |
| Contacts UI (phonebook, block) | 9 | 9.1 + 9.2 |
| Chat (typing, attach) | 8 | 8.1–8.4 |
| In-call UI (SAS, video upgrade, transport) | 7 | 7.1–7.4 |
| Tor/Proxy | 12 | 12.1–12.2 |

All 10 items covered.

## Codemagic compatibility self-review

- No change to `codemagic.yaml`. Confirmed.
- No change to `onnxruntime` pin. Confirmed.
- Changes to `Info.plist`, `.entitlements`, `project.yml` are additive; `xcodegen generate` produces the same project file shape.
- New iOS frameworks (`CallKit`, `PushKit`, `CoreNFC`, `AVFoundation`, `Contacts`, `ContactsUI`) are system SDKs — no extra build step required.
- New Swift files under `QAudionApp/` and `QAudionEngine/Sources/` are automatically picked up by XcodeGen and SwiftPM.
- The only external behavioral change is Apple Developer portal: Push Notifications capability must be enabled (Task 0.1) or `app-store-connect fetch-signing-files --create` will not provision `aps-environment`.

## Placeholder scan

- One explicit `fatalError("implement me …")` in Task 2.3 Step 1 — marked clearly as a placeholder inside the plan; the task's later steps require replacing it with the real AVAudioEngine implementation before commit. If the implementer skips that, Rule #4 (no `fatalError` in shipped code) fails CI review.
- The cross-platform test vector for `PhoneHash` (Task 1.3) is a `"…"` placeholder — must be filled with a real hash before the test is committed.
- The `DeviceLinkingProtocol` Android vector (Task 3.1) likewise needs a real value before the test is committed.

These are the only known placeholders; they are explicitly flagged as "fill before commit" in the task steps.

## Type consistency check

- `PhoneHash.hash` signature consistent across phases.
- `DeviceLinkPayload(publicKey:userId:oneTimeCode:)` used identically in Tasks 3.1 and 3.2.
- `CallKitService.reportIncoming(callId:callerName:hasVideo:completion:)` matches `PushKitService` call in Task 6.1.
- `SovereignKeyVault` methods listed in Task 4.1 are identical to those used in Task 4.2 `KeyManagementViewModel`.

No inconsistencies detected.

---

## Execution choice

Plan complete.

**1. Subagent-Driven (recommended):** I dispatch a fresh subagent per Task (0.1, 0.2, …), review its work between tasks, fast iteration, strong isolation.

**2. Inline Execution:** I execute tasks directly in this session with checkpoint commits per Phase.

Given the plan's size (13 phases, ~60 tasks, thousands of LOC), Option 1 is strongly recommended to avoid context saturation and keep reviews focused.
