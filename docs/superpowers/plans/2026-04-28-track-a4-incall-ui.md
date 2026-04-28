# Track A.4 — In-call UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Replace partial `CallView.swift` with a new `InCallView` that renders the 7 in-call elements (security badge, waveform TX/RX/Cipher, timer, peer info, controls, video PiP placeholder, SAS prompt) per spec §6.1 + Android reference. Audio-only scope; video-upgrade flow deferred to Track B.

**Architecture:** Pure SwiftUI screen consuming `InCallViewModel` (F1.5) + `SasVerificationViewModel` (F1.6) via `@StateObject` containers. Reuses existing `WaveformView` + `CallSecurityBadge`. App-level `CallView.swift` remains the navigation entry point but its body is replaced with `InCallView(viewModel:)`. CallKit drives state via callbacks from A.3.

**Tech Stack:** SwiftUI (iOS 16+), Combine for async-update streams, `Charts` framework not used (waveforms are custom Path-based). XCTest snapshot tests via SnapshotTesting library — **DEFERRED** to a later test plan if SnapshotTesting is not already a dep. For now, manual visual review.

**Predecessor:** Foundation Sprint F1.5 (InCallViewModel) + F1.6 (SasVerificationViewModel). Spec: §7 A.4 + §6.1 7-elements list.

---

## Reference paths

| What | Path |
|---|---|
| Existing CallView (App layer) | `QAudionApp/Views/CallView.swift` |
| Existing CallSecurityBadge | `QAudionApp/Views/CallSecurityBadge.swift` |
| Existing WaveformView | `QAudionApp/Views/WaveformView.swift` |
| InCallViewModel | `QAudionEngine/Sources/QAudionEngine/UI/ViewModels/InCallViewModel.swift` |
| SasVerificationViewModel | `QAudionEngine/Sources/QAudionEngine/UI/ViewModels/SasVerificationViewModel.swift` |
| Existing engine SasVerificationView | `QAudionEngine/Sources/QAudionEngine/UI/SasVerificationView.swift` |
| Android in-call reference | `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-android-new\feature\feature-call\src\main\java\com\bcrypto\qaudion\feature\call\ui\InCallScreen.kt` |

## D-05 hygiene

`CallView.swift` is in `QAudionApp/Views/` (NOT USER-WT). `WaveformView.swift` and `CallSecurityBadge.swift` are also App-layer. All edits in this plan are safe.

`CallingApi.swift` and `BCryptoCallingApiImpl.swift` ARE USER-WT — do not modify. Use their public protocol surface only.

---

## Phase A — Container + 1:1 binding

### Task A.1: InCallContainer @StateObject wrapper

**Files:**
- Create: `QAudionApp/Views/InCallContainer.swift`
- Create: `QAudionApp/Tests/InCallContainerTests.swift` (if test target exists; else skip)

The container marries `InCallViewModel` (engine value type) with SwiftUI's reactive system. Owns a Combine pipeline that updates the model from CallService.

- [ ] **Step 1:** Implementation:

```swift
import SwiftUI
import Combine
import QAudionEngine

@MainActor
final class InCallContainer: ObservableObject {

    @Published private(set) var viewModel: InCallViewModel

    private var cancellables: Set<AnyCancellable> = []
    private let callService: CallService
    private let callId: UUID

    init(callService: CallService, callId: UUID, initial: InCallViewModel = .mock) {
        self.callService = callService
        self.callId = callId
        self.viewModel = initial
        bind()
    }

    private func bind() {
        callService.$callDuration(forCallId: callId)
            .receive(on: RunLoop.main)
            .sink { [weak self] dur in self?.update { $0.callDuration = dur } }
            .store(in: &cancellables)
        callService.waveformPublisher(forCallId: callId)
            .receive(on: RunLoop.main)
            .sink { [weak self] w in
                self?.update {
                    $0.waveformTx = w.tx
                    $0.waveformRx = w.rx
                    $0.waveformCipher = w.cipher
                }
            }
            .store(in: &cancellables)
        // ... wire security state, controls, etc.
    }

    /// `InCallViewModel` is a value type with all-let properties. Replace the
    /// whole struct on every change.
    private func update(_ mutate: (inout InCallViewModelMutable) -> Void) {
        var copy = viewModel.toMutable()
        mutate(&copy)
        viewModel = copy.toImmutable()
    }

    // User actions:
    func tapMute() { Task { try? await callService.toggleMute(callId: callId) } }
    func tapSpeaker() { Task { try? await callService.toggleSpeaker(callId: callId) } }
    func tapHold() { Task { try? await callService.toggleHold(callId: callId) } }
    func tapEnd() { Task { await callService.endCall(callId: callId) } }
}

/// Pair the immutable view model with a mutable counterpart for incremental
/// updates inside the container. The mutable form is internal-only; the
/// immutable form is what SwiftUI sees.
struct InCallViewModelMutable {
    var peer: InCallViewModel.PeerInfo
    var security: InCallViewModel.SecurityState
    var callDuration: TimeInterval
    var waveformTx: Double
    var waveformRx: Double
    var waveformCipher: Double
    var controls: InCallViewModel.Controls
    var shouldShowSasPrompt: Bool
    var showVideoPip: Bool

    func toImmutable() -> InCallViewModel {
        InCallViewModel(
            peer: peer, security: security, callDuration: callDuration,
            waveformTx: waveformTx, waveformRx: waveformRx, waveformCipher: waveformCipher,
            controls: controls, shouldShowSasPrompt: shouldShowSasPrompt, showVideoPip: showVideoPip
        )
    }
}

extension InCallViewModel {
    func toMutable() -> InCallViewModelMutable {
        InCallViewModelMutable(
            peer: peer, security: security, callDuration: callDuration,
            waveformTx: waveformTx, waveformRx: waveformRx, waveformCipher: waveformCipher,
            controls: controls, shouldShowSasPrompt: shouldShowSasPrompt, showVideoPip: showVideoPip
        )
    }
}
```

> **Caveat — CallService API surface:** `$callDuration(forCallId:)`, `waveformPublisher(forCallId:)`, `toggleMute(callId:)`, etc. may not exist on the current `CallService`. If missing, this task BLOCKS on extending `CallService` (which lives in `QAudionApp/Services/CallService.swift` — verify NOT USER WT first). Document each missing method as a sub-task before proceeding.

- [ ] **Step 2:** Commit.

### Task A.2: InCallView SwiftUI screen

**Files:**
- Create: `QAudionApp/Views/InCallView.swift`

- [ ] **Step 1:** Implementation:

```swift
import SwiftUI
import QAudionEngine

struct InCallView: View {

    @ObservedObject var container: InCallContainer
    @State private var sasContainer: SasVerificationContainer?

    private var vm: InCallViewModel { container.viewModel }

    var body: some View {
        ZStack {
            // Background gradient based on security state
            backgroundGradient.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer().frame(height: 24)

                // (1) Security badge
                CallSecurityBadge(securityState: vm.security)

                // (2) Peer info
                peerInfo

                // (3) Call timer
                Text(timerText)
                    .font(.system(.title2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))

                Spacer()

                // (4) Waveforms
                VStack(spacing: 8) {
                    WaveformView(amplitude: vm.waveformTx, color: .green, label: "TX")
                    WaveformView(amplitude: vm.waveformRx, color: .orange, label: "RX")
                    WaveformView(amplitude: vm.waveformCipher, color: .cyan, label: "Cipher")
                }
                .frame(height: 180)

                Spacer()

                // (5) Controls + (6) end button
                controls
            }
        }
        // (7) SAS prompt sheet
        .sheet(isPresented: Binding(
            get: { vm.shouldShowSasPrompt && sasContainer != nil },
            set: { if !$0 { sasContainer = nil } }
        )) {
            if let sas = sasContainer {
                SasVerificationView(container: sas)
            }
        }
        .onAppear {
            if vm.shouldShowSasPrompt {
                sasContainer = SasVerificationContainer(initial: .mock)  // wire to call session in real impl
            }
        }
    }

    private var peerInfo: some View {
        VStack(spacing: 4) {
            Text(vm.peer.displayName).font(.title)
            Text(vm.peer.fingerprint).font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var timerText: String {
        let total = Int(vm.callDuration)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var backgroundGradient: LinearGradient {
        switch vm.security {
        case .secure:
            return LinearGradient(colors: [.black, Color(red: 0.0, green: 0.15, blue: 0.05)],
                                  startPoint: .top, endPoint: .bottom)
        case .verifying:
            return LinearGradient(colors: [.black, Color(red: 0.15, green: 0.10, blue: 0.0)],
                                  startPoint: .top, endPoint: .bottom)
        case .insecureFallback:
            return LinearGradient(colors: [.black, Color(red: 0.20, green: 0.05, blue: 0.05)],
                                  startPoint: .top, endPoint: .bottom)
        }
    }

    private var controls: some View {
        HStack(spacing: 32) {
            controlButton("mic.slash.fill", on: vm.controls.isMuted) { container.tapMute() }
            controlButton("speaker.wave.2.fill", on: vm.controls.isSpeakerOn) { container.tapSpeaker() }
            controlButton("pause.fill", on: vm.controls.isOnHold) { container.tapHold() }
            Button(action: container.tapEnd) {
                Image(systemName: "phone.down.fill")
                    .font(.title)
                    .padding(20)
                    .background(.red)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
        }
        .padding(.bottom, 48)
    }

    private func controlButton(_ system: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.title2)
                .padding(16)
                .background(on ? .white : .white.opacity(0.15))
                .foregroundStyle(on ? .black : .white)
                .clipShape(Circle())
        }
    }
}

#Preview {
    let container = InCallContainer(callService: .preview, callId: UUID(), initial: .mock)
    return InCallView(container: container)
}
```

- [ ] **Step 2:** Visually verify in Xcode preview (on the engineer's Mac via TestFlight loop or local Xcode). Skip on Windows host — build will be verified by Codemagic.

- [ ] **Step 3:** Commit.

### Task A.3: SasVerificationContainer + SasVerificationView refactor

**Files:**
- Create: `QAudionApp/Views/SasVerificationContainer.swift`
- Modify: `QAudionEngine/Sources/QAudionEngine/UI/SasVerificationView.swift` to consume `SasVerificationViewModel`

Same shape as A.1 but for SAS verification flow. User taps "match" / "mismatch"; container relays to `CallService.recordSasVerdict(callId:verdict:)`.

---

## Phase B — Wire into existing CallView

### Task B.1: Replace CallView body

**Files:**
- Modify: `QAudionApp/Views/CallView.swift`

- [ ] **Step 1:** Replace body with `InCallView(container: InCallContainer(callService: state.callService, callId: callId, initial: ...))`. Keep navigation entry point intact.

- [ ] **Step 2:** Verify navigation still works.

- [ ] **Step 3:** Commit.

---

## Phase C — Closeout

### Task C.1: STATUS + TASK_LOG, optional tag `v1.0.27-a4`.

---

## Self-review checklist

- [ ] **Spec coverage (§6.1 7 elements):**
  1. Security badge ✓ via `CallSecurityBadge` reuse
  2. Waveform TX/RX/Cipher ✓ via `WaveformView` reuse with color triplet
  3. Call timer ✓ derived from `vm.callDuration`
  4. Peer name + avatar — name yes, avatar PLACEHOLDER (no `AsyncImage` yet — flag for follow-up)
  5. Mute/Speaker/Hold/End buttons ✓
  6. Video PiP — placeholder hidden in audio-only A.4 scope ✓
  7. SAS verification prompt ✓ via sheet
- [ ] **CallService API gaps** documented as BLOCKERS with required additions (no auto-extension into USER WT).
- [ ] **No SwiftUI/Combine in QAudionEngine** — container is in `QAudionApp/`, view-model is pure value type.
- [ ] **D-05 hygiene** — `BCryptoCallingApiImpl.swift` not touched.
