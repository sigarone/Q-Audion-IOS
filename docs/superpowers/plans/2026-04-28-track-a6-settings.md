# Track A.6 — Settings 11-Section Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Replace the single `SettingsView.swift` with a hub view + 11 sub-screens matching Android. Each sub-screen consumes a dedicated ViewModel (defined in this plan, since the Foundation Sprint deferred Settings VMs). Pure UI restructure — no new wire calls except where each sub-screen exposes already-frozen REST/WS reads.

**Architecture:** `SettingsHubView` lists 11 sections with chevron navigation. Each section pushes a sub-screen. Sub-screens own their own `*ViewModel` (defined here, in `QAudionEngine/UI/ViewModels/Settings/`) bound via `@StateObject` containers in `QAudionApp/Views/Settings/`. Where data comes from server (e.g. Account profile, Device list), containers fetch on appear and refresh on pull-to-refresh.

**Tech Stack:** SwiftUI (iOS 16+), Combine for reactive bindings, no new SPM deps. Reuses `KeyManagementViewModel` (F1.2) + `DeviceManagementViewModel` (F1.3) for sections 10 + 3.

**Predecessor:** Foundation Sprint (`KeyManagementViewModel`, `DeviceManagementViewModel`). Spec: §7 A.6 + §6.2 (11-section list).

---

## Reference paths

| What | Path |
|---|---|
| Existing SettingsView | `QAudionApp/Views/SettingsView.swift` |
| Engine SecuritySettingsView (existing) | `QAudionEngine/Sources/QAudionEngine/UI/SecuritySettingsView.swift` |
| Engine SecurityDashboardView | `QAudionEngine/Sources/QAudionEngine/UI/SecurityDashboardView.swift` |
| Android Settings reference | `D:\users\f10379a\DEV APP\BCRYPTO\apps\qaudion-android-new\feature\feature-settings\src\main\java\com\bcrypto\qaudion\feature\settings\` |
| Existing F1 VMs to reuse | `QAudionEngine/Sources/QAudionEngine/UI/ViewModels/{KeyManagementViewModel,DeviceManagementViewModel}.swift` |

## D-05 hygiene

`SettingsView.swift` is in `QAudionApp/Views/` (NOT USER-WT). All work safe.

---

## The 11 sections (Android parity)

| # | Section | Sub-screen | Existing iOS file? | New ViewModel needed? |
|---|---|---|---|---|
| 1 | Account | profile editor (display name, avatar, phone, extension) | NO | YES — `AccountSettingsViewModel` |
| 2 | Security Dashboard | key state / device verification / wipe status | YES (engine) | YES — `SecurityDashboardViewModel` |
| 3 | Device Manager | linked devices list + revoke + link new | NO | REUSE `DeviceManagementViewModel` |
| 4 | Privacy | read receipts / typing / blocked list / disappearing-messages | NO | YES — `PrivacySettingsViewModel` |
| 5 | Calls | codec / AEC-NS-AGC / VoIP background | NO | YES — `CallsSettingsViewModel` |
| 6 | Chat | read receipts / typing | NO | YES — `ChatSettingsViewModel` |
| 7 | Notifications | ringtone / quiet hours | NO | YES — `NotificationsSettingsViewModel` |
| 8 | Storage / Backup | `.qabk` upload + restore | NO | YES — `BackupSettingsViewModel` (BLOCKED on §10 backup format incompatibility) |
| 9 | About | version / compliance / legal | NO | YES — `AboutSettingsViewModel` |
| 10 | Key Management | identity QR + rotation + backup | YES (engine) | REUSE `KeyManagementViewModel` |
| 11 | Transport | AUTO / P2P / TURN / Relay | NO | YES — `TransportSettingsViewModel` |

---

## Phase A — ViewModels (TDD per VM)

### Task A.1: AccountSettingsViewModel

**Files:**
- Create: `QAudionEngine/Sources/QAudionEngine/UI/ViewModels/Settings/AccountSettingsViewModel.swift`
- Create: `QAudionEngine/Tests/QAudionEngineTests/UI/Settings/AccountSettingsViewModelTests.swift`

```swift
public struct AccountSettingsViewModel: ViewModelProtocol {
    public let userId: String
    public let phoneHash: String  // §5.1
    public let displayName: String?
    public let statusMessage: String?
    public let avatarUrl: URL?
    public let extension_: String?  // dial-by-extension number

    public init(...) { ... }
    public static let mock = AccountSettingsViewModel(
        userId: "user-aabbccdd-...",
        phoneHash: "abc123...",
        displayName: "Pavel",
        statusMessage: "Working remotely",
        avatarUrl: nil,
        extension_: "4242"
    )
}
```

Tests pin determinism + that `phoneHash.count == 64` (§5.1).

### Task A.2: SecurityDashboardViewModel

```swift
public struct SecurityDashboardViewModel: ViewModelProtocol {
    public enum KeyHealth: Sendable, Equatable { case healthy, rotationDue, compromised }

    public let identityFingerprint: String  // §5.1
    public let keyHealth: KeyHealth
    public let lastKeyRotation: Date?
    public let pqcAlgorithm: String  // "ML-KEM-1024"
    public let unverifiedContacts: Int
    public let activeThreatReports: Int
    public let wipeRequestPending: Bool

    public static let mock = SecurityDashboardViewModel(
        identityFingerprint: "a3f7.c291.8b4e.d012",
        keyHealth: .healthy,
        lastKeyRotation: Date(timeIntervalSince1970: 1_744_000_000),
        pqcAlgorithm: "ML-KEM-1024",
        unverifiedContacts: 2,
        activeThreatReports: 0,
        wipeRequestPending: false
    )
}
```

Tests pin determinism, fingerprint format, pqcAlgorithm = "ML-KEM-1024".

### Task A.3-A.9: PrivacySettings / CallsSettings / ChatSettings / NotificationsSettings / BackupSettings / AboutSettings / TransportSettings

Each follows the same pattern: pure-Swift struct conforming to `ViewModelProtocol`, with deterministic `.mock`. Each gets 2-4 unit tests pinning determinism + structural invariants (e.g. PrivacySettings.disappearingMessagesDuration ∈ {0, 60, 3600, 86400, 604800}).

**BackupSettings is BLOCKED** by spec §10 / `INVARIANTS_VERIFIED.md` "Open discrepancies §10" (Desktop QABK ↔ Android QAUD container incompatibility). Mock can ship; the actual upload/download flow is gated until iOS/Android/Desktop converge on a single container layout. Document this clearly in `BackupSettingsViewModel.swift`'s docstring.

**TransportSettings.mode ∈ {auto, p2p, turn, relay}** — matches Android `TransportSettingsScreen`.

---

## Phase B — Containers + sub-screens

### Task B.1: SettingsHubView

**Files:**
- Modify: `QAudionApp/Views/SettingsView.swift` → rename mentally to "SettingsHubView" but keep the file name to avoid breaking imports. Replace body with a `List` of NavigationLink to sub-screens.

```swift
import SwiftUI
import QAudionEngine

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    NavigationLink("Profile") { AccountSettingsScreen(state: state) }
                    NavigationLink("Security") { SecurityDashboardScreen(state: state) }
                    NavigationLink("Devices") { DeviceManagementScreen(state: state) }
                }
                Section("Privacy & Comms") {
                    NavigationLink("Privacy") { PrivacySettingsScreen(state: state) }
                    NavigationLink("Calls") { CallsSettingsScreen(state: state) }
                    NavigationLink("Chat") { ChatSettingsScreen(state: state) }
                    NavigationLink("Notifications") { NotificationsSettingsScreen(state: state) }
                }
                Section("Storage & Keys") {
                    NavigationLink("Backup") { BackupSettingsScreen(state: state) }
                    NavigationLink("Key Management") { KeyManagementScreen(state: state) }
                }
                Section("System") {
                    NavigationLink("Transport") { TransportSettingsScreen(state: state) }
                    NavigationLink("About") { AboutSettingsScreen(state: state) }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
```

### Task B.2-B.10: 9 sub-screens

Each sub-screen follows the same shape:
1. `*Container: ObservableObject` in `QAudionApp/Views/Settings/` wrapping the engine VM.
2. `*Screen: View` consuming the container.
3. Where the screen edits values (e.g. PrivacySettings toggles), container persists via `UserDefaults` for local-only or via REST/WS for server-synced.

Reuse:
- `DeviceManagementScreen` consumes `DeviceManagementContainer` (wraps `DeviceManagementViewModel` from F1.3) + `BCryptoDeviceListClient` (A.2.C.1 if landed; else local-only mode).
- `KeyManagementScreen` consumes `KeyManagementContainer` (wraps `KeyManagementViewModel` from F1.2).

---

## Phase C — Closeout

### Task C.1: STATUS + TASK_LOG, optional `v1.0.29-a6` tag.

Document `BackupSettings` BLOCKED status; A.6 ships UI but actual backup upload/download wired only after Open Discrepancy §10 (`.qabk` container format) is resolved.

---

## Self-review checklist

- [ ] **Spec coverage:** all 11 Android sections mapped 1:1 in iOS Settings hub. iOS-specific section "Network Simulator" (Android has it as dev-only) is INTENTIONALLY OMITTED from this plan.
- [ ] **VM reuse:** F1.2 `KeyManagementViewModel` → section 10. F1.3 `DeviceManagementViewModel` → section 3. No code duplication.
- [ ] **Backup gap:** §10 `.qabk` discrepancy explicitly documented as a blocker on the upload/download path; mock + UI ship anyway.
- [ ] **D-05 hygiene:** all changes in `QAudionApp/Views/Settings/` and `QAudionEngine/UI/ViewModels/Settings/`. None in USER-WT files.
- [ ] **No SwiftUI/Combine in QAudionEngine** — VMs are pure value types; containers in App layer.
